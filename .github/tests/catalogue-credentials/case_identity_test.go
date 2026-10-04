package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestImmutableNativeCaseAlias detects metadata precedence on a native case-folding checkout.
func TestImmutableNativeCaseAlias(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "actions/fixture")
	if e := os.MkdirAll(directory, 0700); e != nil {
		t.Fatal(e)
	}
	safe := []byte("runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n")
	unsafe := []byte("runs: {using: composite, steps: [{uses: devantler-tech/.github/.github/actions/prepare-fixes@main}]}\n")
	if e := os.WriteFile(filepath.Join(directory, "action.yaml"), safe, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(directory, "Action.YML"), unsafe, 0600); e != nil {
		t.Fatal(e)
	}
	actual, e := os.ReadFile(filepath.Join(directory, "action.yml"))
	if os.IsNotExist(e) {
		t.Skip("native fixture filesystem is case-sensitive")
	}
	if e != nil {
		t.Fatal(e)
	}
	if string(actual) != string(unsafe) {
		t.Fatal("native metadata lookup selected wrong control")
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
	runGit("add", "--", "actions/fixture")
	runGit("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
	revision := runGit("rev-parse", "HEAD")
	t.Log("exact lowercase entry:", runGit("ls-tree", revision, "--", "actions/fixture/action.yml"))
	t.Log("actual entries:", runGit("ls-tree", revision, "actions/fixture/"))
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
		t.Fatal("false-clean: exact Git metadata lookup ignored native case-folded action.yml implementation")
	}
}

// TestCompleteImmutableCaseAliases rejects metadata and parent aliases on every host.
func TestCompleteImmutableCaseAliases(t *testing.T) {
	revision := "1111111111111111111111111111111111111111"
	path := "actions/fixture/action.yaml"
	for _, alias := range []string{"actions/fixture/Action.YAML", "Actions/fixture/action.yml", "actions/Fixture/action.yaml", "Actions/other/action.yaml"} {
		entries := map[string]sourceEntry{
			path:  {Path: path, Mode: "100644", Type: "blob", SHA: "2222222222222222222222222222222222222222"},
			alias: {Path: alias, Mode: "100644", Type: "blob", SHA: "3333333333333333333333333333333333333333"},
		}
		a := auditor{root: t.TempDir(), trees: map[string]map[string]sourceEntry{revision: entries}}
		if _, e := a.immutableEntry(path, revision); e == nil || !strings.Contains(e.Error(), "case") {
			t.Fatalf("case-folded metadata or parent alias accepted (%s): %v", alias, e)
		}
	}
}

// TestLocalCaseAliases does not turn case-sensitive host behavior into universal absence proof.
func TestLocalCaseAliases(t *testing.T) {
	for _, path := range []string{"actions/fixture/Action.YML", "Actions/fixture/action.yml"} {
		root := fixture(t, map[string]string{path: "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n"})
		a := auditor{root: root, sources: map[string]object{}}
		if _, e := a.readSource("actions/fixture/action.yml", ""); e == nil || !strings.Contains(e.Error(), "case") {
			t.Fatalf("local case alias accepted (%s): %v", path, e)
		}
	}
}

func TestNativeCheckoutPathCaseAlias(t *testing.T) {
	root := t.TempDir()
	if e := os.MkdirAll(filepath.Join(root, "helper"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, "helper", "native-marker"), []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, "HELPER", "native-marker"), []byte("replacement"), 0600); os.IsNotExist(e) {
		t.Skip("native filesystem is case-sensitive")
	} else if e != nil {
		t.Fatal(e)
	}
	b, e := os.ReadFile(filepath.Join(root, "helper", "native-marker"))
	if e != nil || string(b) != "replacement" {
		t.Fatalf("native replacement control: %q %v", b, e)
	}
	c := context{"__catalogue_guard_scope": 1}
	bindings := map[string]binding{}
	bindCheckout(object{"with": object{"repository": "devantler-tech/.github", "ref": "1111111111111111111111111111111111111111", "path": "helper"}}, "", c, bindings)
	bindCheckout(object{"with": object{"repository": "devantler-tech/ksail", "ref": "2222222222222222222222222222222222222222", "path": "HELPER"}}, "", c, bindings)
	t.Logf("native-replaced checkout still has bindings: %#v", bindings)
	p, r, owned, e := actionReference("./helper/actions/fixture", "", object{}, c, bindings)
	if e == nil && owned {
		t.Fatalf("false-clean: native replaced source admitted from stale binding %s:%s", r, p)
	}
}

// TestNativeCheckoutPathNormalizationAlias detects equivalent native Unicode directory names.
func TestNativeCheckoutPathNormalizationAlias(t *testing.T) {
	root := t.TempDir()
	original := "helper-caf\u00e9"
	replacement := "helper-cafe\u0301"
	if e := os.MkdirAll(filepath.Join(root, original), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, original, "native-marker"), []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, replacement, "native-marker"), []byte("replacement"), 0600); os.IsNotExist(e) {
		t.Skip("native filesystem keeps normalization variants distinct")
	} else if e != nil {
		t.Fatal(e)
	}
	b, e := os.ReadFile(filepath.Join(root, original, "native-marker"))
	if e != nil || string(b) != "replacement" {
		t.Fatalf("native replacement control: %q %v", b, e)
	}
	c := context{"__catalogue_guard_scope": 1}
	bindings := map[string]binding{}
	bindCheckout(object{"with": object{"repository": "devantler-tech/.github", "ref": "1111111111111111111111111111111111111111", "path": original}}, "", c, bindings)
	bindCheckout(object{"with": object{"repository": "devantler-tech/ksail", "ref": "2222222222222222222222222222222222222222", "path": replacement}}, "", c, bindings)
	p, r, owned, e := actionReference("./"+original+"/actions/fixture", "", object{}, c, bindings)
	if e == nil && owned {
		t.Fatalf("false-clean: normalized native path replacement admitted stale source %s:%s", r, p)
	}
}

// TestPortableCheckoutCaseReplacement rejects overlapping foreign checkout aliases on all hosts.
func TestPortableCheckoutCaseReplacement(t *testing.T) {
	for _, paths := range [][2]string{{"helper", "HELPER"}, {"helper/nested", "HELPER"}, {"helper", "HELPER/nested"}, {"helper-café", "helper-cafe\u0301"}} {
		c := context{"__catalogue_guard_scope": 1}
		bindings := map[string]binding{}
		bindCheckout(object{"with": object{"repository": "devantler-tech/.github", "ref": "1111111111111111111111111111111111111111", "path": paths[0]}}, "", c, bindings)
		bindCheckout(object{"with": object{"repository": "devantler-tech/ksail", "ref": "2222222222222222222222222222222222222222", "path": paths[1]}}, "", c, bindings)
		target := paths[0]
		if len(paths[1]) > len(target) {
			target = paths[1]
		}
		if _, _, owned, e := actionReference("./"+target+"/actions/fixture", "", object{}, c, bindings); e == nil && owned {
			t.Fatalf("foreign replacement aliased an owned checkout: %v", paths)
		}
	}
}

func TestLocalMetadataCrossesOverwrittenCheckout(t *testing.T) {
	root := t.TempDir()
	metadata := filepath.Join(root, "imported/actions/fixture/action.yml")
	alias := filepath.Join(root, ".github/actions/fixture/action.yml")
	safe := []byte("runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n")
	unsafe := []byte("runs: {using: composite, steps: [{uses: devantler-tech/.github/.github/actions/prepare-fixes@main}]}\n")
	for _, d := range []string{filepath.Dir(metadata), filepath.Dir(alias), filepath.Join(root, ".github/workflows")} {
		if e := os.MkdirAll(d, 0700); e != nil {
			t.Fatal(e)
		}
	}
	if e := os.WriteFile(metadata, safe, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink("../../../imported/actions/fixture/action.yml", alias); e != nil {
		t.Fatal(e)
	}
	ci := "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222, path: imported}\n      - uses: ./.github/actions/fixture\n"
	if e := os.WriteFile(filepath.Join(root, ".github/workflows/ci.yaml"), []byte(ci), 0600); e != nil {
		t.Fatal(e)
	}
	e := Audit(root)
	// Replacing the child checkout changes what the native alias reads without changing its spelling.
	if x := os.WriteFile(metadata, unsafe, 0600); x != nil {
		t.Fatal(x)
	}
	native, x := os.ReadFile(alias)
	if x != nil || string(native) != string(unsafe) {
		t.Fatalf("native replacement control %q %v", native, x)
	}
	if e == nil {
		t.Fatal("false-clean: local in-root metadata symlink crosses unowned overwritten checkout")
	}
}

// TestReviewCheckoutRepositoryCaseAlias detects GitHub's case-insensitive checkout repository identity.
func TestReviewCheckoutRepositoryCaseAlias(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{filepath.Join(root, ".github/actions/fixture"), filepath.Join(root, ".github/workflows")} {
		if e := os.MkdirAll(d, 0700); e != nil {
			t.Fatal(e)
		}
	}
	if e := os.WriteFile(filepath.Join(root, ".github/actions/fixture/action.yml"), []byte("runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n"), 0600); e != nil {
		t.Fatal(e)
	}
	ci := "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: Actions/Checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222}\n      - uses: ./.github/actions/fixture\n"
	if e := os.WriteFile(filepath.Join(root, ".github/workflows/ci.yaml"), []byte(ci), 0600); e != nil {
		t.Fatal(e)
	}
	if e := Audit(root); e == nil {
		t.Fatal("false-clean: differently cased native checkout repository did not invalidate prior source binding")
	}
}

// TestLocalDirectorySymlinkRejectsCrossCheckoutMetadata rejects aliases at any parent component.
func TestLocalDirectorySymlinkRejectsCrossCheckoutMetadata(t *testing.T) {
	root := fixture(t, map[string]string{"imported/actions/fixture/action.yml": "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n"})
	if e := os.MkdirAll(filepath.Join(root, ".github/actions"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink("../../imported/actions/fixture", filepath.Join(root, ".github/actions/fixture")); e != nil {
		t.Fatal(e)
	}
	a := auditor{root: root, sources: map[string]object{}}
	if _, e := a.readActionSource(".github/actions/fixture/action.yaml", ""); e == nil {
		t.Fatal("local parent symlink admitted unchecked checkout source")
	}
}

func TestLexicalDotDotDoesNotHideNativeSymlinkTraversal(t *testing.T) {
	root := t.TempDir()
	safe := []byte("runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n")
	unsafe := []byte("runs: {using: composite, steps: [{uses: devantler-tech/.github/actions/fixture@main}]}\n")
	for _, d := range []string{"actions/fixture", "imported/actions/fixture", "imported/link-target", ".github/workflows"} {
		if e := os.MkdirAll(filepath.Join(root, d), 0700); e != nil {
			t.Fatal(e)
		}
	}
	if e := os.WriteFile(filepath.Join(root, "actions/fixture/action.yml"), safe, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, "imported/actions/fixture/action.yml"), unsafe, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink("imported/link-target", filepath.Join(root, "link")); e != nil {
		t.Fatal(e)
	}
	rawNative := root + "/link/../actions/fixture/action.yml"
	actual, e := os.ReadFile(rawNative)
	if e != nil || string(actual) != string(unsafe) {
		t.Fatalf("native raw traversal control %q %v", actual, e)
	}
	ci := "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: ./link/../actions/fixture\n"
	if e := os.WriteFile(filepath.Join(root, ".github/workflows/ci.yaml"), []byte(ci), 0600); e != nil {
		t.Fatal(e)
	}
	if e := Audit(root); e == nil {
		t.Fatal("false-clean raw-path identity: lexical clean hides symlink component and audits different native bytes")
	}
}

func TestReviewConditionalCompositeCheckoutCannotEscape(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":    "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222, path: helper}\n      - uses: ./actions/installer\n        if: ${{ vars.INSTALL == 'true' }}\n      - uses: ./helper/actions/fixture\n",
		"actions/installer/action.yml": "runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@1111111111111111111111111111111111111111\n      with: {repository: devantler-tech/.github, ref: '${{ github.sha }}', path: helper}\n",
		"actions/fixture/action.yml":   "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
	})
	if condition("${{ vars.INSTALL == 'true' }}", context{"vars.install": ""}) != false {
		t.Fatal("native skipped installer condition control")
	}
	if condition(nil, context{}) != true {
		t.Fatal("later unconditional action control")
	}
	if e := Audit(root); e == nil {
		t.Fatal("false-clean: checkout inside possibly skipped composite escaped as unconditional source provenance")
	}
}

// TestReviewIgnoredCompositeCheckoutCannotEscape rejects attempt-only provenance at a composite call boundary.
func TestReviewIgnoredCompositeCheckoutCannotEscape(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":    "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222, path: helper}\n      - uses: ./actions/installer\n        continue-on-error: true\n      - uses: ./helper/actions/fixture\n",
		"actions/installer/action.yml": "runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@1111111111111111111111111111111111111111\n      with: {repository: devantler-tech/.github, ref: '${{ github.sha }}', path: helper}\n",
		"actions/fixture/action.yml":   "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
	})
	if condition("${{ vars.INSTALL == 'true' }}", context{"vars.install": ""}) != false {
		t.Fatal("native skipped installer condition control")
	}
	if condition(nil, context{}) != true {
		t.Fatal("later unconditional action control")
	}
	if e := Audit(root); e == nil {
		t.Fatal("false-clean: checkout inside failed ignored composite escaped as unconditional source provenance")
	}
}

// TestCompositeAdmissionScopePositives retains proved installation and within-call source use.
func TestCompositeAdmissionScopePositives(t *testing.T) {
	for _, test := range []struct{ name, outer, inner, after string }{
		{"unconditional installer", "", "", "      - uses: ./helper/actions/fixture\n"},
		{"conditional within-call use", "        if: \u0024{{ vars.INSTALL == 'true' }}\n", "    - uses: ./helper/actions/fixture\n", ""},
		{"ignored within-call use", "        continue-on-error: true\n", "    - uses: ./helper/actions/fixture\n", ""},
		{"untouched root sibling", "        if: \u0024{{ vars.INSTALL == 'true' }}\n", "", "      - uses: ./actions/fixture\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			ci := "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222, path: helper}\n      - uses: ./actions/installer\n" + test.outer + test.after
			root := fixture(t, map[string]string{
				".github/workflows/ci.yaml":    ci,
				"actions/installer/action.yml": "runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@1111111111111111111111111111111111111111\n      with: {repository: devantler-tech/.github, ref: '\u0024{{ github.sha }}', path: helper}\n" + test.inner,
				"actions/fixture/action.yml":   "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
			})
			if e := Audit(root); e != nil {
				t.Fatalf("safe composite scope rejected: %v", e)
			}
		})
	}
}

func TestReviewConditionalCompositeParentCheckoutRemovalCannotEscape(t *testing.T) {
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml":         "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222, path: helper}\n      - uses: ./actions/installer\n        if: ${{ vars.INSTALL == 'true' }}\n      - uses: ./helper/actions/fixture\n",
		"actions/installer/action.yml":      "runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@1111111111111111111111111111111111111111\n      with: {repository: devantler-tech/.github, ref: '${{ github.sha }}'}\n",
		"helper/actions/fixture/action.yml": "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
	})
	if condition("${{ vars.INSTALL == 'true' }}", context{"vars.install": ""}) != false {
		t.Fatal("native skipped installer condition control")
	}
	if condition(nil, context{}) != true {
		t.Fatal("later unconditional action control")
	}
	if e := Audit(root); e == nil {
		t.Fatal("false-clean: conditionally removed foreign child binding escaped as unconditional source provenance")
	}
}

// TestNestedCompositeAdmissionCannotEscape keeps uncertain ancestors on the whole call chain.
func TestNestedCompositeAdmissionCannotEscape(t *testing.T) {
	for _, outer := range []string{"        if: \u0024{{ vars.INSTALL == 'true' }}\n", "        continue-on-error: true\n"} {
		ci := "on: {pull_request: {}}\npermissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n        with: {repository: devantler-tech/ksail, ref: 2222222222222222222222222222222222222222, path: helper}\n      - uses: ./actions/outer\n" + outer + "      - uses: ./helper/actions/fixture\n"
		root := fixture(t, map[string]string{
			".github/workflows/ci.yaml":    ci,
			"actions/outer/action.yml":     "runs: {using: composite, steps: [{uses: ./actions/installer}]}\n",
			"actions/installer/action.yml": "runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@1111111111111111111111111111111111111111\n      with: {repository: devantler-tech/.github, ref: '\u0024{{ github.sha }}', path: helper}\n",
			"actions/fixture/action.yml":   "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
		})
		if e := Audit(root); e == nil || !strings.Contains(e.Error(), "checkout provenance") {
			t.Fatalf("ancestor admission escaped (%s): %v", outer, e)
		}
	}
}

func TestReviewRootWorkflowCallInheritsCallerEvent(t *testing.T) {
	ci := "on: {workflow_call: {}}\npermissions: {}\njobs:\n  writer:\n    if: ${{ github.event_name == 'push' }}\n    permissions: {contents: write}\n    steps: [{run: echo fixture}]\n"
	if condition("${{ github.event_name == 'push' }}", context{"github.event_name": "push"}) != true {
		t.Fatal("caller push eligibility control")
	}
	if e := Audit(fixture(t, map[string]string{".github/workflows/ci.yaml": ci})); e == nil {
		t.Fatal("false-clean: workflow_call uses caller event, not literal workflow_call")
	}
}
