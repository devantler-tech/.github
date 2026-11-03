package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestReviewMutableGithubGuard refuses a same-text guard whose value changes between steps.
func TestReviewMutableGithubGuard(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		".github/workflows/ci.yaml":          "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - id: helper\n        if: ${{ github.action != 'helper' }}\n        uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {path: helper}\n      - id: consumer\n        if: ${{ github.action != 'helper' }}\n        uses: ./helper/actions/fixture\n",
		"actions/fixture/action.yaml":        "runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n",
		"helper/actions/fixture/action.yaml": "runs: {using: composite, steps: [{run: echo fixture, shell: bash, env: {EXTRA: '${{ secrets.TOKEN }}'}}]}\n",
	}
	for name, body := range files {
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := Audit(root); err == nil {
		t.Fatal("false-clean: mutable github.action granted conditional checkout dominance")
	}
}

// TestStableGuardGithubFields refuses per-step and unrecognized context properties.
func TestStableGuardGithubFields(t *testing.T) {
	for _, name := range []string{"github.action", "github.action_status", "github.action_ref", "github.action_repository", "github.action_path", "github.env", "github.path", "github.future_artifact"} {
		if stableGuard(name + " != 'fixture'") {
			t.Fatalf("mutable or unknown context accepted: %s", name)
		}
	}
	for _, name := range []string{"github.event_name", "github.ref", "github.event.pull_request.head.sha"} {
		if !stableGuard(name + " == 'fixture'") {
			t.Fatalf("immutable fact rejected: %s", name)
		}
	}
}
