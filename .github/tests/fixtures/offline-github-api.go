// A loopback-only stand-in for the GitHub REST API.
//
// It serves the reviewed responses of one scenario file and appends every request it
// receives to a record file, so a test can run an action that talks to GitHub and then
// assert the complete conversation: no network, no credential, nothing to mutate.
//
// It fails closed. A request without the fixture token is answered 401, a request no
// route describes is answered 404, and both are recorded as such for the verifier.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// route is one reviewed response. A request matches when its method and path are equal
// and it carries every listed query value; the first matching route in file order wins.
type route struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Query   map[string]string `json:"query"`
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers"`
	Body    json.RawMessage   `json:"body"`
}

// entry is one recorded request. Route is the index of the route that answered it, or -1.
// The Authorization header itself is never written, only whether it was the fixture token.
type entry struct {
	Method     string              `json:"method"`
	Path       string              `json:"path"`
	Query      map[string][]string `json:"query"`
	Authorized bool                `json:"authorized"`
	Body       json.RawMessage     `json:"body"`
	Route      int                 `json:"route"`
	Status     int                 `json:"status"`
}

const maxBody = 1 << 20

func loadScenario(path string) ([]route, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// Only "routes" is the stand-in's; the other keys belong to the test that owns the
	// file. Inside a route every key is known, so a misspelt constraint is an error
	// rather than a route that silently matches more than was reviewed.
	var document map[string]json.RawMessage
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	var routes []route
	decoder := json.NewDecoder(bytes.NewReader(document["routes"]))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&routes); err != nil {
		return nil, fmt.Errorf("%s: routes: %w", path, err)
	}
	if len(routes) == 0 {
		return nil, fmt.Errorf("%s: a scenario needs at least one route", path)
	}
	for index, candidate := range routes {
		switch {
		case candidate.Method == "" || candidate.Method != strings.ToUpper(candidate.Method):
			return nil, fmt.Errorf("%s: route %d needs an upper-case method", path, index)
		case !strings.HasPrefix(candidate.Path, "/"):
			return nil, fmt.Errorf("%s: route %d needs an absolute path", path, index)
		case candidate.Status < 200 || candidate.Status > 599:
			return nil, fmt.Errorf("%s: route %d needs a status between 200 and 599", path, index)
		}
	}
	return routes, nil
}

func authorized(header, token string) bool {
	scheme, value, found := strings.Cut(header, " ")
	if !found {
		return false
	}
	switch strings.ToLower(scheme) {
	case "token", "bearer":
		return value == token
	}
	return false
}

func match(routes []route, request *http.Request) int {
	query := request.URL.Query()
	for index, candidate := range routes {
		if candidate.Method != request.Method || candidate.Path != request.URL.Path {
			continue
		}
		matched := true
		for name, value := range candidate.Query {
			if query.Get(name) != value {
				matched = false
				break
			}
		}
		if matched {
			return index
		}
	}
	return -1
}

func recordedBody(raw []byte) json.RawMessage {
	if len(bytes.TrimSpace(raw)) == 0 {
		return json.RawMessage("null")
	}
	if json.Valid(raw) {
		return json.RawMessage(raw)
	}
	quoted, _ := json.Marshal(string(raw))
	return quoted
}

type server struct {
	routes  []route
	token   string
	baseURL string
	mutex   sync.Mutex
	record  *os.File
}

func (s *server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	raw, err := io.ReadAll(io.LimitReader(request.Body, maxBody))
	if err != nil {
		raw = nil
	}
	recorded := entry{
		Method:     request.Method,
		Path:       request.URL.Path,
		Query:      request.URL.Query(),
		Authorized: authorized(request.Header.Get("Authorization"), s.token),
		Body:       recordedBody(raw),
		Route:      -1,
	}
	var body []byte
	headers := map[string]string{"Content-Type": "application/json; charset=utf-8"}
	switch {
	case !recorded.Authorized:
		recorded.Status = http.StatusUnauthorized
		body = []byte(`{"message":"Bad credentials (the offline stand-in accepts only its fixture token)"}`)
	default:
		recorded.Route = match(s.routes, request)
		if recorded.Route < 0 {
			recorded.Status = http.StatusNotFound
			body = []byte(`{"message":"Not Found (the offline stand-in has no route for this request)"}`)
			break
		}
		answer := s.routes[recorded.Route]
		recorded.Status = answer.Status
		body = answer.Body
		for name, value := range answer.Headers {
			headers[name] = strings.ReplaceAll(value, "{{base_url}}", s.baseURL)
		}
	}

	// Record before answering: the caller may act on the response at once, and the
	// verifier must never read a conversation that is missing its last request.
	line, err := json.Marshal(recorded)
	if err == nil {
		s.mutex.Lock()
		_, err = s.record.Write(append(line, '\n'))
		s.mutex.Unlock()
	}
	if err != nil {
		http.Error(writer, "the offline stand-in could not record this request", http.StatusInternalServerError)
		return
	}

	for name, value := range headers {
		writer.Header().Set(name, value)
	}
	writer.WriteHeader(recorded.Status)
	if recorded.Status != http.StatusNoContent && request.Method != http.MethodHead {
		_, _ = writer.Write(body)
	}
}

func run() error {
	scenarioPath := flag.String("scenario", "", "scenario file holding the reviewed routes")
	recordPath := flag.String("record", "", "file that receives one JSON line per request")
	addressPath := flag.String("address-file", "", "file that receives the stand-in's base URL once it listens")
	token := flag.String("token", "", "the only token the stand-in accepts")
	flag.Parse()
	if *scenarioPath == "" || *recordPath == "" || *addressPath == "" || *token == "" || flag.NArg() != 0 {
		return errors.New("usage: offline-github-api -scenario FILE -record FILE -address-file FILE -token TOKEN")
	}

	routes, err := loadScenario(*scenarioPath)
	if err != nil {
		return err
	}
	record, err := os.OpenFile(*recordPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer record.Close()

	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	baseURL := "http://" + listener.Addr().String()
	handler := &server{routes: routes, token: *token, baseURL: baseURL, record: record}
	httpServer := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}

	// Publish the address only once the listener exists, and atomically, so a caller
	// that sees the file can connect.
	pending := filepath.Join(filepath.Dir(*addressPath), "."+filepath.Base(*addressPath)+".pending")
	if err := os.WriteFile(pending, []byte(baseURL+"\n"), 0o600); err != nil {
		return err
	}
	if err := os.Rename(pending, *addressPath); err != nil {
		return err
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	failed := make(chan error, 1)
	go func() { failed <- httpServer.Serve(listener) }()
	select {
	case err := <-failed:
		return err
	case <-stop:
	}
	deadline, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return httpServer.Shutdown(deadline)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "offline-github-api:", err)
		os.Exit(1)
	}
}
