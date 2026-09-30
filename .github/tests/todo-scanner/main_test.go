package main

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
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
