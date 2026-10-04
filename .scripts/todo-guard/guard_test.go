package guard

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func request(t *testing.T, g http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "token fixture-token")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}
func fixtureGuard(t *testing.T, upstream http.HandlerFunc) *guard {
	t.Helper()
	s := httptest.NewServer(upstream)
	t.Cleanup(s.Close)
	u, _ := url.Parse(s.URL)
	return newGuard(config{API: u, Repository: "offline/fixture", Server: "https://example.invalid", Token: "fixture-token", SHA: strings.Repeat("1", 40)}, s.Client())
}
func TestFailedSearchNeverAuthorizesCreation(t *testing.T) {
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			writes++
		}
		w.WriteHeader(503)
		io.WriteString(w, `{"message":"unavailable"}`)
	})
	request(t, g, "GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", "")
	request(t, g, "POST", "/repos/offline/fixture/issues", `{"title":"Task","body":"source","labels":[],"assignees":[]}`)
	if writes != 0 {
		t.Fatalf("failed duplicate evidence allowed %d mutation(s)", writes)
	}
	if g.verdict() == nil {
		t.Fatal("failed search reported success")
	}
}
func TestFailedCloseNeverAuthorizesComment(t *testing.T) {
	writes := []string{}
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			io.WriteString(w, `[{"number":11,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/11"}]`)
			return
		}
		writes = append(writes, r.Method+" "+r.URL.Path)
		w.WriteHeader(422)
		io.WriteString(w, `{"message":"rejected"}`)
	})
	request(t, g, "GET", "/repos/offline/fixture/issues?per_page=100&page=1&state=open", "")
	request(t, g, "PATCH", "/repos/offline/fixture/issues/11", `{"state":"closed"}`)
	request(t, g, "POST", "/repos/offline/fixture/issues/11/comments", `{"body":"Closed in 1111111111111111111111111111111111111111."}`)
	if len(writes) != 1 {
		t.Fatalf("rejected close forwarded follow-up writes: %v", writes)
	}
	if g.verdict() == nil {
		t.Fatal("rejected close reported success")
	}
}
func TestFailedCommentPreservesCompletedCloseAndFails(t *testing.T) {
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			io.WriteString(w, `[{"number":11,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/11"}]`)
		case "PATCH":
			io.WriteString(w, `{"number":11,"state":"closed"}`)
		case "POST":
			w.WriteHeader(422)
			io.WriteString(w, `{"message":"rejected"}`)
		}
	})
	request(t, g, "GET", "/repos/offline/fixture/issues?per_page=100&page=1&state=open", "")
	request(t, g, "PATCH", "/repos/offline/fixture/issues/11", `{"state":"closed"}`)
	request(t, g, "POST", "/repos/offline/fixture/issues/11/comments", `{"body":"Closed in 1111111111111111111111111111111111111111."}`)
	if !g.closed[11] || g.verdict() == nil {
		t.Fatalf("completed close or failed-comment evidence lost: closed=%v verdict=%v", g.closed, g.verdict())
	}
}
func TestHealthyCreationAndDuplicateEvidence(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		t.Run(fmt.Sprint(duplicate), func(t *testing.T) {
			writes := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "GET" {
					if duplicate {
						io.WriteString(w, `{"total_count":1,"incomplete_results":false,"items":[{"number":7,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/7"}]}`)
					} else {
						io.WriteString(w, `{"total_count":0,"incomplete_results":false,"items":[]}`)
					}
					return
				}
				writes++
				w.WriteHeader(201)
				io.WriteString(w, `{"number":8}`)
			})
			w := request(t, g, "GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", "")
			if w.Code != 200 {
				t.Fatalf("healthy search failed: %d %s", w.Code, w.Body.String())
			}
			if !duplicate {
				w = request(t, g, "POST", "/repos/offline/fixture/issues", `{"title":"Task","body":"source","labels":[],"assignees":[]}`)
				if w.Code != 201 {
					t.Fatalf("healthy creation failed: %d %s", w.Code, w.Body.String())
				}
			}
			if g.verdict() != nil || writes != map[bool]int{false: 1, true: 0}[duplicate] {
				t.Fatalf("healthy result failed: %v writes=%d", g.verdict(), writes)
			}
		})
	}
}
func TestIncompleteSearchCannotAuthorizeMutation(t *testing.T) {
	for _, body := range []string{`{"total_count":0,"incomplete_results":true,"items":[]}`, `{"items":[]}`, `{"total_count":1,"incomplete_results":false,"items":[]}`, `{"total_count":1001,"incomplete_results":false,"items":[]}`, `{"total_count":0,"incomplete_results":false,"items":null}`, `{"total_count":0,"incomplete_results":false,"items":[]} trailing`} {
		t.Run(body, func(t *testing.T) {
			writes := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" {
					writes++
				}
				io.WriteString(w, body)
			})
			request(t, g, "GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", "")
			request(t, g, "POST", "/repos/offline/fixture/issues", `{"title":"Task","body":"source","labels":[],"assignees":[]}`)
			if writes != 0 || g.verdict() == nil {
				t.Fatalf("incomplete search authorized mutation: writes=%d verdict=%v", writes, g.verdict())
			}
		})
	}
}
func TestSearchCompletesEveryPageBeforeReturning(t *testing.T) {
	pages := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		pages++
		if r.URL.Query().Get("page") == "2" {
			io.WriteString(w, `{"total_count":2,"incomplete_results":false,"items":[{"number":8,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/8"}]}`)
			return
		}
		w.Header().Set("Link", fmt.Sprintf("<http://%s/search/issues?q=repo%%3Aoffline%%2Ffixture+is%%3Aissue+in%%3Atitle+Task&per_page=30&page=2>; rel=\"next\"", r.Host))
		io.WriteString(w, `{"total_count":2,"incomplete_results":false,"items":[{"number":7,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/7"}]}`)
	})
	w := request(t, g, "GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", "")
	var body struct{ Items []json.RawMessage }
	if json.Unmarshal(w.Body.Bytes(), &body) != nil || w.Code != 200 || len(body.Items) != 2 || pages != 2 || w.Header().Get("Link") != "" {
		t.Fatalf("partial duplicate evidence returned: pages=%d response=%d %s", pages, w.Code, w.Body.String())
	}
}
func TestFailedLaterIssuePageDeniesClosure(t *testing.T) {
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			writes++
		}
		if r.URL.Query().Get("page") == "2" {
			w.WriteHeader(503)
			return
		}
		w.Header().Set("Link", fmt.Sprintf("<http://%s/repos/offline/fixture/issues?per_page=100&page=2&state=open>; rel=\"next\"", r.Host))
		io.WriteString(w, `[{"number":11,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/11"}]`)
	})
	w := request(t, g, "GET", "/repos/offline/fixture/issues?per_page=100&page=1&state=open", "")
	request(t, g, "PATCH", "/repos/offline/fixture/issues/11", `{"state":"closed"}`)
	if w.Code < 400 || writes != 0 || g.verdict() == nil {
		t.Fatalf("partial issue evidence authorized closure: %d writes=%d", w.Code, writes)
	}
}
func TestUnexpectedRoutesAndCredentialsNeverReachUpstream(t *testing.T) {
	for _, spec := range []struct{ method, path, token string }{{"POST", "/repos/other/fixture/issues", "token fixture-token"}, {"DELETE", "/repos/offline/fixture/issues/7", "token fixture-token"}, {"GET", "/search/issues?q=repo%3Aother%2Ffixture+is%3Aissue+in%3Atitle+Task", "token fixture-token"}, {"GET", "/repos/offline/fixture/issues", "token wrong"}} {
		t.Run(spec.method+spec.path+spec.token, func(t *testing.T) {
			calls := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) { calls++; io.WriteString(w, "[]") })
			r := httptest.NewRequest(spec.method, spec.path, nil)
			r.Header.Set("Authorization", spec.token)
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if calls != 0 || w.Code < 400 || g.verdict() == nil {
				t.Fatalf("unexpected request escaped: calls=%d status=%d", calls, w.Code)
			}
		})
	}
}

func TestHealthyDiffAndBoundFallback(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		t.Run(fmt.Sprint(fallback), func(t *testing.T) {
			calls := 0
			g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
				calls++
				if fallback && strings.Contains(r.URL.Path, "/compare/") {
					w.WriteHeader(503)
					io.WriteString(w, `{"message":"unavailable"}`)
					return
				}
				io.WriteString(w, "diff --git a/a.sh b/a.sh\n")
			})
			g.cfg.Before = "fixture-base"
			r := httptest.NewRequest("GET", "/repos/offline/fixture/compare/fixture-base...1111111111111111111111111111111111111111", nil)
			r.Header.Set("Authorization", "token fixture-token")
			r.Header.Set("Accept", "application/vnd.github.v3.diff")
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if fallback {
				if w.Code < 400 || g.verdict() == nil {
					t.Fatal("failed compare did not require fallback")
				}
				r = httptest.NewRequest("GET", "/repos/offline/fixture/commits/1111111111111111111111111111111111111111", nil)
				r.Header.Set("Authorization", "token fixture-token")
				r.Header.Set("Accept", "application/vnd.github.v3.diff")
				w = httptest.NewRecorder()
				g.ServeHTTP(w, r)
			}
			if w.Code != 200 || g.verdict() != nil || calls != map[bool]int{false: 1, true: 2}[fallback] {
				t.Fatalf("healthy diff rejected: calls=%d status=%d verdict=%v", calls, w.Code, g.verdict())
			}
		})
	}
}
func TestOrdinaryReferencedCommentRemainsAvailable(t *testing.T) {
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		writes++
		w.WriteHeader(201)
		io.WriteString(w, `{"id":9}`)
	})
	w := request(t, g, "POST", "/repos/offline/fixture/issues/12/comments", `{"body":"Task\n\nhttps://example.invalid/offline/fixture/blob/1111111111111111111111111111111111111111/a.sh#L1"}`)
	if w.Code != 201 || writes != 1 || g.verdict() != nil {
		t.Fatalf("referenced comment regressed: status=%d writes=%d verdict=%v", w.Code, writes, g.verdict())
	}
}
func TestPullRequestRowsDoNotInvalidateCompleteIssueRead(t *testing.T) {
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `[{"number":4,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/pull/4","pull_request":{"url":"https://api.example.invalid/repos/offline/fixture/pulls/4"}},{"number":11,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/11"}]`)
	})
	w := request(t, g, "GET", "/repos/offline/fixture/issues?per_page=100&page=1&state=open", "")
	if w.Code != 200 || g.verdict() != nil || !g.issues[11] || g.issues[4] {
		t.Fatalf("normal issue/PR list failed: status=%d verdict=%v issues=%v", w.Code, g.verdict(), g.issues)
	}
	var rows []any
	json.Unmarshal(w.Body.Bytes(), &rows)
	if len(rows) != 1 {
		t.Fatalf("pull request leaked into TODO issue matching: %s", w.Body.String())
	}
}

func TestCurrentCommentIDRemainsValid(t *testing.T) {
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(201)
		io.WriteString(w, `{"id":5956146819}`)
	})
	w := request(t, g, "POST", "/repos/offline/fixture/issues/12/comments", `{"body":"Task"}`)
	if w.Code != 201 || g.Verdict() != nil {
		t.Fatalf("current native comment ID rejected: %d %v", w.Code, g.Verdict())
	}
}
func TestCompressedNativeResponses(t *testing.T) {
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Encoding", "gzip")
		z := gzip.NewWriter(w)
		defer z.Close()
		io.WriteString(z, `{"total_count":0,"incomplete_results":false,"items":[]}`)
	})
	r := httptest.NewRequest("GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", nil)
	r.Header.Set("Authorization", "token fixture-token")
	r.Header.Set("Accept-Encoding", "gzip, deflate")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Content-Encoding") != "" || g.Verdict() != nil {
		t.Fatalf("native compression failed: %d headers=%v verdict=%v", w.Code, w.Header(), g.Verdict())
	}
}
func TestNonterminalLastLinkCannotAuthorizeClosure(t *testing.T) {
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			writes++
		}
		w.Header().Set("Link", fmt.Sprintf("<http://%s/repos/offline/fixture/issues?per_page=100&page=2&state=open>; rel=\"last\"", r.Host))
		io.WriteString(w, `[{"number":11,"title":"Task","state":"open","html_url":"https://example.invalid/offline/fixture/issues/11"}]`)
	})
	w := request(t, g, "GET", "/repos/offline/fixture/issues?per_page=100&page=1&state=open", "")
	request(t, g, "PATCH", "/repos/offline/fixture/issues/11", `{"state":"closed"}`)
	if w.Code < 400 || writes != 0 || g.Verdict() == nil {
		t.Fatalf("incomplete list authorized closure: %d writes=%d", w.Code, writes)
	}
}
func TestLinkedClosedIssueUpdateUsesBoundRead(t *testing.T) {
	calls := []string{}
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		io.WriteString(w, `{"number":12,"title":"Old","state":"closed","html_url":"https://example.invalid/offline/fixture/issues/12"}`)
	})
	w := request(t, g, "PATCH", "/repos/offline/fixture/issues/12", `{"title":"Task","body":"source","labels":[],"assignees":[]}`)
	if w.Code != 200 || g.Verdict() != nil || len(calls) != 2 || calls[0] != "GET /repos/offline/fixture/issues/12" {
		t.Fatalf("linked update failed: status=%d calls=%v verdict=%v", w.Code, calls, g.Verdict())
	}
}

func TestEmptyBeforeRetainsBoundCommitFallback(t *testing.T) {
	calls := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if strings.Contains(r.URL.Path, "/compare/") {
			w.WriteHeader(422)
			return
		}
		io.WriteString(w, "diff --git a/a.sh b/a.sh\n")
	})
	for _, path := range []string{"/repos/offline/fixture/compare/...1111111111111111111111111111111111111111", "/repos/offline/fixture/commits/1111111111111111111111111111111111111111"} {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("Authorization", "token fixture-token")
		r.Header.Set("Accept", "application/vnd.github.v3.diff")
		g.ServeHTTP(httptest.NewRecorder(), r)
	}
	if calls != 2 || g.Verdict() != nil {
		t.Fatalf("empty event before rejected native fallback: calls=%d verdict=%v", calls, g.Verdict())
	}
}
