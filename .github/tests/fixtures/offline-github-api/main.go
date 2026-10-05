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
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"hash"
	"io"
	"net"
	"net/http"
	"net/url"
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

// maxBody bounds a recorded request body; a larger one is refused rather than truncated.
const maxBody = 1 << 20

// Reject duplicate keys before typed decoding can silently choose a last value.
func unambiguousJSON(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	var value func(int) error
	value = func(depth int) error {
		if depth > 100 {
			return errors.New("JSON nesting exceeds the fixture limit")
		}
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		keys := map[string]bool{}
		for decoder.More() {
			if delim == '{' {
				key, err := decoder.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				if !ok || keys[name] {
					return errors.New("duplicate or invalid JSON object key")
				}
				keys[name] = true
			}
			if err := value(depth + 1); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
		return err
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("expected one JSON document")
	}
	return nil
}

func httpToken(value string) bool {
	if value == "" {
		return false
	}
	for _, ch := range value {
		if ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || strings.ContainsRune("!#$%&'*+-.^_`|~", ch) {
			continue
		}
		return false
	}
	return true
}

// loadScenario reads the reviewed routes of a scenario file and rejects any the stand-in
// could not serve exactly as written.
func loadScenario(path string) ([]route, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseScenario(raw, path)
}

func parseScenario(raw []byte, path string) ([]route, error) {
	if err := unambiguousJSON(raw); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	// Only "routes" is the stand-in's; the other keys belong to the test that owns the
	// file. Inside a route every key is known, so a misspelt constraint is an error
	// rather than a route that silently matches more than was reviewed.
	var document map[string]json.RawMessage
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	// Struct decoding also accepts case-insensitive field aliases. Check exact
	// keys first so served routes and the scenario verifier mean the same thing.
	var routeDocuments []map[string]json.RawMessage
	if err := json.Unmarshal(document["routes"], &routeDocuments); err != nil {
		return nil, err
	}
	for _, fields := range routeDocuments {
		for name := range fields {
			switch name {
			case "method", "path", "query", "status", "headers", "body":
			default:
				return nil, errors.New("route field names must match the exact scenario schema")
			}
		}
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
		case !httpToken(candidate.Method) || candidate.Method != strings.ToUpper(candidate.Method):
			return nil, fmt.Errorf("%s: route %d needs an upper-case method", path, index)
		case !strings.HasPrefix(candidate.Path, "/") || strings.ContainsAny(candidate.Path, "?#\r\n"):
			return nil, fmt.Errorf("%s: route %d needs an absolute path", path, index)
		case candidate.Status < 200 || candidate.Status > 599:
			return nil, fmt.Errorf("%s: route %d needs a status between 200 and 599", path, index)
		}
		if len(candidate.Body) > 0 && (candidate.Method == http.MethodHead || candidate.Status == 204 || candidate.Status == 304) {
			return nil, fmt.Errorf("%s: route %d would discard its reviewed body", path, index)
		}
		headerNames := map[string]bool{}
		for name, value := range candidate.Headers {
			canonical := http.CanonicalHeaderKey(name)
			if headerNames[canonical] {
				return nil, errors.New("route header names must be unique ignoring case")
			}
			headerNames[canonical] = true
			// The HTTP transport trims edge whitespace and removes Content-Type
			// from 304 responses. Never certify a header it cannot serve unchanged.
			if value != strings.Trim(value, " \t") || candidate.Status == http.StatusNotModified && canonical == "Content-Type" {
				return nil, fmt.Errorf("%s: route %d has an unservable header", path, index)
			}
			if !httpToken(name) || strings.IndexFunc(value, func(ch rune) bool { return ch < 32 && ch != '\t' || ch == 127 }) >= 0 || strings.EqualFold(name, "Content-Length") || strings.EqualFold(name, "Transfer-Encoding") || strings.EqualFold(name, "Trailer") {
				return nil, fmt.Errorf("%s: route %d has an unservable header", path, index)
			}
		}
	}
	// A null value decodes as an empty Go string; it is not a reviewed query value.
	var constraints []struct {
		Query   map[string]json.RawMessage `json:"query"`
		Headers map[string]json.RawMessage `json:"headers"`
	}
	if err := json.Unmarshal(document["routes"], &constraints); err != nil {
		return nil, err
	}
	for _, constraint := range constraints {
		for _, values := range []map[string]json.RawMessage{constraint.Query, constraint.Headers} {
			for _, value := range values {
				if len(value) == 0 || value[0] != '"' {
					return nil, errors.New("query/header values must be strings")
				}
			}
		}
	}
	return routes, nil
}

// authorized reports whether an Authorization header carries the fixture token.
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

// match returns the index of the first route that answers a request, or -1.
func match(routes []route, request *http.Request) int {
	query, err := url.ParseQuery(request.URL.RawQuery)
	if err != nil {
		return -1
	}
	for index, candidate := range routes {
		if candidate.Method != request.Method || candidate.Path != request.URL.Path {
			continue
		}
		matched := true
		for name, value := range candidate.Query {
			if values, present := query[name]; !present || len(values) != 1 || values[0] != value {
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

// recordedBody returns a request body as the record stores it: JSON as sent, other text as
// a string, and nothing as null.
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

// server answers requests from the reviewed routes and records each one.
type server struct {
	routes     []route
	token      string
	baseURL    string
	mutex      sync.Mutex
	record     *os.File
	recordHash hash.Hash
	failure    chan error
}

// ServeHTTP records a request and then answers it: 401 without the fixture token, 413 for a
// body it cannot record whole, the matching route otherwise, and 404 when no route
// describes it.
func (s *server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	// A body the stand-in cannot read whole is never recorded as if it were complete.
	raw, unreadable := io.ReadAll(http.MaxBytesReader(writer, request.Body, maxBody))
	if unreadable != nil {
		raw = nil
	}
	query, malformedQuery := url.ParseQuery(request.URL.RawQuery)
	recorded := entry{
		Method:     request.Method,
		Path:       request.URL.Path,
		Query:      query,
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
	case unreadable != nil:
		recorded.Status = http.StatusRequestEntityTooLarge
		body = []byte(`{"message":"The offline stand-in could not read this request body"}`)
	case malformedQuery != nil:
		recorded.Status = http.StatusBadRequest
		body = []byte(`{"message":"The offline stand-in could not parse the complete query"}`)
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
			headers[http.CanonicalHeaderKey(name)] = strings.ReplaceAll(value, "{{base_url}}", s.baseURL)
		}
	}

	// Record before answering: the caller may act on the response at once, and the
	// verifier must never read a conversation that is missing its last request.
	line, err := json.Marshal(recorded)
	if err == nil {
		s.mutex.Lock()
		line = append(line, '\n')
		_, err = s.record.Write(line)
		if err == nil && s.recordHash != nil {
			_, _ = s.recordHash.Write(line)
		}
		s.mutex.Unlock()
	}
	if err != nil {
		if s.failure != nil {
			select {
			case s.failure <- err:
			default:
			}
		}
		http.Error(writer, "the offline stand-in could not record this request", http.StatusInternalServerError)
		return
	}

	for name, value := range headers {
		writer.Header().Set(name, value)
	}
	writer.WriteHeader(recorded.Status)
	if recorded.Status != http.StatusNoContent && request.Method != http.MethodHead {
		if _, err := writer.Write(body); err != nil && s.failure != nil {
			select {
			case s.failure <- err:
			default:
			}
		}
	}
}

// run starts the stand-in from its command line and returns once it has stopped.
func run() error {
	scenarioPath := flag.String("scenario", "", "scenario file holding the reviewed routes")
	recordPath := flag.String("record", "", "file that receives one JSON line per request")
	addressPath := flag.String("address-file", "", "file that receives the stand-in's base URL once it listens")
	token := flag.String("token", "", "the only token the stand-in accepts")
	completionPath := flag.String("completion-file", "", "clean completion receipt path")
	nonce := flag.String("nonce", "", "per-start completion identity")
	flag.Parse()
	if *scenarioPath == "" || *recordPath == "" || *addressPath == "" || *token == "" || flag.NArg() != 0 {
		return errors.New("usage: offline-github-api -scenario FILE -record FILE -address-file FILE -token TOKEN")
	}
	if (*completionPath == "") != (*nonce == "") {
		return errors.New("completion file and nonce must be paired")
	}

	// Retain the same admitted bytes used to create routes. A replacement file
	// after serving must never receive a clean receipt for responses not served.
	scenario, err := os.ReadFile(*scenarioPath)
	if err != nil {
		return err
	}
	routes, err := parseScenario(scenario, *scenarioPath)
	if err != nil {
		return err
	}
	record, err := os.OpenFile(*recordPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if *completionPath != "" {
		info, statError := record.Stat()
		if statError != nil {
			return errors.Join(statError, record.Close())
		}
		if info.Size() != 0 {
			return errors.Join(errors.New("completion requires an empty record"), record.Close())
		}
	}
	recordHash := sha256.New()
	// The record is the test's evidence, so a close that fails is the stand-in's failure.
	err = errors.Join(serve(routes, *token, *addressPath, record, recordHash), record.Sync(), record.Close())
	if err != nil || *completionPath == "" {
		return err
	}
	raw, err := os.ReadFile(*recordPath)
	if err != nil {
		return err
	}
	storedHash := sha256.Sum256(raw)
	if !bytes.Equal(recordHash.Sum(nil), storedHash[:]) {
		return errors.New("record changed outside the server's request writes")
	}
	receipt, err := json.Marshal(map[string]string{"nonce": *nonce, "record_sha256": fmt.Sprintf("%x", recordHash.Sum(nil)), "scenario_sha256": fmt.Sprintf("%x", sha256.Sum256(scenario))})
	if err != nil {
		return err
	}
	pending := *completionPath + ".pending"
	if err := os.WriteFile(pending, receipt, 0600); err != nil {
		return err
	}
	return os.Rename(pending, *completionPath)
}

// serve answers requests until the process is asked to stop.
func serve(routes []route, token, addressPath string, record *os.File, recordHash hash.Hash) error {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	baseURL := "http://" + listener.Addr().String()
	recordFailure := make(chan error, 1)
	handler := &server{routes: routes, token: token, baseURL: baseURL, record: record, recordHash: recordHash, failure: recordFailure}
	httpServer := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}

	// Publish the address only once the listener exists, and atomically, so a caller
	// that sees the file can connect.
	pending := filepath.Join(filepath.Dir(addressPath), "."+filepath.Base(addressPath)+".pending")
	if err := os.WriteFile(pending, []byte(baseURL+"\n"), 0o600); err != nil {
		return errors.Join(err, listener.Close())
	}
	if err := os.Rename(pending, addressPath); err != nil {
		return errors.Join(err, listener.Close())
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stop)
	failed := make(chan error, 1)
	go func() { failed <- httpServer.Serve(listener) }()
	var recordingError error
	select {
	case err := <-failed:
		return err
	case <-stop:
	case recordingError = <-recordFailure:
	}
	deadline, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	shutdownError := httpServer.Shutdown(deadline)
	select {
	case err := <-recordFailure:
		recordingError = errors.Join(recordingError, err)
	default:
	}
	return errors.Join(recordingError, shutdownError)
}

// main exits non-zero when the stand-in could not start, serve or keep its record.
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "offline-github-api:", err)
		os.Exit(1)
	}
}
