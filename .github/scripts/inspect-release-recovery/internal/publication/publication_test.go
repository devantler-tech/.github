package publication

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/devantler-tech/dotgithub/inspect-release-recovery/internal/inspection"
)

const source = "607fd864e98d7883274270d0737934963039407c"
const producer = "devantler-tech/actions/.github/workflows/create-release.yaml@10ab0f1c94b951c16f6db58d094b42d49e2f775f"
const config = `{"branches":["main"],"plugins":["@semantic-release/commit-analyzer","@semantic-release/release-notes-generator","@semantic-release/github"]}`
const repo = "/repos/devantler-tech/platform"
const token = "fixture-writer-token"

func args() []string {
	return []string{"--repository", "devantler-tech/platform", "--tag", "v1.222.1", "--source-sha", source,
		"--run-id", "38418390528", "--run-attempt", "1", "--producer-ref", producer}
}

func blobSHA(content string) string {
	return fmt.Sprintf("%x", sha1.Sum([]byte(fmt.Sprintf("blob %d%c%s", len(content), 0, content))))
}

func release(id int, tag string) map[string]any {
	return map[string]any{"id": id, "tag_name": tag, "target_commitish": "main", "draft": false, "prerelease": false,
		"published_at": "2026-10-15T10:00:00Z", "body": ""}
}

// github is a stateful stand-in for the GitHub REST API: a POST really creates the release
// that later reads observe, so readback and rerun reconciliation are exercised end to end.
type github struct {
	mu         sync.Mutex
	releases   []map[string]any // newest first, as the API lists them
	latest     int              // id of the latest release, 0 for none
	posts      []map[string]any
	requests   []string
	counts     map[string]int
	edit       func(r *http.Request, count int, status *int, body *string) // adjust a GET response
	onPost     func(w http.ResponseWriter, created map[string]any) bool    // true when it wrote the response
	unexpected []string
}

func newGitHub() *github {
	return &github{releases: []map[string]any{release(9, "v1.222.0")}, latest: 9, counts: map[string]int{}}
}

func (g *github) find(tag string) map[string]any {
	for _, r := range g.releases {
		if r["tag_name"] == tag {
			return r
		}
	}
	return nil
}

func encode(value any) string {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(raw)
}

func (g *github) get(r *http.Request) (int, string) {
	path := r.URL.Path
	switch path {
	case repo:
		return 200, `{"id":42,"name":"platform","owner":{"login":"devantler-tech"},"full_name":"devantler-tech/platform","visibility":"public","private":false,"archived":false,"disabled":false,"default_branch":"main","permissions":{"admin":false,"push":true,"pull":true}}`
	case repo + "/actions/runs/38418390528/attempts/1":
		return 200, `{"id":38418390528,"run_attempt":1,"path":".github/workflows/release.yaml","event":"push","status":"completed","conclusion":"failure","head_sha":"` + source + `","head_branch":"main","repository":{"id":42,"full_name":"devantler-tech/platform","private":false},"head_repository":{"id":42,"full_name":"devantler-tech/platform","private":false},"referenced_workflows":[{"path":"` + producer + `","sha":"10ab0f1c94b951c16f6db58d094b42d49e2f775f"}]}`
	case repo + "/git/ref/tags/v1.222.1":
		return 200, `{"ref":"refs/tags/v1.222.1","object":{"type":"commit","sha":"` + source + `"}}`
	case repo + "/git/commits/" + source:
		return 200, `{"sha":"` + source + `","tree":{"sha":"3333333333333333333333333333333333333333"}}`
	case repo + "/git/trees/3333333333333333333333333333333333333333":
		return 200, `{"sha":"3333333333333333333333333333333333333333","truncated":false,"tree":[{"path":".releaserc","type":"blob","mode":"100644","sha":"` + blobSHA(config) + `"}]}`
	case repo + "/contents/.releaserc":
		return 200, encode(map[string]any{"type": "file", "path": ".releaserc", "sha": blobSHA(config), "encoding": "base64",
			"size": len(config), "content": base64.StdEncoding.EncodeToString([]byte(config))})
	case repo + "/releases/tags/v1.222.1":
		if found := g.find("v1.222.1"); found != nil {
			return 200, encode(found)
		}
		return 404, `{"message":"Not Found"}`
	case repo + "/releases/latest":
		for _, r := range g.releases {
			if r["id"] == g.latest {
				return 200, encode(r)
			}
		}
		return 404, `{"message":"Not Found"}`
	case repo + "/releases":
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		if r.URL.Query().Get("per_page") != "100" || page < 1 {
			return 500, `{"message":"unreviewed page request"}`
		}
		start, end := (page-1)*100, page*100
		if start > len(g.releases) {
			start = len(g.releases)
		}
		if end > len(g.releases) {
			end = len(g.releases)
		}
		return 200, encode(g.releases[start:end])
	}
	return 500, `{"message":"unreviewed fixture request"}`
}

func (g *github) serve(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		defer g.mu.Unlock()
		g.requests = append(g.requests, r.Method+" "+r.URL.RequestURI())
		g.counts[r.Method+" "+r.URL.Path]++
		if r.Header.Get("Authorization") != "Bearer "+token {
			g.unexpected = append(g.unexpected, "request without the fixture credential")
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet:
			status, body := g.get(r)
			if g.edit != nil {
				g.edit(r, g.counts[r.Method+" "+r.URL.Path], &status, &body)
			}
			w.WriteHeader(status)
			_, _ = io.WriteString(w, body)
		case r.Method == http.MethodPost && r.URL.Path == repo+"/releases":
			raw, _ := io.ReadAll(r.Body)
			var payload map[string]any
			if err := json.Unmarshal(raw, &payload); err != nil {
				g.unexpected = append(g.unexpected, "malformed publication payload")
			}
			g.posts = append(g.posts, payload)
			created := release(18, text(payload["tag_name"]))
			created["target_commitish"] = payload["target_commitish"]
			created["body"] = payload["body"]
			created["name"] = payload["name"]
			if g.onPost != nil && g.onPost(w, created) {
				return
			}
			g.releases = append([]map[string]any{created}, g.releases...)
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, encode(created))
		default:
			g.unexpected = append(g.unexpected, "unreviewed "+r.Method+" "+r.URL.Path)
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{"message":"unreviewed request"}`)
		}
	}))
}

func (g *github) exercise(t *testing.T) (map[string]any, error) {
	t.Helper()
	server := g.serve(t)
	defer server.Close()
	var out bytes.Buffer
	err := run(args(), token, &out, newPublisher(server.Client(), server.URL))
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.unexpected) != 0 {
		t.Fatalf("publisher sent unreviewed requests: %v", g.unexpected)
	}
	if err != nil {
		if out.Len() != 0 {
			t.Fatalf("refusal also printed a result: %q", out.String())
		}
		if strings.Contains(err.Error(), token) {
			t.Fatal("credential leaked in diagnostic")
		}
		return nil, err
	}
	var result map[string]any
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatalf("result is not JSON: %q", out.String())
	}
	return result, nil
}

func admission() *inspection.Admission {
	return &inspection.Admission{Repository: "devantler-tech/platform", Tag: "v1.222.1", SourceSHA: source,
		RunID: "38418390528", RunAttempt: "1", ProducerRef: producer, DefaultBranch: "main"}
}

// One request publishes the existing tag with the honest receipt and without touching latest.
func TestPublishesOnceAndReadsBack(t *testing.T) {
	g := newGitHub()
	result, err := g.exercise(t)
	if err != nil {
		t.Fatal(err)
	}
	if result["result"] != "published" || result["release_id"] != "18" || result["publication_requests"] != float64(1) {
		t.Fatalf("unexpected result %v", result)
	}
	if len(g.posts) != 1 {
		t.Fatalf("expected exactly one publication request, got %d", len(g.posts))
	}
	want := map[string]any{"tag_name": "v1.222.1", "target_commitish": source, "name": "v1.222.1", "body": Receipt(admission()),
		"draft": false, "prerelease": false, "generate_release_notes": false, "make_latest": "false"}
	if encode(g.posts[0]) != encode(want) {
		t.Fatalf("publication payload %s, want %s", encode(g.posts[0]), encode(want))
	}
	if g.latest != 9 {
		t.Fatal("latest release moved")
	}
}

// The receipt names the original run, tag, source and producer, and says notes were not rebuilt.
func TestReceiptIsHonestAndDeterministic(t *testing.T) {
	receipt := Receipt(admission())
	for _, want := range []string{"v1.222.1", source, "/devantler-tech/platform/actions/runs/38418390528/attempts/1",
		producer, "original generated release notes were not reconstructed"} {
		if !strings.Contains(receipt, want) {
			t.Fatalf("receipt omits %q:\n%s", want, receipt)
		}
	}
	if receipt != Receipt(admission()) {
		t.Fatal("receipt is not deterministic")
	}
}

// A matching publication found at admission or at re-admission is a verified no-op.
func TestMatchingPublicationIsNoOp(t *testing.T) {
	t.Run("at-admission", func(t *testing.T) {
		g := newGitHub()
		g.releases = append([]map[string]any{release(17, "v1.222.1")}, g.releases...)
		result, err := g.exercise(t)
		if err != nil || result["result"] != "already-published" || len(g.posts) != 0 {
			t.Fatalf("expected a no-op, got %v %v posts=%d", result, err, len(g.posts))
		}
		if g.counts["GET "+repo+"/releases"] != 0 {
			t.Fatal("no-op still took a writer inventory")
		}
	})
	t.Run("at-re-admission", func(t *testing.T) {
		g := newGitHub()
		g.edit = func(r *http.Request, count int, status *int, body *string) {
			// Admission reads the publication twice; it appears before the third read.
			if r.URL.Path == repo+"/releases/tags/v1.222.1" && count == 3 {
				g.releases = append([]map[string]any{release(17, "v1.222.1")}, g.releases...)
				*status, *body = 200, encode(release(17, "v1.222.1"))
			}
		}
		result, err := g.exercise(t)
		if err != nil || result["result"] != "already-published" || len(g.posts) != 0 {
			t.Fatalf("expected a no-op, got %v %v posts=%d", result, err, len(g.posts))
		}
	})
}

// Every refusal before the write sends zero publication requests.
func TestRefusalsBeforeWriteSendNothing(t *testing.T) {
	fullPage := func(g *github, pages int) {
		for i := 0; i < pages*100; i++ {
			g.releases = append(g.releases, release(1000+i, fmt.Sprintf("v0.0.%d", i)))
		}
	}
	cases := map[string]func(g *github){
		"wrong-identity": func(g *github) {
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo+"/git/ref/tags/v1.222.1" {
					*body = strings.Replace(*body, source, strings.Repeat("a", 40), 1)
				}
			}
		},
		"missing-push-metadata": func(g *github) {
			g.edit = func(r *http.Request, count int, _ *int, body *string) {
				if r.URL.Path == repo {
					*body = strings.Replace(*body, `,"permissions":{"admin":false,"push":true,"pull":true}`, "", 1)
				}
			}
		},
		"push-false": func(g *github) {
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo {
					*body = strings.Replace(*body, `"push":true`, `"push":false`, 1)
				}
			}
		},
		"draft-on-later-page": func(g *github) {
			fullPage(g, 1)
			draft := release(5000, "v9.9.9")
			draft["draft"] = true
			g.releases = append(g.releases, draft)
		},
		"conflicting-record": func(g *github) {
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo+"/releases" {
					*body = encode([]any{release(17, "v1.222.1"), release(9, "v1.222.0")})
				}
			}
		},
		"inventory-beyond-bound": func(g *github) { fullPage(g, maxPages) },
		"inventory-changed": func(g *github) {
			g.edit = func(r *http.Request, count int, _ *int, body *string) {
				if r.URL.Path == repo+"/releases/latest" && count == 2 {
					*body = encode(release(10, "v1.222.0"))
				}
			}
		},
		"malformed-inventory": func(g *github) {
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo+"/releases" {
					*body = `{"releases":[]}`
				}
			}
		},
		"failed-inventory-read": func(g *github) {
			g.edit = func(r *http.Request, _ int, status *int, _ *string) {
				if r.URL.Path == repo+"/releases" {
					*status = 502
				}
			}
		},
		"prerelease-latest": func(g *github) {
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo+"/releases/latest" {
					*body = strings.Replace(*body, `"prerelease":false`, `"prerelease":true`, 1)
				}
			}
		},
		"source-changed-at-re-admission": func(g *github) {
			g.edit = func(r *http.Request, count int, _ *int, body *string) {
				if r.URL.Path == repo+"/git/ref/tags/v1.222.1" && count >= 3 {
					*body = `{"ref":"refs/tags/v1.222.1","object":{"type":"commit","sha":"` + strings.Repeat("b", 40) + `"}}`
				}
			}
		},
	}
	reasons := map[string]string{
		"wrong-identity":                 "tag does not resolve directly to the captured source",
		"missing-push-metadata":          "no proven push access",
		"push-false":                     "no proven push access",
		"draft-on-later-page":            "a draft release exists",
		"conflicting-record":             "a release record for this tag exists",
		"inventory-beyond-bound":         "exceeds the supported bound",
		"inventory-changed":              "changed between independent reads",
		"malformed-inventory":            "page is malformed",
		"failed-inventory-read":          "release inventory: API read",
		"prerelease-latest":              "latest release is not a published stable release",
		"source-changed-at-re-admission": "re-admission:",
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			g := newGitHub()
			setup(g)
			if result, err := g.exercise(t); err == nil {
				t.Fatalf("expected a refusal, got %v", result)
			} else if !strings.Contains(err.Error(), reasons[name]) {
				t.Fatalf("refused for the wrong reason: %v (want %q)", err, reasons[name])
			}
			if len(g.posts) != 0 {
				t.Fatalf("refusal sent %d publication requests", len(g.posts))
			}
		})
	}
}

// After the single write, failures are reported and never retried.
func TestWriteOutcomesAreNeverRetried(t *testing.T) {
	cases := map[string]func(g *github){
		"refused-write": func(g *github) {
			g.onPost = func(w http.ResponseWriter, _ map[string]any) bool {
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = io.WriteString(w, `{"message":"Validation Failed"}`)
				return true
			}
		},
		"malformed-success": func(g *github) {
			g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
				g.releases = append([]map[string]any{created}, g.releases...)
				w.WriteHeader(http.StatusCreated)
				_, _ = io.WriteString(w, `{"id":18,"tag_name":"v1.222.1","draft":false,"prerelease":false,"id":19}`)
				return true
			}
		},
		"readback-body-differs": func(g *github) {
			g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
				stored := map[string]any{}
				for k, v := range created {
					stored[k] = v
				}
				stored["body"] = "generated notes"
				g.releases = append([]map[string]any{stored}, g.releases...)
				w.WriteHeader(http.StatusCreated)
				_, _ = io.WriteString(w, encode(created))
				return true
			}
		},
		"latest-moved": func(g *github) {
			g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
				g.releases = append([]map[string]any{created}, g.releases...)
				g.latest = 18
				w.WriteHeader(http.StatusCreated)
				_, _ = io.WriteString(w, encode(created))
				return true
			}
		},
		"failed-readback": func(g *github) {
			g.edit = func(r *http.Request, count int, status *int, _ *string) {
				if r.URL.Path == repo+"/releases/tags/v1.222.1" && len(g.posts) == 1 {
					*status = 503
				}
			}
		},
	}
	reasons := map[string]string{
		"refused-write":         "refused with status 422",
		"malformed-success":     "does not describe the requested release",
		"readback-body-differs": "readback does not match",
		"latest-moved":          "latest release changed",
		"failed-readback":       "publication readback: API read",
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			g := newGitHub()
			setup(g)
			if result, err := g.exercise(t); err == nil {
				t.Fatalf("expected a failure, got %v", result)
			} else if !strings.Contains(err.Error(), reasons[name]) {
				t.Fatalf("refused for the wrong reason: %v (want %q)", err, reasons[name])
			}
			if len(g.posts) != 1 {
				t.Fatalf("expected exactly one publication request, got %d", len(g.posts))
			}
		})
	}
}

// A connection lost after GitHub accepted the write fails without retrying; an explicit
// rerun then finds the publication through fresh reads and sends nothing more.
func TestConnectionLossThenRerunReconciles(t *testing.T) {
	g := newGitHub()
	g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
		g.releases = append([]map[string]any{created}, g.releases...)
		connection, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			_ = connection.Close()
		}
		return true
	}
	if result, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "do not retry") {
		t.Fatalf("expected an unknown-outcome failure, got %v %v", result, err)
	}
	g.onPost = nil
	result, err := g.exercise(t)
	if err != nil || result["result"] != "already-published" {
		t.Fatalf("rerun did not reconcile: %v %v", result, err)
	}
	if len(g.posts) != 1 {
		t.Fatalf("expected one publication request across both runs, got %d", len(g.posts))
	}
}

// Invalid incident flags or credentials are refused before any request.
func TestInvalidInputSendsNoRequest(t *testing.T) {
	g := newGitHub()
	server := g.serve(t)
	defer server.Close()
	var out bytes.Buffer
	if err := run(append(args(), "--tag", "v1.0.0"), token, &out, newPublisher(server.Client(), server.URL)); err == nil {
		t.Fatal("repeated flag accepted")
	}
	if err := run(args(), "", &out, newPublisher(server.Client(), server.URL)); err == nil {
		t.Fatal("missing credential accepted")
	}
	if len(g.requests) != 0 || out.Len() != 0 {
		t.Fatalf("refused input still sent %d requests", len(g.requests))
	}
}
