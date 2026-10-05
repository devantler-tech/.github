package guard

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

// Exercise GitHub's numeric repository alias and directional cursors through the
// whole inventory read: closure is admitted only after every page is complete.
func TestGitHubIssueCursorPagination(t *testing.T) {
	for _, fault := range []string{"", "same-page-control", "contradictory-page-cursors", "foreign-id", "missing-id", "invalid-id", "changed-state", "changed-size", "extra-filter", "empty-cursor", "duplicate-cursor", "mixed-cursors", "wrong-direction", "wrong-terminal-direction", "failed-second-page", "lost-last", "foreign-origin", "wrong-endpoint"} {
		t.Run(fault, func(t *testing.T) {
			reads, writes := 0, 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" {
					writes++
					io.WriteString(w, `{"number":11,"state":"closed"}`)
					return
				}
				reads++
				if reads == 1 {
					link := fmt.Sprintf("<http://%s/repositories/4242/issues?state=open&per_page=100&after=Y3Vyc29yOjE%%3D&page=2>; rel=\"next\"", r.Host)
					switch fault {
					case "foreign-id":
						link = strings.ReplaceAll(link, "/4242/", "/4243/")
					case "changed-state":
						link = strings.ReplaceAll(link, "state=open", "state=closed")
					case "changed-size":
						link = strings.ReplaceAll(link, "per_page=100", "per_page=1")
					case "extra-filter":
						link = strings.ReplaceAll(link, "&page=2", "&labels=hidden&page=2")
					case "empty-cursor":
						link = strings.ReplaceAll(link, "Y3Vyc29yOjE%3D", "")
					case "duplicate-cursor":
						link = strings.ReplaceAll(link, "&page=2", "&after=Y3Vyc29yOjI%3D&page=2")
					case "mixed-cursors":
						link = strings.ReplaceAll(link, "&page=2", "&before=Y3Vyc29yOjI%3D&page=2")
					case "wrong-direction":
						link = strings.ReplaceAll(link, "&after=", "&before=")
					case "foreign-origin":
						link = strings.ReplaceAll(link, r.Host, "other.invalid")
					case "wrong-endpoint":
						link = strings.ReplaceAll(link, "/issues?", "/milestones?")
					case "lost-last":
						link += fmt.Sprintf(", <http://%s/repositories/4242/issues?state=open&per_page=100&after=Y3Vyc29yOjM%%3D&page=3>; rel=\"last\"", r.Host)
					case "same-page-control":
						link += ", " + strings.ReplaceAll(link, `rel="next"`, `rel="last"`)
					case "contradictory-page-cursors":
						link += ", " + strings.ReplaceAll(strings.ReplaceAll(link, `rel="next"`, `rel="last"`), "Y3Vyc29yOjE%3D", "Y3Vyc29yOjI%3D")
					}
					w.Header().Set("Link", link)
					io.WriteString(w, `[{"number":7,"title":"Earlier task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/7"}]`)
					return
				}
				if reads != 2 || r.URL.Path != "/repositories/4242/issues" || r.URL.Query().Get("after") != "Y3Vyc29yOjE=" || r.URL.Query().Get("page") != "2" {
					t.Errorf("unexpected pagination request: %s", r.URL.RequestURI())
				}
				if fault == "failed-second-page" {
					w.WriteHeader(503)
					io.WriteString(w, `{"message":"unavailable"}`)
					return
				}
				previous := fmt.Sprintf("<http://%s/repositories/4242/issues?state=open&per_page=100&before=Y3Vyc29yOjI%%3D&page=1>; rel=\"prev\"", r.Host)
				if fault == "wrong-terminal-direction" {
					previous = strings.ReplaceAll(previous, "&before=", "&after=")
				}
				w.Header().Set("Link", previous)
				io.WriteString(w, `[{"number":11,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/11"}]`)
			})
			g.cfg.RepositoryID = "4242"
			if fault == "missing-id" {
				g.cfg.RepositoryID = ""
			} else if fault == "invalid-id" {
				g.cfg.RepositoryID = "04242"
			}
			inventory := request(t, g, "GET", "/repos/offline/fixture/issues?state=open&per_page=100", "")
			closed := request(t, g, "PATCH", "/repos/offline/fixture/issues/11", `{"state":"closed"}`)
			if fault == "" || fault == "same-page-control" {
				if inventory.Code != 200 || closed.Code != 200 || reads != 2 || writes != 1 || g.Verdict() != nil || !strings.Contains(inventory.Body.String(), "Earlier task") || !strings.Contains(inventory.Body.String(), "Task") {
					t.Fatalf("healthy complete inventory refused: inventory=%d close=%d reads=%d writes=%d verdict=%v", inventory.Code, closed.Code, reads, writes, g.Verdict())
				}
			} else if inventory.Code < 400 || closed.Code < 400 || writes != 0 || g.Verdict() == nil {
				t.Fatalf("incomplete inventory authorized mutation: inventory=%d close=%d writes=%d verdict=%v", inventory.Code, closed.Code, writes, g.Verdict())
			}
		})
	}
}
