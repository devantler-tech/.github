package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type fixtureAPI struct {
	run      []byte
	page     []byte
	final    []byte
	pages    map[int][]byte
	failPage int
	reads    int
}

func (f *fixtureAPI) read(_ context.Context, path string) ([]byte, error) {
	switch path {
	case "repos/example/repo/actions/runs/42":
		f.reads++
		if f.reads > 1 && f.final != nil {
			return f.final, nil
		}
		return f.run, nil
	default:
		prefix := "repos/example/repo/actions/runs/42/jobs?filter=latest&per_page=100&page="
		if strings.HasPrefix(path, prefix) {
			page, err := strconv.Atoi(strings.TrimPrefix(path, prefix))
			if err != nil {
				return nil, err
			}
			data := f.page
			if f.pages != nil {
				data = f.pages[page]
			}
			if page == f.failPage {
				return data, errors.New("fixture secret: plausible partial output before failure")
			}
			if data != nil {
				return data, nil
			}
		}
		return nil, fmt.Errorf("unexpected route")
	}
}

func fixture(seconds int) fixtureAPI {
	end := time.Date(2026, 10, 19, 0, 0, seconds, 0, time.UTC).Format(time.RFC3339)
	return fixtureAPI{
		run:  []byte(`{"id":42,"run_attempt":1,"repository":{"full_name":"example/repo"},"head_sha":"` + head + `","path":".github/workflows/ci.yaml","event":"pull_request","status":"completed","conclusion":"success","created_at":"2026-10-19T00:00:00Z","updated_at":"2026-10-19T05:00:00Z"}`),
		page: []byte(`{"total_count":1,"jobs":[{"id":101,"run_id":42,"run_attempt":1,"head_sha":"` + head + `","status":"completed","conclusion":"success","started_at":"2026-10-19T00:01:00Z","completed_at":"` + end + `"}]}`),
	}
}

func TestBudgetUsesJobCompletionAndStrictBoundary(t *testing.T) {
	for _, tc := range []struct {
		name    string
		seconds int
		state   string
		code    int
	}{
		{"below", 899, "within_budget", 0},
		{"at", 900, "over_budget", 1},
		{"above", 901, "over_budget", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			o := options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}
			api := fixture(tc.seconds)
			got, code := inspect(context.Background(), o, &api, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
			if code != tc.code || got.State != tc.state || got.ElapsedSeconds == nil || *got.ElapsedSeconds != float64(tc.seconds) {
				t.Fatalf("got %+v code=%d; want %s code=%d elapsed=%d", got, code, tc.state, tc.code, tc.seconds)
			}
		})
	}
}

func change(t *testing.T, raw []byte, mutate func(map[string]any)) []byte {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	mutate(value)
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestRefusesIncompleteOrMismatchedEvidence(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*fixtureAPI)
		code   int
	}{
		{"empty jobs", func(f *fixtureAPI) { f.page = []byte(`{"total_count":0,"jobs":[]}`) }, 2},
		{"short page", func(f *fixtureAPI) { f.page = change(t, f.page, func(v map[string]any) { v["total_count"] = 2 }) }, 2},
		{"missing count", func(f *fixtureAPI) { f.page = change(t, f.page, func(v map[string]any) { delete(v, "total_count") }) }, 2},
		{"fractional count", func(f *fixtureAPI) { f.page = change(t, f.page, func(v map[string]any) { v["total_count"] = 1.5 }) }, 2},
		{"partial success then error", func(f *fixtureAPI) { f.failPage = 1 }, 2},
		{"invalid JSON", func(f *fixtureAPI) { f.page = []byte("{") }, 2},
		{"trailing JSON", func(f *fixtureAPI) { f.page = append(f.page, []byte("{}")...) }, 2},
		{"run mismatch", func(f *fixtureAPI) { f.run = change(t, f.run, func(v map[string]any) { v["id"] = 43 }) }, 2},
		{"repository mismatch", func(f *fixtureAPI) {
			f.run = change(t, f.run, func(v map[string]any) { v["repository"] = map[string]any{"full_name": "other/repo"} })
		}, 2},
		{"head mismatch", func(f *fixtureAPI) {
			f.run = change(t, f.run, func(v map[string]any) { v["head_sha"] = strings.Repeat("b", 40) })
		}, 2},
		{"workflow mismatch", func(f *fixtureAPI) {
			f.run = change(t, f.run, func(v map[string]any) { v["path"] = ".github/workflows/fast.yaml" })
		}, 2},
		{"event mismatch", func(f *fixtureAPI) { f.run = change(t, f.run, func(v map[string]any) { v["event"] = "push" }) }, 2},
		{"attempt mismatch", func(f *fixtureAPI) { f.run = change(t, f.run, func(v map[string]any) { v["run_attempt"] = 2 }) }, 2},
		{"run pending", func(f *fixtureAPI) { f.run = change(t, f.run, func(v map[string]any) { v["status"] = "in_progress" }) }, 2},
		{"run failed", func(f *fixtureAPI) { f.run = change(t, f.run, func(v map[string]any) { v["conclusion"] = "failure" }) }, 1},
		{"run cancelled", func(f *fixtureAPI) {
			f.run = change(t, f.run, func(v map[string]any) { v["conclusion"] = "cancelled" })
		}, 1},
		{"invalid creation", func(f *fixtureAPI) { f.run = change(t, f.run, func(v map[string]any) { v["created_at"] = "invalid" }) }, 2},
		{"creation after jobs", func(f *fixtureAPI) {
			f.run = change(t, f.run, func(v map[string]any) { v["created_at"] = "2026-10-19T00:15:00Z" })
		}, 2},
		{"changed attempt at final read", func(f *fixtureAPI) { f.final = change(t, f.run, func(v map[string]any) { v["run_attempt"] = 2 }) }, 2},
		{"changed head at final read", func(f *fixtureAPI) {
			f.final = change(t, f.run, func(v map[string]any) { v["head_sha"] = strings.Repeat("b", 40) })
		}, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := fixture(899)
			tc.mutate(&f)
			got, code := inspect(context.Background(), options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
			if code != tc.code || got.State == "within_budget" || got.ElapsedSeconds != nil {
				t.Fatalf("invalid observation was accepted: %+v code=%d", got, code)
			}
		})
	}
}

func TestRejectsUnboundOrUnfinishedJobs(t *testing.T) {
	for _, tc := range []struct {
		key   string
		value any
	}{
		{"id", 0}, {"run_id", 43}, {"run_attempt", 0}, {"run_attempt", 2}, {"head_sha", strings.Repeat("b", 40)},
		{"status", "queued"}, {"conclusion", "failure"}, {"conclusion", "cancelled"}, {"conclusion", "abandoned"},
		{"started_at", "invalid"}, {"completed_at", nil}, {"completed_at", "2026-10-19T00:00:01Z"},
		{"completed_at", "2026-10-20T00:00:00Z"},
	} {
		t.Run(fmt.Sprintf("%s=%v", tc.key, tc.value), func(t *testing.T) {
			f := fixture(899)
			f.page = change(t, f.page, func(v map[string]any) { v["jobs"].([]any)[0].(map[string]any)[tc.key] = tc.value })
			got, code := inspect(context.Background(), options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
			if code != 2 || got.ElapsedSeconds != nil {
				t.Fatalf("job mismatch accepted: %+v code=%d", got, code)
			}
		})
	}
}

func TestCompletePaginationAndStableAttempt(t *testing.T) {
	f := fixture(899)
	var one map[string]any
	if err := json.Unmarshal(f.page, &one); err != nil {
		t.Fatal(err)
	}
	job := one["jobs"].([]any)[0].(map[string]any)
	var first []any
	for i := 0; i < 100; i++ {
		copy := map[string]any{}
		for k, v := range job {
			copy[k] = v
		}
		copy["id"] = i + 1
		first = append(first, copy)
	}
	page1, err := json.Marshal(map[string]any{"total_count": 101, "jobs": first})
	if err != nil {
		t.Fatal(err)
	}
	page2 := change(t, f.page, func(v map[string]any) { v["total_count"] = 101 })
	f.pages = map[int][]byte{1: page1, 2: page2}
	o := options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}
	got, code := inspect(context.Background(), o, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
	if code != 0 || got.ElapsedSeconds == nil || *got.ElapsedSeconds != 899 {
		t.Fatalf("complete pages failed: %+v code=%d", got, code)
	}
	for _, mutate := range []func(*fixtureAPI){
		func(f *fixtureAPI) { f.failPage = 2 },
		func(f *fixtureAPI) { f.pages[2] = change(t, page2, func(v map[string]any) { v["total_count"] = 102 }) },
		func(f *fixtureAPI) {
			f.pages[2] = change(t, page2, func(v map[string]any) { v["jobs"].([]any)[0].(map[string]any)["id"] = 1 })
		},
	} {
		f.pages = map[int][]byte{1: page1, 2: page2}
		f.failPage = 0
		mutate(&f)
		got, code = inspect(context.Background(), o, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
		if code != 2 || got.ElapsedSeconds != nil {
			t.Fatalf("partial pages accepted: %+v code=%d", got, code)
		}
	}
}

func TestRerunRetainsOriginalCreationClock(t *testing.T) {
	f := fixture(901)
	f.run = change(t, f.run, func(v map[string]any) { v["run_attempt"] = 2; v["run_started_at"] = "2026-10-19T00:14:59Z" })
	// Successful jobs reused by a partial rerun still belong to attempt1.
	got, code := inspect(context.Background(), options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 2}, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
	if code != 1 || got.ElapsedSeconds == nil || *got.ElapsedSeconds != 901 {
		t.Fatalf("rerun reset budget: %+v code=%d", got, code)
	}
}

func TestSkippedJobsCannotHideLateCompletionOrEmptyExecution(t *testing.T) {
	f := fixture(899)
	f.page = change(t, f.page, func(v map[string]any) {
		v["total_count"] = 2
		v["jobs"] = append(v["jobs"].([]any), map[string]any{
			"id": 102, "run_id": 42, "run_attempt": 1, "head_sha": head, "status": "completed", "conclusion": "skipped",
			"started_at": "2026-10-19T00:15:01Z", "completed_at": "2026-10-19T00:15:01Z",
		})
	})
	got, code := inspect(context.Background(), options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
	if code != 1 || got.ElapsedSeconds == nil || *got.ElapsedSeconds != 901 {
		t.Fatalf("late skip hid duration: %+v code=%d", got, code)
	}
	f = fixture(899)
	f.page = change(t, f.page, func(v map[string]any) { v["jobs"].([]any)[0].(map[string]any)["conclusion"] = "skipped" })
	got, code = inspect(context.Background(), options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
	if code != 2 || got.ElapsedSeconds != nil {
		t.Fatalf("empty execution passed: %+v code=%d", got, code)
	}
}

func TestNativeSkippedJobHasNoExecutionStartClock(t *testing.T) {
	// GitHub reports these placeholder skip timestamps in catalogue run39263825120.
	f := fixture(899)
	f.page = change(t, f.page, func(v map[string]any) {
		v["total_count"] = 2
		v["jobs"] = append(v["jobs"].([]any), map[string]any{
			"id": 102, "run_id": 42, "run_attempt": 1, "head_sha": head, "status": "completed", "conclusion": "skipped",
			"started_at": "2026-10-19T00:00:03Z", "completed_at": "2026-10-19T00:00:02Z",
		})
	})
	got, code := inspect(context.Background(), options{"example/repo", head, ".github/workflows/ci.yaml", "pull_request", 42, 1}, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
	if code != 0 || got.ElapsedSeconds == nil || *got.ElapsedSeconds != 899 {
		t.Fatalf("native skip placeholder rejected: %+v code=%d", got, code)
	}
}

func TestCLIEmitsScopedReceipts(t *testing.T) {
	args := []string{"--repository", "example/repo", "--run-id", "42", "--attempt", "1", "--head-sha", head, "--workflow-path", ".github/workflows/ci.yaml", "--event", "pull_request"}
	for _, tc := range []struct {
		seconds, code int
		state         string
	}{
		{899, 0, "within_budget"}, {900, 1, "over_budget"}, {901, 1, "over_budget"},
	} {
		f := fixture(tc.seconds)
		var out bytes.Buffer
		code := execute(args, &out, &f, time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC))
		var receipt struct {
			State, Scope string
			Elapsed      *float64 `json:"elapsed_seconds"`
		}
		if err := json.Unmarshal(out.Bytes(), &receipt); err != nil {
			t.Fatal(err)
		}
		if code != tc.code || receipt.State != tc.state || receipt.Scope != "single_workflow_run" || receipt.Elapsed == nil || *receipt.Elapsed != float64(tc.seconds) {
			t.Fatalf("CLI: %s code=%d", out.String(), code)
		}
	}
	for _, bad := range [][]string{
		{}, {"--run-id", "42"}, {"--repository", "../../secret"}, {"--budget", "999999"}, {"--head-sha", "secret-token"}, {"--run-id", "-1"},
	} {
		var out bytes.Buffer
		f := fixture(899)
		code := execute(bad, &out, &f, time.Now())
		if code != 2 || f.reads != 0 || strings.Contains(out.String(), "secret-token") {
			t.Fatalf("bad flags admitted or echoed: %s code=%d reads=%d", out.String(), code, f.reads)
		}
	}
}

func TestNativeCommandIsReadOnlyAndRejectsPlausibleFailedOutput(t *testing.T) {
	dir := t.TempDir()
	program := filepath.Join(dir, "gh")
	for _, tc := range []struct {
		exit      string
		wantError bool
	}{{"0", false}, {"17", true}} {
		script := "#!/bin/sh\n[ \"$#\" -eq 7 ] && [ \"$1\" = api ] && [ \"$2\" = --hostname ] && [ \"$3\" = github.com ] && [ \"$4\" = --method ] && [ \"$5\" = GET ] && [ \"$6\" = -- ] && [ \"$7\" = repos/example/repo/actions/runs/42 ] || exit 99\nprintf '%s' '{\"id\":42}'\nprintf '%s' 'synthetic-secret' >&2\nexit " + tc.exit + "\n"
		if err := os.WriteFile(program, []byte(script), 0o700); err != nil {
			t.Fatal(err)
		}
		api := commandAPI{program: program}
		data, err := api.read(context.Background(), "repos/example/repo/actions/runs/42")
		if tc.wantError {
			if err == nil || data != nil || strings.Contains(err.Error(), "synthetic-secret") {
				t.Fatalf("accepted partial command result: %q %v", data, err)
			}
		} else if err != nil || string(data) != `{"id":42}` {
			t.Fatalf("native GET failed: %q %v", data, err)
		}
	}
}
