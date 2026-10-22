// publish-release-recovery publishes one missing GitHub release for an existing stable tag.
// It is a separate command so the inspection command stays read-only.
package main

import (
	"fmt"
	"os"

	"github.com/devantler-tech/dotgithub/inspect-release-recovery/internal/publication"
)

// main requires an explicit writer credential and reports refusals without exposing response bodies.
func main() {
	if err := publication.Run(os.Args[1:], os.Getenv("GH_TOKEN"), os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "release publication stopped:", err)
		os.Exit(1)
	}
}
