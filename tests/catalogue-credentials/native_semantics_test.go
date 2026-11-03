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

// TestArrayContainsRequiresMeasuredStringEquality refuses mixed native coercion
// rather than manufacturing a proof that a privileged job will not execute.
func TestArrayContainsRequiresMeasuredStringEquality(t *testing.T) {
	for _, expression := range []string{
		"contains(fromJSON('[false]'), '')",
		"contains(fromJSON('[\"true\"]'), true)",
		"contains(fromJSON('[null]'), '')",
		"contains(fromJSON('[0]'), '')",
		"contains(fromJSON('[1]'), true)",
		"contains(fromJSON('[\"safe\", false]'), 'safe')",
		"contains(fromJSON('[false, \"safe\"]'), 'safe')",
	} {
		t.Run(expression, func(t *testing.T) {
			if value := evaluate(expression, context{}); known(value) {
				t.Fatalf("mixed-type array membership became a skip proof: %v", value)
			}
		})
	}
}

func TestArrayContainsCannotHideWriter(t *testing.T) {
	for _, condition := range []string{
		"contains(fromJSON('[false]'), '')",
		"!contains(fromJSON('[\"true\"]'), true)",
	} {
		t.Run(condition, func(t *testing.T) {
			ci := "permissions: {}\njobs:\n  writer:\n    if: \u0024{{ " + condition + " }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n"
			if err := Audit(fixture(t, map[string]string{".github/workflows/ci.yaml": ci})); err == nil || !strings.Contains(err.Error(), "write authority") {
				t.Fatalf("mixed-type condition hid live writer: %v", err)
			}
		})
	}
}

func TestMeasuredArrayContainsIsPreserved(t *testing.T) {
	for _, sample := range []struct {
		expression string
		want       bool
	}{
		{"contains(fromJSON('[\"push\", \"pull_request\"]'), 'PUSH')", true},
		{"contains(fromJSON('[\"push\", \"pull_request\"]'), 'merge_group')", false},
		{"contains(fromJSON('[]'), false)", false},
		{"contains(fromJSON('[]'), '')", false},
		{"contains('true', true)", true},
	} {
		if got := evaluate(sample.expression, context{}); got != sample.want {
			t.Errorf("%s: got %v, want %v", sample.expression, got, sample.want)
		}
	}
}
