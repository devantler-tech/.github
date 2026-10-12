package main

import "testing"

func TestNativeGoCacheObserverAndFixtureRemainRequiredTogether(t *testing.T) {
	i, w := dotnetSelectionFixture(t)
	if _, err := validateInventory(i, w); err != nil {
		t.Fatalf("complete native cache observer rejected: %v", err)
	}
	for _, path := range []string{"actions/upload-coverage/action.yaml", ".github/scripts/observe-go-cache.sh", ".github/workflows/validate-go-project.yaml", "unclassified"} {
		got := selectJobs(i, "pull_request", []string{path})
		seen := map[string]bool{}
		for _, id := range got {
			seen[id] = true
		}
		if !seen["test-go-cache-native-observer"] || !seen["test-validate-go-postgresql-fixture"] {
			t.Fatalf("%s separated native observation from the fixture: %v", path, got)
		}
	}
}

func TestNativeGoCacheObserverInventoryRejectsMissingOrBypassedEvidence(t *testing.T) {
	for _, mutation := range []string{"remove both", "missing fixture", "missing observer", "wrong dependency", "missing dependency", "different owners", "both ownerless", "optional observer", "optional fixture", "preserved observer", "unbound fixture"} {
		t.Run(mutation, func(t *testing.T) {
			i, w := dotnetSelectionFixture(t)
			switch mutation {
			case "remove both":
				delete(i.Jobs, "test-go-cache-native-observer")
				delete(w.Jobs, "test-go-cache-native-observer")
				delete(i.Jobs, "test-validate-go-postgresql-fixture")
				delete(w.Jobs, "test-validate-go-postgresql-fixture")
			case "missing fixture":
				delete(i.Jobs, "test-validate-go-postgresql-fixture")
				delete(w.Jobs, "test-validate-go-postgresql-fixture")
			case "missing observer":
				delete(i.Jobs, "test-go-cache-native-observer")
				delete(w.Jobs, "test-go-cache-native-observer")
			case "wrong dependency", "missing dependency":
				j := w.Jobs["test-go-cache-native-observer"]
				j.Needs = []any{"select-ci-tests"}
				if mutation == "wrong dependency" {
					j.Needs = []any{"select-ci-tests", "test-one"}
				}
				w.Jobs["test-go-cache-native-observer"] = j
			case "different owners":
				i.Jobs["test-go-cache-native-observer"] = []string{"actions/one/"}
			case "both ownerless":
				i.Jobs["test-go-cache-native-observer"] = []string{}
				i.Jobs["test-validate-go-postgresql-fixture"] = []string{}
			case "optional observer":
				i.CatalogueOptional = append(i.CatalogueOptional, "test-go-cache-native-observer")
			case "optional fixture":
				i.CatalogueOptional = append(i.CatalogueOptional, "test-validate-go-postgresql-fixture")
			case "preserved observer":
				i.Preserved["test-go-cache-native-observer"] = w.Jobs["test-go-cache-native-observer"]
			case "unbound fixture":
				j := w.Jobs["test-validate-go-postgresql-fixture"]
				j.Uses = "./.github/workflows/other.yaml"
				w.Jobs["test-validate-go-postgresql-fixture"] = j
			}
			if _, err := validateInventory(i, w); err == nil {
				t.Fatalf("accepted %s", mutation)
			}
		})
	}
}
