package main

import "testing"

// This control exercises the existing read-only prose extractor. It does not
// authorize a URL, open a network connection or change the production command.
func TestCodeScanningRulePositiveControl(t *testing.T) {
	text := "Quoted link: https://github.com/example/current remains prose."
	matches := repositoryURL.FindAllStringSubmatchIndex(text, -1)
	if len(matches) != 1 || len(matches[0]) != 4 {
		t.Fatalf("expected one repository capture, got %v", matches)
	}
	if got := text[matches[0][2]:matches[0][3]]; got != "example/current" {
		t.Fatalf("repository capture = %q", got)
	}
}

// This temporary control handles prose only; it never validates a destination.
func TestCodeScanningRuleFindingControl(t *testing.T) {
	matches := codeScanningRuleProseControl("Quoted link: https://github.com/example/current remains prose.")
	if len(matches) != 1 || matches[0] != "https://github.com/example/current" {
		t.Fatalf("prose matches = %v", matches)
	}
}
