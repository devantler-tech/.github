// Test-only entrypoint: run the unchanged scanner inside its image while all HTTP
// operations terminate at a strict replay fixture. Docker disables networking.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	guard "github.com/devantler-tech/dotgithub/scripts/todo-guard"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"reflect"
	"strings"
	"sync"
	"time"
)

type exchange struct {
	Method, Path, Body, Response string
	Status                       int
	Raw                          bool
	Headers                      map[string]string
}

type scenario struct {
	Name            string
	Exchanges       []exchange
	WantFailure     bool
	Output          []string
	ForbiddenOutput []string
}

type replay struct {
	mu        sync.Mutex
	exchanges []exchange
	next      int
	failures  []string
}

func newReplay(exchanges []exchange) *replay { return &replay{exchanges: exchanges} }

func (f *replay) reject(w http.ResponseWriter, reason string) {
	f.failures = append(f.failures, reason)
	http.Error(w, reason, http.StatusBadGateway)
}

func (f *replay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.next >= len(f.exchanges) {
		f.reject(w, fmt.Sprintf("unexpected additional request (%s %s)", r.Method, r.URL.RequestURI()))
		return
	}
	want := f.exchanges[f.next]
	path, err := url.Parse(want.Path)
	if err != nil {
		f.reject(w, "invalid expected API path")
		return
	}
	query, queryErr := url.ParseQuery(r.URL.RawQuery)
	wantQuery, wantQueryErr := url.ParseQuery(path.RawQuery)
	if queryErr != nil || wantQueryErr != nil || r.Method != want.Method || r.URL.Path != path.Path || !reflect.DeepEqual(query, wantQuery) {
		f.reject(w, fmt.Sprintf("request %d: wrong method or path (%s %s)", f.next+1, r.Method, r.URL.Path))
		return
	}
	token := "token offline-token"
	if want.Raw {
		token = ""
		if r.Host != "raw.githubusercontent.com" {
			f.reject(w, "wrong language-rule host")
			return
		}
	} else if r.URL.Path == "/graphql" {
		token = "Bearer offline-project-token"
		if r.Header.Get("Authorization") != token {
			f.reject(w, "unexpected project credential")
			return
		}
	} else if host, _, err := net.SplitHostPort(r.Host); (err != nil && r.Host != "127.0.0.1") || (err == nil && host != "127.0.0.1") {
		f.reject(w, "API request must stay on loopback")
		return
	}
	if r.Header.Get("Authorization") != token {
		f.reject(w, "unexpected credential")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(body) > 1<<20 || !sameJSON(body, []byte(want.Body)) {
		f.reject(w, fmt.Sprintf("request %d: issue payload differs", f.next+1))
		return
	}
	f.next++
	w.Header().Set("Content-Type", "application/json")
	for key, value := range want.Headers {
		w.Header().Set(key, value)
	}
	w.Header().Set("Content-Length", fmt.Sprint(len(want.Response)))
	w.WriteHeader(want.Status)
	_, _ = io.WriteString(w, want.Response)
}

func sameJSON(got, want []byte) bool {
	if len(want) == 0 {
		return len(got) == 0
	}
	var a, b any
	return json.Unmarshal(got, &a) == nil && json.Unmarshal(want, &b) == nil && reflect.DeepEqual(a, b)
}

func (f *replay) verify() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.failures) > 0 {
		return errors.New(strings.Join(f.failures, "; "))
	}
	if f.next != len(f.exchanges) {
		return fmt.Errorf("missing requests: consumed %d of %d", f.next, len(f.exchanges))
	}
	return nil
}

type replayTransport struct{ fixture *replay }

func (t replayTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	w := httptest.NewRecorder()
	serverRequest := r.Clone(r.Context())
	if serverRequest.Host == "" {
		serverRequest.Host = serverRequest.URL.Host
	}
	if serverRequest.Body == nil {
		serverRequest.Body = http.NoBody
	}
	t.fixture.ServeHTTP(w, serverRequest)
	return w.Result(), nil
}
func run() error {
	if os.Getenv("INPUT_TOKEN") != "offline-token" {
		return errors.New("scanner fixture requires synthetic issue authentication")
	}
	project := os.Getenv("INPUT_PROJECT")
	projectToken := os.Getenv("INPUT_PROJECTS_SECRET")
	if (project == "" && projectToken != "") || (project != "" && projectToken != "offline-project-token") {
		return errors.New("scanner fixture requires synthetic project authentication")
	}
	data, err := os.ReadFile("/fixture/case.json")
	if err != nil {
		return err
	}
	var test scenario
	if err = json.Unmarshal(data, &test); err != nil {
		return err
	}
	fixture := newReplay(test.Exchanges)
	api, _ := url.Parse("http://127.0.0.1")
	supervisor := guard.New(guard.Config{API: api, Repository: "offline/fixture", Server: "https://example.invalid", Token: "offline-token", SHA: os.Getenv("INPUT_SHA"), Before: os.Getenv("INPUT_BEFORE"), Project: project, ProjectToken: projectToken}, &http.Client{Transport: replayTransport{fixture}})
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var output bytes.Buffer
	scannerErr := guard.RunChild(ctx, supervisor, []string{"/usr/bin/python3.11", "/app/main.py"}, os.Environ(), &output)
	if scannerErr != nil {
		fmt.Fprintln(&output, scannerErr)
	}
	fmt.Print(output.String())
	if ctx.Err() != nil {
		return errors.New("scanner timed out")
	}
	if err = fixture.verifyScannerResult(test, scannerErr, output.String()); err != nil {
		return err
	}
	fmt.Printf("PASS: real pinned scanner — %s (%d requests)\n", test.Name, len(test.Exchanges))
	return nil
}
func (f *replay) verifyScannerResult(test scenario, scannerErr error, output string) error {
	if err := f.verify(); err != nil {
		return err
	}
	if (scannerErr != nil) != test.WantFailure {
		return fmt.Errorf("unexpected scanner exit: %v", scannerErr)
	}
	for _, message := range test.Output {
		if !strings.Contains(output, message) {
			return fmt.Errorf("missing scanner result: %q", message)
		}
	}
	for _, message := range test.ForbiddenOutput {
		if strings.Contains(output, message) {
			return fmt.Errorf("forbidden scanner result: %q", message)
		}
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}
