package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture writes an isolated, minimal catalogue graph used by the admission tests.
func fixture(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		if name == ".github/workflows/ci.yaml" && !strings.HasPrefix(body, "on:") {
			body = "on: {pull_request: {}, push: {branches: [main]}, merge_group: {}}\n" + body
		}
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// TestCredentialAuthority rejects new reachable writers while admitting proven skipped leaves.
func TestCredentialAuthority(t *testing.T) {
	cases := []struct{ name, ci, called, want string }{
		{"new root writer", "permissions: {}\njobs:\n  new-test:\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n", "", "write authority"},
		{"inherited writer", "permissions: {issues: write}\njobs:\n  new-test:\n    steps: [{run: echo fixture}]\n", "", "write authority"},
		{"new root secret", "permissions: {}\nenv: {EXTRA: '${{ secrets[\"TOKEN\"] }}'}\njobs:\n  new-test:\n    permissions: {contents: read}\n    steps: [{run: echo fixture}]\n", "", "external secret"},
		{"dry run blocks writer", "permissions: {}\njobs:\n  caller:\n    permissions: {contents: write}\n    uses: ./.github/workflows/callee.yaml\n    with: {dry-run: true}\n", "on:\n  workflow_call:\n    inputs:\n      dry-run: {type: boolean, default: false}\npermissions: {}\njobs:\n  writer:\n    if: ${{ !inputs.dry-run }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n", ""},
		{"missing dry run exposes writer", "permissions: {}\njobs:\n  caller:\n    permissions: {contents: write}\n    uses: ./.github/workflows/callee.yaml\n", "on:\n  workflow_call:\n    inputs:\n      dry-run: {type: boolean, default: false}\npermissions: {}\njobs:\n  writer:\n    if: ${{ !inputs.dry-run }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n", "write authority"},
		{"skipped dependency blocks writer", "permissions: {}\njobs:\n  skip:\n    if: false\n    permissions: {}\n    steps: [{run: echo fixture}]\n  writer:\n    needs: skip\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n", "", ""},
		{"always restores writer", "permissions: {}\njobs:\n  skip:\n    if: false\n    permissions: {}\n    steps: [{run: echo fixture}]\n  writer:\n    needs: skip\n    if: ${{ always() }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n", "", "write authority"},
		{"unknown gate cannot clear writer", "permissions: {}\njobs:\n  writer:\n    if: ${{ vars.MAYBE == 'false' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n", "", "write authority"},
		{"bulk inheritance", "permissions: {}\njobs:\n  caller:\n    permissions: {contents: read}\n    secrets: inherit\n    uses: ./.github/workflows/callee.yaml\n", "on: {workflow_call: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps: [{run: echo fixture}]\n", "external secret"},
		{"mutable first party source", "permissions: {}\njobs:\n  caller:\n    permissions: {contents: read}\n    uses: devantler-tech/.github/.github/workflows/callee.yaml@main\n", "", "UNKNOWN"},
		{"missing source", "permissions: {}\njobs:\n  caller:\n    permissions: {contents: read}\n    uses: ./.github/workflows/missing.yaml\n", "", "UNKNOWN"},
		{"duplicate jobs", "permissions: {}\njobs: {}\njobs: {}\n", "", "UNKNOWN"},
		{"read token allowed", "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    env: {GH_TOKEN: '${{ secrets.GITHUB_TOKEN }}'}\n    steps: [{run: echo fixture}]\n", "", ""},
		{"job ceiling replaces workflow", "permissions: {issues: write}\njobs:\n  read:\n    permissions: {contents: read}\n    steps: [{run: echo fixture}]\n", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			files := map[string]string{".github/workflows/ci.yaml": tc.ci}
			if tc.called != "" {
				files[".github/workflows/callee.yaml"] = tc.called
			}
			err := Audit(fixture(t, files))
			if tc.want == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want %q, got %v", tc.want, err)
			}
		})
	}
}

// TestSecretCompleteness rejects mixed safe and unresolved bulk/dynamic access.
func TestSecretCompleteness(t *testing.T) {
	for _, expression := range []string{"${{ secrets.GITHUB_TOKEN && toJSON(secrets) }}", "${{ secrets.GITHUB_TOKEN && secrets[inputs.name] }}", "${{ secrets.GITHUB_TOKEN || SeCrEtS[format('TOK{0}', inputs.suffix)] }}"} {
		if err := checkSecrets(expression, context{"secrets.github_token": "github-token"}); err == nil {
			t.Fatalf("accepted unresolved secret access: %s", expression)
		}
	}
}

// TestEventDiscovery covers a newly introduced CI trigger rather than a fixed event allowlist.
func TestEventDiscovery(t *testing.T) {
	root := fixture(t, map[string]string{".github/workflows/ci.yaml": "on: {pull_request_target: {}}\npermissions: {}\njobs:\n  writer:\n    if: ${{ github.event_name == 'pull_request_target' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n"})
	if err := Audit(root); err == nil || !strings.Contains(err.Error(), "write authority") {
		t.Fatalf("new trigger falsely cleared: %v", err)
	}
}

// TestObjectComparison retains unknown identity rather than comparing printed map values.
func TestObjectComparison(t *testing.T) {
	if truth(evaluate("fromJSON('{}') != fromJSON('{}')", context{})) == false {
		t.Fatal("distinct runtime objects falsely compare equal")
	}
}

// TestConservativeValueSemantics keeps unsupported value behavior from proving a false job gate.
func TestConservativeValueSemantics(t *testing.T) {
	for _, expression := range []string{"(vars.MAYBE || 'main') == 'main'", "contains(fromJSON('[\"ABC\"]'), 'abc')", "fromJSON('[1]') != fromJSON('[1]')", "format('{{{0}}}', 'a') == '{a}'", "contains('', null)"} {
		if truth(evaluate(expression, context{})) == false {
			t.Fatalf("false skip proof: %s", expression)
		}
	}
}

// TestLocalNeedsIsolation prevents a caller's skipped-result fact from clearing a callee writer.
func TestLocalNeedsIsolation(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":     "permissions: {}\njobs:\n  check:\n    if: false\n    permissions: {}\n    steps: [{run: echo fixture}]\n  caller:\n    if: ${{ always() }}\n    needs: check\n    permissions: {contents: write}\n    uses: ./.github/workflows/callee.yaml\n",
		".github/workflows/callee.yaml": "on: {workflow_call: {}}\npermissions: {}\njobs:\n  check:\n    permissions: {}\n    steps: [{run: echo fixture}]\n  writer:\n    needs: check\n    if: ${{ needs.check.result != 'skipped' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n",
	})
	if err := Audit(root); err == nil || !strings.Contains(err.Error(), "write authority") {
		t.Fatalf("caller context falsely clears callee: %v", err)
	}
}

// TestIncompleteCompoundValues retains unresolved nested values through pure functions.
func TestIncompleteCompoundValues(t *testing.T) {
	c := context{"inputs": object{"gate": uncertain}}
	if known(evaluate("toJSON(inputs)", c)) {
		t.Fatal("partial input object was treated as complete")
	}
	for _, e := range []string{"format('{0}', null) == ''", "format('{0}', fromJSON('{}')) == ''"} {
		if truth(evaluate(e, c)) == false {
			t.Fatalf("false skip proof: %s", e)
		}
	}
}

// TestQuotedExpressionDelimiters sees secret access after braces inside quoted values.
func TestQuotedExpressionDelimiters(t *testing.T) {
	for _, e := range []string{"${{ '}}' && secrets.TOKEN }}", "${{ format('{{}}{0}', secrets.TOKEN) }}"} {
		if err := checkSecrets(e, context{}); err == nil {
			t.Fatalf("secret hidden by quoted delimiter: %s", e)
		}
	}
}

// TestCheckoutBinding refuses to read candidate metadata for a mutable helper checkout.
func TestCheckoutBinding(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":   "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/.github, ref: main, path: .devantler-tech-actions}\n      - uses: ./.devantler-tech-actions/actions/fixture\n",
		"actions/fixture/action.yaml": "inputs: {}\nruns: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n",
	})
	if err := Audit(root); err == nil || !strings.Contains(err.Error(), "UNKNOWN") {
		t.Fatalf("mutable helper source falsely cleared: %v", err)
	}
}

// TestCompositeInputStrings uses the action's string input contract for YAML boolean arguments.
func TestCompositeInputStrings(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":   "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {persist-credentials: false}\n      - uses: ./actions/fixture\n        with: {enabled: false}\n",
		"actions/fixture/action.yaml": "inputs: {enabled: {default: 'true'}}\nruns:\n  using: composite\n  steps:\n    - if: ${{ inputs.enabled == 'false' }}\n      run: echo fixture\n      shell: bash\n      env: {EXTRA: '${{ secrets.TOKEN }}'}\n",
	})
	if err := Audit(root); err == nil || !strings.Contains(err.Error(), "external secret") {
		t.Fatalf("action boolean incorrectly skips secret: %v", err)
	}
}

// TestTruthProofDoesNotInventAValue separates safe conjunction truth from unknown operand identity.
func TestTruthProofDoesNotInventAValue(t *testing.T) {
	if truth(evaluate("vars.MAYBE && false", context{})) != false {
		t.Fatal("false conjunction was not proven")
	}
	if known(evaluate("vars.MAYBE && false", context{})) {
		t.Fatal("unknown selected value acquired an identity")
	}
}

// TestTypedDefaults retains reusable boolean and number defaults in value expressions.
func TestTypedDefaults(t *testing.T) {
	c := inputs(object{"enabled": object{"type": "boolean"}, "count": object{"type": "number"}}, nil, context{})
	if evaluate("toJSON(inputs.enabled) == 'false'", c) != true {
		t.Fatal("boolean default differs from native false")
	}
	if evaluate("toJSON(inputs.count) == '0'", c) != true {
		t.Fatal("number default differs from native zero")
	}
}

// TestEnvironmentSecretBoundary does not infer absence from omitted caller forwarding.
func TestEnvironmentSecretBoundary(t *testing.T) {
	root := fixture(t, map[string]string{".github/workflows/ci.yaml": "permissions: {}\njobs:\n  caller:\n    permissions: {contents: read}\n    uses: ./.github/workflows/callee.yaml\n", ".github/workflows/callee.yaml": "on:\n  workflow_call:\n    secrets:\n      TOKEN: {required: false}\npermissions: {}\njobs:\n  read:\n    environment: fixture-environment\n    permissions: {contents: read}\n    env: {EXTRA: '${{ secrets.TOKEN }}'}\n    steps: [{run: echo fixture}]\n"})
	if err := Audit(root); err == nil || !strings.Contains(err.Error(), "UNKNOWN") {
		t.Fatalf("environment secret absence invented: %v", err)
	}
}

// TestUnmeasuredValueIdentity retains formatting, interpolation and token identity uncertainty.
func TestUnmeasuredValueIdentity(t *testing.T) {
	if known(evaluate("toJSON(fromJSON('{\"x\":1}'))", context{})) {
		t.Fatal("nonempty JSON serialization format invented")
	}
	if known(resolveScalar("prefix${{ vars.SUFFIX }}", context{})) {
		t.Fatal("mixed interpolation treated as a literal")
	}
}

// TestTokenIdentity never substitutes a fixture token for the native opaque credential.
func TestTokenIdentity(t *testing.T) {
	root := fixture(t, map[string]string{".github/workflows/ci.yaml": "permissions: {}\njobs:\n  writer:\n    if: ${{ github.token != 'github-token' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n"})
	if err := Audit(root); err == nil {
		t.Fatal("opaque token identity skipped a writer")
	}
	if err := checkSecrets("${{ secrets.forwarded }}", context{"secrets.forwarded": builtinToken{}}); err != nil {
		t.Fatalf("builtin token forwarding rejected: %v", err)
	}
}

// TestUnknownCheckoutPath invalidates earlier source bindings when the destination is unmeasured.
func TestUnknownCheckoutPath(t *testing.T) {
	bindings := map[string]binding{".": {valid: true}}
	bindCheckout(object{"with": object{"path": "${{ vars.PATH }}"}}, "", context{}, bindings)
	if bindings["."].valid {
		t.Fatal("unmeasured checkout left a valid source binding")
	}
}

// TestMalformedMetadataCannotFallback rejects ambiguous metadata even when one file is valid.
func TestMalformedMetadataCannotFallback(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":   "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: ./actions/fixture\n",
		"actions/fixture/action.yaml": "runs: {}\nruns: {}\n",
		"actions/fixture/action.yml":  "runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n",
	})
	if err := Audit(root); err == nil || !strings.Contains(err.Error(), "UNKNOWN") {
		t.Fatalf("malformed chosen metadata ignored: %v", err)
	}
}

// TestNativeScalarComparisons covers numeric identities and unsupported coercion.
func TestNativeScalarComparisons(t *testing.T) {
	if truth(evaluate("fromJSON('-0') == 0", context{})) == false {
		t.Fatal("negative zero acquired a different numeric identity")
	}
	if truth(evaluate("'01' != 1", context{})) == false {
		t.Fatal("non-JSON numeric string falsely compares equal")
	}
	if truth(evaluate("format('{0}{1}', '{1}', 'x') != 'xx'", context{})) == false {
		t.Fatal("format replacement reprocessed as a placeholder")
	}
}

// TestAncestorCheckoutReplacesBindings rejects stale child provenance after replacement.
func TestAncestorCheckoutReplacesBindings(t *testing.T) {
	bindings := map[string]binding{"helper/nested": {valid: true}}
	bindCheckout(object{"with": object{"repository": "fixture/other", "path": "helper", "ref": "1111111111111111111111111111111111111111"}}, "", context{}, bindings)
	if bindings["helper/nested"].valid {
		t.Fatal("ancestor replacement preserved stale child checkout")
	}
}

// TestPlusBranchPattern retains uncertainty for GitHub's repetition operator.
func TestPlusBranchPattern(t *testing.T) {
	root := fixture(t, map[string]string{".github/workflows/ci.yaml": "on: {push: {branches: ['main+']}}\npermissions: {}\njobs:\n  writer:\n    if: ${{ github.ref != 'refs/heads/main+' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n"})
	if err := Audit(root); err == nil {
		t.Fatal("branch pattern became an exact-ref proof")
	}
}

// TestCheckoutRootAction binds metadata to the root of the repository checked out there.
func TestCheckoutRootAction(t *testing.T) {
	p, _, _, err := actionReference("./helper", "", object{}, context{}, map[string]binding{"helper": {valid: true}})
	if err != nil || p != "action.yaml" {
		t.Fatalf("incorrect repository-root metadata: %q %v", p, err)
	}
}

// TestConditionalCheckoutScopes rejects coincidentally identical expressions in different calls.
func TestConditionalCheckoutScopes(t *testing.T) {
	bindings := map[string]binding{}
	step := object{"if": "${{ inputs.enabled }}", "with": object{"path": "helper"}}
	bindCheckout(step, "", context{"__catalogue_guard_scope": 1}, bindings)
	_, _, _, err := actionReference("./helper/actions/fixture", "", step, context{"__catalogue_guard_scope": 2}, bindings)
	if err == nil {
		t.Fatal("identical condition text crossed call scopes")
	}
	if stableGuard("${{ steps.changed.outputs.enabled }}") || stableGuard("${{ success() }}") || stableGuard("${{ hashFiles('fixture') }}") {
		t.Fatal("mutable guard granted checkout implication")
	}
}

// TestSuccessfulCheckoutAdmission rejects attempted installation as proof of success.
func TestSuccessfulCheckoutAdmission(t *testing.T) {
	recovery := "${{ !cancelled() && (success() || inputs.manual-workflow-fixes == true || inputs.manual-workflow-fixes == 'true') }}"
	c := context{"__catalogue_guard_scope": 1, "inputs.manual-workflow-fixes": true}
	bindings := map[string]binding{}
	checkout := object{"id": "helper", "if": recovery, "with": object{"path": "helper"}}
	bindCheckout(checkout, "", c, bindings)
	if _, _, _, err := actionReference("./helper/actions/fixture", "", object{"if": recovery}, c, bindings); err == nil {
		t.Fatal("failed checkout could execute pre-existing helper metadata")
	}
	guarded := "${{ steps.helper.outcome == 'success' && !cancelled() && (success() || inputs.manual-workflow-fixes == true || inputs.manual-workflow-fixes == 'true') }}"
	if _, _, _, err := actionReference("./helper/actions/fixture", "", object{"if": guarded}, c, bindings); err != nil {
		t.Fatalf("successful-outcome prerequisite rejected: %v", err)
	}
	if checkoutSucceeded("helper", "${{ steps.helper.outcome == 'success' || true }}", c) {
		t.Fatal("disjunctive outcome bypass accepted")
	}
	if checkoutSucceeded("helper", nil, c) {
		t.Fatal("implicit success hid ignored checkout failure")
	}
}

// TestUnmeasuredRendering avoids platform-specific number formatting and Unicode folding proofs.
func TestUnmeasuredRendering(t *testing.T) {
	for _, expression := range []string{"toJSON(fromJSON('1e30'))", "format('{0}', fromJSON('1e30'))", "'I' == 'ı'", "contains('I', 'ı')", "startsWith('I', 'ı')"} {
		if known(evaluate(expression, context{})) {
			t.Fatalf("unmeasured rendering acquired an identity: %s", expression)
		}
	}
	if known(evaluate("NaN", context{})) {
		t.Fatal("invalid native numeric literal was accepted")
	}
}
