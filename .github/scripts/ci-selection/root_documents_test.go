package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func sortedReaders() []string {
	readers := []string{}
	for id := range readmeReaders {
		readers = append(readers, id)
	}
	sort.Strings(readers)
	return readers
}

func allJobs(i inventory) []string {
	all := []string{}
	for id := range i.Jobs {
		all = append(all, id)
	}
	sort.Strings(all)
	return all
}

func union(lists ...[]string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, list := range lists {
		for _, id := range list {
			if !seen[id] {
				seen[id] = true
				out = append(out, id)
			}
		}
	}
	sort.Strings(out)
	return out
}

// The root README selects exactly its gated readers. Root AGENTS.md only rides
// along with a recognized non-documentation change; everything else stays full.
func TestRootDocumentRouting(t *testing.T) {
	i, _ := dotnetSelectionFixture(t)
	all := allJobs(i)
	one := []string{"test-one", "test-one-wrapper"}
	readers := sortedReaders()
	for _, tc := range []struct {
		name  string
		paths []string
		want  []string
	}{
		{"README only", []string{"README.md"}, readers},
		{"AGENTS only", []string{"AGENTS.md"}, all},
		{"README and AGENTS", []string{"README.md", "AGENTS.md"}, all},
		{"AGENTS with action README only", []string{"AGENTS.md", "actions/one/README.md"}, all},
		{"AGENTS with uppercase Markdown only", []string{"AGENTS.md", "actions/one/NOTES.MD"}, all},
		{"AGENTS with action source", []string{"actions/one/action.yaml", "AGENTS.md"}, one},
		{"README with action source", []string{"actions/one/action.yaml", "README.md"}, union(one, readers)},
		{"README AGENTS and action source", []string{"AGENTS.md", "README.md", "actions/one/main.go"}, union(one, readers)},
		{"README with unknown", []string{"README.md", "unclassified"}, all},
		{"AGENTS with source and unknown", []string{"actions/one/action.yaml", "AGENTS.md", "docs/guide.md"}, all},
		{"AGENTS with shared helper", []string{".scripts/retry.sh", "AGENTS.md"}, all},
		{"AGENTS with workflow", []string{".github/workflows/ci.yaml", "AGENTS.md"}, all},
		{"nested README", []string{"docs/README.md"}, all},
		{"lowercase readme", []string{"readme.md"}, all},
		{"nested AGENTS", []string{"actions/one/action.yaml", "actions/AGENTS.md"}, all},
		{"CLAUDE shim", []string{"actions/one/action.yaml", "CLAUDE.md"}, all},
		{"unproven marker", []string{"README.md", ".ci-selection-unproven-workflow-change"}, all},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := selectJobs(i, "pull_request", tc.paths); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %v; want %v", got, tc.want)
			}
		})
	}
	for _, event := range []string{"push", "merge_group"} {
		if got := selectJobs(i, event, []string{"README.md"}); !reflect.DeepEqual(got, all) {
			t.Fatalf("%s narrowed a README change: %v", event, got)
		}
	}
}

// The reviewed production inventory binds README to exactly its readers.
func TestProductionInventoryReadmeRoute(t *testing.T) {
	var i inventory
	if err := load("inventory.json", &i); err != nil {
		t.Fatal(err)
	}
	owners := []string{}
	for id, paths := range i.Jobs {
		for _, p := range paths {
			if p == rootReadme {
				owners = append(owners, id)
			}
			if p == rootAgents {
				t.Fatalf("AGENTS.md must have no gated owner, found %s", id)
			}
		}
	}
	sort.Strings(owners)
	if !reflect.DeepEqual(owners, sortedReaders()) {
		t.Fatalf("inventory README owners %v; reviewed readers %v", owners, sortedReaders())
	}
	if got := selectJobs(i, "pull_request", []string{"README.md"}); !reflect.DeepEqual(got, sortedReaders()) {
		t.Fatalf("README-only selection %v", got)
	}
	if got := selectJobs(i, "pull_request", []string{"AGENTS.md"}); len(got) != len(i.Jobs) {
		t.Fatalf("AGENTS-only selection narrowed: %v", got)
	}
	action := selectJobs(i, "pull_request", []string{"actions/approve-pr/action.yaml"})
	if got := selectJobs(i, "pull_request", []string{"actions/approve-pr/action.yaml", "AGENTS.md"}); !reflect.DeepEqual(got, action) {
		t.Fatalf("AGENTS companion changed an action selection: %v vs %v", got, action)
	}
}

func TestReadmeReaderOwnershipFailsClosed(t *testing.T) {
	reader := sortedReaders()[0]
	for _, mutation := range []string{"complete", "missing owner", "duplicate owner", "preserved reader", "missing job", "invented reader", "AGENTS owner"} {
		t.Run(mutation, func(t *testing.T) {
			i, w := dotnetSelectionFixture(t)
			switch mutation {
			case "missing owner":
				i.Jobs[reader] = []string{}
			case "duplicate owner":
				i.Jobs[reader] = []string{rootReadme, rootReadme}
			case "preserved reader":
				i.Preserved[reader] = w.Jobs[reader]
			case "missing job":
				delete(i.Jobs, reader)
				delete(w.Jobs, reader)
			case "invented reader":
				i.Jobs["test-one"] = append(i.Jobs["test-one"], rootReadme)
			case "AGENTS owner":
				i.Jobs["test-one"] = append(i.Jobs["test-one"], rootAgents)
			}
			_, err := validateInventory(i, w)
			if mutation == "complete" {
				if err != nil {
					t.Fatalf("complete README readers rejected: %v", err)
				}
			} else if err == nil {
				t.Fatalf("accepted %s", mutation)
			}
		})
	}
}

// Additions, deletions, renames, symlinks and mode changes of a root document
// are not ordinary modifications and must keep full coverage.
func TestRootDocumentGitStatusRetainsFullFallback(t *testing.T) {
	for _, doc := range []string{rootReadme, rootAgents} {
		for _, kind := range []string{"modified", "added", "deleted", "symlink", "renamed", "executable"} {
			t.Run(doc+" "+kind, func(t *testing.T) {
				dir, _, git := gitFixture(t)
				p := filepath.Join(dir, doc)
				if kind != "added" {
					if err := os.WriteFile(p, []byte("base\n"), 0600); err != nil {
						t.Fatal(err)
					}
					git("add", "--", doc)
					git("commit", "-qm", "document baseline")
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
					if err := os.Symlink("actions/one/action.yaml", p); err != nil {
						t.Fatal(err)
					}
				case "renamed":
					if err := os.Rename(p, filepath.Join(dir, "actions/one/"+doc)); err != nil {
						t.Fatal(err)
					}
				case "executable":
					if err := os.Chmod(p, 0700); err != nil {
						t.Fatal(err)
					}
				}
				// AGENTS.md can only narrow beside a recognized source change.
				if doc == rootAgents {
					if err := os.WriteFile(filepath.Join(dir, "actions/one/action.yaml"), []byte("source\n"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				git("add", "-A", "--", ".")
				git("commit", "-qm", "document change")
				paths, err := changedPaths(dir, base, git("rev-parse", "HEAD"))
				if err != nil {
					t.Fatal(err)
				}
				i, _ := dotnetSelectionFixture(t)
				got := selectJobs(i, "pull_request", paths)
				want := sortedReaders()
				if doc == rootAgents {
					want = []string{"test-one", "test-one-wrapper"}
				}
				if kind == "modified" {
					if !reflect.DeepEqual(got, want) {
						t.Fatalf("ordinary modification selected %v; want %v", got, want)
					}
				} else if len(got) != len(i.Jobs) {
					t.Fatalf("%s incorrectly narrowed coverage: %v", kind, got)
				}
			})
		}
	}
}
