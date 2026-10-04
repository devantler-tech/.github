// Package guard supervises the digest-pinned scanner's complete API operations.
package guard

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	API                                                           *url.URL
	Repository, Server, Token, SHA, Before, Project, ProjectToken string
}
type config = Config
type guard struct {
	mu              sync.Mutex
	certificate     tls.Certificate
	cfg             Config
	client          *http.Client
	failed          error
	mutationStarted bool
	closed          map[int]bool
	issues          map[int]bool
	titles          map[int]string
	searches        map[string]bool
	issueIDs        map[string]bool
	projectIDs      map[string]bool
	diffPending     bool
}
type Guard = guard

func New(c Config, client *http.Client) *Guard { return newGuard(c, client) }
func newGuard(c Config, client *http.Client) *guard {
	if client == nil {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.Proxy = nil
		client = &http.Client{Transport: transport, Timeout: 30 * time.Second}
	}
	copyClient := *client
	copyClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &guard{cfg: c, client: &copyClient, closed: map[int]bool{}, issues: map[int]bool{}, titles: map[int]string{}, searches: map[string]bool{}, issueIDs: map[string]bool{}, projectIDs: map[string]bool{}}
}
func (g *guard) verdict() error { return g.Verdict() }
func (g *guard) Verdict() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.failed != nil {
		return g.failed
	}
	if g.diffPending {
		return errors.New("diff read has no successful bound fallback")
	}
	return nil
}
func (g *guard) MutationStarted() bool { g.mu.Lock(); defer g.mu.Unlock(); return g.mutationStarted }
func (g *guard) CompletedCloses() int  { g.mu.Lock(); defer g.mu.Unlock(); return len(g.closed) }
func (g *guard) fail(w http.ResponseWriter, class string) {
	if g.failed == nil {
		g.failed = errors.New(class)
	}
	http.Error(w, "Incomplete scanner operation: "+class, http.StatusBadGateway)
}
func (g *guard) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		g.connect(w, r)
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.failed != nil {
		http.Error(w, "Scanner operation already failed", 502)
		return
	}
	if r.URL.Host == "raw.githubusercontent.com" || r.Host == "raw.githubusercontent.com" {
		g.raw(w, r)
		return
	}
	if r.URL.Path == "/graphql" {
		g.graphql(w, r)
		return
	}
	if r.URL.IsAbs() {
		g.fail(w, "unexpected absolute API route")
		return
	}
	if r.Header.Get("Authorization") != "token "+g.cfg.Token || g.cfg.Token == "" {
		g.fail(w, "unexpected REST credential")
		return
	}
	if r.URL.RawPath != "" || ambiguousPath(r.URL.Path) || strings.Contains(r.URL.Path, "//") {
		g.fail(w, "ambiguous REST route")
		return
	}
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		g.fail(w, "invalid REST query")
		return
	}
	for _, v := range q {
		if len(v) != 1 {
			g.fail(w, "duplicate REST query")
			return
		}
	}
	prefix := "/repos/" + g.cfg.Repository
	switch {
	case r.Method == "GET" && r.URL.Path == "/search/issues":
		title, ok := strings.CutPrefix(q.Get("q"), "repo:"+g.cfg.Repository+" is:issue in:title ")
		if !ok || !literalSearchTitle(title) || !onlyQuery(q, "q", "per_page", "page") {
			g.fail(w, "unbound search route")
			return
		}
		g.list(w, r, true, title)
	case r.Method == "GET" && (r.URL.Path == prefix+"/issues" || r.URL.Path == prefix+"/milestones"):
		if q.Get("state") != "open" || q.Get("per_page") != "100" || (q.Get("page") != "" && q.Get("page") != "1") || !onlyQuery(q, "state", "per_page", "page") {
			g.fail(w, "unbound list route")
			return
		}
		g.list(w, r, false, "")
	case r.Method == "GET" && strings.HasPrefix(r.URL.Path, prefix+"/assignees/"):
		name := strings.TrimPrefix(r.URL.Path, prefix+"/assignees/")
		if name == "" || strings.Contains(name, "/") || len(q) != 0 {
			g.fail(w, "unbound assignee read")
			return
		}
		p, e := g.fetch(r, r.URL, nil)
		if e != nil || (p.code != 204 && p.code != 404) {
			g.fail(w, "assignee read failed")
			return
		}
		writeResponse(w, p)
	case r.Method == "GET" && (strings.HasPrefix(r.URL.Path, prefix+"/compare/") || strings.HasPrefix(r.URL.Path, prefix+"/commits/") || strings.HasPrefix(r.URL.Path, prefix+"/pulls/")):
		if len(q) != 0 {
			g.fail(w, "unexpected diff query")
			return
		}
		g.diff(w, r, prefix)
	case (r.Method == "POST" || r.Method == "PATCH") && strings.HasPrefix(r.URL.Path, prefix+"/"):
		if len(q) != 0 || g.diffPending {
			g.fail(w, "mutation lacks complete input reads")
			return
		}
		g.mutate(w, r, prefix)
	default:
		g.fail(w, "unexpected REST operation")
	}
}

// The pinned scanner forwards the title as unescaped GitHub search syntax.
// Unsupported expressions cannot certify the absence of a literal issue title.
func literalSearchTitle(title string) bool {
	if title == "" || strings.ContainsAny(title, ":\"\\()\r\n*") {
		return false
	}
	for _, word := range strings.Fields(title) {
		if strings.HasPrefix(word, "-") || word == "OR" || word == "AND" || word == "NOT" {
			return false
		}
	}
	return true
}
func onlyQuery(q url.Values, keys ...string) bool {
	for k := range q {
		found := false
		for _, want := range keys {
			if k == want {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

type response struct {
	code   int
	header http.Header
	body   []byte
}

func (g *guard) fetch(r *http.Request, target *url.URL, body []byte) (response, error) {
	u := *g.cfg.API
	if target.IsAbs() {
		if target.Scheme != u.Scheme || target.Host != u.Host || !strings.HasPrefix(target.Path, strings.TrimSuffix(u.Path, "/")+"/") {
			return response{}, errors.New("unbound page origin")
		}
		u = *target
	} else {
		u.Path = strings.TrimSuffix(u.Path, "/") + target.Path
		u.RawQuery = target.RawQuery
	}
	req, e := http.NewRequestWithContext(r.Context(), r.Method, u.String(), bytes.NewReader(body))
	if e != nil {
		return response{}, errors.New("request construction failed")
	}
	req.Header = r.Header.Clone()
	req.Header.Del("Accept-Encoding")
	req.Header.Del("Proxy-Authorization")
	req.Header.Del("Connection")
	req.Host = ""
	p, e := g.client.Do(req)
	if e != nil {
		return response{}, errors.New("API transport failed")
	}
	defer p.Body.Close()
	b, e := io.ReadAll(io.LimitReader(p.Body, (16<<20)+1))
	if e != nil || len(b) > 16<<20 {
		return response{}, errors.New("API response incomplete")
	}
	return response{p.StatusCode, p.Header.Clone(), b}, nil
}
func writeResponse(w http.ResponseWriter, p response) {
	for k, v := range p.header {
		switch strings.ToLower(k) {
		case "connection", "transfer-encoding", "content-length", "content-encoding", "set-cookie", "location", "link":
		default:
			w.Header()[k] = v
		}
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(p.body)))
	w.WriteHeader(p.code)
	_, _ = w.Write(p.body)
}

// Native search/list pages are buffered and joined before the child receives any evidence.
func (g *guard) list(w http.ResponseWriter, r *http.Request, search bool, title string) {
	target := r.URL
	items := []any{}
	seen := map[int]bool{}
	total := -1
	lastDeclared := 0
	var first response
	for page := 1; page <= 100; page++ {
		p, e := g.fetch(r, target, nil)
		if e != nil || p.code != 200 {
			g.fail(w, "complete list read failed")
			return
		}
		if page == 1 {
			first = p
		}
		v, e := decode(p.body)
		if e != nil {
			g.fail(w, "malformed list evidence")
			return
		}
		var rows []any
		if search {
			obj, ok := v.(map[string]any)
			if !ok {
				g.fail(w, "malformed search evidence")
				return
			}
			n, ok := integer(obj["total_count"])
			complete, valid := obj["incomplete_results"].(bool)
			parsedRows, okRows := obj["items"].([]any)
			rows = parsedRows
			if !ok || n < 0 || n > 1000 || !valid || complete || !okRows || (total != -1 && total != n) {
				g.fail(w, "incomplete search evidence")
				return
			}
			if total == -1 {
				total = n
			}
		} else {
			var ok bool
			rows, ok = v.([]any)
			if !ok {
				g.fail(w, "malformed list evidence")
				return
			}
		}
		for _, row := range rows {
			obj, ok := row.(map[string]any)
			if !ok {
				g.fail(w, "malformed list identity")
				return
			}
			n, ok := integer(obj["number"])
			name, okTitle := obj["title"].(string)
			if !ok || n <= 0 || !okTitle || name == "" || seen[n] {
				g.fail(w, "contradictory list identity")
				return
			}
			seen[n] = true
			if search || strings.HasSuffix(r.URL.Path, "/issues") {
				link, okURL := obj["html_url"].(string)
				state, okState := obj["state"].(string)
				if _, pr := obj["pull_request"]; pr {
					if search || !okURL || link != strings.TrimSuffix(g.cfg.Server, "/")+"/"+g.cfg.Repository+"/pull/"+strconv.Itoa(n) || !okState || (state != "open" && state != "closed") {
						g.fail(w, "unbound pull request identity")
						return
					}
					continue
				}
				if !okURL || link != strings.TrimSuffix(g.cfg.Server, "/")+"/"+g.cfg.Repository+"/issues/"+strconv.Itoa(n) || !okState || (state != "open" && state != "closed") {
					g.fail(w, "unbound issue identity")
					return
				}
			}
			items = append(items, row)
		}
		next, last, e := nextPage(p.header.Values("Link"), target, g.cfg.API, page, lastDeclared)
		lastDeclared = last
		if e != nil {
			g.fail(w, "ambiguous page evidence")
			return
		}
		if next == nil {
			if search && len(items) != total {
				g.fail(w, "incomplete search evidence")
				return
			}
			first.body, _ = json.Marshal(items)
			if search {
				first.body, _ = json.Marshal(map[string]any{"total_count": total, "incomplete_results": false, "items": items})
				for _, knownTitle := range g.titles {
					if knownTitle != title {
						continue
					}
					found := false
					for _, x := range items {
						if x.(map[string]any)["title"] == title {
							found = true
						}
					}
					if !found {
						g.fail(w, "search contradicts verified issue identity")
						return
					}
				}
				g.searches[title] = true
				for _, x := range items {
					m := x.(map[string]any)
					if m["title"] == title {
						g.searches[title] = false
					}
				}
			}
			if search || strings.HasSuffix(r.URL.Path, "/issues") {
				for _, x := range items {
					m := x.(map[string]any)
					n, _ := integer(m["number"])
					g.issues[n] = m["state"] == "open"
					g.titles[n] = m["title"].(string)
				}
			}
			writeResponse(w, first)
			return
		}
		if len(rows) == 0 {
			g.fail(w, "empty nonterminal page")
			return
		}
		target = next
	}
	g.fail(w, "page ceiling exceeded")
}
func nextPage(headers []string, current, base *url.URL, page, declaredLast int) (*url.URL, int, error) {
	var next *url.URL
	seen := map[string]bool{}
	last := declaredLast
	for _, header := range headers {
		for _, part := range strings.Split(header, ",") {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			end := strings.Index(part, ">")
			if !strings.HasPrefix(part, "<") || end < 1 {
				return nil, last, errors.New("malformed link")
			}
			attrs := strings.Fields(strings.TrimSpace(part[end+1:]))
			if len(attrs) != 2 || attrs[0] != ";" || !strings.HasPrefix(attrs[1], "rel=\"") || !strings.HasSuffix(attrs[1], "\"") {
				return nil, last, errors.New("malformed link relation")
			}
			rel := strings.TrimSuffix(strings.TrimPrefix(attrs[1], "rel=\""), "\"")
			if seen[rel] {
				return nil, last, errors.New("duplicate link relation")
			}
			seen[rel] = true
			if rel != "next" && rel != "last" && rel != "first" && rel != "prev" {
				return nil, last, errors.New("unknown link relation")
			}
			u, e := url.Parse(part[1:end])
			if e != nil || u.User != nil || u.Fragment != "" || u.RawPath != "" || u.Scheme != base.Scheme || u.Host != base.Host || u.Path != strings.TrimSuffix(base.Path, "/")+currentPath(current, base) {
				return nil, last, errors.New("page origin differs")
			}
			q, e := url.ParseQuery(u.RawQuery)
			old, e2 := url.ParseQuery(current.RawQuery)
			n, e3 := strconv.Atoi(q.Get("page"))
			if e != nil || e2 != nil || e3 != nil || n < 1 || n > 100 || len(q["page"]) != 1 {
				return nil, last, errors.New("page identity differs")
			}
			for _, values := range q {
				if len(values) != 1 {
					return nil, last, errors.New("duplicate page query")
				}
			}
			q.Del("page")
			old.Del("page")
			if q.Encode() != old.Encode() {
				return nil, last, errors.New("page query differs")
			}
			switch rel {
			case "next":
				if n != page+1 {
					return nil, last, errors.New("page progression differs")
				}
				next = u
			case "last":
				if n < page || (declaredLast != 0 && n != declaredLast) {
					return nil, last, errors.New("last page differs")
				}
				last = n
			case "first":
				if n != 1 {
					return nil, last, errors.New("first page differs")
				}
			case "prev":
				if n != page-1 {
					return nil, last, errors.New("previous page differs")
				}
			}
		}
	}
	if (last > page && next == nil) || (last == page && next != nil) {
		return nil, last, errors.New("incomplete page chain")
	}
	return next, last, nil
}
func currentPath(u, base *url.URL) string {
	if u.IsAbs() {
		return strings.TrimPrefix(u.Path, strings.TrimSuffix(base.Path, "/"))
	}
	return u.Path
}
func (g *guard) diff(w http.ResponseWriter, r *http.Request, prefix string) {
	if r.Header.Get("Accept") != "application/vnd.github.v3.diff" {
		g.fail(w, "unbound diff representation")
		return
	}
	compare := prefix + "/compare/"
	commit := prefix + "/commits/"
	pull := prefix + "/pulls/"
	switch {
	case strings.HasPrefix(r.URL.Path, compare):
		if strings.TrimPrefix(r.URL.Path, compare) != g.cfg.Before+"..."+g.cfg.SHA {
			g.fail(w, "unbound compare")
			return
		}
	case strings.HasPrefix(r.URL.Path, commit):
		if strings.TrimPrefix(r.URL.Path, commit) != g.cfg.SHA {
			g.fail(w, "unbound commit fallback")
			return
		}
	case strings.HasPrefix(r.URL.Path, pull):
		n, e := strconv.Atoi(strings.TrimPrefix(r.URL.Path, pull))
		if e != nil || n <= 0 {
			g.fail(w, "unbound pull diff")
			return
		}
	}
	p, e := g.fetch(r, r.URL, nil)
	if e != nil || p.code != 200 {
		if strings.HasPrefix(r.URL.Path, compare) && !g.mutationStarted {
			g.diffPending = true
			http.Error(w, "Compare unavailable; bound fallback required", 502)
			return
		}
		g.fail(w, "diff read failed")
		return
	}
	text := strings.TrimSpace(string(p.body))
	if text != "" && !strings.HasPrefix(text, "diff --git ") {
		g.fail(w, "malformed diff evidence")
		return
	}
	if strings.HasPrefix(r.URL.Path, commit) {
		g.diffPending = false
	}
	writeResponse(w, p)
}
func (g *guard) mutate(w http.ResponseWriter, r *http.Request, prefix string) {
	b, e := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if e != nil || len(b) > 1<<20 {
		g.fail(w, "mutation body incomplete")
		return
	}
	v, e := decode(b)
	m, ok := v.(map[string]any)
	if e != nil || !ok {
		g.fail(w, "malformed mutation body")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, prefix+"/")
	number := 0
	kind := ""
	switch {
	case path == "issues" && r.Method == "POST":
		title, ok := m["title"].(string)
		if !ok || !g.searches[title] || !issuePayload(m) {
			g.fail(w, "creation lacks complete duplicate evidence")
			return
		}
		kind = "create"
		g.searches[title] = false
	case path == "milestones" && r.Method == "POST":
		title, ok := m["title"].(string)
		if !ok || title == "" || len(m) != 1 {
			g.fail(w, "unbound milestone creation")
			return
		}
		kind = "milestone"
	default:
		segments := strings.Split(path, "/")
		if len(segments) < 2 || segments[0] != "issues" {
			g.fail(w, "unexpected mutation route")
			return
		}
		number, e = strconv.Atoi(segments[1])
		if e != nil || number <= 0 {
			g.fail(w, "invalid issue number")
			return
		}
		if len(segments) == 3 && segments[2] == "comments" && r.Method == "POST" {
			body, ok := m["body"].(string)
			if !ok || body == "" || len(m) != 1 || (body == "Closed in "+g.cfg.SHA+"." && !g.closed[number]) {
				g.fail(w, "comment lacks completed closure")
				return
			}
			kind = "comment"
		} else if len(segments) == 2 && r.Method == "PATCH" && m["state"] == "closed" {
			if len(m) != 1 {
				g.fail(w, "unbound closure payload")
				return
			}
			if !g.issues[number] && !g.linkedIssue(r, number) {
				g.fail(w, "closure lacks complete issue evidence")
				return
			}
			kind = "close"
		} else if len(segments) == 2 && r.Method == "PATCH" && issuePayload(m) {
			if !g.issues[number] && !g.linkedIssue(r, number) {
				g.fail(w, "linked issue read failed")
				return
			}
			kind = "update"
		} else {
			g.fail(w, "unbound issue mutation")
			return
		}
	}
	g.mutationStarted = true
	p, e := g.fetch(r, r.URL, b)
	want := 201
	if r.Method == "PATCH" {
		want = 200
	}
	if e != nil || p.code != want {
		g.fail(w, kind+" operation failed")
		return
	}
	v, e = decode(p.body)
	result, ok := v.(map[string]any)
	if e != nil || !ok {
		g.fail(w, kind+" response incomplete")
		return
	}
	key := "number"
	if kind == "comment" {
		key = "id"
	}
	n, valid := integer(result[key])
	if !valid || n <= 0 || (number > 0 && kind != "comment" && n != number) || (kind == "close" && result["state"] != "closed") {
		g.fail(w, kind+" result unverified")
		return
	}
	if kind == "close" {
		g.closed[number] = true
		delete(g.issues, number)
	}
	if kind == "create" || kind == "update" {
		g.issues[n] = true
		g.titles[n] = m["title"].(string)
	}
	writeResponse(w, p)
}
func issuePayload(m map[string]any) bool {
	title, ok := m["title"].(string)
	body, okBody := m["body"].(string)
	labels, okLabels := m["labels"].([]any)
	assignees, okAssignees := m["assignees"].([]any)
	if !ok || title == "" || !okBody || body == "" || !okLabels || !okAssignees {
		return false
	}
	for k := range m {
		if k != "title" && k != "body" && k != "labels" && k != "assignees" && k != "milestone" {
			return false
		}
	}
	for _, a := range append(labels, assignees...) {
		if s, ok := a.(string); !ok || s == "" {
			return false
		}
	}
	if x, ok := m["milestone"]; ok {
		if n, ok := integer(x); !ok || n <= 0 {
			return false
		}
	}
	return true
}
func integer(x any) (int, bool) {
	n, ok := x.(json.Number)
	if !ok {
		return 0, false
	}
	i, e := strconv.ParseInt(string(n), 10, 64)
	return int(i), e == nil
}
func decode(b []byte) (any, error) {
	// Reject duplicate keys before normal unmarshalling, including nested documents.
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	if e := uniqueValue(d); e != nil {
		return nil, e
	}
	if _, e := d.Token(); e != io.EOF {
		return nil, errors.New("trailing JSON")
	}
	d = json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	e := d.Decode(&v)
	return v, e
}
func uniqueValue(d *json.Decoder) error {
	tok, e := d.Token()
	if e != nil {
		return e
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for d.More() {
			k, e := d.Token()
			s, ok := k.(string)
			if e != nil || !ok || seen[s] {
				return errors.New("duplicate or invalid JSON key")
			}
			seen[s] = true
			if e := uniqueValue(d); e != nil {
				return e
			}
		}
		end, e := d.Token()
		if e != nil || end != json.Delim('}') {
			return errors.New("incomplete JSON object")
		}
	case '[':
		for d.More() {
			if e := uniqueValue(d); e != nil {
				return e
			}
		}
		end, e := d.Token()
		if e != nil || end != json.Delim(']') {
			return errors.New("incomplete JSON array")
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	return nil
}

func ambiguousPath(path string) bool {
	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return true
		}
	}
	return false
}

// Explicit source links can target closed issues; verify them independently of the open inventory.
func (g *guard) linkedIssue(r *http.Request, number int) bool {
	target := &url.URL{Path: "/repos/" + g.cfg.Repository + "/issues/" + strconv.Itoa(number)}
	read := r.Clone(r.Context())
	read.Method = "GET"
	p, e := g.fetch(read, target, nil)
	if e != nil || p.code != 200 {
		return false
	}
	v, e := decode(p.body)
	m, ok := v.(map[string]any)
	if e != nil || !ok {
		return false
	}
	n, ok := integer(m["number"])
	return ok && n == number && m["html_url"] == strings.TrimSuffix(g.cfg.Server, "/")+"/"+g.cfg.Repository+"/issues/"+strconv.Itoa(number) && (m["state"] == "open" || m["state"] == "closed") && m["pull_request"] == nil
}
