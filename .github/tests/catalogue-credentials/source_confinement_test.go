package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSourceSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	body := []byte("runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n")
	target := filepath.Join(outside, "action.yaml")
	if e := os.WriteFile(target, body, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.MkdirAll(filepath.Join(root, "actions"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink(outside, filepath.Join(root, "actions", "fixture")); e != nil {
		t.Fatal(e)
	}
	a := auditor{root: root, sources: map[string]object{}}
	if _, e := a.readSource("actions/fixture/action.yaml", ""); e == nil {
		t.Fatal("source escaped catalogue through directory symlink")
	}
}
func TestInternalWorkflowIdentityCannotBeEvaluated(t *testing.T) {
	if known(evaluate("${{ __workflow_revision }}", context{"__workflow_revision": "fixture"})) {
		t.Fatal("internal workflow identity exposed as native context")
	}
}
