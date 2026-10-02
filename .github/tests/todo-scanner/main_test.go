package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestLanguageRulesTravelThroughTheIsolatedTLSProxy(t *testing.T) {
	fixture := newReplay([]exchange{{Method: "GET", Path: "/github/linguist/master/lib/linguist/languages.yml", Raw: true, Status: 200, Response: "Shell: fixture"}})
	pair, ca, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	fixture.certificate = pair
	server := httptest.NewServer(fixture)
	defer server.Close()
	proxy, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		t.Fatal("fixture CA is invalid")
	}
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	response, err := client.Get("https://raw.githubusercontent.com/github/linguist/master/lib/linguist/languages.yml")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || response.StatusCode != 200 || string(body) != "Shell: fixture" {
		t.Fatalf("language rules differ: %d, %s, %v", response.StatusCode, body, err)
	}
	if err := fixture.verify(); err != nil {
		t.Fatal(err)
	}
}

func TestTLSProxyReturnsRejectedRequestWithoutHanging(t *testing.T) {
	fixture := newReplay([]exchange{{Method: "GET", Path: "/expected", Raw: true, Status: 200, Response: "fixture"}})
	pair, ca, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	fixture.certificate = pair
	server := httptest.NewServer(fixture)
	defer server.Close()
	proxy, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(ca)
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	response, err := client.Get("https://raw.githubusercontent.com/unexpected")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	_, err = io.ReadAll(response.Body)
	if err != nil || response.StatusCode != 502 || fixture.verify() == nil {
		t.Fatalf("rejection did not finish: %d, %v", response.StatusCode, err)
	}
}

func TestReplayRejectsUnsafeOrIncorrectRequests(t *testing.T) {
	for _, tc := range []struct {
		name, method, path, token, body string
	}{
		{"live API route", "POST", "/repos/live/repo/issues", "token offline-token", `{"title":"Repair"}`},
		{"wrong verb", "PATCH", "/repos/offline/fixture/issues", "token offline-token", `{"title":"Repair"}`},
		{"malformed query", "POST", "/repos/offline/fixture/issues?unexpected=%ZZ", "token offline-token", `{"title":"Repair"}`},
		{"wrong credential", "POST", "/repos/offline/fixture/issues", "token real-token", `{"title":"Repair"}`},
		{"wrong title", "POST", "/repos/offline/fixture/issues", "token offline-token", `{"title":"Other"}`},
		{"extra payload field", "POST", "/repos/offline/fixture/issues", "token offline-token", `{"title":"Repair","milestone":1}`},
		{"oversized payload suffix", "POST", "/repos/offline/fixture/issues", "token offline-token", `{"title":"Repair"}` + strings.Repeat(" ", (1<<20)-len(`{"title":"Repair"}`)) + "trailing"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fixture := newReplay([]exchange{{Method: "POST", Path: "/repos/offline/fixture/issues", Body: `{"title":"Repair"}`, Status: 201, Response: `{"number":7}`}})
			r := httptest.NewRequest(tc.method, "http://127.0.0.1"+tc.path, strings.NewReader(tc.body))
			r.Header.Set("Authorization", tc.token)
			w := httptest.NewRecorder()
			fixture.ServeHTTP(w, r)
			if w.Code < 400 || fixture.verify() == nil {
				t.Fatalf("unsafe request accepted: status=%d", w.Code)
			}
		})
	}
}

func TestScannerEnvironmentClearsConflictingProxySettings(t *testing.T) {
	env := scannerEnvironment([]string{"https_proxy=http://external.invalid", "no_proxy=*", "ALL_PROXY=http://external.invalid", "HTTPS_PROXY=http://old.invalid", "INPUT_GITHUB_URL=https://api.github.com", "KEEP=fixture"}, "http://127.0.0.1:1234", "/tmp/fixture.pem")
	got := map[string]string{}
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		if _, found := got[key]; found {
			t.Fatalf("duplicate environment key %s", key)
		}
		got[key] = value
	}
	want := map[string]string{"KEEP": "fixture", "INPUT_GITHUB_URL": "http://127.0.0.1:1234", "HTTPS_PROXY": "http://127.0.0.1:1234", "REQUESTS_CA_BUNDLE": "/tmp/fixture.pem", "NO_PROXY": "127.0.0.1"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("conflicting scanner environment: %#v", got)
	}
}

func TestReplayRequiresEveryOperationAndRejectsExtraOperations(t *testing.T) {
	fixture := newReplay([]exchange{{Method: "POST", Path: "/repos/offline/fixture/issues", Body: `{"title":"Repair"}`, Status: 201, Response: `{"number":7}`}})
	if fixture.verify() == nil {
		t.Fatal("missing issue creation passed")
	}
	r := httptest.NewRequest("POST", "http://127.0.0.1/repos/offline/fixture/issues", strings.NewReader(`{"title":"Repair"}`))
	r.Header.Set("Authorization", "token offline-token")
	w := httptest.NewRecorder()
	fixture.ServeHTTP(w, r)
	if w.Code != 201 || fixture.verify() != nil {
		t.Fatalf("valid issue creation rejected: %d, %v", w.Code, fixture.verify())
	}
	fixture.ServeHTTP(httptest.NewRecorder(), r)
	if fixture.verify() == nil {
		t.Fatal("duplicate issue operation passed")
	}
}

func TestProxyRejectsUnexpectedDestination(t *testing.T) {
	fixture := newReplay(nil)
	r := httptest.NewRequest("CONNECT", "http://api.github.com:443", nil)
	r.Host = "api.github.com:443"
	w := httptest.NewRecorder()
	fixture.ServeHTTP(w, r)
	if w.Code < 400 || fixture.verify() == nil {
		t.Fatal("proxy accepted live API destination")
	}
}

func TestScannerResultRejectsMisleadingOrIncompleteDiagnostics(t *testing.T) {
	test := scenario{WantFailure: true, Output: []string{"Offline API failure"}, ForbiddenOutput: []string{"Issue created:", "Issue closed"}}
	for _, tc := range []struct {
		name, output string
		err          error
		wantError    bool
	}{
		{"reported failure", "Offline API failure", errors.New("exit 1"), false},
		{"missing diagnostic", "Traceback", errors.New("exit 1"), true},
		{"false creation", "Offline API failure\nIssue created: #7", errors.New("exit 1"), true},
		{"false closure", "Issue closed\nOffline API failure", errors.New("exit 1"), true},
		{"unexpected success exit", "Offline API failure", nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := newReplay(nil).verifyScannerResult(test, tc.err, tc.output)
			if (err != nil) != tc.wantError {
				t.Fatalf("result = %v, want rejection = %v", err, tc.wantError)
			}
		})
	}
	if err := newReplay(nil).verifyScannerResult(scenario{Output: []string{"Issue created: #7"}}, nil, "Issue created: #7"); err != nil {
		t.Fatalf("healthy success rejected: %v", err)
	}
	if err := newReplay(nil).verifyScannerResult(scenario{Output: []string{"Issue could not be created"}}, nil, "Issue could not be created"); err != nil {
		t.Fatalf("observed zero-exit rejection rejected: %v", err)
	}
	if err := newReplay(nil).verifyScannerResult(scenario{}, errors.New("exit 1"), ""); err == nil {
		t.Fatal("unexpected failed exit accepted")
	}
}

func TestFailedReadResultRequiresTheWholePlanAndRejectsAWrite(t *testing.T) {
	plan := []exchange{
		{Method: "GET", Path: "/repos/offline/fixture/issues", Status: 200, Response: `[{"number":11,"title":"Tracked"}]`},
		{Method: "GET", Path: "/repos/offline/fixture/milestones", Status: 503, Response: `{"message":"Offline API failure"}`},
	}
	test := scenario{WantFailure: true, Output: []string{"Offline API failure"}}
	fixture := newReplay(plan)
	observe := func(method, path string, wantStatus int) {
		t.Helper()
		r := httptest.NewRequest(method, "http://127.0.0.1"+path, nil)
		r.Header.Set("Authorization", "token offline-token")
		w := httptest.NewRecorder()
		fixture.ServeHTTP(w, r)
		if w.Code != wantStatus {
			t.Fatalf("status = %d, want %d", w.Code, wantStatus)
		}
	}
	observe("GET", plan[0].Path, 200)
	if err := fixture.verifyScannerResult(test, errors.New("exit 1"), "Offline API failure"); err == nil {
		t.Fatal("partial read plan was accepted on a diagnostic alone")
	}
	observe("GET", plan[1].Path, 503)
	if err := fixture.verifyScannerResult(test, errors.New("exit 1"), "Offline API failure"); err != nil {
		t.Fatalf("complete failed-read observation rejected: %v", err)
	}
	observe("POST", "/repos/offline/fixture/issues", 502)
	if err := fixture.verifyScannerResult(test, errors.New("exit 1"), "Offline API failure"); err == nil {
		t.Fatal("write after failed read was accepted")
	}
}
