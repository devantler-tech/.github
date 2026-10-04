package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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

func TestReplayTransportSupportsBodylessLanguageGet(t *testing.T) {
	fixture := newReplay([]exchange{{Method: "GET", Path: "/github/linguist/master/lib/linguist/languages.yml", Raw: true, Status: 200, Response: "Shell: fixture"}})
	req, err := http.NewRequest("GET", "https://raw.githubusercontent.com/github/linguist/master/lib/linguist/languages.yml", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := (replayTransport{fixture}).RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || fixture.verify() != nil {
		t.Fatalf("bodyless transport failed: status=%d verdict=%v", response.StatusCode, fixture.verify())
	}
}
