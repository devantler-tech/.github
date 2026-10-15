package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

const source = "607fd864e98d7883274270d0737934963039407c"
const producer = "devantler-tech/actions/.github/workflows/create-release.yaml@10ab0f1c94b951c16f6db58d094b42d49e2f775f"
const config = `{"branches":["main"],"plugins":[["@semantic-release/commit-analyzer",{"parserOpts":{"breakingHeaderPattern":"^(\\w*)(?:\\((.*)\\))?!: (.*)$"},"releaseRules":[{"breaking":true,"release":"major"}]}],["@semantic-release/release-notes-generator",{"parserOpts":{"breakingHeaderPattern":"^(\\w*)(?:\\((.*)\\))?!: (.*)$"}}],"@semantic-release/github"]}`

func args() []string {
	return []string{"--repository", "devantler-tech/platform", "--tag", "v1.222.1", "--source-sha", source,
		"--run-id", "38418390528", "--run-attempt", "1", "--producer-ref", producer}
}

type responseEdit func(*http.Request, int, *int, *string, http.Header)

// Native HTTP is the external boundary. All parsing, diagnosis and output are real.
func exercise(t *testing.T, edit responseEdit, arguments []string, token string) (string, error, []string) {
	t.Helper()
	var requests []string
	counts := map[string]int{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.RequestURI())
		counts[r.URL.Path]++
		if r.Method != http.MethodGet || r.Header.Get("Authorization") != "Bearer fixture-token" {
			t.Error("inspector sent a write or did not use the fixture credential")
		}
		if strings.Contains(r.URL.Path, "/contents") && r.URL.Query().Get("ref") != source {
			t.Error("source config read was not pinned to the captured commit")
		}
		w.Header().Set("Content-Type", "application/json")
		status, body := fixture(r.URL.Path)
		if edit != nil {
			edit(r, counts[r.URL.Path], &status, &body, w.Header())
		}
		w.WriteHeader(status)
		_, _ = fmt.Fprint(w, body)
	}))
	defer server.Close()
	var out bytes.Buffer
	err := run(arguments, token, &out, newInspector(server.Client(), server.URL))
	return out.String(), err, requests
}

func refuse(t *testing.T, edit responseEdit) {
	t.Helper()
	out, err, _ := exercise(t, edit, args(), "fixture-token")
	if err == nil || out != "" {
		t.Fatalf("incomplete admission produced output %q (error %v)", out, err)
	}
	if strings.Contains(err.Error(), "fixture-token") {
		t.Fatal("credential leaked in diagnostic")
	}
}

func changeJSON(body string, change func(map[string]any)) string {
	var value map[string]any
	if err := json.Unmarshal([]byte(body), &value); err != nil {
		panic(err)
	}
	change(value)
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(raw)
}

func sourceContent(content string) string {
	raw, _ := json.Marshal(map[string]any{"type": "file", "path": ".releaserc", "sha": blobSHA(content),
		"encoding": "base64", "size": len(content), "content": base64.StdEncoding.EncodeToString([]byte(content))})
	return string(raw)
}

func changeConfig(content string) responseEdit {
	return func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
		if strings.Contains(r.URL.Path, "/git/trees/") {
			*body = changeJSON(*body, func(v map[string]any) { v["tree"].([]any)[0].(map[string]any)["sha"] = blobSHA(content) })
		}
		if strings.HasSuffix(r.URL.Path, "/contents/.releaserc") {
			*body = sourceContent(content)
		}
	}
}

const publication = `{"id":17,"tag_name":"v1.222.1","target_commitish":"` + source + `","draft":false,"prerelease":false,"published_at":"2026-10-15T10:00:00Z"}`

func TestPresentReleaseIsDiagnosisWithoutPublicationOrNotesClaim(t *testing.T) {
	out, err, requests := exercise(t, func(r *http.Request, _ int, status *int, body *string, _ http.Header) {
		if strings.Contains(r.URL.Path, "/releases/tags/") {
			*status, *body = 200, publication
		}
	}, args(), "fixture-token")
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatal(err)
	}
	if result["diagnosis"] != "github-release-present" || result["authorization"] != "none" ||
		result["channel_metadata"] != "not-inspected" || result["publication_success"] != false || len(requests) != 14 {
		t.Fatalf("misleading diagnosis %s; requests=%d", out, len(requests))
	}
}

func TestInvalidCLIInputsMakeNoRequests(t *testing.T) {
	for index, values := range map[int][]string{
		1:  {"elsewhere/platform", "devantler-tech/..", "devantler-tech/a/b", "devantler-tech/platform?token=secret"},
		3:  {"1.2.3", "v01.2.3", "v1.2.3-rc.1", "v1.2.3+build", "v1000000000000000.1.0"},
		5:  {"main", strings.Repeat("A", 40), source + "0"},
		7:  {"0", "01", "-1", "1e3", "18446744073709551616"},
		9:  {"0", "1.0", "+1"},
		11: {"devantler-tech/.github/.github/workflows/create-release.yaml@main", "elsewhere/actions/.github/workflows/create-release.yaml@" + source, "devantler-tech/.github/.github/workflows/publish-app.yaml@" + source},
	} {
		for _, value := range values {
			t.Run(strconv.Itoa(index)+"-"+value, func(t *testing.T) {
				arguments := args()
				arguments[index] = value
				out, err, requests := exercise(t, nil, arguments, "fixture-token")
				if err == nil || out != "" || len(requests) != 0 {
					t.Fatalf("invalid input used network or stdout: %v %q %v", err, out, requests)
				}
			})
		}
	}
	for _, arguments := range [][]string{args()[:10], append(args(), "unexpected"), append(args(), "--api-url", "http://127.0.0.1"), append(args(), "--tag", "v1.222.1")} {
		out, err, requests := exercise(t, nil, arguments, "fixture-token")
		if err == nil || out != "" || len(requests) != 0 {
			t.Fatalf("ambiguous flags used network: %v %q %v", err, out, requests)
		}
	}
	for _, token := range []string{"", "fixture-token\n", "contains secret", strings.Repeat("a", 4097)} {
		out, err, requests := exercise(t, nil, args(), token)
		if err == nil || out != "" || len(requests) != 0 {
			t.Fatal("invalid credential reached API")
		}
	}
}

func TestIdentityMismatchesAndMissingFieldsRefuseAllDiagnosis(t *testing.T) {
	cases := []struct {
		path, key string
		value     any
	}{
		{"", "id", 0}, {"", "name", "other"}, {"", "full_name", "elsewhere/platform"}, {"", "owner", map[string]any{"login": "elsewhere"}},
		{"", "private", true}, {"", "archived", true}, {"", "disabled", true}, {"", "default_branch", ""},
		{"/actions/runs/38418390528/attempts/1", "id", 1}, {"/actions/runs/38418390528/attempts/1", "run_attempt", 2},
		{"/actions/runs/38418390528/attempts/1", "head_sha", strings.Repeat("a", 40)}, {"/actions/runs/38418390528/attempts/1", "head_branch", "other"},
		{"/actions/runs/38418390528/attempts/1", "event", "pull_request"}, {"/actions/runs/38418390528/attempts/1", "status", "in_progress"},
		{"/actions/runs/38418390528/attempts/1", "conclusion", "success"}, {"/actions/runs/38418390528/attempts/1", "path", "../release.yaml"},
		{"/actions/runs/38418390528/attempts/1", "repository", map[string]any{"id": 43, "full_name": "devantler-tech/platform", "private": false}},
		{"/actions/runs/38418390528/attempts/1", "head_repository", map[string]any{"id": 42, "full_name": "devantler-tech/fork", "private": false}},
		{"/actions/runs/38418390528/attempts/1", "referenced_workflows", []any{}},
		{"/actions/runs/38418390528/attempts/1", "referenced_workflows", []any{map[string]any{"path": producer, "sha": source}}},
		{"/git/ref/tags/v1.222.1", "ref", "refs/tags/v1.222.2"}, {"/git/ref/tags/v1.222.1", "object", map[string]any{"type": "commit", "sha": strings.Repeat("a", 40)}},
		{"/contents/.releaserc", "path", "other"}, {"/contents/.releaserc", "encoding", "none"}, {"/contents/.releaserc", "sha", strings.Repeat("a", 40)},
		{"/contents/.releaserc", "size", 1}, {"/contents/.releaserc", "content", "not-base64!"},
	}
	for _, test := range cases {
		for _, omit := range []bool{false, true} {
			t.Run(test.path+"/"+test.key+fmt.Sprint(omit), func(t *testing.T) {
				refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
					if r.URL.Path == "/repos/devantler-tech/platform"+test.path {
						*body = changeJSON(*body, func(value map[string]any) {
							if omit {
								delete(value, test.key)
							} else {
								value[test.key] = test.value
							}
						})
					}
				})
			})
		}
	}
}

func TestUnsafeOrMissingPublicationMetadataDoesNotBecomePresent(t *testing.T) {
	for key, value := range map[string]any{"id": 0, "tag_name": "v1.222.2", "target_commitish": "main", "draft": true, "prerelease": true, "published_at": ""} {
		for _, omit := range []bool{false, true} {
			t.Run(key+fmt.Sprint(omit), func(t *testing.T) {
				refuse(t, func(r *http.Request, _ int, status *int, body *string, _ http.Header) {
					if strings.Contains(r.URL.Path, "/releases/tags/") {
						*status = 200
						*body = changeJSON(publication, func(object map[string]any) {
							if omit {
								delete(object, key)
							} else {
								object[key] = value
							}
						})
					}
				})
			})
		}
	}
}

func TestEveryHTTPReadFailsClosedWithoutRedirectRetryOrPartialOutput(t *testing.T) {
	paths := []string{"", "/actions/runs/38418390528/attempts/1", "/git/ref/tags/v1.222.1", "/git/commits/" + source, "/git/trees/3333333333333333333333333333333333333333", "/contents/.releaserc", "/releases/tags/v1.222.1"}
	for _, path := range paths {
		for _, kind := range []string{"unauthorized", "forbidden", "rate-limit", "server-error", "redirect", "unexpected-status", "wrong-type", "malformed", "duplicate", "oversized", "truncated", "not-found"} {
			t.Run(path+"/"+kind, func(t *testing.T) {
				out, err, requests := exercise(t, func(r *http.Request, _ int, status *int, body *string, header http.Header) {
					if r.URL.Path != "/repos/devantler-tech/platform"+path {
						return
					}
					switch kind {
					case "unauthorized":
						*status = 401
					case "forbidden":
						*status = 403
					case "rate-limit":
						*status = 429
					case "server-error":
						*status = 500
					case "redirect":
						*status = 302
						header.Set("Location", "/do-not-follow")
					case "unexpected-status":
						*status = 201
					case "wrong-type":
						header.Set("Content-Type", "text/html")
					case "malformed":
						*body = `{"unterminated":`
					case "duplicate":
						*body = `{"private":true,"private":false}`
					case "oversized":
						*body = strings.Repeat(" ", (1<<20)+1) + `{}`
					case "truncated":
						header.Set("Content-Length", strconv.Itoa(len(*body)+10))
					case "not-found":
						*status = 404
						*body = `{"message":"ambiguous absence"}`
					}
				}, args(), "fixture-token")
				if err == nil || out != "" {
					t.Fatalf("unsafe HTTP observation succeeded: %v %q", err, out)
				}
				count := 0
				for _, request := range requests {
					if strings.Contains(request, "/do-not-follow") {
						t.Fatal("followed API redirect")
					}
					if strings.HasPrefix(request, "GET /repos/devantler-tech/platform"+path+"?") || request == "GET /repos/devantler-tech/platform"+path {
						count++
					}
				}
				if count != 1 {
					t.Fatalf("failed request was retried: %v", requests)
				}
			})
		}
	}
}

func TestUnsupportedReleaseConfigurationRefusesDiagnosis(t *testing.T) {
	configs := []string{"branches: [main]", `{"branches":["main"],"branches":["main"],"plugins":[]}`}
	for _, mutate := range []func(map[string]any){
		func(v map[string]any) { v["extends"] = "arbitrary-code" }, func(v map[string]any) { v["tagFormat"] = "other${version}" },
		func(v map[string]any) { v["branches"] = []any{"other"} }, func(v map[string]any) { v["plugins"] = []any{"@semantic-release/npm"} },
		func(v map[string]any) {
			v["plugins"].([]any)[2] = []any{"@semantic-release/github", map[string]any{"assets": []any{"dist/*"}}}
		},
		func(v map[string]any) { v["plugins"].([]any)[0].([]any)[1].(map[string]any)["preset"] = "unreviewed" },
		func(v map[string]any) {
			v["plugins"].([]any)[0].([]any)[1].(map[string]any)["releaseRules"] = []any{map[string]any{"type": "fix", "release": "major"}}
		},
		func(v map[string]any) {
			v["plugins"].([]any)[1].([]any)[1].(map[string]any)["parserOpts"] = map[string]any{"breakingHeaderPattern": ".*"}
		},
	} {
		configs = append(configs, changeJSON(config, mutate))
	}
	for index, content := range configs {
		t.Run(strconv.Itoa(index), func(t *testing.T) {
			refuse(t, changeConfig(content))
		})
	}
	for _, name := range []string{".releaserc.json", ".releaserc.js", ".releaserc.yaml", "release.config.cjs", "release.config.ts"} {
		t.Run(name, func(t *testing.T) {
			refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
				if strings.Contains(r.URL.Path, "/git/trees/") {
					*body = changeJSON(*body, func(v map[string]any) {
						v["tree"] = append(v["tree"].([]any), map[string]any{"path": name, "type": "blob", "mode": "100644", "sha": source})
					})
				}
			})
		})
	}
}

func TestAnnotatedTagMustNameOriginalTagAndDirectCommit(t *testing.T) {
	for _, scenario := range []string{"matching", "wrong-name", "wrong-sha", "nested", "wrong-source", "missing"} {
		t.Run(scenario, func(t *testing.T) {
			out, err, requests := exercise(t, func(r *http.Request, _ int, status *int, body *string, _ http.Header) {
				if strings.Contains(r.URL.Path, "/git/ref/") {
					*body = `{"ref":"refs/tags/v1.222.1","object":{"type":"tag","sha":"2222222222222222222222222222222222222222"}}`
				}
				if strings.HasSuffix(r.URL.Path, "/git/tags/2222222222222222222222222222222222222222") {
					*status = 200
					*body = `{"sha":"2222222222222222222222222222222222222222","tag":"v1.222.1","object":{"type":"commit","sha":"` + source + `"}}`
					*body = changeJSON(*body, func(v map[string]any) {
						switch scenario {
						case "wrong-name":
							v["tag"] = "v1.222.2"
						case "wrong-sha":
							v["sha"] = source
						case "nested":
							v["object"].(map[string]any)["type"] = "tag"
						case "wrong-source":
							v["object"].(map[string]any)["sha"] = strings.Repeat("a", 40)
						case "missing":
							*status = 404
						}
					})
				}
			}, args(), "fixture-token")
			if scenario == "matching" {
				if err != nil || !strings.Contains(out, `"diagnosis":"missing-github-release"`) || len(requests) != 16 {
					t.Fatalf("annotated source refused: %v %q", err, out)
				}
			} else if err == nil || out != "" {
				t.Fatal("conflicting annotation accepted")
			}
		})
	}
}

func TestChangedValidObservationsRefusePrematureDiagnosis(t *testing.T) {
	for _, scenario := range []string{"publication-created", "publication-replaced", "config-changed", "repository-replaced"} {
		t.Run(scenario, func(t *testing.T) {
			refuse(t, func(r *http.Request, count int, status *int, body *string, _ http.Header) {
				switch scenario {
				case "publication-created":
					if count == 2 && strings.Contains(r.URL.Path, "/releases/tags/") {
						*status, *body = 200, publication
					}
				case "publication-replaced":
					if strings.Contains(r.URL.Path, "/releases/tags/") {
						*status, *body = 200, publication
						if count == 2 {
							*body = strings.Replace(*body, `"id":17`, `"id":18`, 1)
						}
					}
				case "config-changed":
					if count == 2 {
						changeConfig(`{"branches":["main"],"plugins":["@semantic-release/commit-analyzer","@semantic-release/release-notes-generator","@semantic-release/github"]}`)(r, count, status, body, nil)
					}
				case "repository-replaced":
					if count == 2 {
						*body = strings.ReplaceAll(*body, `"id":42`, `"id":43`)
					}
				}
			})
		})
	}
}

func TestReadTimeoutDoesNotProducePartialDiagnosis(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(40 * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{}`)
	}))
	defer server.Close()
	client := server.Client()
	client.Timeout = 5 * time.Millisecond
	var out bytes.Buffer
	if err := run(args(), "fixture-token", &out, newInspector(client, server.URL)); err == nil || out.Len() != 0 {
		t.Fatal("timed-out API read produced a verdict")
	}
}

func TestMalformedUTF8AndConflictingVisibilityRefuseDiagnosis(t *testing.T) {
	for _, scenario := range []string{"invalid-utf8", "conflicting-visibility", "missing-visibility", "symlink-target"} {
		t.Run(scenario, func(t *testing.T) {
			refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
				if scenario == "symlink-target" && strings.Contains(r.URL.Path, "/git/trees/") {
					*body = strings.Replace(*body, `"mode":"100644"`, `"mode":"120000"`, 1)
				}
				if r.URL.Path != "/repos/devantler-tech/platform" {
					return
				}
				switch scenario {
				case "invalid-utf8":
					*body = strings.TrimSuffix(*body, "}") + ",\"ignored\":\"\xff\"}"
				case "conflicting-visibility":
					*body = strings.Replace(*body, `"visibility":"public"`, `"visibility":"private"`, 1)
				case "missing-visibility":
					*body = strings.Replace(*body, `"visibility":"public",`, "", 1)
				}
			})
		})
	}
}

func TestDuplicateSecurityFieldsCannotHideBehindOtherwiseValidResponses(t *testing.T) {
	for path, duplicate := range map[string]string{
		"":                                     `"private":false`,
		"/actions/runs/38418390528/attempts/1": `"id":38418390528`,
		"/git/ref/tags/v1.222.1":               `"ref":"refs/tags/v1.222.1"`,
		"/contents/.releaserc":                 `"encoding":"base64"`,
		"/releases/tags/v1.222.1":              `"message":"Not Found"`,
	} {
		t.Run(path, func(t *testing.T) {
			refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
				if r.URL.Path == "/repos/devantler-tech/platform"+path {
					*body = strings.TrimSuffix(*body, "}") + "," + duplicate + "}"
				}
			})
		})
	}
	refuse(t, changeConfig(strings.Replace(config, `"branches":["main"]`, `"branches":["main"],"branches":["main"]`, 1)))
}

func TestPackageJSONMayNotProvideAnotherReleaseConfiguration(t *testing.T) {
	for _, content := range []string{`{"name":"fixture"}`, `{"name":"fixture","release":null}`, `{"release":{"extends":"arbitrary-code"}}`, `[]`} {
		t.Run(content, func(t *testing.T) {
			out, err, requests := exercise(t, func(r *http.Request, _ int, status *int, body *string, _ http.Header) {
				if strings.Contains(r.URL.Path, "/git/trees/") {
					*body = changeJSON(*body, func(v map[string]any) {
						v["tree"] = append(v["tree"].([]any), map[string]any{"path": "package.json", "type": "blob", "mode": "100644", "sha": blobSHA(content)})
					})
				}
				if strings.HasSuffix(r.URL.Path, "/contents/package.json") {
					*status = 200
					*body = strings.Replace(sourceContent(content), `"path":".releaserc"`, `"path":"package.json"`, 1)
				}
			}, args(), "fixture-token")
			if content == `{"name":"fixture"}` {
				if err != nil || !strings.Contains(out, `"diagnosis":"missing-github-release"`) || len(requests) != 16 {
					t.Fatalf("inert package refused: %v %q", err, out)
				}
			} else if err == nil || out != "" {
				t.Fatal("uninspected package release configuration admitted")
			}
		})
	}
}

func TestIncompleteConfigurationInventoriesRefuseDiagnosis(t *testing.T) {
	for _, scenario := range []string{"empty", "wrong-shape", "duplicate", "missing-config", "symlink", "submodule", "truncated"} {
		t.Run(scenario, func(t *testing.T) {
			refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
				if !strings.Contains(r.URL.Path, "/git/trees/") {
					return
				}
				*body = changeJSON(*body, func(v map[string]any) {
					entry := v["tree"].([]any)[0].(map[string]any)
					switch scenario {
					case "empty":
						v["tree"] = []any{}
					case "wrong-shape":
						v["tree"] = map[string]any{}
					case "duplicate":
						v["tree"] = []any{entry, entry}
					case "missing-config":
						entry["path"] = "README.md"
					case "symlink":
						entry["mode"] = "120000"
					case "submodule":
						entry["type"] = "commit"
						entry["mode"] = "160000"
					case "truncated":
						v["truncated"] = true
					}
				})
			})
		})
	}
}

func TestLateReadFailuresNeverEmitFirstObservationAsVerdict(t *testing.T) {
	for _, path := range []string{"", "/actions/runs/38418390528/attempts/1", "/git/ref/tags/v1.222.1", "/git/commits/" + source, "/git/trees/3333333333333333333333333333333333333333", "/contents/.releaserc", "/releases/tags/v1.222.1"} {
		t.Run(path, func(t *testing.T) {
			refuse(t, func(r *http.Request, count int, status *int, _ *string, _ http.Header) {
				if count == 2 && r.URL.Path == "/repos/devantler-tech/platform"+path {
					*status = 503
				}
			})
		})
	}
}

func TestMaintainedProducerAndHarmlessJSONFieldOrderingRemainSupported(t *testing.T) {
	maintained := "devantler-tech/.github/.github/workflows/create-release.yaml@10ab0f1c94b951c16f6db58d094b42d49e2f775f"
	arguments := args()
	arguments[11] = maintained
	out, err, requests := exercise(t, func(r *http.Request, count int, _ *int, body *string, _ http.Header) {
		if strings.Contains(r.URL.Path, "/actions/runs/") {
			*body = strings.Replace(*body, producer, maintained, 1)
		}
		if count == 2 && strings.HasPrefix(*body, "{") {
			*body = changeJSON(*body, func(map[string]any) {})
		}
	}, arguments, "fixture-token")
	if err != nil || !strings.Contains(out, `"diagnosis":"missing-github-release"`) || len(requests) != 14 {
		t.Fatalf("supported producer or ordering refused: %v %q", err, out)
	}
}

func fixture(path string) (int, string) {
	switch path {
	case "/repos/devantler-tech/platform":
		return 200, `{"id":42,"name":"platform","owner":{"login":"devantler-tech"},"full_name":"devantler-tech/platform","visibility":"public","private":false,"archived":false,"disabled":false,"default_branch":"main"}`
	case "/repos/devantler-tech/platform/actions/runs/38418390528/attempts/1":
		return 200, `{"id":38418390528,"run_attempt":1,"path":".github/workflows/release.yaml","event":"push","status":"completed","conclusion":"failure","head_sha":"` + source + `","head_branch":"main","repository":{"id":42,"full_name":"devantler-tech/platform","private":false},"head_repository":{"id":42,"full_name":"devantler-tech/platform","private":false},"referenced_workflows":[{"path":"` + producer + `","sha":"10ab0f1c94b951c16f6db58d094b42d49e2f775f"}]}`
	case "/repos/devantler-tech/platform/git/ref/tags/v1.222.1":
		return 200, `{"ref":"refs/tags/v1.222.1","object":{"type":"commit","sha":"` + source + `"}}`
	case "/repos/devantler-tech/platform/git/commits/" + source:
		return 200, `{"sha":"` + source + `","tree":{"sha":"3333333333333333333333333333333333333333"}}`
	case "/repos/devantler-tech/platform/git/trees/3333333333333333333333333333333333333333":
		return 200, `{"sha":"3333333333333333333333333333333333333333","truncated":false,"tree":[{"path":".releaserc","type":"blob","mode":"100644","sha":"` + blobSHA(config) + `"}]}`
	case "/repos/devantler-tech/platform/contents/.releaserc":
		return 200, sourceContent(config)
	case "/repos/devantler-tech/platform/releases/tags/v1.222.1":
		return 404, `{"message":"Not Found"}`
	default:
		return 500, `{"message":"unreviewed fixture request"}`
	}
}

func blobSHA(content string) string {
	return fmt.Sprintf("%x", sha1.Sum([]byte(fmt.Sprintf("blob %d%c%s", len(content), 0, content))))
}

func TestAuthoritativeTreeModesAndSourceCommitAreRequired(t *testing.T) {
	for _, scenario := range []string{"wrong-commit", "missing-tree", "wrong-tree", "truncated", "duplicate", "symlink", "submodule", "wrong-blob", "missing-mode"} {
		t.Run(scenario, func(t *testing.T) {
			refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
				if strings.Contains(r.URL.Path, "/git/commits/") {
					*body = changeJSON(*body, func(value map[string]any) {
						switch scenario {
						case "wrong-commit":
							value["sha"] = strings.Repeat("a", 40)
						case "missing-tree":
							delete(value, "tree")
						}
					})
				}
				if !strings.Contains(r.URL.Path, "/git/trees/") {
					return
				}
				*body = changeJSON(*body, func(value map[string]any) {
					entry := value["tree"].([]any)[0].(map[string]any)
					switch scenario {
					case "wrong-tree":
						value["sha"] = source
					case "truncated":
						value["truncated"] = true
					case "duplicate":
						value["tree"] = []any{entry, entry}
					case "symlink":
						entry["mode"] = "120000"
					case "submodule":
						entry["mode"] = "160000"
						entry["type"] = "commit"
					case "wrong-blob":
						entry["sha"] = strings.Repeat("a", 40)
					case "missing-mode":
						delete(entry, "mode")
					}
				})
			})
		})
	}
}

func TestContentBytesMustMatchGitBlobEvenWhenAllClaimedIdentitiesAgree(t *testing.T) {
	refuse(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
		if !strings.HasSuffix(r.URL.Path, "/contents/.releaserc") {
			return
		}
		*body = changeJSON(*body, func(v map[string]any) {
			// Semantically identical valid JSON still has a different Git blob ID.
			content := " " + config
			v["content"] = base64.StdEncoding.EncodeToString([]byte(content))
			v["size"] = len(content)
		})
	})
}

func TestExecutableRegularGitBlobIsSupported(t *testing.T) {
	out, err, _ := exercise(t, func(r *http.Request, _ int, _ *int, body *string, _ http.Header) {
		if strings.Contains(r.URL.Path, "/git/trees/") {
			*body = strings.Replace(*body, `"mode":"100644"`, `"mode":"100755"`, 1)
		}
	}, args(), "fixture-token")
	if err != nil || !strings.Contains(out, `"diagnosis":"missing-github-release"`) {
		t.Fatalf("regular executable blob was refused: %v %q", err, out)
	}
}

// Removing run/tag/source verification or returning a verdict before the second
// observation would admit the wrong incident, so success asserts the conversation.
func TestMissingPublicationRequiresTwoCompleteReadOnlyObservations(t *testing.T) {
	var requests []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.RequestURI())
		if r.Method != http.MethodGet || r.Header.Get("Authorization") != "Bearer fixture-token" {
			t.Errorf("unexpected method or authorization")
		}
		w.Header().Set("Content-Type", "application/json")
		status, body := fixture(r.URL.Path)
		w.WriteHeader(status)
		_, _ = fmt.Fprint(w, body)
	}))
	defer server.Close()
	var out bytes.Buffer
	if err := run(args(), "fixture-token", &out, newInspector(server.Client(), server.URL)); err != nil {
		t.Fatal(err)
	}
	var diagnosis map[string]any
	if err := json.Unmarshal(out.Bytes(), &diagnosis); err != nil {
		t.Fatal(err)
	}
	if diagnosis["diagnosis"] != "missing-github-release" || diagnosis["authorization"] != "none" ||
		diagnosis["channel_metadata"] != "not-inspected" || diagnosis["publication_success"] != false ||
		diagnosis["publication_scope"] != "published-release-by-tag" || diagnosis["draft_inventory"] != "not-inspected" {
		t.Fatalf("unsafe or missing diagnosis: %s", &out)
	}
	want := []string{
		"GET /repos/devantler-tech/platform",
		"GET /repos/devantler-tech/platform/actions/runs/38418390528/attempts/1",
		"GET /repos/devantler-tech/platform/git/ref/tags/v1.222.1",
		"GET /repos/devantler-tech/platform/git/commits/" + source,
		"GET /repos/devantler-tech/platform/git/trees/3333333333333333333333333333333333333333",
		"GET /repos/devantler-tech/platform/contents/.releaserc?ref=" + source,
		"GET /repos/devantler-tech/platform/releases/tags/v1.222.1",
	}
	if strings.Join(requests, "\n") != strings.Join(append(want, want...), "\n") {
		t.Fatalf("incomplete or unexpected reads: %v", requests)
	}
}
