package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// delayedPages records real HTTP overlap; the response order differs from page
// order. Each request carries only the fixture credential and fixed run cutoff.
type delayedPages struct {
	mu                        sync.Mutex
	active, peak, reads, done int
	writes                    []string
	change                    string
	finished                  []int
}

func (f *delayedPages) serve(t *testing.T, w http.ResponseWriter, r *http.Request) {
	t.Helper()
	if r.Header.Get("Authorization") != "Bearer offline-fixture-token" {
		t.Error("unexpected credential")
		w.WriteHeader(401)
		return
	}
	if r.Method == "DELETE" {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.active != 0 || f.done != 9 {
			t.Error("deletion preceded complete enumeration")
		}
		f.writes = append(f.writes, r.URL.Path)
		w.WriteHeader(204)
		return
	}
	if r.URL.Path == fixtureRepo+"/actions/workflows" {
		_, _ = io.WriteString(w, workflowBody)
		return
	}
	if r.Method != "GET" || r.URL.Path != fixtureRepo+"/actions/runs" || r.URL.Query().Get("created") != "1970-01-01T00:00:00Z..2026-10-05T23:59:59Z" || r.URL.Query().Get("per_page") != "100" {
		t.Errorf("unexpected history request: %s %s", r.Method, r.URL.RequestURI())
		w.WriteHeader(403)
		return
	}
	page, err := strconv.Atoi(r.URL.Query().Get("page"))
	if err != nil || page < 1 || page > 9 {
		t.Error("invalid page")
		w.WriteHeader(403)
		return
	}
	f.mu.Lock()
	f.active++
	f.reads++
	f.peak = max(f.peak, f.active)
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.active--
		f.done++
		f.finished = append(f.finished, page)
		f.mu.Unlock()
	}()
	// Uneven response delays exercise ordering without assuming network order.
	if err := delay(r.Context(), time.Duration(60-page%4*10)*time.Millisecond); err != nil {
		return
	}
	if f.change == "denied" && page == 4 {
		w.WriteHeader(403)
		return
	}
	if f.change == "malformed" && page == 4 {
		_, _ = io.WriteString(w, `{"total_count":801,"workflow_runs":[`)
		return
	}
	total := 801
	if f.change == "changed-total" && page == 4 {
		total++
	}
	items := []string{}
	for id := (page-1)*100 + 1; id <= min(page*100, 801); id++ {
		if f.change == "duplicate" && page == 4 && id == 301 {
			items = append(items, oldRun(1))
		} else {
			items = append(items, oldRun(id))
		}
	}
	if f.change == "empty" && page == 4 {
		items = nil
	}
	_, _ = fmt.Fprintf(w, `{"total_count":%d,"workflow_runs":[%s]}`, total, strings.Join(items, ","))
}

// Sequential page reads fail this concurrency assertion while selecting the
// same single retained-policy candidate. No fixture determines the decision.
func TestHistoryPagesOverlapWithinBoundBeforeDeletion(t *testing.T) {
	f := &delayedPages{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { f.serve(t, w, r) }))
	defer server.Close()
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 800, false
	var log bytes.Buffer
	start := time.Now()
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
	elapsed := time.Since(start)
	f.mu.Lock()
	defer f.mu.Unlock()
	t.Logf("history fixture: elapsed=%s reads=%d peak=%d selected=%v", elapsed, f.reads, f.peak, f.writes)
	if err != nil || f.reads != 9 || f.done != 9 || !reflect.DeepEqual(f.writes, []string{fixtureRepo + "/actions/runs/1"}) {
		t.Fatalf("history or deletion decision changed: err=%v reads=%d done=%d writes=%v log=%q", err, f.reads, f.done, f.writes, log.String())
	}
	if f.peak <= 1 || f.peak > 4 {
		t.Fatalf("history reads must overlap within four requests; peak=%d", f.peak)
	}
}

func TestConcurrentHistoryFailureCannotReachDeletion(t *testing.T) {
	for _, change := range []string{"denied", "malformed", "changed-total", "duplicate", "empty"} {
		t.Run(change, func(t *testing.T) {
			f := &delayedPages{change: change}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { f.serve(t, w, r) }))
			defer server.Close()
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 800, false
			var log bytes.Buffer
			err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
			f.mu.Lock()
			defer f.mu.Unlock()
			if err == nil || len(f.writes) != 0 || strings.Contains(log.String(), "Cleanup completed:") {
				t.Fatalf("failed history read reached mutation or success: %v writes=%v", err, f.writes)
			}
		})
	}
}

// Short pages are unusual but were supported by the sequential reader. Totals
// establish only a minimum required page count, never a complete snapshot.
func TestShortPagesContinueUntilDeclaredTotal(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		if page < 1 || page > 3 {
			t.Error("unexpected page")
			w.WriteHeader(403)
			return
		}
		_, _ = fmt.Fprintf(w, `{"total_count":3,"workflows":[{"id":%d}]}`, page)
	}))
	defer server.Close()
	a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: delay, budget: &rateLimitWaitBudget{}}
	items, err := a.list(context.Background(), fixtureRepo+"/actions/workflows", "workflows")
	if err != nil || len(items) != 3 || requests != 3 {
		t.Fatalf("short-page snapshot changed: %v items=%v requests=%d", err, items, requests)
	}
	for i, raw := range items {
		var item struct{ ID int }
		if json.Unmarshal(raw, &item) != nil || item.ID != i+1 {
			t.Fatal("page order changed")
		}
	}
}

type pageTransport func(*http.Request) (*http.Response, error)

func (f pageTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Cancellation must join the four in-flight client calls, rather than return
// while a producer still uses the caller's transport. DELETE remains forbidden.
func TestCancellationJoinsOutstandingPageReads(t *testing.T) {
	started := make(chan struct{}, 4)
	var active, writes atomic.Int64
	client := &http.Client{Transport: pageTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			writes.Add(1)
			return nil, fmt.Errorf("unexpected mutation")
		}
		body := workflowBody
		if strings.HasSuffix(r.URL.Path, "/runs") {
			if r.URL.Query().Get("page") != "1" {
				active.Add(1)
				defer active.Add(-1)
				started <- struct{}{}
				<-r.Context().Done()
				return nil, r.Context().Err()
			}
			items := []string{}
			for id := 1; id <= 100; id++ {
				items = append(items, oldRun(id))
			}
			body = fmt.Sprintf(`{"total_count":801,"workflow_runs":[%s]}`, strings.Join(items, ","))
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		cfg := baseConfig()
		cfg.minimum, cfg.dryRun = 800, false
		finished <- clean(ctx, cfg, "https://offline.invalid", "offline-fixture-token", client, fixedNow, io.Discard, delay)
	}()
	for range 4 {
		select {
		case <-started:
		case err := <-finished:
			t.Fatalf("cleanup stopped before concurrent reads: %v", err)
		case <-time.After(3 * time.Second):
			t.Fatal("four page reads did not start")
		}
	}
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) || active.Load() != 0 || writes.Load() != 0 {
			t.Fatalf("cancellation leaked work or reached mutation: err=%v active=%d writes=%d", err, active.Load(), writes.Load())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cancelled page reads were not joined")
	}
}

type fixtureRoute struct {
	method, target, body string
	status               int
}

type fixtureAPI struct {
	server   *httptest.Server
	mu       sync.Mutex
	requests []string
	routes   []fixtureRoute
	snapshot string
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
		target := r.URL.RequestURI()
		if r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/runs") {
			q := r.URL.Query()
			rangeParts := strings.Split(q.Get("created"), "..")
			valid := len(rangeParts) == 2 && rangeParts[0] == "1970-01-01T00:00:00Z"
			if valid {
				end, err := time.Parse(time.RFC3339, rangeParts[1])
				valid = err == nil && !end.After(time.Now()) && (f.snapshot == "" || rangeParts[1] == f.snapshot)
			}
			if !valid || len(q) != 3 {
				t.Errorf("run read omitted a valid fixed snapshot: %s", target)
				w.WriteHeader(403)
				return
			}
			q.Del("created")
			target = r.URL.Path + "?" + q.Encode()
		}
		for _, route := range f.routes {
			if route.method == r.Method && route.target == target {
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

// recentRun falls inside the trailing day a capped whole-history search splits off first.
func recentRun(id int) string { return runJSON(id, "2026-10-05T12:00:00Z", "completed", "success") }

// standardRoutes supplies complete workflow metadata and the shared repository-run snapshot.
func standardRoutes(runs string) []fixtureRoute {
	return []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflowBody), listing(fixtureRepo+"/actions/runs", runs)}
}

// baseConfig represents the public workflow's preview defaults.
func baseConfig() config {
	return config{repository: "fixture/catalogue", days: 30, minimum: 6, dryRun: true, states: "ALL", conclusions: "ALL"}
}

var fixedNow = time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC)

// executeFixture exercises the real driver against synthetic HTTP history.
func executeFixture(t *testing.T, cfg config, f *fixtureAPI) (string, error) {
	t.Helper()
	f.snapshot = fixedNow.Add(-time.Second).Format(time.RFC3339)
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

// TestMutationPacingAndCancellation observes writes around each interruptible wait.
func TestMutationPacingAndCancellation(t *testing.T) {
	for _, scenario := range []string{"live", "cancelled-between-writes", "preview"} {
		t.Run(scenario, func(t *testing.T) {
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, scenario == "preview"
			f := newFixture(t, append(standardRoutes(runBody(oldRun(101), oldRun(102), oldRun(103))), deletion(101, 204), deletion(102, 204), deletion(103, 204)))
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var waits []time.Duration
			wait := func(ctx context.Context, duration time.Duration) error {
				waits = append(waits, duration)
				// The first write is immediate; each later one waits after the prior confirmed write.
				if got := len(deletions(f)); got != len(waits) {
					t.Fatalf("wait %d followed %d writes", len(waits), got)
				}
				if scenario == "cancelled-between-writes" {
					cancel()
					return delay(ctx, duration)
				}
				return nil
			}
			var log bytes.Buffer
			err := clean(ctx, cfg, f.server.URL, "offline-fixture-token", f.server.Client(), fixedNow, &log, wait)
			wantWaits := []time.Duration{time.Second, time.Second}
			wantWrites := 3
			if scenario == "preview" {
				wantWaits, wantWrites = nil, 0
				if !strings.Contains(log.String(), "Would delete run 103") {
					t.Fatal("preview omitted a selected run")
				}
			}
			if scenario == "cancelled-between-writes" {
				wantWaits, wantWrites = []time.Duration{time.Second}, 1
				if err != context.Canceled || strings.Contains(log.String(), "Cleanup completed") {
					t.Fatalf("interrupted pacing reported completion: err=%v log=%q", err, log.String())
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(waits, wantWaits) || len(deletions(f)) != wantWrites {
				t.Fatalf("waits=%v writes=%v, want waits=%v writes=%d", waits, deletions(f), wantWaits, wantWrites)
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

// TestListingFailuresProduceNoWrites blocks partial history and late orphan-revalidation failures.
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
	t.Run("later-orphan-revalidation", func(t *testing.T) {
		cfg := baseConfig()
		cfg.minimum = 0
		cfg.dryRun = false
		orphan := strings.Replace(oldRun(900), `"workflow_id":11`, `"workflow_id":99`, 1)
		f := newFixture(t, []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflowBody), listing(fixtureRepo+"/actions/runs", runBody(oldRun(101), orphan)), {"GET", fixtureRepo + "/actions/workflows/99", `{"message":"denied"}`, 403}})
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
	orphan := strings.Replace(oldRun(900), `"workflow_id":11`, `"workflow_id":99`, 1)
	f := newFixture(t, []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflowBody), listing(fixtureRepo+"/actions/runs", `{"total_count":102,"workflow_runs":[`+strings.Join(first, ",")+`]}`), {"GET", fixtureRepo + "/actions/runs?page=2&per_page=100", `{"total_count":102,"workflow_runs":[` + oldRun(1200) + `,` + orphan + `]}`, 200}})
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
			routes[1].body = runBody(oldRun(101), orphan)
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
	query := "?created=" + url.QueryEscape("1970-01-01T00:00:00Z..2026-10-05T23:59:59Z") + "&page=1&per_page=100"
	want := []string{"GET /repos/fixture/catalogue/actions/workflows?page=1&per_page=100", "GET /repos/fixture/catalogue/actions/runs" + query}
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
			routes[1].status = status
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
		{"GET", fixtureRepo + "/actions/runs?page=2&per_page=100", `{"message":"denied"}`, 403},
		{"GET", fixtureRepo + "/actions/runs?page=2&per_page=100", `{"total_count":3,"workflow_runs":[` + oldRun(102) + `]}`, 200},
		{"GET", fixtureRepo + "/actions/runs?page=2&per_page=100", `{"total_count":2,"workflow_runs":[` + oldRun(101) + `]}`, 200},
		{"GET", fixtureRepo + "/actions/runs?page=2&per_page=100", `{"total_count":2,"workflow_runs":[]}`, 200},
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
		name                       string
		status, failures, attempts int
		retryAfter, failureBody    string
		rateRemaining, rateReset   string
		succeeds                   bool
		waits                      []time.Duration
	}{
		{"server-errors-recover", 503, 2, 3, "", "", "", "", true, []time.Duration{2 * time.Second, 4 * time.Second}},
		{"server-errors-stop", 503, 4, 3, "", "", "", "", false, []time.Duration{2 * time.Second, 4 * time.Second}},
		{"authorization-denial", 403, 4, 1, "", `{"message":"Resource not accessible by integration"}`, "", "", false, []time.Duration{}},
		{"rate-limited-forbidden-recovers", 403, 2, 3, "7", "", "", "", true, []time.Duration{7 * time.Second, 7 * time.Second}},
		{"primary-rate-limited-installation-recovers", 403, 2, 3, "", `{"message":"API rate limit exceeded for installation"}`, "0", "1", true, []time.Duration{time.Second, time.Second}},
		{"primary-rate-limit-missing-reset", 403, 4, 1, "", "", "0", "", false, []time.Duration{}},
		{"primary-rate-limit-invalid-reset", 403, 4, 1, "", "", "0", "later", false, []time.Duration{}},
		{"primary-rate-limit-reset-exceeds-bound", 403, 4, 1, "", "", "0", "9999999999", false, []time.Duration{}},
		{"secondary-rate-limit-message-stops-at-wait-bound", 403, 2, 2, "", `{"message":"You have exceeded a secondary rate limit."}`, "", "", false, []time.Duration{60 * time.Second}},
		{"too-many-requests-recovers", 429, 2, 3, "5", "", "", "", true, []time.Duration{5 * time.Second, 5 * time.Second}},
		{"too-many-requests-without-delay-stops-at-wait-bound", 429, 2, 2, "", "", "", "", false, []time.Duration{60 * time.Second}},
		{"malformed-rate-limit-delay", 403, 4, 1, "later", "", "", "", false, []time.Duration{}},
		{"unbounded-rate-limit-delay", 403, 4, 1, "61", "", "", "", false, []time.Duration{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if calls <= tc.failures {
					if tc.retryAfter != "" {
						w.Header().Set("Retry-After", tc.retryAfter)
					}
					if tc.rateRemaining != "" {
						w.Header().Set("X-RateLimit-Remaining", tc.rateRemaining)
					}
					if tc.rateReset != "" {
						w.Header().Set("X-RateLimit-Reset", tc.rateReset)
					}
					w.WriteHeader(tc.status)
					_, _ = io.WriteString(w, tc.failureBody)
					return
				}
				_, _ = io.WriteString(w, workflowBody)
			}))
			defer server.Close()
			waits := []time.Duration{}
			a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }, budget: &rateLimitWaitBudget{}}
			_, err := a.list(context.Background(), fixtureRepo+"/actions/workflows", "workflows")
			if (err == nil) != tc.succeeds || calls != tc.attempts {
				t.Fatalf("retry outcome err=%v attempts=%d; want %d success=%t", err, calls, tc.attempts, tc.succeeds)
			}
			if !reflect.DeepEqual(waits, tc.waits) {
				t.Fatalf("retry delays=%v want=%v", waits, tc.waits)
			}
		})
	}
}

// TestRateLimitWaitBudgetSpansPagination prevents each page from resetting the cleanup-wide bound.
func TestRateLimitWaitBudgetSpansPagination(t *testing.T) {
	calls := map[int]int{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		page, err := strconv.Atoi(r.URL.Query().Get("page"))
		if err != nil || page < 1 || page > 2 {
			t.Errorf("unexpected page %q", r.URL.Query().Get("page"))
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		calls[page]++
		if calls[page] == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		count, start := 100, 1
		if page == 2 {
			count, start = 1, 101
		}
		items := make([]string, count)
		for i := range count {
			items[i] = fmt.Sprintf(`{"id":%d}`, start+i)
		}
		_, _ = fmt.Fprintf(w, `{"total_count":101,"workflows":[%s]}`, strings.Join(items, ","))
	}))
	defer server.Close()
	waits := []time.Duration{}
	a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: func(_ context.Context, d time.Duration) error {
		waits = append(waits, d)
		return nil
	}, budget: &rateLimitWaitBudget{}}
	_, err := a.list(context.Background(), fixtureRepo+"/actions/workflows", "workflows")
	if err == nil || calls[1] != 2 || calls[2] != 1 {
		t.Fatalf("pagination reset rate-limit budget: err=%v calls=%v", err, calls)
	}
	if !reflect.DeepEqual(waits, []time.Duration{maxRateLimitRetryDelay}) {
		t.Fatalf("pagination waits=%v want one cleanup-wide wait", waits)
	}
}

// TestRateLimitWaitBudgetIsAtomicAcrossConcurrentReads keeps overlapping pages inside one bound.
func TestRateLimitWaitBudgetIsAtomicAcrossConcurrentReads(t *testing.T) {
	var calls, waits atomic.Int64
	var attempts sync.Map
	firstAttempts := make(chan struct{}, 2)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		value, _ := attempts.LoadOrStore(r.URL.Path, &atomic.Int64{})
		if value.(*atomic.Int64).Add(1) == 1 {
			firstAttempts <- struct{}{}
			<-release
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		_, _ = io.WriteString(w, workflowBody)
	}))
	defer server.Close()
	a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: func(context.Context, time.Duration) error {
		waits.Add(1)
		return nil
	}, budget: &rateLimitWaitBudget{}}
	results := make(chan error, 2)
	for _, path := range []string{"/first", "/second"} {
		go func() {
			_, err := a.request(context.Background(), "GET", path)
			results <- err
		}()
	}
	<-firstAttempts
	<-firstAttempts
	close(release)
	successes := 0
	for range 2 {
		if <-results == nil {
			successes++
		}
	}
	if successes != 1 || calls.Load() != 3 || waits.Load() != 1 {
		t.Fatalf("concurrent budget was not atomic: successes=%d calls=%d waits=%d", successes, calls.Load(), waits.Load())
	}
}

func TestPrimaryRateLimitResetDelay(t *testing.T) {
	now := time.Unix(1_000, 0)
	response := &http.Response{StatusCode: http.StatusForbidden, Header: http.Header{
		"X-Ratelimit-Remaining": []string{"0"},
		"X-Ratelimit-Reset":     []string{"1007"},
	}}
	delay, limited, err := rateLimitRetryDelay(response, nil, now)
	if err != nil || !limited || delay != 7*time.Second {
		t.Fatalf("primary rate-limit delay=%s limited=%t err=%v", delay, limited, err)
	}
}

func TestRetryAfterHTTPDateDelay(t *testing.T) {
	now := time.Unix(1_000, 0).UTC()
	for _, tc := range []struct {
		name      string
		offset    time.Duration
		wantDelay time.Duration
		wantError bool
	}{
		{"bounded", 30 * time.Second, 30 * time.Second, false},
		{"not-positive", 0, 0, true},
		{"exceeds-bound", 61 * time.Second, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := &http.Response{StatusCode: http.StatusTooManyRequests, Header: http.Header{
				"Retry-After": []string{now.Add(tc.offset).Format(http.TimeFormat)},
			}}
			delay, limited, err := rateLimitRetryDelay(response, nil, now)
			if (err != nil) != tc.wantError || (!tc.wantError && (!limited || delay != tc.wantDelay)) {
				t.Fatalf("HTTP-date retry delay=%s limited=%t err=%v", delay, limited, err)
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
	a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: delay, budget: &rateLimitWaitBudget{}}
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
	source, err := filepath.Abs("main.go")
	if err != nil {
		t.Fatal(err)
	}
	build := exec.Command("go", "build", "-o", binary, source)
	// The wrapper invokes the source file from outside its nested module. Match
	// that workspace layout without changing the runner's selected toolchain.
	build.Dir = t.TempDir()
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

// TestRunEnumerationFreezesCreationTime excludes arrivals while history is paginated.
func TestRunEnumerationFreezesCreationTime(t *testing.T) {
	var writes atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			writes.Add(1)
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == fixtureRepo+"/actions/workflows" {
			_, _ = io.WriteString(w, workflowBody)
			return
		}
		want := "1970-01-01T00:00:00Z..2026-10-05T23:59:59Z"
		if r.URL.Query().Get("created") != want {
			w.WriteHeader(403)
			return
		}
		_, _ = io.WriteString(w, runBody(oldRun(101)))
	}))
	defer server.Close()
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	var log bytes.Buffer
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
	if err != nil || writes.Load() != 1 || !strings.Contains(log.String(), "Cleanup completed:") {
		t.Fatalf("fixed snapshot was not used for repository-run reads: %v writes=%d log=%q", err, writes.Load(), log.String())
	}
}

// TestCappedRunSearchSplitsWithoutDroppingHistory protects retention beyond GitHub's 1,000-result cap.
func TestCappedRunSearchSplitsWithoutDroppingHistory(t *testing.T) {
	cutoff := fixedNow.Add(-time.Second).Unix()
	middle := cutoff - recentWindow
	format := func(second int64) string { return time.Unix(second, 0).UTC().Format(time.RFC3339) }
	whole := format(0) + ".." + format(cutoff)
	left := format(0) + ".." + format(middle)
	right := format(middle+1) + ".." + format(cutoff)
	newer := []string{}
	for id := 1; id <= 999; id++ {
		newer = append(newer, recentRun(id))
	}
	older := []string{runJSON(1000, "1990-01-01T00:00:00Z", "completed", "success"), runJSON(1001, "1990-01-02T00:00:00Z", "completed", "success")}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Error("dry-run issued a mutation")
			w.WriteHeader(403)
			return
		}
		if r.URL.Path == fixtureRepo+"/actions/workflows" {
			_, _ = io.WriteString(w, workflowBody)
			return
		}
		created := r.URL.Query().Get("created")
		page := r.URL.Query().Get("page")
		if created == whole {
			// Even exactly 1,000 can be a capped total: never regard it as complete.
			_, _ = io.WriteString(w, `{"total_count":1000,"workflow_runs":[]}`)
			return
		}
		if created == left && page == "1" {
			_, _ = io.WriteString(w, runBody(older...))
			return
		}
		if created == right {
			start := 0
			_, _ = fmt.Sscan(page, &start)
			start = (start - 1) * 100
			end := min(start+100, len(newer))
			if start >= 0 && start < len(newer) {
				_, _ = fmt.Fprintf(w, `{"total_count":999,"workflow_runs":[%s]}`, strings.Join(newer[start:end], ","))
				return
			}
		}
		t.Errorf("unexpected range/page: %s", r.URL.RequestURI())
		w.WriteHeader(403)
	}))
	defer server.Close()
	cfg := baseConfig()
	// The trailing-day runs are recent, so age-based retention is off to keep every run selectable.
	cfg.minimum, cfg.days = 0, 0
	var log bytes.Buffer
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
	if err != nil || !strings.Contains(log.String(), "selected=1001 dry-run=true") || !strings.Contains(log.String(), "Would delete run 1001\n") {
		t.Fatalf("capped search lost old history: %v log=%q", err, log.String())
	}
}

// TestSnapshotFailuresProduceNoWrites rejects unbounded, inconsistent and inaccessible history.
func TestSnapshotFailuresProduceNoWrites(t *testing.T) {
	for _, scenario := range []string{"out-of-range", "dense-second", "later-partition-denied"} {
		t.Run(scenario, func(t *testing.T) {
			var writes, reads atomic.Int64
			cutoff := fixedNow.Add(-time.Second).Unix()
			whole := "1970-01-01T00:00:00Z..2026-10-05T23:59:59Z"
			left := "1970-01-01T00:00:00Z.." + time.Unix(cutoff-recentWindow, 0).UTC().Format(time.RFC3339)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "DELETE" {
					writes.Add(1)
					w.WriteHeader(204)
					return
				}
				if r.URL.Path == fixtureRepo+"/actions/workflows" {
					_, _ = io.WriteString(w, workflowBody)
					return
				}
				reads.Add(1)
				switch scenario {
				case "out-of-range":
					_, _ = io.WriteString(w, runBody(runJSON(101, "2026-10-06T00:00:00Z", "completed", "success")))
				case "dense-second":
					_, _ = io.WriteString(w, `{"total_count":1000,"workflow_runs":[]}`)
				case "later-partition-denied":
					switch r.URL.Query().Get("created") {
					case whole:
						_, _ = io.WriteString(w, `{"total_count":1000,"workflow_runs":[]}`)
					case left:
						_, _ = io.WriteString(w, runBody(runJSON(101, "1990-01-01T00:00:00Z", "completed", "success")))
					default:
						w.WriteHeader(403)
					}
				}
			}))
			defer server.Close()
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, false
			var log bytes.Buffer
			err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
			if err == nil || writes.Load() != 0 || strings.Contains(log.String(), "Cleanup completed:") || reads.Load() > 33 {
				t.Fatalf("uncertain snapshot accepted or unbounded: %v reads=%d writes=%d log=%q", err, reads.Load(), writes.Load(), log.String())
			}
		})
	}
}

// TestSingleRepositorySnapshotDrivesEveryWorkflow refuses redundant per-workflow rescans.
func TestSingleRepositorySnapshotDrivesEveryWorkflow(t *testing.T) {
	var reads, writes atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			writes.Add(1)
			w.WriteHeader(204)
			return
		}
		reads.Add(1)
		switch r.URL.Path {
		case fixtureRepo + "/actions/workflows":
			_, _ = io.WriteString(w, `{"total_count":2,"workflows":[{"id":11,"name":"CI","path":".github/workflows/ci.yaml","state":"active"},{"id":22,"name":"Release","path":".github/workflows/release.yaml","state":"active"}]}`)
		case fixtureRepo + "/actions/runs":
			_, _ = io.WriteString(w, runBody(oldRun(101), strings.Replace(oldRun(102), `"workflow_id":11`, `"workflow_id":22`, 1)))
		default:
			w.WriteHeader(403)
		}
	}))
	defer server.Close()
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	var log bytes.Buffer
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
	if err != nil || reads.Load() != 2 || writes.Load() != 2 || !strings.Contains(log.String(), "selected=2 dry-run=false") {
		t.Fatalf("a complete shared snapshot was discarded or rescanned: %v reads=%d writes=%d log=%q", err, reads.Load(), writes.Load(), log.String())
	}
}

// TestSharedSnapshotRetainsMinimumForEachWorkflow separates retention and filters within one history.
func TestSharedSnapshotRetainsMinimumForEachWorkflow(t *testing.T) {
	workflows := `{"total_count":2,"workflows":[{"id":11,"name":"CI","path":".github/workflows/ci.yaml","state":"active"},{"id":22,"name":"Release","path":".github/workflows/release.yaml","state":"active"}]}`
	runs := runBody(
		runJSON(101, "2000-01-01T00:00:00Z", "completed", "success"),
		runJSON(102, "2000-01-02T00:00:00Z", "completed", "success"),
		strings.Replace(runJSON(103, "2000-01-01T00:00:00Z", "completed", "success"), `"workflow_id":11`, `"workflow_id":22`, 1),
		strings.Replace(runJSON(104, "2000-01-02T00:00:00Z", "completed", "success"), `"workflow_id":11`, `"workflow_id":22`, 1),
		runJSON(105, "2026-10-05T00:00:00Z", "completed", "success"))
	for _, tc := range []struct {
		name, pattern string
		want          []string
	}{
		{"both-workflows", "", []string{"DELETE /repos/fixture/catalogue/actions/runs/101", "DELETE /repos/fixture/catalogue/actions/runs/103"}},
		{"only-CI", "CI.YAML", []string{"DELETE /repos/fixture/catalogue/actions/runs/101"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t, []fixtureRoute{listing(fixtureRepo+"/actions/workflows", workflows), listing(fixtureRepo+"/actions/runs", runs), deletion(101, 204), deletion(103, 204)})
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun, cfg.pattern = 1, false, tc.pattern
			log, err := executeFixture(t, cfg, f)
			if err != nil || !reflect.DeepEqual(deletions(f), tc.want) {
				t.Fatalf("shared history crossed workflow retention boundaries: %v deletes=%v log=%q", err, deletions(f), log)
			}
		})
	}
}

func TestChangingHistoryRestartsFromAnEmptyInventory(t *testing.T) {
	for _, next := range []string{"complete", "changed-again", "malformed", "denied"} {
		t.Run(next, func(t *testing.T) {
			var starts, reads, active, joined atomic.Int64
			var mu sync.Mutex
			deleted := []string{}
			cutoff := "1970-01-01T00:00:00Z.." + fixedNow.Add(-time.Second).Format(time.RFC3339)
			middle := fixedNow.Add(-time.Second).Unix() - recentWindow
			left := "1970-01-01T00:00:00Z.." + time.Unix(middle, 0).UTC().Format(time.RFC3339)
			right := time.Unix(middle+1, 0).UTC().Format(time.RFC3339) + ".." + fixedNow.Add(-time.Second).Format(time.RFC3339)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "DELETE" {
					mu.Lock()
					defer mu.Unlock()
					deleted = append(deleted, r.URL.Path)
					if active.Load() != 0 || joined.Load() != 7 {
						t.Error("mutation preceded complete joined inventory")
					}
					w.WriteHeader(204)
					return
				}
				if r.URL.Path == fixtureRepo+"/actions/workflows" {
					_, _ = io.WriteString(w, workflowBody)
					return
				}
				span := r.URL.Query().Get("created")
				if r.Method != "GET" || r.URL.Path != fixtureRepo+"/actions/runs" || (span != cutoff && span != left && span != right) || r.URL.Query().Get("per_page") != "100" {
					t.Errorf("unexpected history request: %s %s", r.Method, r.URL.RequestURI())
					w.WriteHeader(403)
					return
				}
				active.Add(1)
				defer active.Add(-1)
				reads.Add(1)
				page, _ := strconv.Atoi(r.URL.Query().Get("page"))
				attempt := starts.Load()
				if span == cutoff && page == 1 {
					attempt = starts.Add(1)
				}
				if attempt > 2 || page < 1 || page > 5 {
					t.Error("unbounded history restart")
					w.WriteHeader(403)
					return
				}
				if attempt == 2 && span == cutoff && page == 1 {
					if active.Load() != 1 || joined.Load() != 7 {
						t.Error("restart preceded joined first-attempt reads")
					}
					switch next {
					case "complete":
						_, _ = fmt.Fprintf(w, `{"total_count":1,"workflow_runs":[%s]}`, runJSON(2, "1990-01-01T00:00:00Z", "completed", "success"))
						return
					case "malformed":
						_, _ = io.WriteString(w, `{"total_count":`)
						return
					case "denied":
						w.WriteHeader(403)
						_, _ = io.WriteString(w, `{"message":"denied"}`)
						return
					}
				}
				if attempt == 1 {
					defer joined.Add(1)
				}
				if span == cutoff {
					_, _ = io.WriteString(w, `{"total_count":1000,"workflow_runs":[]}`)
					return
				}
				if span == left {
					_, _ = fmt.Fprintf(w, `{"total_count":2,"workflow_runs":[%s,%s]}`, runJSON(1, "1990-01-01T00:00:00Z", "completed", "success"), runJSON(2, "1990-01-01T00:00:00Z", "completed", "success"))
					return
				}
				if page > 1 {
					if err := delay(r.Context(), time.Duration(page)*10*time.Millisecond); err != nil {
						return
					}
				}
				total := 401
				if page == 2 {
					total = 400
				}
				rows := []string{}
				for id := (page-1)*100 + 1; id <= min(page*100, 401); id++ {
					rows = append(rows, recentRun(id+2))
				}
				_, _ = fmt.Fprintf(w, `{"total_count":%d,"workflow_runs":[%s]}`, total, strings.Join(rows, ","))
			}))
			defer server.Close()
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, false
			var log bytes.Buffer
			err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, func(context.Context, time.Duration) error { return nil })
			mu.Lock()
			defer mu.Unlock()
			expectedReads := int64(8)
			if next == "changed-again" {
				expectedReads = 14
			}
			if starts.Load() != 2 || reads.Load() != expectedReads || active.Load() != 0 {
				t.Fatalf("restart bounds: starts=%d reads=%d active=%d err=%v", starts.Load(), reads.Load(), active.Load(), err)
			}
			if next == "complete" {
				if err != nil || !reflect.DeepEqual(deleted, []string{fixtureRepo + "/actions/runs/2"}) || !strings.Contains(log.String(), "Cleanup completed: selected=1 dry-run=false") {
					t.Fatalf("fresh inventory was not used alone: err=%v deleted=%v log=%q", err, deleted, log.String())
				}
			} else if err == nil || len(deleted) != 0 || log.Len() != 0 {
				t.Fatalf("uncertain fresh inventory reached mutation or receipt: err=%v deleted=%v log=%q", err, deleted, log.String())
			}
		})
	}
}

func TestOtherHistoryFailuresDoNotRestartInventory(t *testing.T) {
	for _, failure := range []string{"denied", "malformed", "duplicate", "missing-total"} {
		t.Run(failure, func(t *testing.T) {
			var reads, writes atomic.Int64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "DELETE" {
					writes.Add(1)
					w.WriteHeader(204)
					return
				}
				if r.URL.Path == fixtureRepo+"/actions/workflows" {
					_, _ = io.WriteString(w, workflowBody)
					return
				}
				reads.Add(1)
				switch failure {
				case "denied":
					w.WriteHeader(403)
					_, _ = io.WriteString(w, `{"message":"denied"}`)
				case "malformed":
					_, _ = io.WriteString(w, `{"total_count":`)
				case "duplicate":
					_, _ = fmt.Fprintf(w, `{"total_count":2,"workflow_runs":[%s,%s]}`, oldRun(1), oldRun(1))
				case "missing-total":
					_, _ = io.WriteString(w, `{"workflow_runs":[]}`)
				}
			}))
			defer server.Close()
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, false
			var log bytes.Buffer
			err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, delay)
			if err == nil || reads.Load() != 1 || writes.Load() != 0 || log.Len() != 0 {
				t.Fatalf("non-drift failure was restarted or accepted: err=%v reads=%d writes=%d log=%q", err, reads.Load(), writes.Load(), log.String())
			}
		})
	}
}

func TestFreshHistorySharesTheRateLimitWaitBudget(t *testing.T) {
	var roots, reads, writes, waits atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			writes.Add(1)
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == fixtureRepo+"/actions/workflows" {
			_, _ = io.WriteString(w, workflowBody)
			return
		}
		reads.Add(1)
		if r.URL.Query().Get("page") == "2" {
			_, _ = io.WriteString(w, `{"total_count":100,"workflow_runs":[]}`)
			return
		}
		switch roots.Add(1) {
		case 1, 3:
			w.Header().Set("Retry-After", strconv.Itoa(int(maxRateLimitRetryDelay/time.Second)))
			w.WriteHeader(429)
			_, _ = io.WriteString(w, `{"message":"limited"}`)
		case 2:
			rows := []string{}
			for id := 1; id <= 100; id++ {
				rows = append(rows, oldRun(id))
			}
			_, _ = fmt.Fprintf(w, `{"total_count":101,"workflow_runs":[%s]}`, strings.Join(rows, ","))
		default:
			_, _ = fmt.Fprintf(w, `{"total_count":1,"workflow_runs":[%s]}`, oldRun(999))
		}
	}))
	defer server.Close()
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	var log bytes.Buffer
	wait := func(ctx context.Context, d time.Duration) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		waits.Add(1)
		if d != maxRateLimitRetryDelay {
			t.Errorf("unexpected rate-limit wait: %s", d)
		}
		return nil
	}
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, wait)
	if err == nil || roots.Load() != 3 || reads.Load() != 4 || waits.Load() != 1 || writes.Load() != 0 || log.Len() != 0 {
		t.Fatalf("fresh history replenished rate-limit budget: err=%v roots=%d reads=%d waits=%d writes=%d log=%q", err, roots.Load(), reads.Load(), waits.Load(), writes.Load(), log.String())
	}
}

func TestFreshHistoryCannotReplenishItsPartitionBudget(t *testing.T) {
	var reads atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.Add(1)
		if r.URL.Query().Get("page") == "2" {
			_, _ = io.WriteString(w, `{"total_count":100,"workflow_runs":[]}`)
			return
		}
		rows := []string{}
		for id := 1; id <= 100; id++ {
			rows = append(rows, oldRun(id))
		}
		_, _ = fmt.Fprintf(w, `{"total_count":101,"workflow_runs":[%s]}`, strings.Join(rows, ","))
	}))
	defer server.Close()
	a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: delay, budget: &rateLimitWaitBudget{}}
	partitions := 9999
	upper := fixedNow.Add(-time.Second).Unix()
	_, err := a.listRunSnapshot(context.Background(), fixtureRepo+"/actions/runs", upper, &partitions)
	if !errors.Is(err, historyChanged) || partitions != 10000 || reads.Load() != 2 {
		t.Fatalf("first inventory did not consume the remaining partition: err=%v partitions=%d reads=%d", err, partitions, reads.Load())
	}
	_, err = a.listRunSnapshot(context.Background(), fixtureRepo+"/actions/runs", upper, &partitions)
	if err == nil || !strings.Contains(err.Error(), "partition limit") || reads.Load() != 2 {
		t.Fatalf("fresh inventory replenished the partition budget: err=%v reads=%d", err, reads.Load())
	}
}

func TestChangingTotalsCannotHideOtherHistoryFailures(t *testing.T) {
	for _, defect := range []string{"null-items", "malformed-run", "duplicate", "out-of-range", "cross-partition-duplicate", "malformed-prior", "malformed-later", "denied-later"} {
		t.Run(defect, func(t *testing.T) {
			var starts, active, writes atomic.Int64
			cutoff := fixedNow.Add(-time.Second).Unix()
			middle := cutoff - recentWindow
			stamp := func(s int64) string { return time.Unix(s, 0).UTC().Format(time.RFC3339) }
			whole := stamp(0) + ".." + stamp(cutoff)
			left := stamp(0) + ".." + stamp(middle)
			right := stamp(middle+1) + ".." + stamp(cutoff)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "DELETE" {
					writes.Add(1)
					w.WriteHeader(204)
					return
				}
				if r.URL.Path == fixtureRepo+"/actions/workflows" {
					_, _ = io.WriteString(w, workflowBody)
					return
				}
				active.Add(1)
				defer active.Add(-1)
				page, _ := strconv.Atoi(r.URL.Query().Get("page"))
				switch r.URL.Query().Get("created") {
				case whole:
					if starts.Add(1) > 1 {
						_, _ = fmt.Fprintf(w, `{"total_count":1,"workflow_runs":[%s]}`, runJSON(2, "1990-01-01T00:00:00Z", "completed", "success"))
						return
					}
					_, _ = io.WriteString(w, `{"total_count":1000,"workflow_runs":[]}`)
					return
				case left:
					_, _ = fmt.Fprintf(w, `{"total_count":2,"workflow_runs":[%s,%s]}`, runJSON(1, "1990-01-01T00:00:00Z", "completed", "success"), runJSON(2, "1990-01-01T00:00:00Z", "completed", "success"))
					return
				case right:
				default:
					t.Error("unexpected history range")
					w.WriteHeader(403)
					return
				}
				if page < 1 || page > 5 {
					t.Error("unexpected history page")
					w.WriteHeader(403)
					return
				}
				if page == 3 && defect == "denied-later" {
					w.WriteHeader(403)
					_, _ = io.WriteString(w, `{"message":"denied"}`)
					return
				}
				if page == 3 && defect == "malformed-later" {
					_, _ = io.WriteString(w, `{"total_count":`)
					return
				}
				if page == 2 && defect == "null-items" {
					_, _ = io.WriteString(w, `{"total_count":400,"workflow_runs":null}`)
					return
				}
				rows := []string{}
				for id := (page-1)*100 + 1; id <= min(page*100, 401); id++ {
					row := recentRun(id + 2)
					if page == 2 && id == 101 {
						switch defect {
						case "malformed-run":
							row = `{"id":103}`
						case "duplicate":
							row = recentRun(3)
						case "out-of-range":
							row = runJSON(103, "1990-01-01T00:00:00Z", "completed", "success")
						case "cross-partition-duplicate":
							row = recentRun(1)
						}
					}
					if page == 1 && id == 1 && defect == "malformed-prior" {
						row = `{"id":3}`
					}
					rows = append(rows, row)
				}
				total := 401
				if page == 2 {
					total = 400
				}
				_, _ = fmt.Fprintf(w, `{"total_count":%d,"workflow_runs":[%s]}`, total, strings.Join(rows, ","))
			}))
			defer server.Close()
			cfg := baseConfig()
			cfg.minimum, cfg.dryRun = 0, false
			var log bytes.Buffer
			err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, func(context.Context, time.Duration) error { return nil })
			server.Close()
			if err == nil || starts.Load() != 1 || active.Load() != 0 || writes.Load() != 0 || log.Len() != 0 {
				t.Fatalf("changing totals hid %s: err=%v starts=%d active=%d writes=%d log=%q", defect, err, starts.Load(), active.Load(), writes.Load(), log.String())
			}
		})
	}
}

// Capped totals are lower bounds. Every descendant must be observed before
// a partial plan may reach either a mutation or a completion receipt.
func TestCappedHistoryCannotShrinkBelowItsMinimum(t *testing.T) {
	for _, test := range []struct {
		name                string
		parent, descendants int
		accept              bool
	}{
		{"empty", 1000, 0, false},
		{"one", 1000, 1, false},
		{"one-short", 1000, 999, false},
		{"exact-minimum", 1000, 1000, true},
		{"above-minimum", 1000, 1001, true},
		{"larger-advertised-minimum", 1500, 1001, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			cutoff := fixedNow.Add(-time.Second).Unix()
			stamp := func(second int64) string { return time.Unix(second, 0).UTC().Format(time.RFC3339) }
			whole := stamp(0) + ".." + stamp(cutoff)
			left := stamp(0) + ".." + stamp(cutoff-recentWindow)
			right := stamp(cutoff-recentWindow+1) + ".." + stamp(cutoff)
			older, newer := []string{}, []string{}
			for id := 1; id <= test.descendants; id++ {
				if id <= (test.descendants+1)/2 {
					older = append(older, runJSON(id, "1990-01-01T00:00:00Z", "completed", "success"))
				} else {
					newer = append(newer, recentRun(id))
				}
			}
			var writes atomic.Int64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "DELETE" {
					writes.Add(1)
					w.WriteHeader(204)
					return
				}
				if r.URL.Path == fixtureRepo+"/actions/workflows" {
					_, _ = io.WriteString(w, workflowBody)
					return
				}
				var runs []string
				switch r.URL.Query().Get("created") {
				case whole:
					_, _ = fmt.Fprintf(w, `{"total_count":%d,"workflow_runs":[]}`, test.parent)
					return
				case left:
					runs = older
				case right:
					runs = newer
				default:
					t.Errorf("unexpected range: %s", r.URL.RequestURI())
					w.WriteHeader(403)
					return
				}
				page, err := strconv.Atoi(r.URL.Query().Get("page"))
				if err != nil || page < 1 || (page-1)*100 > len(runs) {
					w.WriteHeader(403)
					return
				}
				start := (page - 1) * 100
				_, _ = fmt.Fprintf(w, `{"total_count":%d,"workflow_runs":[%s]}`, len(runs), strings.Join(runs[start:min(start+100, len(runs))], ","))
			}))
			defer server.Close()
			cfg := baseConfig()
			cfg.minimum, cfg.days, cfg.dryRun = 0, 0, test.accept
			var log bytes.Buffer
			err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, func(context.Context, time.Duration) error { return nil })
			if test.accept {
				if err != nil || !strings.Contains(log.String(), fmt.Sprintf("Cleanup completed: selected=%d dry-run=true", test.descendants)) {
					t.Fatalf("complete capped history rejected: err=%v log bytes=%d", err, log.Len())
				}
			} else if err == nil || !strings.Contains(err.Error(), "capped minimum") || log.Len() != 0 {
				t.Fatalf("incomplete split accepted: err=%v writes=%d log bytes=%d", err, writes.Load(), log.Len())
			}
			if writes.Load() != 0 {
				t.Fatalf("partial or dry-run history reached %d DELETEs", writes.Load())
			}
		})
	}
}

func TestEarlierSiblingCannotHideNestedCappedShortage(t *testing.T) {
	cutoff := fixedNow.Add(-time.Second).Unix()
	middle := cutoff - recentWindow
	stamp := func(second int64) string { return time.Unix(second, 0).UTC().Format(time.RFC3339) }
	whole := stamp(0) + ".." + stamp(cutoff)
	left := stamp(0) + ".." + stamp(middle)
	right := stamp(middle+1) + ".." + stamp(cutoff)
	nestedMiddle := middle + 1 + (cutoff-middle-1)/2
	nestedLeft := stamp(middle+1) + ".." + stamp(nestedMiddle)
	nestedRight := stamp(nestedMiddle+1) + ".." + stamp(cutoff)
	older := []string{}
	for id := 1; id <= 999; id++ {
		older = append(older, runJSON(id, "1990-01-01T00:00:00Z", "completed", "success"))
	}
	var writes atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			writes.Add(1)
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == fixtureRepo+"/actions/workflows" {
			_, _ = io.WriteString(w, workflowBody)
			return
		}
		switch r.URL.Query().Get("created") {
		case whole, right:
			_, _ = io.WriteString(w, `{"total_count":1000,"workflow_runs":[]}`)
		case left:
			page, _ := strconv.Atoi(r.URL.Query().Get("page"))
			start := (page - 1) * 100
			if page < 1 || start >= len(older) {
				w.WriteHeader(403)
				return
			}
			_, _ = fmt.Fprintf(w, `{"total_count":999,"workflow_runs":[%s]}`, strings.Join(older[start:min(start+100, len(older))], ","))
		case nestedLeft:
			_, _ = io.WriteString(w, runBody(runJSON(1000, "2026-10-05T06:00:00Z", "completed", "success")))
		case nestedRight:
			_, _ = io.WriteString(w, runBody())
		default:
			t.Errorf("unexpected range: %s", r.URL.RequestURI())
			w.WriteHeader(403)
		}
	}))
	defer server.Close()
	cfg := baseConfig()
	cfg.minimum, cfg.dryRun = 0, false
	var log bytes.Buffer
	err := clean(context.Background(), cfg, server.URL, "offline-fixture-token", server.Client(), fixedNow, &log, func(context.Context, time.Duration) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "capped minimum") || writes.Load() != 0 || log.Len() != 0 {
		t.Fatalf("earlier sibling hid partial nested inventory: err=%v writes=%d log bytes=%d", err, writes.Load(), log.Len())
	}
}

// searchHistory serves GitHub's created-range run search over a frozen synthetic history:
// newest first, 100 per page, with only the first 1,000 results reachable.
func searchHistory(t *testing.T, created []int64) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	runs := append([]int64(nil), created...)
	sort.Slice(runs, func(i, j int) bool { return runs[i] > runs[j] })
	var reads atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != fixtureRepo+"/actions/runs" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.RequestURI())
			w.WriteHeader(403)
			return
		}
		reads.Add(1)
		bounds := strings.Split(r.URL.Query().Get("created"), "..")
		if len(bounds) != 2 {
			t.Errorf("unbounded run search: %s", r.URL.RequestURI())
			w.WriteHeader(422)
			return
		}
		lower, lowerErr := time.Parse(time.RFC3339, bounds[0])
		upper, upperErr := time.Parse(time.RFC3339, bounds[1])
		if lowerErr != nil || upperErr != nil || upper.Before(lower) {
			t.Errorf("malformed run search range: %s", r.URL.RequestURI())
			w.WriteHeader(422)
			return
		}
		matched := []string{}
		for index, second := range runs {
			if second >= lower.Unix() && second <= upper.Unix() {
				stamp := time.Unix(second, 0).UTC().Format(time.RFC3339)
				matched = append(matched, runJSON(index+1, stamp, "completed", "success"))
			}
		}
		page := 0
		_, _ = fmt.Sscan(r.URL.Query().Get("page"), &page)
		start := (page - 1) * 100
		end := min(start+100, len(matched), 1000)
		items := []string{}
		if start >= 0 && start < end {
			items = matched[start:end]
		}
		_, _ = fmt.Fprintf(w, `{"total_count":%d,"workflow_runs":[%s]}`, len(matched), strings.Join(items, ","))
	}))
	return server, &reads
}

// TestSplitPointSeparatesOnlyTheWholeHistorysTrailingDay keeps every other range on bisection.
func TestSplitPointSeparatesOnlyTheWholeHistorysTrailingDay(t *testing.T) {
	snapshot := fixedNow.Add(-time.Second).Unix()
	for _, test := range []struct {
		name                string
		lower, upper, split int64
	}{
		{"whole history", 0, snapshot, snapshot - recentWindow},
		{"nested range bisects", snapshot - recentWindow + 1, snapshot, snapshot - recentWindow + 1 + (recentWindow-1)/2},
		{"left child bisects", 0, snapshot - recentWindow, (snapshot - recentWindow) / 2},
		{"history of exactly one day", 0, recentWindow, 0},
		{"history shorter than a day", 0, recentWindow - 1, (recentWindow - 1) / 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			upper := snapshot
			if test.lower == 0 && test.upper <= recentWindow {
				upper = test.upper
			}
			split := splitPoint(test.lower, test.upper, upper)
			if split != test.split || split < test.lower || split >= test.upper {
				t.Fatalf("splitPoint(%d, %d) = %d, want %d inside [lower, upper)", test.lower, test.upper, split, test.split)
			}
		})
	}
}

// TestRunSearchRequestCounts pins the request cost of the history split for the three frozen
// workloads measured on #612, and proves every run is still returned exactly once.
func TestRunSearchRequestCounts(t *testing.T) {
	cutoff := fixedNow.Add(-time.Second).Unix()
	dense := []int64{}
	for second := range int64(1001) {
		dense = append(dense, cutoff-second)
	}
	year := []int64{}
	for index := range int64(10001) {
		year = append(year, cutoff-index*(365*24*60*60)/10001)
	}
	epoch := []int64{}
	for index := range int64(1001) {
		epoch = append(epoch, index*cutoff/1000)
	}
	for _, workload := range []struct {
		name     string
		created  []int64
		requests int64
	}{
		{"dense-recent-day", dense, 26},
		{"spread-over-a-year", year, 143},
		{"spread-over-the-epoch", epoch, 13},
	} {
		t.Run(workload.name, func(t *testing.T) {
			server, reads := searchHistory(t, workload.created)
			defer server.Close()
			a := api{base: server.URL, token: "offline-fixture-token", client: server.Client(), wait: delay, budget: &rateLimitWaitBudget{}}
			items, err := a.listRuns(context.Background(), fixtureRepo+"/actions/runs", fixedNow)
			if err != nil {
				t.Fatalf("run search failed: %v", err)
			}
			seen := map[int64]bool{}
			for _, raw := range items {
				var run struct {
					ID int64 `json:"id"`
				}
				if json.Unmarshal(raw, &run) != nil || run.ID <= 0 || seen[run.ID] {
					t.Fatalf("invalid or repeated run in result: %s", raw)
				}
				seen[run.ID] = true
			}
			if len(seen) != len(workload.created) {
				t.Fatalf("returned %d runs, want every one of %d", len(seen), len(workload.created))
			}
			if got := reads.Load(); got != workload.requests {
				t.Fatalf("run search used %d requests, want %d", got, workload.requests)
			}
		})
	}
}
