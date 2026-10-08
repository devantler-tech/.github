package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

const dotnetSubject = ".github/workflows/run-dotnet-tests.yaml"

var dotnetSubjects = []string{"test-run-dotnet-tests-gate-lockstep", "test-run-dotnet-tests-mtp", "test-run-dotnet-tests-workflow", "test-run-dotnet-tests-workflow-authenticated"}

func dotnetSelectionFixture(t *testing.T) (inventory, workflow) {
	t.Helper()
	i := fixtureInventory()
	w := workflow{Jobs: map[string]job{"select-ci-tests": {}, "ci-required-checks": {}, "lint-ci-coverage-parity": {}}}
	for id := range i.Jobs {
		w.Jobs[id] = job{If: selectionGuard(id), Needs: []any{"select-ci-tests"}}
	}
	i.Preserved = map[string]job{}
	for _, id := range dotnetSubjects {
		i.Jobs[id] = []string{dotnetSubject}
		j := job{If: selectionGuard(id), Needs: []any{"select-ci-tests"}}
		if id == "test-run-dotnet-tests-workflow" || id == "test-run-dotnet-tests-workflow-authenticated" {
			j.Uses = "./" + dotnetSubject
		}
		if id == "test-run-dotnet-tests-workflow-authenticated" {
			j.If = "${{ trusted_same_repository_pull_request }}"
			j.Needs = nil
			i.Preserved[id] = job{If: j.If}
		}
		w.Jobs[id] = j
	}
	return i, w
}

func TestDotnetWorkflowSelectsEveryReviewedDependency(t *testing.T) {
	i, w := dotnetSelectionFixture(t)
	if _, err := validateInventory(i, w); err != nil {
		t.Fatalf("complete .NET ownership rejected: %v", err)
	}
	if got := selectJobs(i, "pull_request", []string{dotnetSubject}); !reflect.DeepEqual(got, dotnetSubjects) {
		t.Fatalf("got %v, want %v", got, dotnetSubjects)
	}
}

func TestDotnetWorkflowOwnershipCannotOmitOrInventDependencies(t *testing.T) {
	for _, id := range dotnetSubjects {
		t.Run("missing "+id, func(t *testing.T) {
			i, w := dotnetSelectionFixture(t)
			i.Jobs[id] = []string{}
			if _, err := validateInventory(i, w); err == nil {
				t.Fatalf("accepted missing workflow owner on %s", id)
			}
		})
	}
	for _, kind := range []string{"unrelated owner", "duplicate owner", "changed caller", "unowned caller", "changed authenticated admission"} {
		t.Run(kind, func(t *testing.T) {
			i, w := dotnetSelectionFixture(t)
			switch kind {
			case "unrelated owner":
				i.Jobs["test-one"] = append(i.Jobs["test-one"], dotnetSubject)
			case "duplicate owner":
				i.Jobs[dotnetSubjects[0]] = append(i.Jobs[dotnetSubjects[0]], dotnetSubject)
			case "changed caller":
				j := w.Jobs["test-run-dotnet-tests-workflow"]
				j.Uses = "./.github/workflows/other.yaml"
				w.Jobs["test-run-dotnet-tests-workflow"] = j
			case "unowned caller":
				j := w.Jobs["test-one"]
				j.Uses = "./" + dotnetSubject
				w.Jobs["test-one"] = j
			case "changed authenticated admission":
				j := w.Jobs["test-run-dotnet-tests-workflow-authenticated"]
				j.If = "${{ true }}"
				w.Jobs["test-run-dotnet-tests-workflow-authenticated"] = j
			}
			if _, err := validateInventory(i, w); err == nil {
				t.Fatalf("accepted %s", kind)
			}
		})
	}
}

func TestDotnetWorkflowUnknownAndSharedPathsKeepFullSelection(t *testing.T) {
	i, _ := dotnetSelectionFixture(t)
	all := []string{}
	for id := range i.Jobs {
		all = append(all, id)
	}
	sort.Strings(all)
	for _, paths := range [][]string{{dotnetSubject + ".bak"}, {dotnetSubject + "/extra"}, {dotnetSubject, ".github/workflows/ci.yaml"}, {dotnetSubject, ".github/scripts/helper.sh"}} {
		if got := selectJobs(i, "pull_request", paths); !reflect.DeepEqual(got, all) {
			t.Fatalf("incomplete fallback for %v: %v", paths, got)
		}
	}
}

func TestDotnetWorkflowGitStatusRetainsFullFallback(t *testing.T) {
	for _, kind := range []string{"modified", "added", "deleted", "symlink", "renamed"} {
		t.Run(kind, func(t *testing.T) {
			dir, _, git := gitFixture(t)
			p := filepath.Join(dir, dotnetSubject)
			if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
				t.Fatal(err)
			}
			if kind != "added" {
				if err := os.WriteFile(p, []byte("base\n"), 0600); err != nil {
					t.Fatal(err)
				}
				git("add", "--", dotnetSubject)
				git("commit", "-qm", "workflow baseline")
			}
			base := git("rev-parse", "HEAD")
			switch kind {
			case "modified", "added":
				if err := os.WriteFile(p, []byte("changed\n"), 0600); err != nil {
					t.Fatal(err)
				}
			case "deleted":
				if err := os.Remove(p); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Remove(p); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("missing", p); err != nil {
					t.Fatal(err)
				}
			case "renamed":
				if err := os.Rename(p, p+".renamed"); err != nil {
					t.Fatal(err)
				}
			}
			git("add", "--", ".github/workflows")
			git("commit", "-qm", "workflow change")
			paths, err := changedPaths(dir, base, git("rev-parse", "HEAD"))
			if err != nil {
				t.Fatal(err)
			}
			i, _ := dotnetSelectionFixture(t)
			got := selectJobs(i, "pull_request", paths)
			if kind == "modified" {
				if !reflect.DeepEqual(got, dotnetSubjects) {
					t.Fatalf("ordinary modification lost its dependency selection: %v", got)
				}
			} else if len(got) != len(i.Jobs) {
				t.Fatalf("%s incorrectly narrowed coverage: %v", kind, got)
			}
		})
	}
}

func TestDotnetWorkflowRawReadDoesNotAcceptPartialSuccess(t *testing.T) {
	for _, kind := range []string{"failed-after-output", "truncated-output"} {
		t.Run(kind, func(t *testing.T) {
			dir, _, git := gitFixture(t)
			p := filepath.Join(dir, dotnetSubject)
			if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte("base\n"), 0600); err != nil {
				t.Fatal(err)
			}
			git("add", "--", dotnetSubject)
			git("commit", "-qm", "baseline")
			base := git("rev-parse", "HEAD")
			if err := os.WriteFile(p, []byte("changed\n"), 0600); err != nil {
				t.Fatal(err)
			}
			git("add", "--", dotnetSubject)
			git("commit", "-qm", "change")
			head := git("rev-parse", "HEAD")
			realGit, err := exec.LookPath("git")
			if err != nil {
				t.Fatal(err)
			}
			bin := t.TempDir()
			mock := `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == diff && "$2" == --raw ]]; then
  if [[ "$CI_RAW_CASE" == failed-after-output ]]; then
    "$CI_REAL_GIT" "$@"
    exit 17
  fi
  printf ':100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb M\0.github/workflows/run-dotnet-tests.yaml'
  exit 0
fi
exec "$CI_REAL_GIT" "$@"
`
			if err := os.WriteFile(filepath.Join(bin, "git"), []byte(mock), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("CI_REAL_GIT", realGit)
			t.Setenv("CI_RAW_CASE", kind)
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			paths, err := changedPaths(dir, base, head)
			if kind == "failed-after-output" {
				if err == nil {
					t.Fatal("accepted plausible stdout from a failed raw Git read")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				i, _ := dotnetSelectionFixture(t)
				if got := selectJobs(i, "pull_request", paths); len(got) != len(i.Jobs) {
					t.Fatalf("truncated evidence narrowed coverage: %v", got)
				}
			}
		})
	}
}
