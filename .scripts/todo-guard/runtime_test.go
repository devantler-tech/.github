package guard

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestChildZeroExitCannotHideAPIFailure(t *testing.T) {
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			writes++
		}
		w.WriteHeader(503)
		io.WriteString(w, `{"message":"unavailable"}`)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	err := RunChild(ctx, g, []string{"/bin/sh", "-c", `curl -s -H 'Authorization: token fixture-token' "$INPUT_GITHUB_URL/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30" >/dev/null; curl -s -X POST -H 'Authorization: token fixture-token' -d '{"title":"Task","body":"source","labels":[],"assignees":[]}' "$INPUT_GITHUB_URL/repos/offline/fixture/issues" >/dev/null; exit 0`}, []string{"PATH=/usr/bin:/bin"}, io.Discard)
	if err == nil || writes != 0 {
		t.Fatalf("zero child exit hid API failure or replayed a write: err=%v writes=%d", err, writes)
	}
}
func TestChildProxyCannotBeBypassedByInheritedEnvironment(t *testing.T) {
	env := childEnvironment([]string{"https_proxy=https://untrusted.invalid", "HTTP_PROXY=https://untrusted.invalid", "ALL_PROXY=https://untrusted.invalid", "NO_PROXY=*", "INPUT_GITHUB_URL=https://untrusted.invalid", "REQUESTS_CA_BUNDLE=/untrusted", "INPUT_TOKEN=fixture-token"}, "http://127.0.0.1:1234", "/trusted-ca")
	for _, entry := range env {
		if strings.Contains(entry, "untrusted") || entry == "NO_PROXY=*" {
			t.Fatalf("inherited bypass retained: %s", entry)
		}
	}
	if !containsEntry(env, "HTTPS_PROXY=http://127.0.0.1:1234") || !containsEntry(env, "NO_PROXY=127.0.0.1") || !containsEntry(env, "INPUT_TOKEN=fixture-token") {
		t.Fatalf("guard routing lost: %v", env)
	}
}
func containsEntry(env []string, want string) bool {
	for _, s := range env {
		if s == want {
			return true
		}
	}
	return false
}
func TestLanguageReadsRetryOnlyBeforeAnyMutation(t *testing.T) {
	for _, started := range []bool{false, true} {
		t.Run(map[bool]string{false: "before", true: "after"}[started], func(t *testing.T) {
			attempts := 0
			g := newGuard(Config{}, &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				attempts++
				if r.Header.Get("Authorization") != "" {
					t.Fatal("credential leaked to language download")
				}
				if attempts == 1 {
					return nil, errors.New("transient transport")
				}
				return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/plain"}}, Body: io.NopCloser(strings.NewReader("Shell:\n"))}, nil
			})})
			g.mutationStarted = started
			r := httptest.NewRequest("GET", "https://raw.githubusercontent.com/github/linguist/master/lib/linguist/languages.yml", nil)
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if started {
				if attempts != 1 || g.verdict() == nil {
					t.Fatalf("read retried after mutation: attempts=%d verdict=%v", attempts, g.verdict())
				}
			} else if attempts != 2 || w.Code != 200 || g.verdict() != nil {
				t.Fatalf("read-only recovery failed: attempts=%d status=%d verdict=%v", attempts, w.Code, g.verdict())
			}
		})
	}
}
func TestRawPathsAndCredentialsAreBound(t *testing.T) {
	for _, path := range []string{"/github/linguist/master/other.yml", "/alstr/todo-to-issue-action/master/syntax.json?other=1"} {
		t.Run(path, func(t *testing.T) {
			calls := 0
			g := newGuard(Config{}, &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) { calls++; return nil, errors.New("unexpected") })})
			r := httptest.NewRequest("GET", "https://raw.githubusercontent.com"+path, nil)
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if calls != 0 || g.verdict() == nil {
				t.Fatalf("unexpected language route escaped: calls=%d verdict=%v", calls, g.verdict())
			}
		})
	}
}

func TestConcurrentCreationConsumesSearchBeforeSend(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			io.WriteString(w, `{"total_count":0,"incomplete_results":false,"items":[]}`)
			return
		}
		writes++
		close(started)
		<-release
		w.WriteHeader(201)
		io.WriteString(w, `{"number":8}`)
	})
	request(t, g, "GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", "")
	done := make(chan int, 2)
	body := `{"title":"Task","body":"source","labels":[],"assignees":[]}`
	go func() { done <- request(t, g, "POST", "/repos/offline/fixture/issues", body).Code }()
	<-started
	go func() { done <- request(t, g, "POST", "/repos/offline/fixture/issues", body).Code }()
	close(release)
	a, b := <-done, <-done
	if writes != 1 || !((a == 201 && b == 502) || (a == 502 && b == 201)) {
		t.Fatalf("creation authorization reused: writes=%d status=%d/%d", writes, a, b)
	}
}
func TestAcceptedMutationWithLostResponseDeniesQueuedWrite(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	writes := 0
	g := fixtureGuard(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			io.WriteString(w, `{"total_count":0,"incomplete_results":false,"items":[]}`)
			return
		}
		writes++
		close(started)
		<-release
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	})
	request(t, g, "GET", "/search/issues?q=repo%3Aoffline%2Ffixture+is%3Aissue+in%3Atitle+Task&per_page=30", "")
	done := make(chan int, 2)
	go func() {
		done <- request(t, g, "POST", "/repos/offline/fixture/issues", `{"title":"Task","body":"source","labels":[],"assignees":[]}`).Code
	}()
	<-started
	go func() {
		done <- request(t, g, "POST", "/repos/offline/fixture/issues/12/comments", `{"body":"later"}`).Code
	}()
	close(release)
	a, b := <-done, <-done
	if writes != 1 || a != 502 || b != 502 || !g.MutationStarted() || g.Verdict() == nil {
		t.Fatalf("uncertain mutation replayed: writes=%d status=%d/%d verdict=%v", writes, a, b, g.Verdict())
	}
}
