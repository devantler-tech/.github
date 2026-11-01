package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type startupFixtureAPI struct {
	responses map[string][][]byte
	failures  map[string]error
	calls     map[string]int
}

// read preserves exact routes and can return plausible partial output with an error.
func (f *startupFixtureAPI) read(_ context.Context, path string) ([]byte, error) {
	f.calls[path]++
	rows := f.responses[path]
	if len(rows) == 0 {
		return nil, fmt.Errorf("unexpected fixture route")
	}
	index := f.calls[path] - 1
	if index >= len(rows) {
		index = len(rows) - 1
	}
	return rows[index], f.failures[path]
}

// startupRun builds native metadata; tests vary only the property they evaluate.
func startupRun(id, workflow, number uint64, event, status string, conclusion any) map[string]any {
	return map[string]any{
		"id": id, "workflow_id": workflow, "run_number": number, "run_attempt": 1,
		"repository": map[string]any{"full_name": "example/repo"}, "head_sha": head,
		"event": event, "status": status, "conclusion": conclusion,
		"head_branch": "feature", "pull_requests": []map[string]any{{"number": 7}},
	}
}

// startupJSON keeps invalid JSON deliberate rather than an accidental fixture typo.
func startupJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// startupFixture includes the current native run and complete first-page inventory.
func startupFixture(t *testing.T, extra ...map[string]any) *startupFixtureAPI {
	t.Helper()
	current := startupRun(42, 1, 1, "pull_request", "in_progress", nil)
	runs := append([]map[string]any{current}, extra...)
	api := &startupFixtureAPI{
		responses: map[string][][]byte{
			"repos/example/repo/actions/runs/42": {startupJSON(t, current)},
			startupRunsPath(1): {startupJSON(t, map[string]any{
				"total_count": len(runs), "workflow_runs": runs,
			})},
		},
		failures: map[string]error{},
		calls:    map[string]int{},
	}
	return api
}

// startupRunsPath fixes the only permitted census query for this native head.
func startupRunsPath(page int) string {
	return fmt.Sprintf("repos/example/repo/actions/runs?head_sha=%s&per_page=100&page=%d", head, page)
}

// runStartup executes the real CLI dispatcher and checks the sanitized snapshot verdict.
func runStartup(t *testing.T, api *startupFixtureAPI, code int, state string) {
	t.Helper()
	var out bytes.Buffer
	got := execute([]string{
		"startup", "--repository", "example/repo", "--head-sha", head,
		"--run-id", "42", "--attempt", "1", "--event", "pull_request",
	}, &out, api, time.Time{})
	if got != code {
		t.Fatalf("exit=%d want=%d; receipt=%s", got, code, out.String())
	}
	var receipt map[string]any
	if err := json.Unmarshal(out.Bytes(), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt["state"] != state || receipt["scope"] != "head_workflow_startup_snapshot" {
		t.Fatalf("wrong verdict or scope: %s", out.String())
	}
	if strings.Contains(out.String(), "PRIVATE_API_SENTINEL") {
		t.Fatal("raw API diagnostic escaped")
	}
}

// TestStartupHistoryRequiresSuccessfulSameEventRecovery rejects false recovery.
func TestStartupHistoryRequiresSuccessfulSameEventRecovery(t *testing.T) {
	bad := startupRun(100, 2, 2, "pull_request", "completed", "startup_failure")
	for _, tc := range []struct {
		name  string
		next  map[string]any
		code  int
		state string
	}{
		{"no replacement", nil, 1, "blocked"},
		{"successful PR rerun", startupRun(101, 2, 3, "pull_request", "completed", "success"), 0, "clear"},
		{"manual success", startupRun(101, 2, 3, "workflow_dispatch", "completed", "success"), 1, "blocked"},
		{"different workflow success", startupRun(101, 3, 3, "pull_request", "completed", "success"), 1, "blocked"},
		{"pending replacement", startupRun(101, 2, 3, "pull_request", "queued", nil), 1, "blocked"},
		{"skipped replacement", startupRun(101, 2, 3, "pull_request", "completed", "skipped"), 1, "blocked"},
		{"older success", startupRun(99, 2, 1, "pull_request", "completed", "success"), 1, "blocked"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := startupFixture(t, bad)
			if tc.next != nil {
				api = startupFixture(t, tc.next, bad)
			}
			runStartup(t, api, tc.code, tc.state)
		})
	}
}

// TestStartupOtherBranchesAndPRsCannotEraseFailure prevents same-SHA cross-talk.
func TestStartupOtherBranchesAndPRsCannotEraseFailure(t *testing.T) {
	for _, tc := range []struct {
		name          string
		changeBad     func(map[string]any)
		changeSuccess func(map[string]any)
	}{
		{"other branch", nil, func(r map[string]any) { r["head_branch"] = "another-feature" }},
		{"other PR", nil, func(r map[string]any) { r["pull_requests"] = []map[string]any{{"number": 8}} }},
		{"unbound startup failure", func(r map[string]any) { r["pull_requests"] = []any{} }, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bad := startupRun(100, 2, 2, "pull_request", "completed", "startup_failure")
			success := startupRun(101, 2, 3, "pull_request", "completed", "success")
			if tc.changeBad != nil {
				tc.changeBad(bad)
			}
			if tc.changeSuccess != nil {
				tc.changeSuccess(success)
			}
			runStartup(t, startupFixture(t, bad, success), 1, "blocked")
		})
	}
}

// TestStartupConflictingNativeSequenceIsUnknown rejects a fabricated recovery.
func TestStartupConflictingNativeSequenceIsUnknown(t *testing.T) {
	api := startupFixture(t,
		startupRun(100, 2, 2, "pull_request", "completed", "startup_failure"),
		startupRun(101, 2, 2, "pull_request", "completed", "success"),
	)
	runStartup(t, api, 2, "unknown")
}

// TestStartupFailedAttemptJobEvidenceMustBeComplete distinguishes absence from
// missing data, and refuses jobs from another head, run or attempt.
func TestStartupFailedAttemptJobEvidenceMustBeComplete(t *testing.T) {
	for _, tc := range []struct {
		name string
		page map[string]any
	}{
		{"missing jobs", map[string]any{"total_count": 0}},
		{"null jobs", map[string]any{"total_count": 0, "jobs": nil}},
		{"missing page entries", map[string]any{"total_count": 1, "jobs": []any{}}},
		{"foreign attempt", map[string]any{"total_count": 1, "jobs": []map[string]any{{
			"id": 501, "run_id": 100, "run_attempt": 2, "head_sha": head,
		}}}},
		{"foreign head", map[string]any{"total_count": 1, "jobs": []map[string]any{{
			"id": 501, "run_id": 100, "run_attempt": 1, "head_sha": strings.Repeat("b", 40),
		}}}},
		{"foreign run", map[string]any{"total_count": 1, "jobs": []map[string]any{{
			"id": 501, "run_id": 101, "run_attempt": 1, "head_sha": head,
		}}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := startupFixture(t, startupRun(100, 2, 2, "pull_request", "completed", "failure"))
			api.responses["repos/example/repo/actions/runs/100/attempts/1/jobs?per_page=100&page=1"] =
				[][]byte{startupJSON(t, tc.page)}
			runStartup(t, api, 2, "unknown")
		})
	}
}

// TestStartupPaginationRequiresTheCompleteHeadInventory catches a missing late page.
func TestStartupPaginationRequiresTheCompleteHeadInventory(t *testing.T) {
	for _, failure := range []string{"none", "missing second page", "duplicate second page", "changed count"} {
		t.Run(failure, func(t *testing.T) {
			current := startupRun(42, 1, 1, "pull_request", "in_progress", nil)
			runs := []map[string]any{current}
			for index := uint64(1); index <= 100; index++ {
				runs = append(runs, startupRun(100+index, 2, index, "pull_request", "queued", nil))
			}
			api := startupFixture(t)
			api.responses[startupRunsPath(1)] = [][]byte{startupJSON(t, map[string]any{
				"total_count": 101, "workflow_runs": runs[:100],
			})}
			last, total := runs[100], 101
			if failure == "duplicate second page" {
				last = runs[0]
			}
			if failure == "changed count" {
				total = 102
			}
			api.responses[startupRunsPath(2)] = [][]byte{startupJSON(t, map[string]any{
				"total_count": total, "workflow_runs": []map[string]any{last},
			})}
			code, state := 0, "clear"
			if failure != "none" {
				code, state = 2, "unknown"
			}
			if failure == "missing second page" {
				delete(api.responses, startupRunsPath(2))
			}
			runStartup(t, api, code, state)
		})
	}
}

// TestStartupNoJobFailuresCannotHideBehindAGreenJobRollup binds exact attempts.
func TestStartupNoJobFailuresCannotHideBehindAGreenJobRollup(t *testing.T) {
	for _, count := range []int{0, 1} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			api := startupFixture(t, startupRun(100, 2, 2, "pull_request", "completed", "failure"))
			jobs := []map[string]any{}
			if count > 0 {
				jobs = append(jobs, map[string]any{
					"id": 501, "run_id": 100, "run_attempt": 1, "head_sha": head,
					"status": "completed", "conclusion": "failure",
				})
			}
			api.responses["repos/example/repo/actions/runs/100/attempts/1/jobs?per_page=100&page=1"] =
				[][]byte{startupJSON(t, map[string]any{"total_count": count, "jobs": jobs})}
			code, state := 1, "blocked"
			if count > 0 {
				code, state = 0, "clear" // Existing job gates still own ordinary job failures.
			}
			runStartup(t, api, code, state)
		})
	}
}

// TestStartupMalformedOrIncompleteEvidenceNeverPasses pins refusal boundaries.
func TestStartupMalformedOrIncompleteEvidenceNeverPasses(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"missing count", func(p map[string]any) { delete(p, "total_count") }},
		{"truncated page", func(p map[string]any) { p["total_count"] = 2 }},
		{"API search cap", func(p map[string]any) { p["total_count"] = 1000 }},
		{"duplicate identity", func(p map[string]any) {
			r := p["workflow_runs"].([]any)
			p["workflow_runs"] = append(r, r[0])
			p["total_count"] = 2
		}},
		{"missing current run", func(p map[string]any) { p["workflow_runs"] = []any{}; p["total_count"] = 0 }},
		{"foreign head", func(p map[string]any) {
			p["workflow_runs"].([]any)[0].(map[string]any)["head_sha"] = strings.Repeat("b", 40)
		}},
		{"foreign repository", func(p map[string]any) {
			p["workflow_runs"].([]any)[0].(map[string]any)["repository"] = map[string]any{"full_name": "elsewhere/repo"}
		}},
		{"unknown terminal verdict", func(p map[string]any) {
			r := p["workflow_runs"].([]any)[0].(map[string]any)
			r["status"] = "completed"
			r["conclusion"] = "new_unknown_verdict"
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := startupFixture(t)
			api.responses[startupRunsPath(1)][0] = change(t, api.responses[startupRunsPath(1)][0], tc.mutate)
			runStartup(t, api, 2, "unknown")
		})
	}
}

// TestStartupChangingEvidenceAndFailedProducersRemainUnknown rejects partial success.
func TestStartupChangingEvidenceAndFailedProducersRemainUnknown(t *testing.T) {
	t.Run("plausible output followed by error", func(t *testing.T) {
		api := startupFixture(t)
		api.failures[startupRunsPath(1)] = errors.New("PRIVATE_API_SENTINEL")
		runStartup(t, api, 2, "unknown")
	})
	t.Run("failure appeared during observation", func(t *testing.T) {
		api := startupFixture(t)
		later := startupFixture(t, startupRun(100, 2, 2, "pull_request", "completed", "startup_failure"))
		api.responses[startupRunsPath(1)] = append(api.responses[startupRunsPath(1)], later.responses[startupRunsPath(1)][0])
		runStartup(t, api, 2, "unknown")
	})
	t.Run("native attempt moved", func(t *testing.T) {
		api := startupFixture(t)
		key := "repos/example/repo/actions/runs/42"
		api.responses[key] = append(api.responses[key], change(t, api.responses[key][0], func(r map[string]any) { r["run_attempt"] = 2 }))
		runStartup(t, api, 2, "unknown")
	})
	t.Run("ordinary progress does not manufacture a failure", func(t *testing.T) {
		api := startupFixture(t, startupRun(100, 2, 2, "pull_request", "queued", nil))
		next := change(t, api.responses[startupRunsPath(1)][0], func(p map[string]any) {
			p["workflow_runs"].([]any)[1].(map[string]any)["status"] = "in_progress"
		})
		api.responses[startupRunsPath(1)] = append(api.responses[startupRunsPath(1)], next)
		runStartup(t, api, 0, "clear")
	})
}

// TestStartupInvalidContextMakesNoAPIRequest binds all egress before execution.
func TestStartupInvalidContextMakesNoAPIRequest(t *testing.T) {
	for _, tc := range []struct {
		name  string
		index int
		value string
	}{
		{"unsafe repository operand", 2, "example/repo/../other"},
		{"repository dot segment", 2, "example/.."},
		{"missing head", 4, ""},
		{"invalid head", 4, strings.Repeat("z", 40)},
		{"missing run", 6, "0"},
		{"missing attempt", 8, "0"},
		{"manual event", 10, "workflow_dispatch"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			args := []string{"startup", "--repository", "example/repo", "--head-sha", head,
				"--run-id", "42", "--attempt", "1", "--event", "pull_request"}
			args[tc.index] = tc.value
			api := startupFixture(t)
			var out bytes.Buffer
			if code := execute(args, &out, api, time.Time{}); code != 2 {
				t.Fatalf("invalid context returned %d: %s", code, out.String())
			}
			if len(api.calls) != 0 {
				t.Fatal("invalid context reached metadata transport")
			}
		})
	}
}
