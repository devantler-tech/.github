package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"reflect"
	"sort"
	"strings"
	"time"
)

// startupOptions bind a snapshot to the native invocation, never a branch name.
type startupOptions struct {
	repository, head, event string
	runID, attempt          uint64
}

// startupRunRecord contains only authoritative identity and result metadata.
type startupRunRecord struct {
	ID         uint64 `json:"id"`
	WorkflowID uint64 `json:"workflow_id"`
	Number     uint64 `json:"run_number"`
	Attempt    uint64 `json:"run_attempt"`
	Repository struct {
		Name string `json:"full_name"`
	} `json:"repository"`
	Head       string      `json:"head_sha"`
	Event      string      `json:"event"`
	Status     string      `json:"status"`
	Conclusion string      `json:"conclusion"`
	Branch     string      `json:"head_branch"`
	PRs        []startupPR `json:"pull_requests"`
}

type startupPR struct {
	Number uint64 `json:"number"`
}

type startupRunsPage struct {
	Total *uint64            `json:"total_count"`
	Runs  []startupRunRecord `json:"workflow_runs"`
}

// startupReceipt is deliberately not a CI-budget or all-checks-green verdict.
type startupReceipt struct {
	Schema      int    `json:"schema"`
	State       string `json:"state"`
	Scope       string `json:"scope"`
	Reason      string `json:"reason"`
	Repository  string `json:"repository,omitempty"`
	Head        string `json:"head_sha,omitempty"`
	RunID       uint64 `json:"run_id,omitempty"`
	Attempt     uint64 `json:"attempt,omitempty"`
	FailedRunID uint64 `json:"failed_run_id,omitempty"`
}

// valid permits only native CI contexts and refuses unsafe API path operands.
func (o startupOptions) valid() bool {
	return repositoryPattern.MatchString(o.repository) &&
		!strings.HasSuffix(o.repository, "/.") && !strings.HasSuffix(o.repository, "/..") &&
		shaPattern.MatchString(o.head) && o.runID > 0 && o.attempt > 0 &&
		(o.event == "pull_request" || o.event == "merge_group" || o.event == "push")
}

// validStartupRun rejects unknown states rather than erasing an adverse sample.
func validStartupRun(r startupRunRecord, o startupOptions) bool {
	if r.ID == 0 || r.WorkflowID == 0 || r.Number == 0 || r.Attempt == 0 ||
		r.Head != o.head || r.Repository.Name != o.repository || r.Event == "" || r.Branch == "" {
		return false
	}
	seenPRs := map[uint64]bool{}
	for _, pr := range r.PRs {
		if pr.Number == 0 || seenPRs[pr.Number] {
			return false
		}
		seenPRs[pr.Number] = true
	}
	switch r.Status {
	case "completed":
		switch r.Conclusion {
		case "success", "failure", "startup_failure", "cancelled", "timed_out",
			"neutral", "skipped", "stale", "action_required":
			return true
		}
	case "queued", "requested", "waiting", "pending", "in_progress":
		return r.Conclusion == ""
	}
	return false
}

// sameStartupInvocation allows ordinary progress but never another head or attempt.
func sameStartupInvocation(a, b startupRunRecord) bool {
	return a.ID == b.ID && a.WorkflowID == b.WorkflowID && a.Number == b.Number &&
		a.Attempt == b.Attempt && a.Repository == b.Repository &&
		a.Head == b.Head && a.Event == b.Event && startupHistoryKey(a) == startupHistoryKey(b)
}

// startupHistoryKey never lets another branch or PR clear a same-SHA failure.
// An unbound PR failure is conservative: a different run cannot prove recovery;
// a successful retry of its own native run removes that failure from the census.
func startupHistoryKey(run startupRunRecord) string {
	prefix := fmt.Sprintf("%d:%s:%q", run.WorkflowID, run.Event, run.Branch)
	if run.Event != "pull_request" {
		return prefix
	}
	if len(run.PRs) == 0 {
		return fmt.Sprintf("%s:unbound:%d", prefix, run.ID)
	}
	numbers := make([]uint64, 0, len(run.PRs))
	for _, pr := range run.PRs {
		numbers = append(numbers, pr.Number)
	}
	sort.Slice(numbers, func(i, j int) bool { return numbers[i] < numbers[j] })
	return fmt.Sprintf("%s:prs:%v", prefix, numbers)
}

// normalizeStartupPRs makes unordered association metadata stable across reads.
func normalizeStartupPRs(run *startupRunRecord) {
	sort.Slice(run.PRs, func(i, j int) bool { return run.PRs[i].Number < run.PRs[j].Number })
}

// startupCensus requires every page, native identity and the calling run itself.
func startupCensus(ctx context.Context, api reader, o startupOptions, current startupRunRecord) ([]startupRunRecord, error) {
	var total uint64
	var result []startupRunRecord
	seen := map[uint64]bool{}
	counters := map[[2]uint64]bool{}
	foundCurrent := false
	for page := 1; page <= 10; page++ {
		var data startupRunsPage
		path := fmt.Sprintf("repos/%s/actions/runs?head_sha=%s&per_page=100&page=%d", o.repository, o.head, page)
		if err := readJSON(ctx, api, path, &data); err != nil {
			return nil, errors.New("workflow_inventory_unreadable")
		}
		// GitHub caps filtered workflow searches at 1,000 results. Reaching
		// that boundary cannot prove that no later adverse run was omitted.
		if data.Total == nil || *data.Total == 0 || *data.Total >= 1000 {
			return nil, errors.New("workflow_inventory_incomplete")
		}
		if page == 1 {
			total = *data.Total
		}
		if *data.Total != total || uint64(len(result)) > total {
			return nil, errors.New("workflow_count_changed")
		}
		wanted := min(uint64(100), total-uint64(len(result)))
		if uint64(len(data.Runs)) != wanted {
			return nil, errors.New("workflow_page_incomplete")
		}
		for _, run := range data.Runs {
			normalizeStartupPRs(&run)
			counter := [2]uint64{run.WorkflowID, run.Number}
			if seen[run.ID] || counters[counter] || !validStartupRun(run, o) {
				return nil, errors.New("workflow_identity_or_state_invalid")
			}
			seen[run.ID] = true
			counters[counter] = true
			if run.ID == o.runID {
				if !sameStartupInvocation(run, current) {
					return nil, errors.New("current_run_changed")
				}
				foundCurrent = true
			}
			result = append(result, run)
		}
		if uint64(len(result)) == total {
			if !foundCurrent {
				return nil, errors.New("current_run_missing")
			}
			return result, nil
		}
	}
	return nil, errors.New("workflow_inventory_incomplete")
}

// startupCandidates retains failures until a newer success with the same workflow,
// event, branch and known PR associations. An older, manual or pending run cannot clear it.
func startupCandidates(runs []startupRunRecord, own uint64) []startupRunRecord {
	successes := map[string]uint64{}
	for _, run := range runs {
		if run.ID != own && run.Status == "completed" && run.Conclusion == "success" {
			k := startupHistoryKey(run)
			successes[k] = max(successes[k], run.Number)
		}
	}
	candidates := make([]startupRunRecord, 0)
	for _, run := range runs {
		if run.ID == own || (run.Event != "pull_request" && run.Event != "merge_group" && run.Event != "push") {
			continue
		}
		if run.Status == "completed" && run.Number > successes[startupHistoryKey(run)] &&
			(run.Conclusion == "startup_failure" || run.Conclusion == "failure") {
			candidates = append(candidates, run)
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].ID < candidates[j].ID })
	return candidates
}

// startupJobCount observes the exact failed attempt; partial or mixed pages
// cannot establish that a failure had jobs and belongs to the existing job gates.
func startupJobCount(ctx context.Context, api reader, o startupOptions, run startupRunRecord) (uint64, error) {
	var total uint64
	seen := map[uint64]bool{}
	for page := 1; page <= 100; page++ {
		var data jobsPage
		path := fmt.Sprintf("repos/%s/actions/runs/%d/attempts/%d/jobs?per_page=100&page=%d",
			o.repository, run.ID, run.Attempt, page)
		if err := readJSON(ctx, api, path, &data); err != nil ||
			data.Total == nil || data.Jobs == nil || *data.Total > 10000 {
			return 0, errors.New("failed_run_jobs_unreadable")
		}
		if page == 1 {
			total = *data.Total
		}
		if *data.Total != total || uint64(len(seen)) > total ||
			uint64(len(data.Jobs)) != min(uint64(100), total-uint64(len(seen))) {
			return 0, errors.New("failed_run_jobs_incomplete")
		}
		for _, j := range data.Jobs {
			if j.ID == 0 || seen[j.ID] || j.RunID != run.ID || j.Attempt != run.Attempt || j.Head != o.head {
				return 0, errors.New("failed_run_job_identity_mismatch")
			}
			seen[j.ID] = true
		}
		if uint64(len(seen)) == total {
			return total, nil
		}
	}
	return 0, errors.New("failed_run_jobs_incomplete")
}

// inspectStartup validates two complete inventories and rebinds the invocation.
// It reports only startup evidence observed now; future events and ordinary job
// failures remain the responsibility of their existing checks.
func inspectStartup(ctx context.Context, o startupOptions, api reader) (startupReceipt, int) {
	result := startupReceipt{Schema: 1, State: "unknown", Scope: "head_workflow_startup_snapshot", Reason: "invalid_arguments"}
	if !o.valid() {
		return result, 2
	}
	result.Repository, result.Head, result.RunID, result.Attempt = o.repository, o.head, o.runID, o.attempt
	unknown := func(reason string) (startupReceipt, int) {
		result.Reason = reason
		return result, 2
	}
	currentPath := fmt.Sprintf("repos/%s/actions/runs/%d", o.repository, o.runID)
	var current startupRunRecord
	if err := readJSON(ctx, api, currentPath, &current); err != nil || !validStartupRun(current, o) ||
		current.ID != o.runID || current.Attempt != o.attempt || current.Event != o.event {
		return unknown("current_run_unverified")
	}
	normalizeStartupPRs(&current)
	runs, err := startupCensus(ctx, api, o, current)
	if err != nil {
		return unknown(err.Error())
	}
	candidates := startupCandidates(runs, o.runID)
	var failed uint64
	reason := "no_observed_startup_failure"
	for _, run := range candidates {
		if run.Conclusion == "startup_failure" {
			failed, reason = run.ID, "workflow_startup_failed"
			continue
		}
		count, err := startupJobCount(ctx, api, o, run)
		if err != nil {
			return unknown(err.Error())
		}
		if count == 0 {
			failed, reason = run.ID, "workflow_failed_without_jobs"
		}
	}
	final, err := startupCensus(ctx, api, o, current)
	if err != nil || !reflect.DeepEqual(candidates, startupCandidates(final, o.runID)) {
		return unknown("startup_evidence_changed")
	}
	var rebound startupRunRecord
	if err := readJSON(ctx, api, currentPath, &rebound); err != nil || !validStartupRun(rebound, o) {
		return unknown("current_run_changed")
	}
	normalizeStartupPRs(&rebound)
	if !sameStartupInvocation(current, rebound) {
		return unknown("current_run_changed")
	}
	result.Reason = reason
	if failed != 0 {
		result.State, result.FailedRunID = "blocked", failed
		return result, 1
	}
	result.State = "clear"
	return result, 0
}

// executeStartup exposes a bounded, read-only subcommand without changing budget mode.
func executeStartup(args []string, out io.Writer, api reader) int {
	flags := flag.NewFlagSet("startup", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var o startupOptions
	flags.StringVar(&o.repository, "repository", "", "")
	flags.StringVar(&o.head, "head-sha", "", "")
	flags.StringVar(&o.event, "event", "", "")
	flags.Uint64Var(&o.runID, "run-id", 0, "")
	flags.Uint64Var(&o.attempt, "attempt", 0, "")
	result := startupReceipt{Schema: 1, State: "unknown", Scope: "head_workflow_startup_snapshot", Reason: "invalid_arguments"}
	code := 2
	if err := flags.Parse(args); err == nil && flags.NArg() == 0 {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		result, code = inspectStartup(ctx, o, api)
	}
	if err := json.NewEncoder(out).Encode(result); err != nil {
		return 2
	}
	return code
}
