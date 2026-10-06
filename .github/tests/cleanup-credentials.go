// Check the cleanup wrapper's credential boundary and evaluated input behavior.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"regexp"
	"sort"
	"strings"
)

type object = map[string]any

// asObject returns a decoded JSON object, or nil for an absent or invalid shape.
func asObject(value any) object { result, _ := value.(map[string]any); return result }

// read decodes a workflow JSON file and fails the check on unreadable or invalid input.
func read(path string) object {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var result object
	if err := json.Unmarshal(data, &result); err != nil {
		panic(err)
	}
	return result
}

// require fails the check with a boundary-specific diagnostic when an assertion is false.
func require(condition bool, message string) {
	if !condition {
		panic(message)
	}
}

// equal compares decoded values without coercion and includes both values on failure.
func equal(actual, expected any, message string) {
	require(reflect.DeepEqual(actual, expected), fmt.Sprintf("%s: got %#v, want %#v", message, actual, expected))
}

// keys sorts object keys so interface and caller-set assertions are deterministic.
func keys(value object) []string {
	result := make([]string, 0, len(value))
	for key := range value {
		result = append(result, key)
	}
	sort.Strings(result)
	return result
}

var secrets = regexp.MustCompile(`(?i)\bsecrets\b`)

// rejectSecrets recursively permits only the exact read-only job's built-in token expression.
func rejectSecrets(value any, label string) {
	switch typed := value.(type) {
	case string:
		require(!secrets.MatchString(typed) || typed == "${{ secrets.GITHUB_TOKEN }}", label+": cleanup forwards a mutation credential")
	case map[string]any:
		for _, child := range typed {
			rejectSecrets(child, label)
		}
	case []any:
		for _, child := range typed {
			rejectSecrets(child, label)
		}
	}
}

// main checks caller authority, required-check wiring, projection parity and input semantics.
func main() {
	dir := os.Args[1]
	w := read(dir + "/workflow.json")
	ci := read(dir + "/ci.json")
	production := read(dir + "/production.json")
	jobs := asObject(ci["jobs"])
	ids := []string{"test-delete-workflow-runs-all", "test-delete-workflow-runs-specific", "test-delete-workflow-runs-minimal"}
	permissions := object{"actions": "read", "contents": "read"}
	schedule := "${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}"
	gate := asObject(jobs["ci-required-checks"])
	needed := map[string]bool{}
	for _, value := range gate["needs"].([]any) {
		if id, ok := value.(string); ok {
			needed[id] = true
		}
	}
	results := ""
	for _, value := range gate["steps"].([]any) {
		step := asObject(value)
		if step["name"] == "📊 Summarize workflow result" {
			results, _ = asObject(step["env"])["JOB_RESULTS"].(string)
		}
	}
	for _, id := range ids {
		job := asObject(jobs[id])
		require(job != nil, id+": cleanup scenario missing")
		equal(job["permissions"], permissions, id+": cleanup caller has deletion authority")
		equal(job["uses"], "./.github/workflows/delete-workflow-runs-readonly.yaml", id+": cleanup caller bypasses read-only entrypoint")
		equal(job["secrets"], nil, id+": cleanup caller forwards secrets")
		equal(job["env"], nil, id+": cleanup caller forwards environment credentials")
		equal(job["needs"], nil, id+": cleanup caller can be skipped by prerequisites")
		equal(job["if"], schedule, id+": cleanup admission changed")
		require(job["continue-on-error"] == nil || job["continue-on-error"] == false, id+": cleanup failure ignored")
		rejectSecrets(job, id)
		require(needed[id], id+": cleanup caller omitted from required needs")
		require(strings.Contains(results, "${{ needs."+id+".result }}"), id+": cleanup caller omitted from required summary")
	}
	callers := []string{}
	for id, value := range jobs {
		uses, _ := asObject(value)["uses"].(string)
		if uses == "./.github/workflows/delete-workflow-runs.yaml" || uses == "./.github/workflows/delete-workflow-runs-readonly.yaml" {
			callers = append(callers, id)
		}
	}
	sort.Strings(callers)
	expectedIDs := append([]string{}, ids...)
	sort.Strings(expectedIDs)
	equal(callers, expectedIDs, "unexpected cleanup caller")
	equal(asObject(asObject(jobs[ids[0]])["with"])["dry-run"], true, "all scenario must explicitly dry-run")
	equal(asObject(asObject(jobs[ids[1]])["with"])["dry-run"], true, "specific scenario must explicitly dry-run")
	equal(asObject(asObject(jobs[ids[1]])["with"])["delete-workflow-pattern"], "ci.yaml", "specific scenario must name an existing workflow")
	equal(asObject(jobs[ids[2]])["with"], nil, "minimal scenario must exercise declared defaults")
	equal(w["permissions"], object{}, "workflow grants ambient credentials")
	workflowJobs := asObject(w["jobs"])
	equal(keys(workflowJobs), []string{"delete-runs"}, "unexpected cleanup job")
	job := asObject(workflowJobs["delete-runs"])
	equal(job["permissions"], permissions, "cleanup callee has deletion authority")
	equal(asObject(asObject(w["on"])["workflow_call"])["secrets"], nil, "cleanup interface accepts secrets")
	equal(w["env"], nil, "cleanup workflow forwards environment credentials")
	equal(job["env"], nil, "cleanup job forwards environment credentials")
	equal(job["if"], nil, "cleanup execution disabled")
	require(job["continue-on-error"] == nil || job["continue-on-error"] == false, "cleanup execution ignores failure")
	rejectSecrets(w, "cleanup workflow")
	productionJob := asObject(asObject(production["jobs"])["delete-runs"])
	var cleanup object
	for _, value := range productionJob["steps"].([]any) {
		step := asObject(value)
		if step["name"] == "🗑️ Delete workflow runs" {
			cleanup = step
		}
	}
	require(cleanup != nil, "production cleanup action missing")
	equal(cleanup["run"], "go run .devantler-tech-actions/.github/scripts/delete-workflow-runs/main.go", "cleanup driver bypassed")
	equal(cleanup["uses"], nil, "cleanup driver bypassed")
	bindings := asObject(cleanup["env"])
	equal(bindings["CLEANUP_TOKEN"], "${{ secrets.GITHUB_TOKEN }}", "cleanup forwards a mutation credential")
	equal(cleanup["if"], nil, "production cleanup action disabled")
	equal(cleanup["continue-on-error"], nil, "production cleanup ignores failure")
	equal(job["steps"], productionJob["steps"], "cleanup projection changed production steps")
	steps := productionJob["steps"].([]any)
	require(len(steps) == 4, "cleanup driver setup changed")
	equal(asObject(asObject(steps[1])["with"]), object{"repository": "${{ job.workflow_repository }}", "ref": "${{ job.workflow_sha }}", "path": ".devantler-tech-actions", "persist-credentials": false}, "cleanup source is not this workflow's commit")
	equal(asObject(steps[1])["uses"], "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "cleanup source checkout changed")
	equal(asObject(steps[2])["uses"], "actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e", "cleanup toolchain setup changed")
	equal(asObject(steps[2])["with"], object{"go-version-file": ".devantler-tech-actions/.github/scripts/delete-workflow-runs/go.mod", "cache": false}, "cleanup toolchain setup changed")
	var cases []struct {
		Supplied object
		Expected object
	}
	err := json.Unmarshal([]byte(`[
	 {"Supplied":{},"Expected":{"repository":"fixture/catalogue","retain_days":30,"keep_minimum_runs":6,"delete_workflow_pattern":"","delete_workflow_by_state_pattern":"ALL","delete_run_by_conclusion_pattern":"ALL","dry_run":true}},
	 {"Supplied":{"repository":"fixture/other","days":0,"minimum-runs":0,"delete-workflow-pattern":"ci.yaml","delete-workflow-by-state-pattern":"active,disabled_manually","delete-run-by-conclusion-pattern":"cancelled,failure","dry-run":true},"Expected":{"repository":"fixture/other","retain_days":0,"keep_minimum_runs":0,"delete_workflow_pattern":"ci.yaml","delete_workflow_by_state_pattern":"active,disabled_manually","delete_run_by_conclusion_pattern":"cancelled,failure","dry_run":true}},
	 {"Supplied":{"days":7,"minimum-runs":3,"dry-run":false},"Expected":{"repository":"fixture/catalogue","retain_days":7,"keep_minimum_runs":3,"delete_workflow_pattern":"","delete_workflow_by_state_pattern":"ALL","delete_run_by_conclusion_pattern":"ALL","dry_run":false}}
	]`), &cases)
	if err != nil {
		panic(err)
	}
	declarations := asObject(asObject(asObject(production["on"])["workflow_call"])["inputs"])
	expression := regexp.MustCompile(`^\$\{\{ inputs\.([a-z-]+)( \|\| github\.repository)? \}\}$`)
	for _, fixture := range cases {
		inputs := object{}
		for key, value := range declarations {
			spec := asObject(value)
			selected, ok := fixture.Supplied[key]
			if !ok {
				selected = spec["default"]
			}
			if selected == nil && spec["type"] == "string" {
				selected = ""
			}
			inputs[key] = selected
		}
		actual := object{}
		for key, value := range bindings {
			if key == "CLEANUP_TOKEN" {
				continue
			}
			text, _ := value.(string)
			match := expression.FindStringSubmatch(text)
			require(match != nil, "unsupported cleanup input expression: "+text)
			selected := inputs[match[1]]
			if match[2] != "" && (selected == nil || selected == "" || selected == false || selected == float64(0)) {
				selected = "fixture/catalogue"
			}
			actual[strings.ToLower(strings.TrimPrefix(key, "INPUT_"))] = selected
		}
		equal(actual, fixture.Expected, "cleanup input behavior changed")
	}
	fmt.Println("PASS: three read-only cleanup callers; default/explicit modes, repository fallback, zero values and independent filters preserved")
}
