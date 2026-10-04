package guard

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const projectDocument = `query($owner: String!) { organization(login: $owner) { projectsV2(first: 10) { nodes { id title } } } }`
const issueDocument = `query($owner: String!, $repo: String!, $issue_number: Int!) { repository(owner: $owner, name: $repo) { issue(number: $issue_number) { id } } }`
const addDocument = `mutation($projectId: ID!, $contentId: ID!) { addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) { item { id } } }`

func projectRequest(t *testing.T, g *guard, document string, variables map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"query": document, "variables": variables})
	r := httptest.NewRequest("POST", "https://api.github.com/graphql", strings.NewReader(string(b)))
	r.Header.Set("Authorization", "Bearer fixture-project-token")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}
func TestNumericProjectUsesNativeNumberAndCompletesAddition(t *testing.T) {
	queries := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		queries++
		b, _ := io.ReadAll(r.Body)
		var q map[string]any
		json.Unmarshal(b, &q)
		doc := q["query"].(string)
		switch {
		case strings.Contains(doc, "projectV2(number:"):
			vars := q["variables"].(map[string]any)
			if vars["number"] != float64(5) || vars["owner"] != "offline" {
				t.Errorf("numeric selector not bound: %s", b)
			}
			io.WriteString(w, `{"data":{"organization":{"projectV2":{"id":"PVT_fixture","title":"Project Board","number":5}}}}`)
		case strings.Contains(doc, "repository("):
			io.WriteString(w, `{"data":{"repository":{"issue":{"id":"I_fixture"}}}}`)
		case strings.Contains(doc, "addProjectV2ItemById"):
			io.WriteString(w, `{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_fixture"}}}}`)
		default:
			t.Errorf("unexpected query: %s", doc)
			w.WriteHeader(500)
		}
	})
	g.cfg.Project = "organization/offline/5"
	g.cfg.ProjectToken = "fixture-project-token"
	g.issues[7] = true
	p := projectRequest(t, g, projectDocument, map[string]any{"owner": "offline"})
	if p.Code != 200 || !strings.Contains(p.Body.String(), `"title":"5"`) {
		t.Fatalf("numeric project not adapted for unchanged scanner: %d %s", p.Code, p.Body.String())
	}
	projectRequest(t, g, issueDocument, map[string]any{"owner": "offline", "repo": "fixture", "issue_number": 7})
	p = projectRequest(t, g, addDocument, map[string]any{"projectId": "PVT_fixture", "contentId": "I_fixture"})
	if p.Code != 200 || g.verdict() != nil || !g.MutationStarted() || queries != 3 {
		t.Fatalf("healthy project operation failed: queries=%d response=%d verdict=%v", queries, p.Code, g.verdict())
	}
}
func TestTitleProjectDiscoveryCompletesCursorPages(t *testing.T) {
	reads := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		reads++
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), `"cursor":"next"`) {
			io.WriteString(w, `{"data":{"organization":{"projectsV2":{"nodes":[{"id":"PVT_first","title":"Other"}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}`)
		} else {
			io.WriteString(w, `{"data":{"organization":{"projectsV2":{"nodes":[{"id":"PVT_target","title":"Selected"}],"pageInfo":{"hasNextPage":false,"endCursor":"end"}}}}}`)
		}
	})
	g.cfg.Project = "organization/offline/Selected"
	g.cfg.ProjectToken = "fixture-project-token"
	p := projectRequest(t, g, projectDocument, map[string]any{"owner": "offline"})
	if p.Code != 200 || reads != 2 || !strings.Contains(p.Body.String(), "PVT_target") || g.verdict() != nil {
		t.Fatalf("incomplete project pages: reads=%d %s verdict=%v", reads, p.Body.String(), g.verdict())
	}
}
func TestProjectIncompleteEvidenceDeniesLaterMutation(t *testing.T) {
	for _, body := range []string{`{"errors":[{"message":"denied"}],"data":{"organization":{"projectsV2":{"nodes":[]}}}}`, `{"data":null}`, `{"data":{"organization":{"projectsV2":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}`, `{"data":{"organization":{"projectsV2":{"nodes":[{"id":"PVT_first","title":"Other"}],"pageInfo":{"hasNextPage":false,"endCursor":"end"}}}}}`} {
		t.Run(body, func(t *testing.T) {
			calls := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) { calls++; io.WriteString(w, body) })
			g.cfg.Project = "organization/offline/Selected"
			g.cfg.ProjectToken = "fixture-project-token"
			projectRequest(t, g, projectDocument, map[string]any{"owner": "offline"})
			request(t, g, "POST", "/repos/offline/fixture/issues", `{"title":"Task","body":"source","labels":[],"assignees":[]}`)
			if calls != 1 || g.verdict() == nil {
				t.Fatalf("project failure allowed later write: calls=%d verdict=%v", calls, g.verdict())
			}
		})
	}
}
func TestFailedProjectAdditionMakesResultIncomplete(t *testing.T) {
	for _, body := range []string{`{"errors":[{"message":"denied"}],"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_fixture"}}}}`, `{"data":{"addProjectV2ItemById":{"item":null}}}`, `{"data":{"addProjectV2ItemById":{"item":{"id":""}}}}`} {
		t.Run(body, func(t *testing.T) {
			calls := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) { calls++; io.WriteString(w, body) })
			g.cfg.Project = "organization/offline/5"
			g.cfg.ProjectToken = "fixture-project-token"
			g.issueIDs["I_fixture"] = true
			g.projectIDs["PVT_fixture"] = true
			p := projectRequest(t, g, addDocument, map[string]any{"projectId": "PVT_fixture", "contentId": "I_fixture"})
			if p.Code < 400 || g.verdict() == nil || !g.MutationStarted() {
				t.Fatalf("project addition failure reported success: %d verdict=%v started=%v", p.Code, g.verdict(), g.MutationStarted())
			}
			request(t, g, "POST", "/repos/offline/fixture/issues", `{"title":"Task","body":"source","labels":[],"assignees":[]}`)
			if calls != 1 {
				t.Fatal("failed project addition forwarded a later write")
			}
		})
	}
}
func TestUnknownProjectDocumentsAndIdentityCannotReachAPI(t *testing.T) {
	for i, doc := range []string{projectDocument, issueDocument, addDocument, "mutation { deleteProjectV2(input:{projectId:\"PVT_fixture\"}){clientMutationId} }"} {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			calls := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) { calls++; io.WriteString(w, "{}") })
			g.cfg.Project = "organization/offline/5"
			g.cfg.ProjectToken = "fixture-project-token"
			projectRequest(t, g, doc, map[string]any{"owner": "other", "repo": "fixture", "issue_number": 7, "projectId": "PVT_foreign", "contentId": "I_foreign"})
			if calls != 0 || g.verdict() == nil {
				t.Fatalf("unbound GraphQL escaped: calls=%d verdict=%v", calls, g.verdict())
			}
		})
	}
}
