package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fixtureRoute struct {
	method, target, body string
	status               int
}

type fixtureAPI struct {
	server   *httptest.Server
	mu       sync.Mutex
	requests []string
	routes   []fixtureRoute
}

// newFixture records actual HTTP requests and rejects unlisted routes or real credentials.
func newFixture(t *testing.T, routes []fixtureRoute) *fixtureAPI {
	t.Helper()
	f := &fixtureAPI{routes: routes}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.requests = append(f.requests, r.Method+" "+r.URL.RequestURI())
		if r.Header.Get("Authorization") != "Bearer offline-fixture-token" {
			t.Errorf("fixture request did not carry the synthetic token")
			w.WriteHeader(401)
			return
		}
		for _, route := range f.routes {
			if route.method == r.Method && route.target == r.URL.RequestURI() {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(route.status)
				_, _ = w.Write([]byte(route.body))
				return
			}
		}
		t.Errorf("unexpected request: %s %s", r.Method, r.URL.RequestURI())
		w.WriteHeader(404)
	}))
	t.Cleanup(f.server.Close)
	return f
}

const fixtureRepo = "/repos/fixture/catalogue"
const query = "?page=1&per_page=100"
const workflowBody = `{"total_count":1,"workflows":[{"id":11,"name":"CI","path":".github/workflows/ci.yaml","state":"active"}]}`
const emptyRuns = `{"total_count":0,"workflow_runs":[]}`

// listing supplies a literal first-page API response.
func listing(path, body string) fixtureRoute { return fixtureRoute{"GET", path + query, body, 200} }

// deletion supplies the selected fixture deletion's HTTP outcome.
func deletion(id int, status int) fixtureRoute {
	return fixtureRoute{"DELETE", fmt.Sprintf("%s/actions/runs/%d", fixtureRepo, id), "", status}
}

// runBody wraps hand-selected records without calculating expected retention decisions.
func runBody(items ...string) string {
	return fmt.Sprintf(`{"total_count":%d,"workflow_runs":[%s]}`, len(items), strings.Join(items, ","))
}

// runJSON gives each fixture run explicit identity, age and completion evidence.
func runJSON(id int, date, status, conclusion string) string {
	return fmt.Sprintf(`{"id":%d,"workflow_id":11,"created_at":%q,"status":%q,"conclusion":%q}`, id, date, status, conclusion)
}

// oldRun is eligible by age, leaving minimum-run retention to the driver.
func oldRun(id int) string { return runJSON(id, "2000-01-01T00:00:00Z", "completed", "success") }

// standardRoutes supplies complete workflow, repository and selected-workflow listings.
func standardRoutes(runs string) []fixtureRoute {
	return []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflowBody), listing(fixtureRepo+"/actions/runs", emptyRuns), listing(fixtureRepo+"/actions/workflows/11/runs", runs)}
}

// baseConfig represents the public workflow's preview defaults.
func baseConfig() config {
	return config{repository: "fixture/catalogue", days: 30, minimum: 6, dryRun: true, states: "ALL", conclusions: "ALL"}
}

var fixedNow = time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC)

// executeFixture exercises the real driver against synthetic HTTP history.
func executeFixture(t *testing.T, cfg config, f *fixtureAPI) (string, error) {
	t.Helper()
	var log bytes.Buffer
	err := clean(context.Background(), cfg, f.server.URL, "offline-fixture-token", f.server.Client(), fixedNow, &log, func(context.Context, time.Duration) error { return nil })
	return log.String(), err
}

// deletions reads the recorder's mutation evidence under its concurrency guard.
func deletions(f *fixtureAPI) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := []string{}
	for _, request := range f.requests {
		if strings.HasPrefix(request, "DELETE ") {
			result = append(result, request)
		}
	}
	return result
}

// A delete rejected by the server must not be swallowed or followed by another mutation.
func TestRejectedDeletionStopsAndFails(t *testing.T) {
	for _, status := range []int{403, 500} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			cfg := baseConfig()
			cfg.dryRun = false
			cfg.minimum = 0
			f := newFixture(t, append(standardRoutes(runBody(oldRun(101), oldRun(102))), deletion(101, status), deletion(102, 204)))
			log, err := executeFixture(t, cfg, f)
			if err == nil || !strings.Contains(err.Error(), "delete run 101") {
				t.Fatalf("rejected deletion reported success: log=%q err=%v", log, err)
			}
			want := []string{"DELETE /repos/fixture/catalogue/actions/runs/101"}
			if got := deletions(f); !reflect.DeepEqual(got, want) {
				t.Fatalf("deletion retried or continued after failure: got %v want %v", got, want)
			}
		})
	}
}

// TestRetentionDryRunAndFilters verifies selected IDs against literal user expectations.
func TestRetentionDryRunAndFilters(t *testing.T) {
	sevenOld := runBody(oldRun(101), runJSON(102, "2000-01-02T00:00:00Z", "completed", "success"), runJSON(103, "2000-01-03T00:00:00Z", "completed", "success"), runJSON(104, "2000-01-04T00:00:00Z", "completed", "success"), runJSON(105, "2000-01-05T00:00:00Z", "completed", "success"), runJSON(106, "2000-01-06T00:00:00Z", "completed", "success"), runJSON(107, "2000-01-07T00:00:00Z", "completed", "success"), runJSON(108, "2026-10-05T00:00:00Z", "completed", "success"))
	tests := []struct {
		name   string
		cfg    config
		runs   string
		want   []string
		notice string
	}{
		{"defaults", baseConfig(), sevenOld, []string{}, "Would delete run 101"},
		{"explicit-dry-run", config{"fixture/catalogue", 0, 0, true, "ci.yaml", "active", "failure"}, runBody(oldRun(101), runJSON(102, "2000-01-01T00:00:00Z", "completed", "failure")), []string{}, "Would delete run 102"},
		{"retain-six-old-plus-recent", config{"fixture/catalogue", 30, 6, false, "", "ALL", "ALL"}, sevenOld, []string{"DELETE /repos/fixture/catalogue/actions/runs/101"}, "Deleted run 101"},
		{"zero-values-and-filters", config{"fixture/catalogue", 0, 0, false, "release, CI.YAML", "disabled_manually,ACTIVE", "failure|cancelled"}, runBody(oldRun(101), runJSON(102, "2026-10-05T00:00:00Z", "completed", "failure"), runJSON(103, "2000-01-01T00:00:00Z", "in_progress", "failure")), []string{"DELETE /repos/fixture/catalogue/actions/runs/102"}, "Deleted run 102"},
		{"age-boundary", config{"fixture/catalogue", 30, 0, false, "", "ALL", "ALL"}, runBody(runJSON(101, "2026-09-06T00:00:00Z", "completed", "success"), runJSON(102, "2026-09-06T00:00:01Z", "completed", "success")), []string{"DELETE /repos/fixture/catalogue/actions/runs/101"}, "Deleted run 101"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			routes := append(standardRoutes(tc.runs), deletion(101, 204), deletion(102, 204))
			f := newFixture(t, routes)
			log, err := executeFixture(t, tc.cfg, f)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(deletions(f), tc.want) || !strings.Contains(log, tc.notice) {
				t.Fatalf("retention result got deletes=%v log=%q, want deletes=%v notice=%q", deletions(f), log, tc.want, tc.notice)
			}
			if tc.cfg.dryRun && strings.Contains(log, "Deleted run") {
				t.Fatalf("dry run claimed a real deletion: %s", log)
			}
		})
	}
}

// Even a later workflow's failed read must prevent deletion from an earlier complete one.
func TestListingFailuresProduceNoWrites(t *testing.T) {
	malformed := []string{
		`{"total_count":1,"workflow_runs":[]}`,
		`{"total_count":2,"workflow_runs":[` + oldRun(101) + `,` + oldRun(101) + `]}`,
		`{"total_count":1,"workflow_runs":[{"id":101,"workflow_id":11,"status":"completed","conclusion":"success","created_at":"broken"}]}`,
		`{"total_count":1,"total_count":0,"workflow_runs":[]}`,
		`{"total_count":1,"workflow_runs":[` + oldRun(101) + `]} trailing`,
	}
	for i, body := range malformed {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			cfg := baseConfig()
			cfg.minimum = 0
			cfg.dryRun = false
			f := newFixture(t, standardRoutes(body))
			_, err := executeFixture(t, cfg, f)
			if err == nil {
				t.Fatal("incomplete or ambiguous listing reported success")
			}
			if len(deletions(f)) != 0 {
				t.Fatal("deletion started with incomplete evidence")
			}
		})
	}
	t.Run("later-workflow", func(t *testing.T) {
		cfg := baseConfig()
		cfg.minimum = 0
		cfg.dryRun = false
		f := newFixture(t, []fixtureRoute{listing(fixtureRepo+"/actions/workflows", `{"total_count":2,"workflows":[{"id":11,"name":"CI","path":".github/workflows/ci.yaml","state":"active"},{"id":22,"name":"Other","path":".github/workflows/other.yaml","state":"active"}]}`), listing(fixtureRepo+"/actions/runs", emptyRuns), listing(fixtureRepo+"/actions/workflows/11/runs", runBody(oldRun(101))), {"GET", fixtureRepo + "/actions/workflows/22/runs" + query, `{"message":"denied"}`, 403}})
		_, err := executeFixture(t, cfg, f)
		if err == nil || len(deletions(f)) != 0 {
			t.Fatalf("partial enumeration mutated history or reported success: %v %v", err, deletions(f))
		}
	})
}

// TestPaginationAndOrphans verifies minimum retention across pages and confirmed orphan selection.
func TestPaginationAndOrphans(t *testing.T) {
	first := []string{}
	for i := 1; i <= 100; i++ {
		first = append(first, oldRun(1000+i))
	}
	f := newFixture(t, []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflowBody), listing(fixtureRepo+"/actions/runs", `{"total_count":1,"workflow_runs":[{"id":900,"workflow_id":99,"created_at":"2000-01-01T00:00:00Z","status":"completed","conclusion":"success"}]}`), listing(fixtureRepo+"/actions/workflows/11/runs", `{"total_count":101,"workflow_runs":[`+strings.Join(first, ",")+`]}`), {"GET", fixtureRepo + "/actions/workflows/11/runs?page=2&per_page=100", runBody(oldRun(1200)), 200}})
	// The second page must retain the same total, even when it contains a single item.
	f.routes[3].body = strings.Replace(f.routes[3].body, `"total_count":1,`, `"total_count":101,`, 1)
	f.routes = append(f.routes, fixtureRoute{"GET", fixtureRepo + "/actions/workflows/99", `{"message":"Not Found"}`, 404})
	cfg := baseConfig()
	cfg.minimum = 100
	log, err := executeFixture(t, cfg, f)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(log, "Would delete run 900") || !strings.Contains(log, "Would delete run 1001") || strings.Contains(log, "Would delete run 1200") {
		t.Fatalf("pagination, minimum or orphan decision changed: %s", log)
	}
}

// TestConfigRejectsInvalidInputs proves invalid caller inputs cannot start cleanup.
func TestConfigRejectsInvalidInputs(t *testing.T) {
	for _, entry := range []struct{ name, value string }{{"INPUT_RETAIN_DAYS", "-1"}, {"INPUT_RETAIN_DAYS", "NaN"}, {"INPUT_KEEP_MINIMUM_RUNS", "1.5"}, {"INPUT_DRY_RUN", "maybe"}, {"INPUT_REPOSITORY", "fixture/catalogue/other"}} {
		t.Run(entry.name+entry.value, func(t *testing.T) {
			env := map[string]string{"INPUT_REPOSITORY": "fixture/catalogue"}
			env[entry.name] = entry.value
			_, err := parseConfig(func(key string) string { return env[key] })
			if err == nil {
				t.Fatal("invalid input admitted")
			}
		})
	}
	cfg, err := parseConfig(func(key string) string {
		if key == "GITHUB_REPOSITORY" {
			return "fixture/catalogue"
		}
		return ""
	})
	if err != nil || !reflect.DeepEqual(cfg, baseConfig()) {
		t.Fatalf("workflow defaults changed: %#v %v", cfg, err)
	}
}

// TestOrphanWorkflowRevalidation protects workflows created between independent listings.
func TestOrphanWorkflowRevalidation(t *testing.T) {
	orphan := `{"id":900,"workflow_id":99,"created_at":"2026-10-05T00:00:00Z","status":"completed","conclusion":"success"}`
	for _, tc := range []struct {
		name, body string
		status     int
		failure    bool
	}{
		{"workflow-appeared", `{"id":99,"name":"New CI","path":".github/workflows/new.yaml","state":"active"}`, 200, false},
		{"read-denied", `{"message":"denied"}`, 403, true},
		{"unconfirmed-absence", `{"message":"different response"}`, 404, true},
		{"malformed-absence", `{"message":"Not Found","message":"Not Found"}`, 404, true},
		{"wrong-identity", `{"id":98,"name":"New CI","path":".github/workflows/new.yaml","state":"active"}`, 200, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			routes := standardRoutes(runBody(oldRun(101)))
			routes[1].body = runBody(orphan)
			routes = append(routes, fixtureRoute{"GET", fixtureRepo + "/actions/workflows/99", tc.body, tc.status}, deletion(900, 204), deletion(101, 204))
			f := newFixture(t, routes)
			cfg := baseConfig()
			cfg.dryRun = false
			cfg.minimum = 0
			log, err := executeFixture(t, cfg, f)
			want := []string{}
			if !tc.failure {
				want = []string{"DELETE /repos/fixture/catalogue/actions/runs/101"}
			}
			if (err != nil) != tc.failure || !reflect.DeepEqual(deletions(f), want) {
				t.Fatalf("uncertain or live workflow treated as orphan: %v %q %v", err, log, deletions(f))
			}
		})
	}
}

// TestConfirmedOrphansPreservePolicy verifies existing orphan selection after absence is proven.
func TestConfirmedOrphansPreservePolicy(t *testing.T) {
	orphan := `{"id":900,"workflow_id":99,"created_at":"2026-10-05T00:00:00Z","status":"completed","conclusion":"success"}`
	f := newFixture(t, []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflowBody), listing(fixtureRepo+"/actions/runs", runBody(orphan)), {"GET", fixtureRepo + "/actions/workflows/99", `{"message":"Not Found"}`, 404}, deletion(900, 204)})
	cfg := baseConfig()
	cfg.dryRun = false
	cfg.pattern = "release.yaml"
	cfg.states = "disabled_manually"
	cfg.conclusions = "failure"
	log, err := executeFixture(t, cfg, f)
	if err != nil || !reflect.DeepEqual(deletions(f), []string{"DELETE /repos/fixture/catalogue/actions/runs/900"}) || !strings.Contains(log, "Deleted run 900") {
		t.Fatalf("confirmed orphan policy changed: %v %q %v", err, log, deletions(f))
	}
}

// TestRequestEvidenceIsComplete verifies the complete read conversation for a stable workflow.
func TestRequestEvidenceIsComplete(t *testing.T) {
	f := newFixture(t, standardRoutes(runBody(oldRun(101))))
	_, err := executeFixture(t, baseConfig(), f)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"GET /repos/fixture/catalogue/actions/workflows?page=1&per_page=100", "GET /repos/fixture/catalogue/actions/runs?page=1&per_page=100", "GET /repos/fixture/catalogue/actions/workflows/11/runs?page=1&per_page=100"}
	if !reflect.DeepEqual(f.requests, want) {
		t.Fatalf("conversation differs: %v", f.requests)
	}
}

// TestAmbiguousRunIdentityCannotChangeDeletionTarget blocks JSON aliases from choosing another run.
func TestAmbiguousRunIdentityCannotChangeDeletionTarget(t *testing.T) {
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	body := runBody(strings.TrimSuffix(oldRun(101), "}") + `,"ID":102}`)
	f := newFixture(t, append(standardRoutes(body), deletion(102, 204)))
	if _, err := executeFixture(t, cfg, f); err == nil || len(deletions(f)) != 0 {
		t.Fatalf("ambiguous identity accepted: err=%v deletions=%v", err, deletions(f))
	}
}

// TestDeletionRequiresConfirmedNoContentResponse rejects accepted-but-unconfirmed mutations.
func TestDeletionRequiresConfirmedNoContentResponse(t *testing.T) {
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	f := newFixture(t, append(standardRoutes(runBody(oldRun(101), oldRun(102))), deletion(101, 202), deletion(102, 204)))
	log, err := executeFixture(t, cfg, f)
	if err == nil || strings.Contains(log, "Cleanup completed") || len(deletions(f)) != 1 {
		t.Fatalf("unconfirmed deletion reported success or continued: %v %q %v", err, log, deletions(f))
	}
}

// TestListingRequiresConfirmedCompleteResponse prevents partial or asynchronous reads from authorizing deletion.
func TestListingRequiresConfirmedCompleteResponse(t *testing.T) {
	for _, status := range []int{201, 202, 206} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			routes := append(standardRoutes(runBody(oldRun(101))), deletion(101, 204))
			routes[2].status = status
			f := newFixture(t, routes)
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, false
			if _, err := executeFixture(t, cfg, f); err == nil || len(deletions(f)) != 0 {
				t.Fatalf("unconfirmed listing accepted or mutated: %v %v", err, deletions(f))
			}
		})
	}
}

// TestPaginationFailuresBeforeMutation rejects incomplete, shifting or repeated pages.
func TestPaginationFailuresBeforeMutation(t *testing.T) {
	first := `{"total_count":2,"workflow_runs":[` + oldRun(101) + `]}`
	for _, second := range []fixtureRoute{
		{"GET", fixtureRepo + "/actions/workflows/11/runs?page=2&per_page=100", `{"message":"denied"}`, 403},
		{"GET", fixtureRepo + "/actions/workflows/11/runs?page=2&per_page=100", `{"total_count":3,"workflow_runs":[` + oldRun(102) + `]}`, 200},
		{"GET", fixtureRepo + "/actions/workflows/11/runs?page=2&per_page=100", `{"total_count":2,"workflow_runs":[` + oldRun(101) + `]}`, 200},
		{"GET", fixtureRepo + "/actions/workflows/11/runs?page=2&per_page=100", `{"total_count":2,"workflow_runs":[]}`, 200},
	} {
		t.Run(fmt.Sprint(second.status)+second.body, func(t *testing.T) {
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, false
			f := newFixture(t, append(standardRoutes(first), second))
			if _, err := executeFixture(t, cfg, f); err == nil || len(deletions(f)) != 0 {
				t.Fatalf("partial pagination accepted or mutated: %v %v", err, deletions(f))
			}
		})
	}
}

// TestReadRetriesAreBoundedAndOnlyForTransientFailures preserves recovery without retrying authorization failures.
func TestReadRetriesAreBoundedAndOnlyForTransientFailures(t *testing.T) {
	for _, tc := range []struct {
		status, failures, attempts int
		succeeds                   bool
	}{
		{503, 2, 3, true}, {503, 4, 3, false}, {403, 4, 1, false},
	} {
		t.Run(fmt.Sprint(tc), func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if calls <= tc.failures {
					w.WriteHeader(tc.status)
					return
				}
				_, _ = io.WriteString(w, workflowBody)
			}))
			defer server.Close()
			waits := []time.Duration{}
			a := api{server.URL, "offline-fixture-token", server.Client(), func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }}
			_, err := a.list(context.Background(), fixtureRepo+"/actions/workflows", "workflows")
			if (err == nil) != tc.succeeds || calls != tc.attempts {
				t.Fatalf("retry outcome err=%v attempts=%d; want %d success=%t", err, calls, tc.attempts, tc.succeeds)
			}
			want := []time.Duration{}
			if tc.attempts == 3 {
				want = []time.Duration{2 * time.Second, 4 * time.Second}
			}
			if !reflect.DeepEqual(waits, want) {
				t.Fatalf("retry delays=%v want=%v", waits, want)
			}
		})
	}
}

// TestLostDeletionResponseIsNeverReplayed stops after an unknown write outcome.
func TestLostDeletionResponseIsNeverReplayed(t *testing.T) {
	var writes atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			writes.Add(1)
			connection, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			_ = connection.Close()
			return
		}
		switch r.URL.Path {
		case fixtureRepo + "/actions/workflows":
			_, _ = io.WriteString(w, workflowBody)
		case fixtureRepo + "/actions/runs":
			_, _ = io.WriteString(w, emptyRuns)
		case fixtureRepo + "/actions/workflows/11/runs":
			_, _ = io.WriteString(w, runBody(oldRun(101), oldRun(102)))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	var log bytes.Buffer
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, func(context.Context, time.Duration) error { t.Fatal("mutation delay/retry"); return nil })
	if err == nil || writes.Load() != 1 || strings.Contains(log.String(), "Cleanup completed") {
		t.Fatalf("lost response replayed or accepted: %v writes=%d log=%q", err, writes.Load(), log.String())
	}
}

// TestRedirectsAndCancellationCannotReachAnotherTarget contains credentials and cancelled reads.
func TestRedirectsAndCancellationCannotReachAnotherTarget(t *testing.T) {
	reached := false
	other := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { reached = true }))
	defer other.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL, http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	a := api{server.URL, "offline-fixture-token", server.Client(), delay}
	if _, err := a.list(context.Background(), fixtureRepo+"/actions/workflows", "workflows"); err == nil || reached {
		t.Fatalf("redirect followed or accepted: %v reached=%t", err, reached)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := a.list(ctx, fixtureRepo+"/actions/workflows", "workflows"); err == nil {
		t.Fatal("cancelled read reported success")
	}
}

// Run the shipped command, with an isolated environment and only synthetic credentials.
func TestNativeCommandDefaultsOverridesAndFailureExit(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "cleanup")
	build := exec.Command("go", "build", "-o", binary, "main.go")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build native command: %v\n%s", err, output)
	}
	for _, tc := range []struct {
		name, repository, event string
		inputs                  []string
		failure                 bool
		selected                bool
	}{
		{"default-push", "fixture/catalogue", "push", nil, false, true},
		{"explicit-pr", "fixture/other", "pull_request", []string{"INPUT_REPOSITORY=fixture/other", "INPUT_DRY_RUN=true", "INPUT_RETAIN_DAYS=0", "INPUT_KEEP_MINIMUM_RUNS=0", "INPUT_DELETE_WORKFLOW_PATTERN=CI.YAML", "INPUT_DELETE_WORKFLOW_BY_STATE_PATTERN=active", "INPUT_DELETE_RUN_BY_CONCLUSION_PATTERN=success"}, false, true},
		{"merge-group-filter-miss", "fixture/catalogue", "merge_group", []string{"INPUT_DELETE_WORKFLOW_PATTERN=release.yaml"}, false, false},
		{"rejected-delete", "fixture/catalogue", "workflow_dispatch", []string{"INPUT_DRY_RUN=false", "INPUT_RETAIN_DAYS=0", "INPUT_KEEP_MINIMUM_RUNS=0"}, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			seven := runBody(oldRun(101), oldRun(102), oldRun(103), oldRun(104), oldRun(105), oldRun(106), oldRun(107))
			routes := append(standardRoutes(seven), deletion(101, 403))
			for i := range routes {
				routes[i].target = strings.ReplaceAll(routes[i].target, fixtureRepo, "/repos/"+tc.repository)
			}
			if !tc.selected {
				routes = routes[:2]
			}
			f := newFixture(t, routes)
			command := exec.Command(binary)
			command.Env = append([]string{"PATH=" + os.Getenv("PATH"), "GITHUB_REPOSITORY=fixture/catalogue", "GITHUB_API_URL=" + f.server.URL, "GITHUB_EVENT_NAME=" + tc.event, "CLEANUP_TOKEN=offline-fixture-token"}, tc.inputs...)
			output, err := command.CombinedOutput()
			if (err != nil) != tc.failure {
				t.Fatalf("exit=%v output=%s", err, output)
			}
			if tc.failure {
				if !strings.Contains(string(output), "Cleanup failed: delete run 101: HTTP 403") || len(deletions(f)) != 1 {
					t.Fatalf("failed command hid error or replayed deletion: %s %v", output, deletions(f))
				}
			} else if len(deletions(f)) != 0 || !strings.Contains(string(output), "Cleanup completed:") || (strings.Contains(string(output), "Would delete run 101") != tc.selected) {
				t.Fatalf("native dry-run behavior incorrect: %s %v", output, deletions(f))
			}
		})
	}
}
