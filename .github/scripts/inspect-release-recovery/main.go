// inspect-release-recovery diagnoses one interrupted public GitHub-only release.
// It has no publication operation, write request, or configurable production API.
package main

import (
	"fmt"
	"os"

	"github.com/devantler-tech/dotgithub/inspect-release-recovery/internal/inspection"
)

// main requires an explicit credential and reports refusals without exposing response bodies.
func main() {
	if err := inspection.Run(os.Args[1:], os.Getenv("GH_TOKEN"), os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "release inspection refused:", err)
		os.Exit(1)
	}
}
