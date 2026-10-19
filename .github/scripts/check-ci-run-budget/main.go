package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"time"
)

type options struct {
	repository, head, workflow, event string
	runID, attempt                    uint64
}

type reader interface {
	read(context.Context, string) ([]byte, error)
}

type receipt struct {
	Schema         int      `json:"schema"`
	State          string   `json:"state"`
	Scope          string   `json:"scope"`
	Reason         string   `json:"reason"`
	Repository     string   `json:"repository,omitempty"`
	RunID          uint64   `json:"run_id,omitempty"`
	Attempt        uint64   `json:"attempt,omitempty"`
	Head           string   `json:"head_sha,omitempty"`
	CreatedAt      string   `json:"created_at,omitempty"`
	CompletedAt    string   `json:"completed_at,omitempty"`
	Jobs           int      `json:"jobs,omitempty"`
	BudgetSeconds  int      `json:"budget_seconds"`
	ElapsedSeconds *float64 `json:"elapsed_seconds"`
}

type workflowRun struct {
	ID         uint64 `json:"id"`
	Attempt    uint64 `json:"run_attempt"`
	Repository struct {
		Name string `json:"full_name"`
	} `json:"repository"`
	Head       string `json:"head_sha"`
	Path       string `json:"path"`
	Event      string `json:"event"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	CreatedAt  string `json:"created_at"`
}

type job struct {
	ID          uint64  `json:"id"`
	RunID       uint64  `json:"run_id"`
	Attempt     uint64  `json:"run_attempt"`
	Head        string  `json:"head_sha"`
	Status      string  `json:"status"`
	Conclusion  string  `json:"conclusion"`
	StartedAt   *string `json:"started_at"`
	CompletedAt *string `json:"completed_at"`
}

type jobsPage struct {
	Total *uint64 `json:"total_count"`
	Jobs  []job   `json:"jobs"`
}

var repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$`)
var shaPattern = regexp.MustCompile(`^[a-f0-9]{40}$`)
var workflowPattern = regexp.MustCompile(`^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.ya?ml$`)

func (o options) valid() bool {
	return repositoryPattern.MatchString(o.repository) &&
		o.repository[len(o.repository)-1:] != "/" &&
		o.repository[len(o.repository)-2:] != "/." &&
		o.repository[len(o.repository)-3:] != "/.." &&
		shaPattern.MatchString(o.head) && workflowPattern.MatchString(o.workflow) &&
		(o.event == "pull_request" || o.event == "merge_group") && o.runID > 0 && o.attempt > 0
}

func readJSON(ctx context.Context, api reader, path string, out any) error {
	data, err := api.read(ctx, path)
	if err != nil {
		return fmt.Errorf("metadata read failed")
	}
	if len(data) > 8<<20 {
		return fmt.Errorf("metadata response too large")
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("invalid metadata")
	}
	return nil
}

func inspect(ctx context.Context, o options, api reader, now time.Time) (receipt, int) {
	result := receipt{Schema: 1, State: "unknown", Scope: "single_workflow_run", Reason: "invalid_arguments", BudgetSeconds: 900}
	unknown := func(reason string) (receipt, int) { result.Reason = reason; return result, 2 }
	if !o.valid() {
		return result, 2
	}
	result.Repository = o.repository
	result.RunID = o.runID
	result.Attempt = o.attempt
	result.Head = o.head
	path := fmt.Sprintf("repos/%s/actions/runs/%d", o.repository, o.runID)
	var run workflowRun
	if err := readJSON(ctx, api, path, &run); err != nil {
		return unknown("run_read_failed")
	}
	if run.ID != o.runID || run.Attempt != o.attempt || run.Repository.Name != o.repository ||
		run.Head != o.head || run.Path != o.workflow || run.Event != o.event || run.Status != "completed" {
		return unknown("run_identity_or_state_mismatch")
	}
	created, err := time.Parse(time.RFC3339Nano, run.CreatedAt)
	if err != nil || created.Year() < 2008 || created.After(now.Add(5*time.Second)) {
		return unknown("invalid_creation_time")
	}
	if run.Conclusion == "failure" || run.Conclusion == "cancelled" || run.Conclusion == "timed_out" || run.Conclusion == "action_required" {
		result.State = "ci_failed"
		result.Reason = "workflow_did_not_succeed"
		return result, 1
	}
	if run.Conclusion != "success" {
		return unknown("workflow_result_unknown")
	}
	var expected uint64
	seen := map[uint64]bool{}
	var ended time.Time
	successful := false
	for page := 1; page <= 100; page++ {
		var data jobsPage
		if err := readJSON(ctx, api, fmt.Sprintf("%s/jobs?filter=latest&per_page=100&page=%d", path, page), &data); err != nil {
			return unknown("jobs_read_failed")
		}
		if data.Total == nil || *data.Total == 0 || *data.Total > 10000 {
			return unknown("invalid_job_count")
		}
		if page == 1 {
			expected = *data.Total
		}
		if *data.Total != expected {
			return unknown("job_count_changed")
		}
		remaining := expected - uint64(len(seen))
		wanted := remaining
		if wanted > 100 {
			wanted = 100
		}
		if uint64(len(data.Jobs)) != wanted {
			return unknown("incomplete_job_page")
		}
		for _, j := range data.Jobs {
			if j.ID == 0 || seen[j.ID] || j.RunID != o.runID || j.Attempt == 0 || j.Attempt > o.attempt || j.Head != o.head || j.Status != "completed" {
				return unknown("job_identity_or_state_mismatch")
			}
			seen[j.ID] = true
			if j.Conclusion != "success" && j.Conclusion != "skipped" {
				return unknown("job_did_not_succeed")
			}
			if j.CompletedAt == nil {
				return unknown("missing_job_times")
			}
			end, err := time.Parse(time.RFC3339Nano, *j.CompletedAt)
			if err != nil || end.Before(created) || end.After(now.Add(5*time.Second)) {
				return unknown("invalid_job_times")
			}
			if j.Conclusion == "success" {
				if j.StartedAt == nil {
					return unknown("missing_job_times")
				}
				start, err := time.Parse(time.RFC3339Nano, *j.StartedAt)
				if err != nil || start.Before(created) || end.Before(start) {
					return unknown("invalid_job_times")
				}
				successful = true
			}
			// A native skip has no execution interval. GitHub may stamp its
			// synthetic start after completion; only its terminal time counts.
			if end.After(ended) {
				ended = end
			}
		}
		if uint64(len(seen)) == expected {
			break
		}
	}
	if uint64(len(seen)) != expected || ended.IsZero() || !successful {
		return unknown("incomplete_jobs")
	}
	var final workflowRun
	if err := readJSON(ctx, api, path, &final); err != nil {
		return unknown("final_run_read_failed")
	}
	if final != run {
		return unknown("run_changed_during_read")
	}
	elapsed := ended.Sub(created)
	seconds := elapsed.Seconds()
	result.CreatedAt = created.UTC().Format(time.RFC3339Nano)
	result.CompletedAt = ended.UTC().Format(time.RFC3339Nano)
	result.Jobs = len(seen)
	result.ElapsedSeconds = &seconds
	result.State = "within_budget"
	result.Reason = "completed_workflow_below_900_seconds"
	if elapsed >= 15*time.Minute {
		result.State = "over_budget"
		result.Reason = "optimize_or_redesign_workflow"
		return result, 1
	}
	return result, 0
}

type commandAPI struct{ program string }

type boundedBuffer struct{ bytes.Buffer }

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 8<<20 {
		return 0, fmt.Errorf("metadata response too large")
	}
	return b.Buffer.Write(p)
}

func (a commandAPI) read(ctx context.Context, path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, a.program, "api", "--hostname", "github.com", "--method", "GET", "--", path)
	cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GH_DEBUG=")
	cmd.WaitDelay = 2 * time.Second
	var output boundedBuffer
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("metadata command failed")
	}
	return output.Bytes(), nil
}

func execute(args []string, out io.Writer, api reader, now time.Time) int {
	flags := flag.NewFlagSet("check-ci-run-budget", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var o options
	flags.StringVar(&o.repository, "repository", "", "")
	flags.StringVar(&o.head, "head-sha", "", "")
	flags.StringVar(&o.workflow, "workflow-path", "", "")
	flags.StringVar(&o.event, "event", "", "")
	flags.Uint64Var(&o.runID, "run-id", 0, "")
	flags.Uint64Var(&o.attempt, "attempt", 0, "")
	result := receipt{Schema: 1, State: "unknown", Scope: "single_workflow_run", Reason: "invalid_arguments", BudgetSeconds: 900}
	code := 2
	if err := flags.Parse(args); err == nil && flags.NArg() == 0 {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		result, code = inspect(ctx, o, api, now)
	}
	if err := json.NewEncoder(out).Encode(result); err != nil {
		return 2
	}
	return code
}

func main() {
	os.Exit(execute(os.Args[1:], os.Stdout, commandAPI{program: "gh"}, time.Now()))
}
