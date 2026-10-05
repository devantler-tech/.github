package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestScenarioAdmission(t *testing.T) {
	valid := `{"routes":[{"method":"GET","path":"/ok","query":{"x":""},"status":200,"headers":{"Link":"{{base_url}}/next"},"body":[]}]}`
	fixtures := map[string]string{
		"duplicate document key": `{"routes":[],"routes":[{"method":"GET","path":"/ok","status":200}]}`,
		"duplicate route key":    `{"routes":[{"method":"GET","path":"/ok","status":403,"status":200}]}`,
		"duplicate query key":    `{"routes":[{"method":"GET","path":"/ok","query":{"x":"a","x":"b"},"status":200}]}`,
		"route field alias":      `{"routes":[{"method":"GET","path":"/ok","status":200,"body":[],"Body":{"different":true}}]}`,
		"header name alias":      `{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"Link":"first","link":"second"}}]}`,
		"null query value":       `{"routes":[{"method":"GET","path":"/ok","query":{"x":null},"status":200}]}`,
		"query in path":          `{"routes":[{"method":"GET","path":"/ok?x=1","status":200}]}`,
		"invalid method":         `{"routes":[{"method":"G@T","path":"/ok","status":200}]}`,
		"invalid header name":    `{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"bad name":"x"}}]}`,
		"invalid header value":   `{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"Link":"x\r\ny"}}]}`,
		"discarded body":         `{"routes":[{"method":"GET","path":"/ok","status":204,"body":{"lost":true}}]}`,
		"head body":              `{"routes":[{"method":"HEAD","path":"/ok","status":200,"body":[]}]}`,
		"transfer header":        `{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"Content-Length":"1"},"body":[]}]}`,
	}
	path := filepath.Join(t.TempDir(), "scenario.json")
	if err := os.WriteFile(path, []byte(valid), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadScenario(path); err != nil {
		t.Fatalf("healthy scenario: %v", err)
	}
	for name, fixture := range fixtures {
		t.Run(name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(fixture), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := loadScenario(path); err == nil {
				t.Fatal("accepted unservable or ambiguous scenario")
			}
		})
	}
}

func requestReviewedRoute(t *testing.T, candidate route) *http.Response {
	t.Helper()
	record, err := os.CreateTemp(t.TempDir(), "record")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = record.Close() })
	fixture := httptest.NewServer(&server{routes: []route{candidate}, token: "fixture", record: record})
	t.Cleanup(fixture.Close)
	request, err := http.NewRequest(candidate.Method, fixture.URL+candidate.Path, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "token fixture")
	client := fixture.Client()
	client.Timeout = time.Second
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = response.Body.Close() })
	return response
}

func TestScenarioRejectsSuppressedNotModifiedHeader(t *testing.T) {
	for _, name := range []string{"Content-Type", "content-type", "CONTENT-TYPE"} {
		t.Run(name, func(t *testing.T) {
			fixture := fmt.Sprintf(`{"routes":[{"method":"GET","path":"/ok","status":304,"headers":{%q:"application/problem+json"}}]}`, name)
			routes, err := parseScenario([]byte(fixture), "reviewed")
			if err == nil {
				// ResponseRecorder keeps headers that the actual HTTP transport
				// suppresses. Exercise the real stand-in before reporting admission.
				response := requestReviewedRoute(t, routes[0])
				if response.StatusCode != http.StatusNotModified {
					t.Fatalf("304 transport control returned %d", response.StatusCode)
				}
				t.Fatalf("admitted unservable 304 header: reviewed Content-Type %q, actual %q", "application/problem+json", response.Header.Get("Content-Type"))
			}
			if !strings.Contains(err.Error(), "unservable header") {
				t.Fatalf("rejected for an unrelated reason: %v", err)
			}
		})
	}
}

func TestReviewedHeadersSurviveHTTPTransport(t *testing.T) {
	for name, raw := range map[string]string{
		"content type":        `{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"content-type":"application/problem+json"}}]}`,
		"not modified":        `{"routes":[{"method":"GET","path":"/ok","status":304,"headers":{"Cache-Control":"max-age=60","X-Fixture":"reviewed"}}]}`,
		"internal whitespace": `{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"X-Fixture":"two words\tinside"}}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			routes, err := parseScenario([]byte(raw), "reviewed")
			if err != nil {
				t.Fatal(err)
			}
			response := requestReviewedRoute(t, routes[0])
			if response.StatusCode != routes[0].Status {
				t.Fatalf("status: got %d, want %d", response.StatusCode, routes[0].Status)
			}
			for header, value := range routes[0].Headers {
				if got := response.Header.Get(header); got != value {
					t.Fatalf("reviewed %s: got %q, want %q", header, got, value)
				}
			}
		})
	}
}

func TestScenarioRejectsTrimmedHeaderValues(t *testing.T) {
	for _, value := range []string{" reviewed", "reviewed ", "\treviewed", "reviewed\t"} {
		t.Run(fmt.Sprintf("%q", value), func(t *testing.T) {
			fixture := fmt.Sprintf(`{"routes":[{"method":"GET","path":"/ok","status":200,"headers":{"X-Fixture":%q}}]}`, value)
			routes, err := parseScenario([]byte(fixture), "reviewed")
			if err == nil {
				response := requestReviewedRoute(t, routes[0])
				if response.StatusCode != http.StatusOK {
					t.Fatalf("header transport control returned %d", response.StatusCode)
				}
				t.Fatalf("admitted unservable header: reviewed %q, actual %q", value, response.Header.Get("X-Fixture"))
			}
			if !strings.Contains(err.Error(), "unservable header") {
				t.Fatalf("rejected for an unrelated reason: %v", err)
			}
		})
	}
}

func TestRunProcessHelper(t *testing.T) {
	if os.Getenv("OFFLINE_RUN_PROCESS_TEST") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			os.Args = append([]string{"offline-github-api"}, os.Args[i+1:]...)
			break
		}
	}
	flag.CommandLine = flag.NewFlagSet("offline-github-api", flag.ExitOnError)
	main()
	os.Exit(0)
}

func TestReceiptBindsAdmittedScenario(t *testing.T) {
	completionConversation(t, false)
}

func TestReceiptRejectsRecordChangedDuringServing(t *testing.T) {
	completionConversation(t, true)
}

func completionConversation(t *testing.T, tamperRecord bool) {
	t.Helper()
	work := t.TempDir()
	scenario, record, address, completion := filepath.Join(work, "scenario"), filepath.Join(work, "record"), filepath.Join(work, "address"), filepath.Join(work, "completion")
	original := []byte(`{"routes":[{"method":"GET","path":"/ok","status":200,"body":[]}]}`)
	replacement := []byte(`{"routes":[{"method":"GET","path":"/ok","status":200,"body":{"unserved":true}}]}`)
	if err := os.WriteFile(scenario, original, 0600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestRunProcessHelper$", "--", "-scenario", scenario, "-record", record, "-address-file", address, "-token", "fixture", "-completion-file", completion, "-nonce", "current")
	cmd.Env = append(os.Environ(), "OFFLINE_RUN_PROCESS_TEST=1")
	var diagnostic bytes.Buffer
	cmd.Stderr = &diagnostic
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill() }()
	var raw []byte
	for until := time.Now().Add(5 * time.Second); time.Now().Before(until); {
		raw, _ = os.ReadFile(address)
		if len(raw) > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(raw) == 0 {
		t.Fatal("server did not publish its address")
	}
	req, err := http.NewRequest("GET", strings.TrimSpace(string(raw))+"/ok", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "token fixture")
	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(body) != "[]" {
		t.Fatalf("original response: %q, %v", body, err)
	}
	if err := os.WriteFile(scenario, replacement, 0600); err != nil {
		t.Fatal(err)
	}
	if tamperRecord {
		if err := os.WriteFile(record, []byte("{}\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	shutdownError := cmd.Wait()
	if tamperRecord {
		if shutdownError == nil {
			t.Fatal("server certified record bytes it did not write")
		}
		if _, err := os.Stat(completion); !os.IsNotExist(err) {
			t.Fatal("tampered record received a completion receipt")
		}
		return
	}
	if err := shutdownError; err != nil {
		t.Fatalf("shutdown: %v: %s", err, diagnostic.String())
	}
	raw, err = os.ReadFile(completion)
	if err != nil {
		t.Fatal(err)
	}
	var receipt map[string]string
	if err := json.Unmarshal(raw, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt["scenario_sha256"] != fmt.Sprintf("%x", sha256.Sum256(original)) {
		t.Fatal("receipt certified scenario bytes the server never served")
	}
}

func TestCompletionRequiresFreshRecord(t *testing.T) {
	work := t.TempDir()
	scenario, record, address, completion := filepath.Join(work, "scenario"), filepath.Join(work, "record"), filepath.Join(work, "address"), filepath.Join(work, "completion")
	if err := os.WriteFile(scenario, []byte(`{"routes":[{"method":"GET","path":"/ok","status":200}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(record, []byte(`{"method":"GET","path":"/ok","query":{},"authorized":true,"body":null,"route":0,"status":200}`+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestRunProcessHelper$", "--", "-scenario", scenario, "-record", record, "-address-file", address, "-token", "fixture", "-completion-file", completion, "-nonce", "current")
	cmd.Env = append(os.Environ(), "OFFLINE_RUN_PROCESS_TEST=1")
	output, err := cmd.CombinedOutput()
	if err == nil || !bytes.Contains(output, []byte("completion requires an empty record")) {
		t.Fatal("preexisting request evidence was not refused before serving")
	}
	if _, err := os.Stat(address); !os.IsNotExist(err) {
		t.Fatal("server accepted stale evidence")
	}
	if _, err := os.Stat(completion); !os.IsNotExist(err) {
		t.Fatal("stale evidence received a receipt")
	}
}

func TestMalformedQuery(t *testing.T) {
	record, err := os.CreateTemp(t.TempDir(), "record")
	if err != nil {
		t.Fatal(err)
	}
	defer record.Close()
	s := &server{routes: []route{{Method: "GET", Path: "/ok", Status: 200}}, token: "fixture", record: record}
	r := httptest.NewRequest("GET", "http://127.0.0.1/ok?ignored=%zz", nil)
	r.Header.Set("Authorization", "token fixture")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("malformed query was served: %d", w.Code)
	}
}

func TestHeaderCaseOverridesDefault(t *testing.T) {
	record, err := os.CreateTemp(t.TempDir(), "record")
	if err != nil {
		t.Fatal(err)
	}
	defer record.Close()
	s := &server{routes: []route{{Method: "GET", Path: "/ok", Status: 200, Headers: map[string]string{"content-type": "application/problem+json"}}}, token: "fixture", record: record}
	for i := 0; i < 30; i++ {
		r := httptest.NewRequest("GET", "http://127.0.0.1/ok", nil)
		r.Header.Set("Authorization", "token fixture")
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Header().Get("Content-Type") != "application/problem+json" {
			t.Fatal("reviewed header override was replaced by a default")
		}
	}
}

func TestEmptyQueryConstraintNeedsPresence(t *testing.T) {
	r := httptest.NewRequest("GET", "http://127.0.0.1/ok", nil)
	if match([]route{{Method: "GET", Path: "/ok", Query: map[string]string{"x": ""}}}, r) != -1 {
		t.Fatal("absent query parameter matched a reviewed empty value")
	}
}

func TestRecordFailureStopsServer(t *testing.T) {
	work := t.TempDir()
	record, err := os.Create(filepath.Join(work, "record"))
	if err != nil {
		t.Fatal(err)
	}
	if err := record.Close(); err != nil {
		t.Fatal(err)
	}
	address := filepath.Join(work, "address")
	done := make(chan error, 1)
	go func() {
		done <- serve([]route{{Method: "GET", Path: "/ok", Status: 200}}, "fixture", address, record, nil)
	}()
	var raw []byte
	for until := time.Now().Add(5 * time.Second); time.Now().Before(until); {
		raw, _ = os.ReadFile(address)
		if len(raw) > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(raw) == 0 {
		t.Fatal("server did not publish its address")
	}
	req, err := http.NewRequest("GET", string(raw[:len(raw)-1])+"/ok", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "token fixture")
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 500 {
		t.Fatalf("record failure status: %d", response.StatusCode)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("record failure reported a clean completion")
		}
	case <-time.After(time.Second):
		// Terminate the healthy baseline server without leaving a test goroutine.
		if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		if err := <-done; err == nil {
			t.Fatal("record failure reported a clean completion")
		}
	}
}
