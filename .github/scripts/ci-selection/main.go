// Select catalogue self-tests only from a complete immutable Git diff and a
// reviewed job inventory. Unclassified paths retain full coverage.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
)

const scheduling = "github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ')"

type inventory struct {
	Always    []string            `json:"always"`
	Jobs      map[string][]string `json:"jobs"`
	Preserved map[string]job      `json:"preserved"`
}
type job struct {
	If    string `json:"if"`
	Needs any    `json:"needs"`
}
type workflow struct {
	Jobs map[string]job `json:"jobs"`
}

func selectionGuard(id string) string {
	return "${{ " + scheduling + " && contains(fromJSON(needs.select-ci-tests.outputs.selected), '" + id + "') }}"
}

func validateInventory(i inventory, w workflow) ([]string, error) {
	seen := map[string]bool{"select-ci-tests": true, "ci-required-checks": true}
	for _, id := range i.Always {
		if seen[id] {
			return nil, fmt.Errorf("duplicate always-on job %s", id)
		}
		j, ok := w.Jobs[id]
		if !ok {
			return nil, fmt.Errorf("missing always-on job %s", id)
		}
		if (j.If != "" && j.If != "${{ "+scheduling+" }}") || j.Needs != nil {
			return nil, fmt.Errorf("conditional shared gate %s", id)
		}
		seen[id] = true
	}
	gated := []string{}
	for id, paths := range i.Jobs {
		j, ok := w.Jobs[id]
		if !ok || seen[id] || !regexp.MustCompile(`^test-[a-z0-9-]+$`).MatchString(id) {
			return nil, fmt.Errorf("missing or invalid inventory job %s", id)
		}
		seen[id] = true
		for _, p := range paths {
			if !regexp.MustCompile(`^actions/[a-z0-9-]+/$`).MatchString(p) {
				return nil, fmt.Errorf("invalid selective owner %q", p)
			}
		}
		if original, ok := i.Preserved[id]; ok {
			if j.If != original.If || !reflect.DeepEqual(j.Needs, original.Needs) {
				return nil, fmt.Errorf("changed event-specific scheduling for %s", id)
			}
		} else {
			needs, ok := j.Needs.([]any)
			if j.If != selectionGuard(id) || !ok || len(needs) != 1 || needs[0] != "select-ci-tests" {
				return nil, fmt.Errorf("invalid selector contract for %s", id)
			}
			gated = append(gated, id)
		}
	}
	for id := range i.Preserved {
		if _, ok := i.Jobs[id]; !ok {
			return nil, fmt.Errorf("unknown preserved job %s", id)
		}
	}
	if len(seen) != len(w.Jobs) {
		return nil, fmt.Errorf("CI job inventory is incomplete")
	}
	for id := range seen {
		if _, ok := w.Jobs[id]; !ok {
			return nil, fmt.Errorf("missing CI job %s", id)
		}
	}
	sort.Strings(gated)
	return gated, nil
}

func selectJobs(i inventory, event string, paths []string) []string {
	all := []string{}
	for id := range i.Jobs {
		all = append(all, id)
	}
	sort.Strings(all)
	if event != "pull_request" || len(paths) == 0 {
		return all
	}
	selected := map[string]bool{}
	for _, path := range paths {
		known := false
		for id, owners := range i.Jobs {
			for _, owner := range owners {
				if strings.HasPrefix(path, owner) {
					selected[id], known = true, true
				}
			}
		}
		if !known {
			return all
		}
	}
	result := []string{}
	for id := range selected {
		result = append(result, id)
	}
	sort.Strings(result)
	return result
}

func changedPaths(root, base, head string) ([]string, error) {
	sha := regexp.MustCompile(`^[a-f0-9]{40}$`)
	if !sha.MatchString(base) || !sha.MatchString(head) {
		return nil, fmt.Errorf("base and head must be immutable full commit IDs")
	}
	git := func(args ...string) ([]byte, error) {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		out, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("incomplete Git evidence: %w", err)
		}
		return out, nil
	}
	for _, ref := range []string{base, head} {
		out, err := git("rev-parse", "--verify", ref+"^{commit}")
		if err != nil || strings.TrimSpace(string(out)) != ref {
			return nil, fmt.Errorf("unresolved commit %s", ref)
		}
	}
	ancestor, err := git("merge-base", "--all", base, head)
	if err != nil {
		return nil, err
	}
	mergeBase := strings.TrimSpace(string(ancestor))
	if !sha.MatchString(mergeBase) {
		return nil, fmt.Errorf("ambiguous merge base")
	}
	// Disabling rename detection deliberately yields both old and new paths.
	// NUL boundaries preserve spaces/newlines without API pagination or truncation.
	out, err := git("diff", "--name-only", "--no-renames", "-z", mergeBase, head, "--")
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, nil
	}
	if out[len(out)-1] != 0 {
		return nil, fmt.Errorf("incomplete path boundaries")
	}
	return strings.Split(string(out[:len(out)-1]), "\x00"), nil
}

func load(path string, value any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	d := json.NewDecoder(f)
	d.DisallowUnknownFields()
	return d.Decode(value)
}

func run() error {
	if len(os.Args) != 4 {
		return fmt.Errorf("usage: ci-selection ROOT INVENTORY WORKFLOW_JSON")
	}
	root, err := filepath.Abs(os.Args[1])
	if err != nil {
		return err
	}
	var i inventory
	if err := load(os.Args[2], &i); err != nil {
		return err
	}
	// Workflow jobs have many unrelated fields; admit them as data, never commands.
	data, err := os.ReadFile(os.Args[3])
	if err != nil {
		return err
	}
	var w workflow
	if err := json.Unmarshal(data, &w); err != nil {
		return err
	}
	gated, err := validateInventory(i, w)
	if err != nil {
		return err
	}
	var paths []string
	event := os.Getenv("EVENT_NAME")
	if event == "pull_request" {
		paths, err = changedPaths(root, os.Getenv("BASE_SHA"), os.Getenv("HEAD_SHA"))
		if err != nil {
			return err
		}
	}
	eligible := os.Getenv("RUN_CATALOGUE")
	if eligible != "true" && eligible != "false" {
		return fmt.Errorf("unknown catalogue scheduling eligibility")
	}
	selected := selectJobs(i, event, paths)
	chosen := map[string]bool{}
	for _, id := range selected {
		chosen[id] = true
	}
	result := []string{}
	if eligible == "true" {
		for _, id := range gated {
			if chosen[id] {
				result = append(result, id)
			}
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(os.Getenv("GITHUB_OUTPUT"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := fmt.Fprintf(f, "selected=%s\n", encoded); err != nil {
		return err
	}
	fmt.Printf("Selected %d of %d gated catalogue jobs; existing shared and event-specific jobs are unchanged.\n", len(result), len(gated))
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "CI selection:", err)
		os.Exit(1)
	}
}
