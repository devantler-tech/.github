package main

import "regexp"

// codeScanningRuleProseControl extracts literal links from inert prose. This
// temporary native-scanner control does not authorize a destination, open a
// network connection, handle credentials or change the production command.
func codeScanningRuleProseControl(text string) []string {
	pattern := regexp.MustCompile(`https?://(?:www\.)?(?:github\.com|raw\.githubusercontent\.com)/([a-z0-9-]+/[a-z0-9_.-]+)`)
	return pattern.FindAllString(text, -1)
}
