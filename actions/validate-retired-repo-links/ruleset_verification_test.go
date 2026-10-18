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
