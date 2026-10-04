package main

import (
	"strings"
	"testing"
)

func TestComparisonContext(t *testing.T) {
	sha := strings.Repeat("1", 40)
	older := strings.Repeat("2", 40)
	newer := strings.Repeat("3", 40)
	for _, test := range []struct{ before, commits, want string }{{"main", "null", "main"}, {strings.Repeat("0", 40), `[{"id":"` + newer + `","timestamp":"2026-10-04T12:00:00Z"},{"id":"` + older + `","timestamp":"2026-10-04T11:00:00Z"}]`, older}, {strings.Repeat("0", 40), `[{"id":"` + sha + `","timestamp":"2026-10-04T12:00:00Z"}]`, ""}} {
		got, e := comparisonBase(test.before, test.commits)
		if e != nil || got != test.want {
			t.Fatalf("comparison context: got=%q want=%q err=%v", got, test.want, e)
		}
	}
}
func TestProjectOriginRejectedBeforeExecution(t *testing.T) {
	for key, value := range map[string]string{"INPUT_GITHUB_URL": "https://api.github.com/proxy", "INPUT_GITHUB_SERVER_URL": "https://github.com", "INPUT_REPO": "offline/fixture", "INPUT_SHA": strings.Repeat("1", 40), "INPUT_TOKEN": "fixture-token", "INPUT_PROJECT": "organization/offline/5", "INPUT_PROJECTS_SECRET": "fixture-project-token"} {
		t.Setenv(key, value)
	}
	if _, e := configuration(); e == nil {
		t.Fatal("project credentials accepted a prefixed API origin")
	}
}
