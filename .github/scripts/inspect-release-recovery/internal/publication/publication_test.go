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
	mu            sync.Mutex
	releases      []map[string]any // newest first, as the API lists them
	latest        int              // id of the latest release, 0 for none
	posts         []map[string]any
	previews      []map[string]any // capability checks do not persist a release or tag
	previewStatus int
	previewBody   string
	previewType   string
	requests      []string
	counts        map[string]int
	edit          func(r *http.Request, count int, status *int, body *string) // adjust a GET response
	onPost        func(w http.ResponseWriter, created map[string]any) bool    // true when it wrote the response
	unexpected    []string
}

func newGitHub() *github {
	return &github{releases: []map[string]any{release(9, "v1.222.0")}, latest: 9, counts: map[string]int{}}
}

// find mirrors GET /releases/tags/{tag}, which returns only a published release.
func (g *github) find(tag string) map[string]any {
	for _, r := range g.releases {
		if r["tag_name"] == tag && r["draft"] != true {
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
		if r.URL.Query().Get("per_page") != strconv.Itoa(pageSize) || page < 1 {
			return 500, `{"message":"unreviewed page request"}`
		}
		start, end := (page-1)*pageSize, page*pageSize
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
			if g.previewStatus == http.StatusForbidden {
				w.WriteHeader(http.StatusForbidden)
				_, _ = io.WriteString(w, `{"message":"Resource not accessible with this credential"}`)
				return
			}
			created := release(18, text(payload["tag_name"]))
			if target, present := payload["target_commitish"]; present {
				created["target_commitish"] = target
			}
			created["body"] = payload["body"]
			created["name"] = payload["name"]
			if g.onPost != nil && g.onPost(w, created) {
				return
			}
			g.releases = append([]map[string]any{created}, g.releases...)
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, encode(created))
		case r.Method == http.MethodPost && r.URL.Path == repo+"/releases/generate-notes":
			raw, _ := io.ReadAll(r.Body)
			var payload map[string]any
			if err := json.Unmarshal(raw, &payload); err != nil || len(payload) != 2 ||
				text(payload["tag_name"]) == "" || payload["tag_name"] == "v1.222.1" || payload["target_commitish"] != "main" {
				g.unexpected = append(g.unexpected, "capability preview did not use a separate tag at the admitted default branch")
			}
			g.previews = append(g.previews, payload)
			if r.Header.Get("Content-Type") != "application/json" || r.Header.Get("Accept") != "application/vnd.github+json" ||
				r.Header.Get("X-GitHub-Api-Version") != "2022-11-28" {
				g.unexpected = append(g.unexpected, "capability preview omitted the fixed API headers")
			}
			status := g.previewStatus
			if status == 0 {
				status = http.StatusOK
			}
			body := g.previewBody
			if body == "" {
				body = `{"name":"Capability preview","body":""}`
			}
			if g.previewType != "" {
				w.Header().Set("Content-Type", g.previewType)
			}
			w.WriteHeader(status)
			_, _ = io.WriteString(w, body)
		default:
			g.unexpected = append(g.unexpected, "unreviewed "+r.Method+" "+r.URL.Path)
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{"message":"unreviewed request"}`)
		}
	}))
}

// Installation-token authority comes from its granted capability, not user-role metadata.
// A read-only token can still describe a user/repository with push=true, so that field cannot
// establish that the credential may inspect drafts or publish.
func TestWriterCapabilityUsesServerPermissionProof(t *testing.T) {
	t.Run("installation-metadata-omits-user-permissions", func(t *testing.T) {
		g := newGitHub()
		g.edit = func(r *http.Request, _ int, _ *int, body *string) {
			if r.URL.Path == repo {
				*body = strings.Replace(*body, `,"permissions":{"admin":false,"push":true,"pull":true}`, "", 1)
			}
		}
		result, err := g.exercise(t)
		if err != nil || result["result"] != "published" || len(g.previews) != 1 || len(g.posts) != 1 {
			t.Fatalf("supported installation writer refused: result=%v err=%v previews=%d writes=%d", result, err, len(g.previews), len(g.posts))
		}
	})
	t.Run("user-role-false-does-not-deny-granted-capability", func(t *testing.T) {
		g := newGitHub()
		g.edit = func(r *http.Request, _ int, _ *int, body *string) {
			if r.URL.Path == repo {
				*body = strings.Replace(*body, `"push":true`, `"push":false`, 1)
			}
		}
		result, err := g.exercise(t)
		if err != nil || result["result"] != "published" || len(g.previews) != 1 || len(g.posts) != 1 {
			t.Fatalf("role metadata overrode granted capability: result=%v err=%v previews=%d writes=%d", result, err, len(g.previews), len(g.posts))
		}
	})
	t.Run("user-metadata-cannot-authorize-read-only-token", func(t *testing.T) {
		g := newGitHub()
		g.previewStatus = http.StatusForbidden
		_, err := g.exercise(t)
		if err == nil || len(g.previews) != 1 || len(g.posts) != 0 {
			t.Fatalf("read-only credential reached publication: err=%v previews=%d writes=%d", err, len(g.previews), len(g.posts))
		}
		for _, request := range g.requests {
			if strings.HasPrefix(request, "GET "+repo+"/releases?") {
				t.Fatalf("denied capability was treated as complete draft visibility: %s", request)
			}
		}
	})
}

// A denied, unavailable or unreadable proof never permits a draft inventory or publication.
func TestUnprovenWriterCapabilityStopsBeforeInventory(t *testing.T) {
	cases := map[string]func(*github){
		"unauthorized": func(g *github) { g.previewStatus = 401 },
		"denied":       func(g *github) { g.previewStatus = 403 },
		"not-found":    func(g *github) { g.previewStatus = 404 },
		"rate-limited": func(g *github) { g.previewStatus = 429 },
		"unavailable":  func(g *github) { g.previewStatus = 502 },
		"redirect":     func(g *github) { g.previewStatus = 307 },
		"malformed":    func(g *github) { g.previewBody = "not json" },
		"duplicate":    func(g *github) { g.previewBody = `{"name":"a","name":"b","body":""}` },
		"empty":        func(g *github) { g.previewBody = " " },
		"wrong-type":   func(g *github) { g.previewBody = `[]` },
		"missing-name": func(g *github) { g.previewBody = `{"body":""}` },
		"missing-body": func(g *github) { g.previewBody = `{"name":"probe"}` },
		"body-type":    func(g *github) { g.previewBody = `{"name":"probe","body":false}` },
		"non-json":     func(g *github) { g.previewType = "text/html" },
		"oversized":    func(g *github) { g.previewBody = strings.Repeat("x", 1024*1024+1) },
		"sensitive-error-body": func(g *github) {
			g.previewStatus, g.previewBody = 403, encode(map[string]string{"message": token})
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			g := newGitHub()
			setup(g)
			if _, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "writer capability") {
				t.Fatalf("unproven capability was not refused at the permission boundary: %v", err)
			}
			if len(g.previews) != 1 || len(g.posts) != 0 || g.counts["GET "+repo+"/releases"] != 0 || len(g.releases) != 1 {
				t.Fatalf("unproven capability reached inventory or persisted state: previews=%d posts=%d", len(g.previews), len(g.posts))
			}
		})
	}
}

// The writer must still address the same active public repository and default branch.
func TestWriterRepositoryRecheckPrecedesCapability(t *testing.T) {
	for name, change := range map[string]func(map[string]any){
		"wrong-repository": func(r map[string]any) { r["full_name"] = "devantler-tech/other" },
		"changed-branch":   func(r map[string]any) { r["default_branch"] = "other" },
		"private":          func(r map[string]any) { r["private"] = true },
		"visibility":       func(r map[string]any) { r["visibility"] = "private" },
		"archived":         func(r map[string]any) { r["archived"] = true },
		"disabled":         func(r map[string]any) { r["disabled"] = true },
	} {
		t.Run(name, func(t *testing.T) {
			g := newGitHub()
			g.edit = func(r *http.Request, count int, _ *int, body *string) {
				// The first two reads admitted the original repository; change only the
				// separate writer recheck, so a later unchanged read cannot hide this one.
				if r.URL.Path == repo && count == 3 {
					var value map[string]any
					if err := json.Unmarshal([]byte(*body), &value); err != nil {
						g.unexpected = append(g.unexpected, "malformed repository fixture")
						return
					}
					change(value)
					*body = encode(value)
				}
			}
			if _, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "no longer matches") {
				t.Fatalf("changed writer repository was not refused: %v", err)
			}
			if len(g.previews) != 0 || len(g.posts) != 0 || g.counts["GET "+repo+"/releases"] != 0 {
				t.Fatal("changed repository reached capability, inventory or publication")
			}
		})
	}
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
	g.previewBody = encode(map[string]string{"name": "Discarded preview", "body": token})
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
	if len(g.previews) != 1 || g.previews[0]["tag_name"] != "release-recovery-capability-probe" {
		t.Fatalf("publication omitted the non-persisting capability proof: %v", g.previews)
	}
	want := map[string]any{"tag_name": "v1.222.1", "name": "v1.222.1", "body": Receipt(admission()),
		"draft": false, "prerelease": false, "generate_release_notes": false, "make_latest": "false"}
	if encode(g.posts[0]) != encode(want) {
		t.Fatalf("publication payload %s, want %s", encode(g.posts[0]), encode(want))
	}
	if g.latest != 9 {
		t.Fatal("latest release moved")
	}
	if result["release_record"] != "matches-request" || result["latest_release_before"] != "9" || result["latest_release_after"] != "9" {
		t.Fatalf("result does not report what verification observed: %v", result)
	}
}

// Recovery publishes an admitted existing tag, so it must not ask the API to resolve a
// separate tag-creation target. GitHub applies extra workflow authorization to some targets.
func TestExistingTagDoesNotSpecifyCreationTarget(t *testing.T) {
	g := newGitHub()
	g.onPost = func(w http.ResponseWriter, _ map[string]any) bool {
		if _, present := g.posts[len(g.posts)-1]["target_commitish"]; present {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, `{"message":"Resource not accessible by integration"}`)
			return true
		}
		return false
	}
	result, err := g.exercise(t)
	if err != nil || result["result"] != "published" || len(g.posts) != 1 {
		t.Fatalf("existing-tag publication requested a separate creation target: result=%v err=%v posts=%d", result, err, len(g.posts))
	}
	if _, present := g.posts[0]["target_commitish"]; present {
		t.Fatal("existing-tag request included target_commitish")
	}
	if g.latest != 9 || result["source_sha"] != source {
		t.Fatalf("existing-tag recovery lost its source or changed latest: %v", result)
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
		if err != nil || result["result"] != "already-published" || len(g.posts) != 0 || len(g.previews) != 0 {
			t.Fatalf("expected a no-op, got %v %v posts=%d", result, err, len(g.posts))
		}
		if g.counts["GET "+repo+"/releases"] != 0 {
			t.Fatal("no-op still took a writer inventory")
		}
		if result["latest_release_before"] != "not-inspected" || result["release_record"] != "not-inspected" {
			t.Fatalf("no-op claimed facts it never checked: %v", result)
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
		for i := 0; i < pages*pageSize; i++ {
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
			g.previewStatus = http.StatusForbidden
			g.edit = func(r *http.Request, count int, _ *int, body *string) {
				if r.URL.Path == repo {
					*body = strings.Replace(*body, `,"permissions":{"admin":false,"push":true,"pull":true}`, "", 1)
				}
			}
		},
		"push-false": func(g *github) {
			g.previewStatus = http.StatusForbidden
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo {
					*body = strings.Replace(*body, `"push":true`, `"push":false`, 1)
				}
			}
		},
		"draft-on-later-page": func(g *github) {
			fullPage(g, 1)
			draft := release(5000, "v1.222.1")
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
		"missing-push-metadata":          "writer capability was refused with status 403",
		"push-false":                     "writer capability was refused with status 403",
		"draft-on-later-page":            "a draft release for this tag",
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
		"malformed-success":     "publication response is unreadable",
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
	if result, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "run recovery again to reconcile") {
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

// A server error can follow an accepted write, so it is reported as an unknown outcome.
func TestServerErrorAfterWriteIsUnknownOutcome(t *testing.T) {
	g := newGitHub()
	g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
		g.releases = append([]map[string]any{created}, g.releases...)
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, `{"message":"Bad Gateway"}`)
		return true
	}
	if result, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "outcome is unknown after status 502") ||
		strings.Contains(err.Error(), "refused") {
		t.Fatalf("server error was not an unknown outcome: %v %v", result, err)
	}
	if len(g.posts) != 1 {
		t.Fatalf("expected exactly one publication request, got %d", len(g.posts))
	}
}

// A failure after the write names the release it created, so nobody publishes it again.
func TestVerificationFailureNamesTheCreatedRelease(t *testing.T) {
	g := newGitHub()
	g.edit = func(r *http.Request, _ int, status *int, _ *string) {
		if r.URL.Path == repo+"/releases/tags/v1.222.1" && len(g.posts) == 1 {
			*status = 503
		}
	}
	_, err := g.exercise(t)
	if err == nil || !strings.Contains(err.Error(), "release 18 was created") || !strings.Contains(err.Error(), "do not publish by hand") {
		t.Fatalf("verification failure hid the created release: %v", err)
	}
}

// A draft for another tag is not this incident and does not block recovery.
func TestUnrelatedDraftDoesNotBlock(t *testing.T) {
	g := newGitHub()
	draft := release(30, "v2.0.0")
	draft["draft"] = true
	g.releases = append(g.releases, draft)
	if result, err := g.exercise(t); err != nil || result["result"] != "published" {
		t.Fatalf("unrelated draft blocked recovery: %v %v", result, err)
	}
}

// A draft for the tag that appears around the write is caught by the post-write inventory.
func TestDraftAppearingDuringWriteFailsVerification(t *testing.T) {
	g := newGitHub()
	g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
		draft := release(19, "v1.222.1")
		draft["draft"] = true
		g.releases = append([]map[string]any{created, draft}, g.releases...)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, encode(created))
		return true
	}
	if _, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "post-publication inventory") {
		t.Fatalf("a draft created during the write went unnoticed: %v", err)
	}
}

// With no earlier stable release there is no latest to preserve; GitHub may pick the new one.
func TestFirstStableReleaseMayBecomeLatest(t *testing.T) {
	g := newGitHub()
	g.releases[0]["prerelease"] = true
	g.latest = 0
	g.onPost = func(w http.ResponseWriter, created map[string]any) bool {
		g.releases = append([]map[string]any{created}, g.releases...)
		g.latest = 18
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, encode(created))
		return true
	}
	result, err := g.exercise(t)
	if err != nil || result["result"] != "published" {
		t.Fatalf("first stable release refused: %v %v", result, err)
	}
	if result["latest_release_before"] != "" || result["latest_release_after"] != "18" {
		t.Fatalf("result hid that the release became latest: %v", result)
	}
}

// A malformed latest-release readback is never read as "unchanged".
func TestMalformedLatestReadbackFails(t *testing.T) {
	g := newGitHub()
	g.edit = func(r *http.Request, _ int, _ *int, body *string) {
		if r.URL.Path == repo+"/releases/latest" && len(g.posts) == 1 {
			*body = `{"id":"18","tag_name":"v1.222.0","draft":false,"prerelease":false}`
		}
	}
	if _, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "latest release is not a published stable release") {
		t.Fatalf("malformed latest readback accepted: %v", err)
	}
}

// The readback compares every requested field, so a renamed release is not a success.
func TestReadbackComparesEveryRequestedField(t *testing.T) {
	for _, field := range []string{"name", "body", "tag_name", "prerelease"} {
		t.Run(field, func(t *testing.T) {
			g := newGitHub()
			g.edit = func(r *http.Request, _ int, _ *int, body *string) {
				if r.URL.Path == repo+"/releases/tags/v1.222.1" && len(g.posts) == 1 {
					var value map[string]any
					_ = json.Unmarshal([]byte(*body), &value)
					switch field {
					case "prerelease":
						value[field] = true
					default:
						value[field] = "changed"
					}
					*body = encode(value)
				}
			}
			if _, err := g.exercise(t); err == nil || !strings.Contains(err.Error(), "readback does not match") {
				t.Fatalf("readback accepted a changed %s: %v", field, err)
			}
		})
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, fmt.Errorf("closed pipe") }

// A result that cannot be written after a verified publication still names the release.
func TestUnwritableResultNamesThePublishedRelease(t *testing.T) {
	g := newGitHub()
	server := g.serve(t)
	defer server.Close()
	err := run(args(), token, failingWriter{}, newPublisher(server.Client(), server.URL))
	if err == nil || !strings.Contains(err.Error(), "release 18 was published and verified") || !strings.Contains(err.Error(), "do not publish it again") {
		t.Fatalf("unwritable result hid the publication: %v", err)
	}
	if len(g.posts) != 1 {
		t.Fatalf("expected exactly one publication request, got %d", len(g.posts))
	}
}

// Listed releases carry their full notes; large generated notes must not overflow a page.
func TestLargeReleaseNotesFitTheInventoryPages(t *testing.T) {
	g := newGitHub()
	notes := strings.Repeat("generated release notes ", 1500) // about 35 KiB per release
	for i := 0; i < 3*pageSize; i++ {
		entry := release(2000+i, fmt.Sprintf("v0.9.%d", i))
		entry["body"] = notes
		g.releases = append(g.releases, entry)
	}
	if result, err := g.exercise(t); err != nil || result["result"] != "published" {
		t.Fatalf("large release notes blocked recovery: %v %v", result, err)
	}
}
