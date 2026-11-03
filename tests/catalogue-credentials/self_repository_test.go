package main

import (
	"strings"
	"testing"
)

// TestSelfRepositoryReferencesBindTheDefiningFile ignores unrelated workspace checkouts.
func TestSelfRepositoryReferencesBindTheDefiningFile(t *testing.T) {
	revision := "1111111111111111111111111111111111111111"
	c := context{"__workflow_revision": "2222222222222222222222222222222222222222"}
	bindings := map[string]binding{".": {revision: "3333333333333333333333333333333333333333", valid: true}}
	p, r, owned, err := actionReference("$/actions/fixture", revision, object{}, c, bindings)
	if err != nil || !owned || p != "actions/fixture/action.yaml" || r != revision {
		t.Fatalf("self action lost defining-file identity: %q %q %v %v", p, r, owned, err)
	}
	p, r, owned, err = reference("$/.github/workflows/callee.yaml", revision, false)
	if err != nil || !owned || p != ".github/workflows/callee.yaml" || r != revision {
		t.Fatalf("self workflow lost defining-file identity: %q %q %v %v", p, r, owned, err)
	}
}

// TestSelfRepositoryReferencesRejectAliases forbids mutable suffixes and path escapes.
func TestSelfRepositoryReferencesRejectAliases(t *testing.T) {
	for _, ref := range []string{"$/", "$/../outside", "$//absolute", "$/actions/fixture@main", "$/actions/fixture#fragment", "$/actions/%2e%2e/fixture"} {
		if _, _, _, err := reference(ref, "", true); err == nil {
			t.Fatalf("accepted ambiguous self reference %q", ref)
		}
	}
}

// TestSelfRepositoryNestedAuthority traverses both actions even without a workspace checkout.
func TestSelfRepositoryNestedAuthority(t *testing.T) {
	for _, unsafe := range []bool{false, true} {
		leaf := "runs: {using: composite, steps: [{run: echo fixture, shell: bash}]}\n"
		if unsafe {
			leaf = "runs: {using: composite, steps: [{run: echo fixture, shell: bash, env: {EXTRA: '${{ secrets.TOKEN }}'}}]}\n"
		}
		files := map[string]string{
			".github/workflows/ci.yaml":   "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: $/actions/wrapper\n",
			"actions/wrapper/action.yaml": "runs: {using: composite, steps: [{uses: '$/actions/inner'}]}\n",
			"actions/inner/action.yaml":   leaf,
		}
		err := Audit(fixture(t, files))
		if !unsafe && err != nil {
			t.Fatalf("safe native self graph rejected: %v", err)
		}
		if unsafe && (err == nil || !strings.Contains(err.Error(), "external secret")) {
			t.Fatalf("native self leaf was not audited: %v", err)
		}
	}
}

// TestImmutableCompositeSelfSource cannot substitute the caller workflow's newer leaf.
func TestImmutableCompositeSelfSource(t *testing.T) {
	const revision = "1111111111111111111111111111111111111111"
	root := fixture(t, map[string]string{
		".github/workflows/ci.yaml": "permissions: {}\njobs:\n  read:\n    permissions: {contents: read}\n    steps:\n      - uses: devantler-tech/.github/actions/wrapper@" + revision + "\n",
		"actions/inner/action.yaml": "runs: {using: composite, steps: [{run: echo safe, shell: bash}]}\n",
	})
	wrapper, err := decode([]byte("runs: {using: composite, steps: [{uses: '$/actions/inner'}]}\n"))
	if err != nil {
		t.Fatal(err)
	}
	inner, err := decode([]byte("runs: {using: composite, steps: [{run: echo fixture, shell: bash, env: {EXTRA: '${{ secrets.TOKEN }}'}}]}\n"))
	if err != nil {
		t.Fatal(err)
	}
	a := auditor{root: root, active: map[string]bool{}, sources: map[string]object{
		revision + ":actions/wrapper/action.yaml": wrapper,
		revision + ":actions/inner/action.yaml":   inner,
	}, trees: map[string]map[string]sourceEntry{revision: {
		"actions/wrapper/action.yaml": {Mode: "100644", Type: "blob", SHA: revision},
		"actions/inner/action.yaml":   {Mode: "100644", Type: "blob", SHA: revision},
	}}}
	c := context{"github.repository": "devantler-tech/.github", "github.event_name": "pull_request", "github.token": builtinToken{}, "secrets.github_token": builtinToken{}}
	if err := a.workflow(".github/workflows/ci.yaml", "", c, nil, nil, nil); err == nil || !strings.Contains(err.Error(), "external secret") {
		t.Fatalf("immutable composite self leaf escaped audit: %v", err)
	}
}
