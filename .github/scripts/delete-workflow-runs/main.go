// Cleanup keeps the workflow interface's age, minimum-run and orphan policy.
// All enumeration completes before mutation. A failed DELETE is never replayed.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type config struct {
	repository                   string
	days                         float64
	minimum                      int
	dryRun                       bool
	pattern, states, conclusions string
}

var repositoryName = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

// parseConfig validates caller inputs and supplies the reusable workflow's defaults.
func parseConfig(get func(string) string) (config, error) {
	value := func(key, fallback string) string {
		if v := get(key); v != "" {
			return v
		}
		return fallback
	}
	cfg := config{repository: value("INPUT_REPOSITORY", get("GITHUB_REPOSITORY")), pattern: get("INPUT_DELETE_WORKFLOW_PATTERN"), states: value("INPUT_DELETE_WORKFLOW_BY_STATE_PATTERN", "ALL"), conclusions: value("INPUT_DELETE_RUN_BY_CONCLUSION_PATTERN", "ALL")}
	if !repositoryName.MatchString(cfg.repository) {
		return cfg, errors.New("repository must be owner/repository")
	}
	var err error
	cfg.days, err = strconv.ParseFloat(value("INPUT_RETAIN_DAYS", "30"), 64)
	if err != nil || math.IsNaN(cfg.days) || math.IsInf(cfg.days, 0) || cfg.days < 0 {
		return cfg, errors.New("days must be a finite nonnegative number")
	}
	minimum, err := strconv.ParseFloat(value("INPUT_KEEP_MINIMUM_RUNS", "6"), 64)
	if err != nil || math.IsNaN(minimum) || math.IsInf(minimum, 0) || minimum < 0 || minimum != math.Trunc(minimum) || minimum >= float64(int(^uint(0)>>1)) {
		return cfg, errors.New("minimum-runs must be a representable nonnegative integer")
	}
	cfg.minimum = int(minimum)
	switch value("INPUT_DRY_RUN", "true") {
	case "true":
		cfg.dryRun = true
	case "false":
		cfg.dryRun = false
	default:
		return cfg, errors.New("dry-run must be true or false")
	}
	return cfg, nil
}

type workflow struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Path  string `json:"path"`
	State string `json:"state"`
}
type workflowRun struct {
	ID         int64  `json:"id"`
	WorkflowID int64  `json:"workflow_id"`
	CreatedAt  string `json:"created_at"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
}

// Reject ambiguous JSON before decoding can silently discard earlier field values.
func unambiguous(raw []byte) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	var consume func(int) error
	consume = func(depth int) error {
		if depth > 100 {
			return errors.New("JSON nesting exceeds limit")
		}
		t, err := d.Token()
		if err != nil {
			return err
		}
		delimiter, ok := t.(json.Delim)
		if !ok {
			return nil
		}
		keys := map[string]bool{}
		for d.More() {
			if delimiter == '{' {
				key, err := d.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				if !ok || keys[name] {
					return errors.New("duplicate JSON key")
				}
				keys[name] = true
			}
			if err := consume(depth + 1); err != nil {
				return err
			}
		}
		_, err = d.Token()
		return err
	}
	if err := consume(0); err != nil {
		return err
	}
	if _, err := d.Token(); !errors.Is(err, io.EOF) {
		return errors.New("expected one JSON document")
	}
	return nil
}

type api struct {
	base, token string
	client      *http.Client
	wait        func(context.Context, time.Duration) error
}

type httpFailure struct{ status int }

// Error reports an HTTP failure without exposing its response body or credentials.
func (e httpFailure) Error() string { return fmt.Sprintf("HTTP %d", e.status) }

// request confirms complete responses, retries transient reads and never retries writes.
func (a api) request(ctx context.Context, method, path string) ([]byte, error) {
	// Copy the client: redirects cannot forward credentials or change the target.
	client := *a.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if client.Timeout == 0 {
		client.Timeout = 30 * time.Second
	}
	for attempt := 0; attempt < 3; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, a.base+path, nil)
		if err != nil {
			return nil, errors.New("invalid API request")
		}
		req.Header.Set("Authorization", "Bearer "+a.token)
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		response, err := client.Do(req)
		if err == nil {
			raw, readErr := io.ReadAll(io.LimitReader(response.Body, (16<<20)+1))
			closeErr := response.Body.Close()
			if readErr != nil || closeErr != nil || len(raw) > 16<<20 {
				return nil, errors.New("incomplete or oversized API response")
			}
			if response.StatusCode >= 200 && response.StatusCode < 300 {
				if method == "GET" && response.StatusCode != http.StatusOK {
					return nil, errors.New("listing was not confirmed with HTTP 200")
				}
				if method == "DELETE" && response.StatusCode != http.StatusNoContent {
					return nil, errors.New("deletion was not confirmed with HTTP 204")
				}
				return raw, nil
			}
			err = httpFailure{response.StatusCode}
			if response.StatusCode < 500 || response.StatusCode > 599 || method != "GET" {
				return raw, err
			}
		}
		if method != "GET" || attempt == 2 || ctx.Err() != nil {
			return nil, errors.New("API request failed or outcome is unknown")
		}
		if err := a.wait(ctx, time.Duration(2<<attempt)*time.Second); err != nil {
			return nil, err
		}
	}
	return nil, errors.New("API request failed")
}

// workflowAbsent revalidates an orphan's parent after observing the run. Only a
// complete GitHub Not Found response proves absence; an existing parent is retained.
func (a api) workflowAbsent(ctx context.Context, prefix string, id int64) (bool, error) {
	raw, err := a.request(ctx, "GET", fmt.Sprintf("%s/actions/workflows/%d", prefix, id))
	if err != nil {
		var failure httpFailure
		if !errors.As(err, &failure) || failure.status != http.StatusNotFound {
			return false, err
		}
		if unambiguous(raw) != nil {
			return false, errors.New("unconfirmed workflow absence")
		}
		var response map[string]json.RawMessage
		if json.Unmarshal(raw, &response) != nil {
			return false, errors.New("invalid workflow absence response")
		}
		var message string
		if json.Unmarshal(response["message"], &message) != nil || message != "Not Found" {
			return false, errors.New("unconfirmed workflow absence")
		}
		return true, nil
	}
	var w workflow
	if unambiguous(raw) != nil || decodeItem(raw, []string{"id", "name", "path", "state"}, &w) != nil || w.ID != id || w.Name == "" || w.Path == "" || w.State == "" {
		return false, errors.New("invalid workflow revalidation")
	}
	return false, nil
}

var searchCapped = errors.New("run search reaches GitHub's 1,000-result limit")

// list requires stable totals, unique identities and complete item shapes on every page.
// Page one establishes the minimum page count; up to four required pages then
// overlap. Short pages continue sequentially until the declared total is met.
func (a api) list(ctx context.Context, path, key string) ([]json.RawMessage, error) {
	result := []json.RawMessage{}
	seen := map[int64]bool{}
	total := -1
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	appendPage := func(raw []byte) error {
		if err := unambiguous(raw); err != nil {
			return errors.New("ambiguous or incomplete listing JSON")
		}
		var document map[string]json.RawMessage
		if err := json.Unmarshal(raw, &document); err != nil {
			return errors.New("invalid listing object")
		}
		var count int
		if value := document["total_count"]; len(value) == 0 || string(value) == "null" {
			return errors.New("missing listing total")
		}
		if err := json.Unmarshal(document["total_count"], &count); err != nil || count < 0 {
			return errors.New("invalid listing total")
		}
		if total < 0 {
			total = count
		}
		if count != total {
			return errors.New("listing total changed between pages")
		}
		var items []json.RawMessage
		if value := document[key]; len(value) == 0 || string(value) == "null" {
			return errors.New("missing listing items")
		}
		if err := json.Unmarshal(document[key], &items); err != nil {
			return errors.New("invalid listing items")
		}
		if len(items) > 100 || len(result)+len(items) > total {
			return errors.New("listing count exceeds declared total")
		}
		if key == "workflow_runs" && strings.Contains(path, "?created=") && count >= 1000 {
			return searchCapped
		}
		for _, item := range items {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(item, &fields); err != nil {
				return errors.New("invalid listing item")
			}
			var id int64
			if err := json.Unmarshal(fields["id"], &id); err != nil || id <= 0 || seen[id] {
				return errors.New("invalid or repeated listing identity")
			}
			seen[id] = true
			result = append(result, item)
		}
		if len(items) == 0 && len(result) != total {
			return errors.New("listing ended before its declared total")
		}
		return nil
	}
	for page := 1; page <= 10000; {
		width := 1
		if total > 0 {
			minimumPages := (total-1)/100 + 1
			width = min(4, max(1, minimumPages-page+1), 10001-page)
		}
		bodies, failures := make([][]byte, width), make([]error, width)
		batch, cancel := context.WithCancel(ctx)
		var reads sync.WaitGroup
		for i := range width {
			reads.Add(1)
			go func(i int) {
				defer reads.Done()
				bodies[i], failures[i] = a.request(batch, "GET", fmt.Sprintf("%s%spage=%d&per_page=100", path, separator, page+i))
				if failures[i] != nil {
					cancel()
				}
			}(i)
		}
		// Join every read before returning or inspecting the next batch. Neither
		// a failed request nor cancellation can leave a background producer.
		reads.Wait()
		cancel()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		for i := range width {
			if failures[i] != nil {
				return nil, failures[i]
			}
			if err := appendPage(bodies[i]); err != nil {
				return nil, err
			}
			if len(result) == total {
				return result, nil
			}
		}
		page += width
	}
	return nil, errors.New("listing exceeds pagination limit")
}

// listRuns freezes creation time and splits capped searches into disjoint second
// ranges. New arrivals cannot shift pages; uncertain or overflowing ranges fail closed.
func (a api) listRuns(ctx context.Context, path string, now time.Time) ([]json.RawMessage, error) {
	upper := now.UTC().Truncate(time.Second).Add(-time.Second).Unix()
	if upper < 0 {
		return nil, errors.New("invalid run snapshot time")
	}
	result := []json.RawMessage{}
	seen := map[int64]bool{}
	partitions := 0
	var visit func(int64, int64) error
	visit = func(lower, upper int64) error {
		partitions++
		if partitions > 10000 {
			return errors.New("run search exceeds partition limit")
		}
		stamp := func(second int64) string { return time.Unix(second, 0).UTC().Format(time.RFC3339) }
		items, err := a.list(ctx, path+"?created="+url.QueryEscape(stamp(lower)+".."+stamp(upper)), "workflow_runs")
		if errors.Is(err, searchCapped) {
			if lower == upper {
				return errors.New("run search cannot prove completeness within one second")
			}
			middle := lower + (upper-lower)/2
			if err := visit(lower, middle); err != nil {
				return err
			}
			return visit(middle+1, upper)
		}
		if err != nil {
			return err
		}
		runs, err := decodeRuns(items)
		if err != nil {
			return err
		}
		for _, run := range runs {
			created, _ := time.Parse(time.RFC3339, run.CreatedAt)
			if created.Before(time.Unix(lower, 0)) || !created.Before(time.Unix(upper+1, 0)) || seen[run.ID] {
				return errors.New("run search returned an out-of-range or repeated identity")
			}
			seen[run.ID] = true
		}
		result = append(result, items...)
		return nil
	}
	if err := visit(0, upper); err != nil {
		return nil, err
	}
	return result, nil
}

// encoding/json accepts case-insensitive struct aliases. Reject those aliases so
// a second identity field cannot override the exact API field we validated.
func decodeItem(item json.RawMessage, required []string, destination any) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(item, &fields); err != nil {
		return err
	}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return errors.New("listing omitted a required field")
		}
		for name := range fields {
			if name != key && strings.EqualFold(name, key) {
				return errors.New("listing contains an ambiguous field alias")
			}
		}
	}
	return json.Unmarshal(item, destination)
}

// decodeRuns requires identities, status and creation time before applying retention.
func decodeRuns(items []json.RawMessage) ([]workflowRun, error) {
	result := []workflowRun{}
	for _, item := range items {
		var r workflowRun
		if err := decodeItem(item, []string{"id", "workflow_id", "created_at", "status", "conclusion"}, &r); err != nil || r.ID <= 0 || r.WorkflowID <= 0 || r.Status == "" {
			return nil, errors.New("invalid run listing")
		}
		if _, err := time.Parse(time.RFC3339, r.CreatedAt); err != nil {
			return nil, errors.New("run listing has an invalid creation time")
		}
		result = append(result, r)
	}
	return result, nil
}

// patterns normalizes the workflow interface's comma or pipe separated filters.
func patterns(raw string) []string {
	result := []string{}
	for _, part := range strings.FieldsFunc(raw, func(c rune) bool { return c == ',' || c == '|' }) {
		if s := strings.ToLower(strings.TrimSpace(part)); s != "" {
			result = append(result, s)
		}
	}
	return result
}

// allows matches an exact state or conclusion, with ALL as the wildcard.
func allows(raw, value string) bool {
	if strings.EqualFold(raw, "ALL") {
		return true
	}
	for _, candidate := range patterns(raw) {
		if candidate == strings.ToLower(value) {
			return true
		}
	}
	return false
}

// selected applies the caller's workflow name, filename and state filters.
func selected(cfg config, w workflow) bool {
	if !allows(cfg.states, w.State) {
		return false
	}
	filters := patterns(cfg.pattern)
	if len(filters) == 0 {
		return true
	}
	name, path := strings.ToLower(w.Name), strings.ToLower(strings.TrimPrefix(w.Path, ".github/workflows/"))
	for _, filter := range filters {
		if strings.Contains(name, filter) || strings.Contains(path, filter) {
			return true
		}
	}
	return false
}

// clean plans from complete reads, revalidates orphan parents and enacts each deletion once.
func clean(ctx context.Context, cfg config, base, token string, client *http.Client, now time.Time, out io.Writer, wait func(context.Context, time.Duration) error) error {
	if token == "" {
		return errors.New("cleanup token is missing")
	}
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "https" && !(u.Scheme == "http" && u.Hostname() == "127.0.0.1")) {
		return errors.New("invalid API base URL")
	}
	if !repositoryName.MatchString(cfg.repository) {
		return errors.New("invalid repository")
	}
	a := api{strings.TrimRight(base, "/"), token, client, wait}
	prefix := "/repos/" + cfg.repository
	items, err := a.list(ctx, prefix+"/actions/workflows", "workflows")
	if err != nil {
		return fmt.Errorf("list workflows: %w", err)
	}
	workflows := []workflow{}
	ids := map[int64]bool{}
	for _, item := range items {
		var w workflow
		if err := decodeItem(item, []string{"id", "name", "path", "state"}, &w); err != nil || w.ID <= 0 || w.Name == "" || w.Path == "" || w.State == "" {
			return errors.New("invalid workflow listing")
		}
		workflows = append(workflows, w)
		ids[w.ID] = true
	}
	items, err = a.listRuns(ctx, prefix+"/actions/runs", now)
	if err != nil {
		return fmt.Errorf("list repository runs: %w", err)
	}
	repositoryRuns, err := decodeRuns(items)
	if err != nil {
		return err
	}
	plan := []int64{}
	orphans := map[int64]int64{}
	runsByWorkflow := map[int64][]workflowRun{}
	planned := map[int64]bool{}
	appendRun := func(id int64) error {
		if planned[id] {
			return errors.New("deletion plan contains a repeated run")
		}
		planned[id] = true
		plan = append(plan, id)
		return nil
	}
	// Orphans retain the existing policy: a run with no listed workflow is selected independently of filters.
	for _, r := range repositoryRuns {
		if !ids[r.WorkflowID] {
			orphans[r.ID] = r.WorkflowID
			if err := appendRun(r.ID); err != nil {
				return err
			}
		} else {
			runsByWorkflow[r.WorkflowID] = append(runsByWorkflow[r.WorkflowID], r)
		}
	}
	for _, w := range workflows {
		if !selected(cfg, w) {
			continue
		}
		candidates := []workflowRun{}
		for _, r := range runsByWorkflow[w.ID] {
			created, _ := time.Parse(time.RFC3339, r.CreatedAt)
			if r.Status == "completed" && (len(patterns(cfg.conclusions)) == 0 || allows(cfg.conclusions, r.Conclusion)) && (cfg.days == 0 || now.Sub(created).Hours()/24 >= cfg.days) {
				candidates = append(candidates, r)
			}
		}
		sort.SliceStable(candidates, func(i, j int) bool {
			left, _ := time.Parse(time.RFC3339, candidates[i].CreatedAt)
			right, _ := time.Parse(time.RFC3339, candidates[j].CreatedAt)
			return left.Before(right)
		})
		count := len(candidates) - cfg.minimum
		if count < 0 {
			count = 0
		}
		for _, r := range candidates[:count] {
			if err := appendRun(r.ID); err != nil {
				return err
			}
		}
	}
	// A workflow can appear between the independent workflow and run listings.
	// Revalidate each orphan parent before any mutation, retaining live parents.
	absent, checked := map[int64]bool{}, map[int64]bool{}
	confirmed := []int64{}
	for _, id := range plan {
		if parent, orphan := orphans[id]; orphan {
			if !checked[parent] {
				missing, err := a.workflowAbsent(ctx, prefix, parent)
				if err != nil {
					return fmt.Errorf("revalidate orphan workflow: %w", err)
				}
				absent[parent], checked[parent] = missing, true
			}
			if !absent[parent] {
				continue
			}
		}
		confirmed = append(confirmed, id)
	}
	plan = confirmed
	deleted := 0
	for _, id := range plan {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if cfg.dryRun {
			if _, err := fmt.Fprintf(out, "Would delete run %d\n", id); err != nil {
				return err
			}
			continue
		}
		// Space confirmed writes to respect GitHub's secondary rate-limit guidance.
		if deleted > 0 {
			if err := a.wait(ctx, time.Second); err != nil {
				return err
			}
		}
		if _, err := a.request(ctx, "DELETE", fmt.Sprintf("%s/actions/runs/%d", prefix, id)); err != nil {
			return fmt.Errorf("delete run %d: %w", id, err)
		}
		deleted++
		if _, err := fmt.Fprintf(out, "Deleted run %d\n", id); err != nil {
			return err
		}
	}
	_, err = fmt.Fprintf(out, "Cleanup completed: selected=%d dry-run=%t\n", len(plan), cfg.dryRun)
	return err
}

// delay makes read backoff and mutation pacing interruptible by cancellation.
func delay(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// main runs cleanup with the caller token and returns a failing exit on any uncertainty.
func main() {
	cfg, err := parseConfig(os.Getenv)
	if err == nil {
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer stop()
		base := os.Getenv("GITHUB_API_URL")
		if base == "" {
			base = "https://api.github.com"
		}
		err = clean(ctx, cfg, base, os.Getenv("CLEANUP_TOKEN"), http.DefaultClient, time.Now(), os.Stdout, delay)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "Cleanup failed: %v\n", err)
		os.Exit(1)
	}
}
