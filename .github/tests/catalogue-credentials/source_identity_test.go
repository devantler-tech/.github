package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestReviewCompositeWorkflowIdentity checks the immutable workflow SHA inside an older composite.
func TestReviewCompositeWorkflowIdentity(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		".github/workflows/ci.yaml": "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: devantler-tech/.github/actions/wrapper@1111111111111111111111111111111111111111\n",
		"actions/inner/action.yaml": "runs: {using: composite, steps: [{run: echo fixture, shell: bash, env: {EXTRA: '${{ secrets.TOKEN }}'}}]}\n",
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
	oldWrapper, err := decode([]byte("runs: {using: composite, steps: [{uses: 'actions/checkout@2222222222222222222222222222222222222222', with: {repository: '${{ job.workflow_repository }}', ref: '${{ job.workflow_sha }}', path: helper}}, {uses: './helper/actions/inner'}]}\n"))
	if err != nil {
		t.Fatal(err)
	}
	oldInner, err := decode([]byte("runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n"))
	if err != nil {
		t.Fatal(err)
	}
	a := auditor{root: root, active: map[string]bool{}, sources: map[string]object{"1111111111111111111111111111111111111111:actions/wrapper/action.yaml": oldWrapper, "1111111111111111111111111111111111111111:actions/inner/action.yaml": oldInner}}
	c := context{"github.repository": "devantler-tech/.github", "github.event_name": "pull_request", "github.token": builtinToken{}, "secrets.github_token": builtinToken{}}
	if err := a.workflow(".github/workflows/ci.yaml", "", c, nil, nil, nil); err == nil {
		t.Fatal("false-clean: job.workflow_sha read old composite leaf instead of current defining workflow leaf")
	}
}

// TestReviewOwnedActionClassification checks alternative spellings of the same owned repository.
func TestReviewOwnedActionClassification(t *testing.T) {
	for _, ref := range []string{"Devantler-Tech/.github/actions/fixture@1111111111111111111111111111111111111111", "devantler-tech/.github@1111111111111111111111111111111111111111"} {
		t.Run(ref, func(t *testing.T) {
			root := t.TempDir()
			p := filepath.Join(root, ".github/workflows/ci.yaml")
			if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
				t.Fatal(err)
			}
			body := "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: " + ref + "\n"
			if err := os.WriteFile(p, []byte(body), 0600); err != nil {
				t.Fatal(err)
			}
			metadata, err := decode([]byte("runs: {using: composite, steps: [{run: echo fixture, shell: bash, env: {EXTRA: '${{ secrets.TOKEN }}'}}]}\n"))
			if err != nil {
				t.Fatal(err)
			}
			a := auditor{root: root, active: map[string]bool{}, sources: map[string]object{"1111111111111111111111111111111111111111:actions/fixture/action.yaml": metadata, "1111111111111111111111111111111111111111:action.yaml": metadata}}
			c := context{"github.repository": "devantler-tech/.github", "github.event_name": "pull_request", "github.token": builtinToken{}, "secrets.github_token": builtinToken{}}
			if err := a.workflow(".github/workflows/ci.yaml", "", c, nil, nil, nil); err == nil {
				t.Fatal("false-clean: owned action metadata classified as opaque external action")
			}
		})
	}
}
