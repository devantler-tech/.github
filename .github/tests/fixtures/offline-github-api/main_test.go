package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	go func() { done <- serve([]route{{Method: "GET", Path: "/ok", Status: 200}}, "fixture", address, record) }()
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
