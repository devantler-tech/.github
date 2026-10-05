package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type failingOutput struct {
	bytes.Buffer
	writeErr, closeErr error
	shortWrite         bool
	closed             int
}

func (output *failingOutput) Write(data []byte) (int, error) {
	if output.writeErr != nil {
		return 0, output.writeErr
	}
	if output.shortWrite {
		data = data[:len(data)-1]
	}
	return output.Buffer.Write(data)
}

func (output *failingOutput) Close() error {
	output.closed++
	return output.closeErr
}

func TestSelectionOutputPropagatesWriteAndCloseFailures(t *testing.T) {
	writeFailure := errors.New("write failed")
	closeFailure := errors.New("close failed")
	for _, tc := range []struct {
		name               string
		writeErr, closeErr error
		shortWrite         bool
		want               []error
	}{
		{name: "complete output"},
		{name: "write failure", writeErr: writeFailure, want: []error{writeFailure}},
		{name: "close failure", closeErr: closeFailure, want: []error{closeFailure}},
		{name: "both failures", writeErr: writeFailure, closeErr: closeFailure, want: []error{writeFailure, closeFailure}},
		{name: "short output", shortWrite: true, want: []error{io.ErrShortWrite}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			output := &failingOutput{writeErr: tc.writeErr, closeErr: tc.closeErr, shortWrite: tc.shortWrite}
			err := writeSelectionOutput(output, []byte(`["test-one"]`))
			for _, want := range tc.want {
				if !errors.Is(err, want) {
					t.Errorf("selection output error = %v; want %v", err, want)
				}
			}
			if len(tc.want) == 0 && (err != nil || output.String() != "selected=[\"test-one\"]\n") {
				t.Errorf("complete output = %q, error %v", output.String(), err)
			}
			if output.closed != 1 {
				t.Errorf("closed %d times; want exactly once even after write failure", output.closed)
			}
		})
	}
}

func fixtureInventory() inventory {
	return inventory{Always: []string{"lint-ci-coverage-parity"}, Jobs: map[string][]string{
		"test-one": {"actions/one/"}, "test-one-wrapper": {"actions/one/"},
		"test-two": {"actions/two/"}, "test-workflow": {},
	}}
}

func TestCompleteSelection(t *testing.T) {
	i := fixtureInventory()
	for _, tc := range []struct {
		name, event string
		paths       []string
		want        []string
	}{
		{"isolated action", "pull_request", []string{"actions/one/action.yaml"}, []string{"test-one", "test-one-wrapper"}},
		{"multiple actions", "pull_request", []string{"actions/one/README.md", "actions/two/action.yaml"}, []string{"test-one", "test-one-wrapper", "test-two"}},
		{"unknown action", "pull_request", []string{"actions/new/action.yaml"}, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"prefix collision", "pull_request", []string{"actions/one-extra/action.yaml"}, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"shared helper", "pull_request", []string{".scripts/retry.sh"}, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"mixed known unknown", "pull_request", []string{"actions/one/action.yaml", "unclassified"}, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"workflow change", "pull_request", []string{".github/workflows/ci.yaml"}, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"empty diff", "pull_request", nil, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"main retains full coverage", "push", []string{"actions/one/action.yaml"}, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
		{"merge group retains full coverage", "merge_group", nil, []string{"test-one", "test-one-wrapper", "test-two", "test-workflow"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := selectJobs(i, tc.event, tc.paths); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %v; want %v", got, tc.want)
			}
		})
	}
}

func gitFixture(t *testing.T) (string, string, func(...string) string) {
	t.Helper()
	dir := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %s: %v", args, out, err)
		}
		return strings.TrimSpace(string(out))
	}
	git("init", "-q")
	git("config", "user.name", "CI fixture")
	git("config", "user.email", "fixture@example.invalid")
	git("config", "commit.gpgsign", "false")
	path := filepath.Join(dir, "actions/one/action.yaml")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("original\n"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", "actions/one/action.yaml")
	git("commit", "-qm", "base")
	return dir, git("rev-parse", "HEAD"), git
}

func TestGitDiffRetainsBothRenameSurfaces(t *testing.T) {
	dir, base, git := gitFixture(t)
	if err := os.MkdirAll(filepath.Join(dir, "actions/two"), 0700); err != nil {
		t.Fatal(err)
	}
	git("mv", "actions/one/action.yaml", "actions/two/action.yaml")
	git("commit", "-qm", "rename")
	paths, err := changedPaths(dir, base, git("rev-parse", "HEAD"))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"actions/one/action.yaml", "actions/two/action.yaml"}; !reflect.DeepEqual(paths, want) {
		t.Fatalf("rename surfaces %v; want %v", paths, want)
	}
	if got := selectJobs(fixtureInventory(), "pull_request", paths); len(got) != 3 {
		t.Fatalf("renamed-away owner lost: %v", got)
	}
}

func TestGitEvidenceMustBeImmutableAndComplete(t *testing.T) {
	dir, base, _ := gitFixture(t)
	for _, head := range []string{"HEAD", "main", strings.Repeat("a", 40), "--help", ""} {
		if _, err := changedPaths(dir, base, head); err == nil {
			t.Fatalf("accepted unresolved or mutable head %q", head)
		}
	}
	if _, err := changedPaths(t.TempDir(), base, base); err == nil {
		t.Fatal("accepted missing Git history")
	}
}

func TestCrissCrossMergeBasesAreNotPartialEvidence(t *testing.T) {
	dir, base, git := gitFixture(t)
	tree := git("rev-parse", base+"^{tree}")
	a := git("commit-tree", tree, "-p", base, "-m", "independent A")
	b := git("commit-tree", tree, "-p", base, "-m", "independent B")
	ab := git("commit-tree", tree, "-p", a, "-p", b, "-m", "merge A B")
	ba := git("commit-tree", tree, "-p", b, "-p", a, "-m", "merge B A")
	if bases := strings.Fields(git("merge-base", "--all", ab, ba)); len(bases) != 2 {
		t.Fatalf("fixture must have exactly two best bases: %v", bases)
	}
	if _, err := changedPaths(dir, ab, ba); err == nil || !strings.Contains(err.Error(), "ambiguous merge base") {
		t.Fatalf("ambiguous Git evidence was accepted: %v", err)
	}
}

func TestJobInventoryFailsClosed(t *testing.T) {
	i := fixtureInventory()
	w := workflow{Jobs: map[string]job{
		"select-ci-tests": {}, "ci-required-checks": {}, "lint-ci-coverage-parity": {},
		"test-one":         {If: selectionGuard("test-one"), Needs: []any{"select-ci-tests"}},
		"test-one-wrapper": {If: selectionGuard("test-one-wrapper"), Needs: []any{"select-ci-tests"}},
		"test-two":         {If: selectionGuard("test-two"), Needs: []any{"select-ci-tests"}},
		"test-workflow":    {If: selectionGuard("test-workflow"), Needs: []any{"select-ci-tests"}},
	}}
	if _, err := validateInventory(i, w); err != nil {
		t.Fatal(err)
	}
	delete(i.Jobs, "test-one")
	if _, err := validateInventory(i, w); err == nil {
		t.Fatal("accepted dropped job inventory")
	}
	i = fixtureInventory()
	w.Jobs["new-test"] = job{}
	if _, err := validateInventory(i, w); err == nil {
		t.Fatal("accepted unclassified new CI job")
	}
	delete(w.Jobs, "new-test")
	w.Jobs["test-one"] = job{If: "false"}
	if _, err := validateInventory(i, w); err == nil {
		t.Fatal("accepted a conditional job bypass")
	}
	w.Jobs["test-one"] = job{If: selectionGuard("test-one"), Needs: []any{"select-ci-tests"}}
	for _, optional := range [][]string{{"missing-job"}, {"lint-ci-coverage-parity"}, {"test-one", "test-one"}} {
		i.CatalogueOptional = optional
		if _, err := validateInventory(i, w); err == nil {
			t.Fatalf("accepted invalid optional smoke inventory %v", optional)
		}
	}
	i.CatalogueOptional = []string{"test-one"}
	i.Preserved = map[string]job{"test-one": w.Jobs["test-one"]}
	if _, err := validateInventory(i, w); err == nil {
		t.Fatal("accepted omission of an event-specific preserved job")
	}
}

func TestEntrypointBindsGitEvidenceAndSelectedOutput(t *testing.T) {
	dir, base, git := gitFixture(t)
	if err := os.WriteFile(filepath.Join(dir, "actions/one/action.yaml"), []byte("changed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", "actions/one/action.yaml")
	git("commit", "-qm", "isolated action")
	head := git("rev-parse", "HEAD")
	i := fixtureInventory()
	w := workflow{Jobs: map[string]job{
		"select-ci-tests": {}, "ci-required-checks": {}, "lint-ci-coverage-parity": {},
	}}
	for id := range i.Jobs {
		w.Jobs[id] = job{If: selectionGuard(id), Needs: []any{"select-ci-tests"}}
	}
	writeJSON := func(name string, value any) string {
		t.Helper()
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	args := os.Args
	os.Args = []string{"ci-selection", dir, writeJSON("inventory.json", i), writeJSON("workflow.json", w)}
	t.Cleanup(func() { os.Args = args })
	output := filepath.Join(dir, "output")
	for _, tc := range []struct {
		name, event, eligible, head, want string
		fails                             bool
	}{
		{"selective PR", "pull_request", "true", head, "selected=[\"test-one\",\"test-one-wrapper\"]\n", false},
		{"main retains complete inventory", "push", "true", "", "selected=[\"test-one\",\"test-one-wrapper\",\"test-two\",\"test-workflow\"]\n", false},
		{"excluded event", "merge_group", "false", "", "selected=[]\n", false},
		{"missing immutable head", "pull_request", "true", strings.Repeat("a", 40), "", true},
		{"unknown eligibility", "push", "", "", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("EVENT_NAME", tc.event)
			t.Setenv("RUN_CATALOGUE", tc.eligible)
			t.Setenv("CATALOGUE_SCOPE", "true")
			t.Setenv("BASE_SHA", base)
			t.Setenv("HEAD_SHA", tc.head)
			t.Setenv("GITHUB_OUTPUT", output)
			if err := os.WriteFile(output, nil, 0600); err != nil {
				t.Fatal(err)
			}
			if err := run(); (err != nil) != tc.fails {
				t.Fatalf("entrypoint error %v; expected failure %v", err, tc.fails)
			}
			data, err := os.ReadFile(output)
			if err != nil || string(data) != tc.want {
				t.Fatalf("output %q, error %v; want %q", data, err, tc.want)
			}
		})
	}
}

// A trusted deployment-only decision may omit only the optional smoke jobs,
// never the independent tests. Missing evidence must not become permission.
func TestDeploymentCatalogueScopeComposesWithSelection(t *testing.T) {
	dir, _, git := gitFixture(t)
	path := filepath.Join(dir, "deploy/example.yaml")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("base\n"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", "deploy/example.yaml")
	git("commit", "-qm", "deployment base")
	base := git("rev-parse", "HEAD")
	if err := os.WriteFile(path, []byte("changed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", "deploy/example.yaml")
	git("commit", "-qm", "deployment change")
	head := git("rev-parse", "HEAD")
	i := fixtureInventory()
	w := workflow{Jobs: map[string]job{"select-ci-tests": {}, "ci-required-checks": {}, "lint-ci-coverage-parity": {}}}
	for id := range i.Jobs {
		w.Jobs[id] = job{If: selectionGuard(id), Needs: []any{"select-ci-tests"}}
	}
	writeJSON := func(name string, value any) string {
		t.Helper()
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		file := filepath.Join(dir, name)
		if err := os.WriteFile(file, data, 0600); err != nil {
			t.Fatal(err)
		}
		return file
	}
	inventoryJSON := map[string]any{"always": i.Always, "jobs": i.Jobs, "catalogue_optional": []string{"test-one", "test-two"}}
	args := os.Args
	os.Args = []string{"ci-selection", dir, writeJSON("inventory.json", inventoryJSON), writeJSON("workflow.json", w)}
	t.Cleanup(func() { os.Args = args })
	output := filepath.Join(dir, "output")
	for _, tc := range []struct {
		name, event, eligible, scope, want string
		fails                              bool
	}{
		{"deployment smoke omission only", "pull_request", "true", "false", "selected=[\"test-one-wrapper\",\"test-workflow\"]\n", false},
		{"full scope", "pull_request", "true", "true", "selected=[\"test-one\",\"test-one-wrapper\",\"test-two\",\"test-workflow\"]\n", false},
		{"missing scope", "pull_request", "true", "", "", true},
		{"malformed scope", "pull_request", "true", "unknown", "", true},
		{"push cannot omit smoke", "push", "true", "false", "", true},
		{"excluded event with skipped scope", "merge_group", "false", "", "selected=[]\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("EVENT_NAME", tc.event)
			t.Setenv("RUN_CATALOGUE", tc.eligible)
			t.Setenv("CATALOGUE_SCOPE", tc.scope)
			t.Setenv("BASE_SHA", base)
			t.Setenv("HEAD_SHA", head)
			t.Setenv("GITHUB_OUTPUT", output)
			if err := os.WriteFile(output, nil, 0600); err != nil {
				t.Fatal(err)
			}
			if err := run(); (err != nil) != tc.fails {
				t.Fatalf("entrypoint error %v; expected failure %v", err, tc.fails)
			}
			data, err := os.ReadFile(output)
			if err != nil || string(data) != tc.want {
				t.Fatalf("output %q, error %v; want %q", data, err, tc.want)
			}
		})
	}
}
