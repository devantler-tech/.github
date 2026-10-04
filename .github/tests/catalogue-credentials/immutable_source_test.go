package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestReviewImmutableSymlinkIdentity binds admission to checked-out metadata, not link target text.
func TestReviewImmutableSymlinkIdentity(t *testing.T) {
	root := t.TempDir()
	runGit := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		b, e := cmd.Output()
		if e != nil {
			t.Fatalf("git %v: %v %s", args, e, b)
		}
		return strings.TrimSpace(string(b))
	}
	runGit("init", "--quiet")
	runGit("config", "core.symlinks", "true")
	directory := filepath.Join(root, "actions", "fixture")
	if e := os.MkdirAll(directory, 0700); e != nil {
		t.Fatal(e)
	}
	target := "runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}"
	realMetadata := []byte("runs: {using: composite, steps: [{uses: devantler-tech/.github/.github/actions/prepare-fixes@main}]}\n")
	if e := os.WriteFile(filepath.Join(directory, target), realMetadata, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink(target, filepath.Join(directory, "action.yaml")); e != nil {
		t.Fatal(e)
	}
	runGit("add", "--", "actions/fixture")
	runGit("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
	revision := runGit("rev-parse", "HEAD")
	t.Log("tree:", runGit("ls-tree", revision, "actions/fixture/action.yaml"))
	t.Log("Git link bytes:", runGit("show", revision+":actions/fixture/action.yaml"))
	checkout := filepath.Join(t.TempDir(), "checkout")
	clone := exec.Command("git", "-c", "core.symlinks=true", "clone", "--quiet", "--no-hardlinks", root, checkout)
	if _, e := clone.Output(); e != nil {
		t.Fatal(e)
	}
	linkInfo, e := os.Lstat(filepath.Join(checkout, "actions/fixture/action.yaml"))
	if e != nil {
		t.Fatal(e)
	}
	if linkInfo.Mode()&os.ModeSymlink == 0 {
		t.Fatal("native Git checkout did not preserve committed symlink")
	}
	actual, e := os.ReadFile(filepath.Join(checkout, "actions/fixture/action.yaml"))
	if e != nil {
		t.Fatal(e)
	}
	if string(actual) == target {
		t.Fatal("fixture did not follow native filesystem symlink")
	}
	actualObject, e := decode(actual)
	if e != nil {
		t.Fatal(e)
	}
	nested := slice(asObject(actualObject["runs"])["steps"])
	if len(nested) != 1 {
		t.Fatal("actual linked metadata has wrong control")
	}
	nestedRef := text(asObject(nested[0])["uses"])
	if _, _, _, e := reference(nestedRef, revision, true); e == nil {
		t.Fatal("actual linked metadata did not require mutable-source rejection")
	}
	ci := "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/.github, ref: " + revision + ", path: helper}\n      - uses: ./helper/actions/fixture\n"
	if e := os.MkdirAll(filepath.Join(root, ".github/workflows"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, ".github/workflows/ci.yaml"), []byte(ci), 0600); e != nil {
		t.Fatal(e)
	}
	a := auditor{root: root, sources: map[string]object{}, active: map[string]bool{}}
	c := context{"github.repository": "devantler-tech/.github", "github.event_name": "pull_request", "github.token": builtinToken{}, "secrets.github_token": builtinToken{}}
	if e := a.workflow(".github/workflows/ci.yaml", "", c, nil, nil, nil); e == nil {
		t.Fatal("false-clean: immutable mode120000 link bytes classified instead of checked-out target metadata")
	}
}

// TestImmutableTreeObservation rejects partial, contradictory and ambiguous API identities.
func TestImmutableTreeObservation(t *testing.T) {
	sha := "1111111111111111111111111111111111111111"
	regular := `{"sha":"1111111111111111111111111111111111111111","truncated":false,"tree":[{"path":"action.yaml","mode":"100644","type":"blob","sha":"2222222222222222222222222222222222222222"}]}`
	entries, e := decodeSourceTree([]byte(regular), sha)
	if e != nil || entries["action.yaml"].Mode != "100644" {
		t.Fatalf("regular complete tree rejected: %v", e)
	}
	for _, raw := range []string{
		strings.Replace(regular, `"truncated":false`, `"truncated":true`, 1),
		strings.Replace(regular, `"truncated":false,`, ``, 1),
		strings.Replace(regular, `"sha":"1111111111111111111111111111111111111111"`, `"sha":"3333333333333333333333333333333333333333"`, 1),
		`{"sha":"1111111111111111111111111111111111111111","truncated":false,"tree":null}`,
		strings.Replace(regular, `"mode":"100644",`, ``, 1),
		strings.Replace(regular, `"sha":"2222222222222222222222222222222222222222"`, `"sha":"unknown"`, 1),
		`{"sha":"1111111111111111111111111111111111111111","truncated":false,"tree":[{"path":"action.yaml","mode":"100644","type":"blob","sha":"2222222222222222222222222222222222222222"},{"path":"action.yaml","mode":"120000","type":"blob","sha":"3333333333333333333333333333333333333333"}]}`,
	} {
		if _, e := decodeSourceTree([]byte(raw), sha); e == nil {
			t.Fatalf("incomplete or contradictory tree accepted: %s", raw)
		}
	}
}

// TestImmutableRegularActionYML proves regular metadata and missing-name fallback remain admitted.
func TestImmutableRegularActionYML(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "actions/fixture/action.yml")
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(path, []byte("runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n"), 0600); e != nil {
		t.Fatal(e)
	}
	runGit := func(args ...string) string {
		t.Helper()
		b, e := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
		if e != nil {
			t.Fatalf("git %v: %v", args, e)
		}
		return strings.TrimSpace(string(b))
	}
	runGit("init", "--quiet")
	runGit("add", "--", "actions/fixture/action.yml")
	runGit("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
	revision := runGit("rev-parse", "HEAD")
	a := auditor{root: root, sources: map[string]object{}, active: map[string]bool{}}
	if _, e := a.readSource("actions/fixture/action.yml", revision); e != nil {
		t.Fatal(e)
	}
	c := context{"__catalogue_guard_scope": 1}
	bindings := map[string]binding{"helper": {valid: true, revision: revision}}
	if e := a.steps([]any{object{"uses": "./helper/actions/fixture"}}, "", c, bindings); e != nil {
		t.Fatalf("regular action.yml fallback rejected: %v", e)
	}
}
