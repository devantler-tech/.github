package main

import (
	"strings"
	"testing"
)

// TestJSONRenderingCannotSkipWriter covers native HTML-sensitive string identity.
func TestJSONRenderingCannotSkipWriter(t *testing.T) {
	ci := "permissions: {}\njobs:\n  writer:\n    if: ${{ toJSON('a<b') == '\"a<b\"' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n"
	e := Audit(fixture(t, map[string]string{".github/workflows/ci.yaml": ci}))
	if e == nil || !strings.Contains(e.Error(), "write authority") {
		t.Fatalf("native JSON string equality hid writer: %v", e)
	}
}

// TestDualActionMetadataIsUnknown refuses two implementations for one owned action.
func TestDualActionMetadataIsUnknown(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":   "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps: [{uses: actions/checkout@1111111111111111111111111111111111111111}, {uses: ./actions/fixture}]\n",
		"actions/fixture/action.yaml": "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
		"actions/fixture/action.yml":  "runs: {using: composite, steps: [{uses: devantler-tech/.github/actions/fixture@main}]}\n",
	})
	if e := Audit(root); e == nil {
		t.Fatal("different runner metadata escaped classification")
	}
}

// TestUnmeasuredJSONStringRendering never invents identity for serializer-specific bytes.
func TestUnmeasuredJSONStringRendering(t *testing.T) {
	for _, s := range []string{"a<b", "a>b", "a&b", "a\u2028b", "a\u2029b", "a\nb", string([]byte{0xff})} {
		if known(call("tojson", []any{s})) {
			t.Fatalf("unmeasured JSON rendering accepted: %q", s)
		}
	}
	if value := call("tojson", []any{"fixture"}); value != `"fixture"` {
		t.Fatalf("measured ASCII string rejected: %v", value)
	}
}
