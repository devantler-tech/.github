package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func cleanupSelectionFixture(t *testing.T) (inventory, workflow) {
	t.Helper()
	i, w := dotnetSelectionFixture(t)
	i.Jobs["test-workflow"] = []string{
		".github/workflows/delete-workflow-runs.yaml",
		".github/workflows/delete-workflow-runs-readonly.yaml",
		cleanupImplementation,
		cleanupModule,
	}
	i.Preserved["test-workflow"] = job{If: "${{ " + scheduling + " }}"}
	// Decode the native workflow shape so an absent caller binding cannot be
	// hidden by constructing only the fields that the old validator examined.
	var caller job
	if err := json.Unmarshal([]byte(`{"if":"${{ `+scheduling+` }}","uses":"./.github/workflows/delete-workflow-runs-readonly.yaml"}`), &caller); err != nil {
		t.Fatal(err)
	}
	w.Jobs["test-workflow"] = caller
	return i, w
}

func TestCleanupWorkflowSelectsItsPreservedCallers(t *testing.T) {
	i, w := cleanupSelectionFixture(t)
	if _, err := validateInventory(i, w); err != nil {
		t.Fatalf("complete read-only caller inventory rejected: %v", err)
	}
	for _, path := range []string{
		".github/workflows/delete-workflow-runs.yaml",
		".github/workflows/delete-workflow-runs-readonly.yaml",
		cleanupImplementation,
		cleanupModule,
	} {
		if got := selectJobs(i, "pull_request", []string{path}); !reflect.DeepEqual(got, []string{"test-workflow"}) {
			t.Fatalf("cleanup-only change allocated unrelated catalogue jobs: %v", got)
		}
	}
}

func TestCleanupWorkflowCallerInventoryFailsClosed(t *testing.T) {
	for _, mutation := range []string{"wrong caller", "missing production", "missing projection", "missing implementation", "missing module", "unclassified workflow"} {
		t.Run(mutation, func(t *testing.T) {
			i, w := cleanupSelectionFixture(t)
			switch mutation {
			case "wrong caller":
				w.Jobs["test-workflow"] = job{If: "${{ " + scheduling + " }}"}
			case "missing production":
				i.Jobs["test-workflow"] = i.Jobs["test-workflow"][1:]
			case "missing projection":
				i.Jobs["test-workflow"] = []string{i.Jobs["test-workflow"][0], cleanupImplementation, cleanupModule}
			case "missing implementation":
				i.Jobs["test-workflow"] = []string{i.Jobs["test-workflow"][0], i.Jobs["test-workflow"][1], cleanupModule}
			case "missing module":
				i.Jobs["test-workflow"] = i.Jobs["test-workflow"][:3]
			case "unclassified workflow":
				i.Jobs["test-workflow"] = []string{".github/workflows/publish-app.yaml"}
			}
			if _, err := validateInventory(i, w); err == nil {
				t.Fatal("accepted incomplete or unbound workflow ownership")
			}
		})
	}
}

func TestCleanupWorkflowPathsRequireExactMatches(t *testing.T) {
	i, _ := cleanupSelectionFixture(t)
	full := []string{"test-one", "test-one-wrapper", "test-run-dotnet-tests-gate-lockstep", "test-run-dotnet-tests-mtp", "test-run-dotnet-tests-workflow", "test-run-dotnet-tests-workflow-authenticated", "test-two", "test-workflow"}
	for _, path := range []string{
		".github/workflows/delete-workflow-runs.yaml.bak",
		".github/workflows/delete-workflow-runs-readonly.yaml/extra",
		".github/workflows/publish-app.yaml",
		".github/workflows/ci.yaml",
		".github/scripts/generate-cleanup-readonly.sh",
		".github/scripts/delete-workflow-runs/main_test.go",
		".github/scripts/delete-workflow-runs-other/main.go",
	} {
		if got := selectJobs(i, "pull_request", []string{path}); !reflect.DeepEqual(got, full) {
			t.Fatalf("unclassified path %q lost complete coverage: %v", path, got)
		}
	}
}

func TestCleanupProductionSourceGitStatusRetainsFullFallback(t *testing.T) {
	for _, subject := range []string{cleanupImplementation, cleanupModule} {
		for _, kind := range []string{"modified", "added", "deleted", "symlink"} {
			t.Run(filepath.Base(subject)+"/"+kind, func(t *testing.T) {
				dir, _, git := gitFixture(t)
				path := filepath.Join(dir, subject)
				if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
					t.Fatal(err)
				}
				if kind != "added" {
					if err := os.WriteFile(path, []byte("base\n"), 0600); err != nil {
						t.Fatal(err)
					}
					git("add", "--", subject)
					git("commit", "-qm", "cleanup source baseline")
				}
				base := git("rev-parse", "HEAD")
				switch kind {
				case "modified", "added":
					if err := os.WriteFile(path, []byte("changed\n"), 0600); err != nil {
						t.Fatal(err)
					}
				case "deleted":
					if err := os.Remove(path); err != nil {
						t.Fatal(err)
					}
				case "symlink":
					if err := os.Remove(path); err != nil {
						t.Fatal(err)
					}
					if err := os.Symlink("missing", path); err != nil {
						t.Fatal(err)
					}
				}
				git("add", "--", subject)
				git("commit", "-qm", "cleanup source change")
				paths, err := changedPaths(dir, base, git("rev-parse", "HEAD"))
				if err != nil {
					t.Fatal(err)
				}
				i, _ := cleanupSelectionFixture(t)
				got := selectJobs(i, "pull_request", paths)
				if kind == "modified" {
					if !reflect.DeepEqual(got, []string{"test-workflow"}) {
						t.Fatalf("ordinary modification lost cleanup selection: %v", got)
					}
				} else if len(got) != len(i.Jobs) {
					t.Fatalf("%s incorrectly narrowed coverage: %v", kind, got)
				}
			})
		}
	}
}

func TestCleanupWorkflowEntrypointRequiresNativeCallerSuccess(t *testing.T) {
	dir, _, git := gitFixture(t)
	path := filepath.Join(dir, ".github/workflows/delete-workflow-runs.yaml")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("base\n"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".github/workflows/delete-workflow-runs.yaml")
	git("commit", "-qm", "cleanup baseline")
	base := git("rev-parse", "HEAD")
	if err := os.WriteFile(path, []byte("changed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".github/workflows/delete-workflow-runs.yaml")
	git("commit", "-qm", "cleanup change")
	i, w := cleanupSelectionFixture(t)
	for name, value := range map[string]any{"inventory.json": i, "workflow.json": w} {
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	args := os.Args
	os.Args = []string{"ci-selection", dir, filepath.Join(dir, "inventory.json"), filepath.Join(dir, "workflow.json")}
	t.Cleanup(func() { os.Args = args })
	output := filepath.Join(dir, "output")
	if err := os.WriteFile(output, nil, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("EVENT_NAME", "pull_request")
	t.Setenv("RUN_CATALOGUE", "true")
	t.Setenv("CATALOGUE_SCOPE", "true")
	t.Setenv("BASE_SHA", base)
	t.Setenv("HEAD_SHA", git("rev-parse", "HEAD"))
	t.Setenv("GITHUB_OUTPUT", output)
	if err := run(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil || string(data) != "selected=[\"test-workflow\"]\n" {
		t.Fatalf("native caller was not bound into the required reducer: %q, %v", data, err)
	}
}
