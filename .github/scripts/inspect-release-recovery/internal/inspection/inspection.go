// inspect-release-recovery diagnoses one interrupted public GitHub-only release.
// It has no publication operation, write request, or configurable production API.
package inspection

import (
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime"
	"net/http"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const apiURL = "https://api.github.com"
const maxResponse = 1 << 20

var (
	repositoryPattern = regexp.MustCompile(`^devantler-tech/[A-Za-z0-9_.-]{1,100}$`)
	tagPattern        = regexp.MustCompile(`^v(0|[1-9][0-9]{0,14})\.(0|[1-9][0-9]{0,14})\.(0|[1-9][0-9]{0,14})$`)
	shaPattern        = regexp.MustCompile(`^[0-9a-f]{40}$`)
	producerPattern   = regexp.MustCompile(`^devantler-tech/(\.github|actions)/\.github/workflows/create-release\.yaml@[0-9a-f]{40}$`)
	workflowPattern   = regexp.MustCompile(`^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.ya?ml$`)
)

type input struct{ Repository, Tag, SourceSHA, RunID, RunAttempt, ProducerRef string }
type inspector struct {
	client *http.Client
	base   string
}

// newInspector bounds requests and prevents redirects, ambient proxies and credential forwarding.
func newInspector(client *http.Client, base string) *inspector {
	return &inspector{client: HardenedClient(client), base: base}
}

// HardenedClient copies a client with a bounded timeout, no redirects and, by default,
// a proxy-free transport, so a credential is only ever sent to the fixed origin.
func HardenedClient(client *http.Client) *http.Client {
	copyClient := http.Client{Timeout: 15 * time.Second}
	if client != nil {
		copyClient = *client
	}
	if copyClient.Timeout <= 0 || copyClient.Timeout > 15*time.Second {
		copyClient.Timeout = 15 * time.Second
	}
	copyClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if copyClient.Transport == nil {
		copyClient.Transport = &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: 10 * time.Second,
			TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}}
	}
	return &copyClient
}

// positive accepts canonical positive identifiers without overflow or alternate encodings.
func positive(value string) bool {
	n, err := strconv.ParseUint(value, 10, 64)
	return err == nil && n > 0 && strconv.FormatUint(n, 10) == value
}

// parse rejects ambiguous incident identities before any credential-bearing request.
func parse(args []string, token string) (input, error) {
	var in input
	flags := flag.NewFlagSet("inspect-release-recovery", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	seen := map[string]bool{}
	for _, argument := range args {
		if !strings.HasPrefix(argument, "-") {
			continue
		}
		name := strings.SplitN(strings.TrimLeft(argument, "-"), "=", 2)[0]
		if seen[name] {
			return in, errors.New("repeated incident flags are ambiguous")
		}
		seen[name] = true
	}
	for name, target := range map[string]*string{"repository": &in.Repository, "tag": &in.Tag,
		"source-sha": &in.SourceSHA, "run-id": &in.RunID, "run-attempt": &in.RunAttempt, "producer-ref": &in.ProducerRef} {
		flags.StringVar(target, name, "", "required incident identity")
	}
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return in, errors.New("expected exactly the documented incident flags")
	}
	name := strings.TrimPrefix(in.Repository, "devantler-tech/")
	if !repositoryPattern.MatchString(in.Repository) || name == "." || name == ".." ||
		!tagPattern.MatchString(in.Tag) || !shaPattern.MatchString(in.SourceSHA) ||
		!positive(in.RunID) || !positive(in.RunAttempt) || !producerPattern.MatchString(in.ProducerRef) {
		return in, errors.New("invalid repository, stable tag, source, run, attempt or immutable producer")
	}
	if token == "" || len(token) > 4096 || strings.IndexFunc(token, func(r rune) bool { return r <= 32 || r >= 127 }) >= 0 {
		return in, errors.New("a non-empty GH_TOKEN without whitespace is required")
	}
	return in, nil
}

// Decode exactly one bounded JSON value, rejecting duplicate keys at every depth.
func strictJSON(raw []byte) (any, error) {
	if !utf8.Valid(raw) {
		return nil, errors.New("JSON is not valid UTF-8")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var read func(int) (any, error)
	read = func(depth int) (any, error) {
		if depth > 64 {
			return nil, errors.New("JSON nesting exceeds the limit")
		}
		token, err := d.Token()
		if err != nil {
			return nil, err
		}
		delim, compound := token.(json.Delim)
		if !compound {
			return token, nil
		}
		if delim == '{' {
			object := map[string]any{}
			for d.More() {
				key, err := d.Token()
				if err != nil {
					return nil, err
				}
				name, ok := key.(string)
				if !ok {
					return nil, errors.New("invalid object key")
				}
				if _, duplicate := object[name]; duplicate {
					return nil, errors.New("duplicate object key")
				}
				value, err := read(depth + 1)
				if err != nil {
					return nil, err
				}
				object[name] = value
			}
			if end, err := d.Token(); err != nil || end != json.Delim('}') {
				return nil, errors.New("incomplete object")
			}
			return object, nil
		}
		if delim != '[' {
			return nil, errors.New("unexpected JSON delimiter")
		}
		array := []any{}
		for d.More() {
			value, err := read(depth + 1)
			if err != nil {
				return nil, err
			}
			array = append(array, value)
		}
		if end, err := d.Token(); err != nil || end != json.Delim(']') {
			return nil, errors.New("incomplete array")
		}
		return array, nil
	}
	value, err := read(0)
	if err != nil {
		return nil, err
	}
	if _, err := d.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("expected one JSON document")
	}
	return value, nil
}

// object leaves a wrong JSON type absent so identity checks fail closed.
func object(value any) map[string]any { result, _ := value.(map[string]any); return result }

// text never coerces numbers or compound JSON into identity strings.
func text(value any) string { result, _ := value.(string); return result }

// equalFields requires exact types and values for every security-relevant field.
func equalFields(value map[string]any, expected map[string]any) bool {
	for key, want := range expected {
		if !reflect.DeepEqual(value[key], want) {
			return false
		}
	}
	return value != nil
}

// onlyKeys confines supported configuration to explicitly reviewed properties.
func onlyKeys(value map[string]any, names ...string) bool {
	if value == nil {
		return false
	}
	for key := range value {
		found := false
		for _, name := range names {
			found = found || key == name
		}
		if !found {
			return false
		}
	}
	return true
}

// selected retains stable evidence while excluding unrelated, mutable API metadata.
func selected(value map[string]any, names ...string) map[string]any {
	result := map[string]any{}
	for _, name := range names {
		result[name] = value[name]
	}
	return result
}

// get performs one bounded read; a documented missing publication is the sole optional absence.
func (i *inspector) get(ctx context.Context, path, token string, missing bool) (any, bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, i.base+path, nil)
	if err != nil {
		return nil, false, errors.New("invalid fixed API request")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	response, err := i.client.Do(request)
	if err != nil {
		return nil, false, errors.New("API request failed")
	}
	defer response.Body.Close()
	value, err := ReadJSONBody(response)
	if err != nil {
		return nil, false, err
	}
	if missing && response.StatusCode == http.StatusNotFound && object(value)["message"] == "Not Found" {
		return value, false, nil
	}
	if response.StatusCode != http.StatusOK {
		return nil, false, errors.New("API read did not return the required success status")
	}
	return value, true, nil
}

// Only the observed main-branch JSON contracts are supported. Nothing is executed.
func configSupported(value any, branch string) bool {
	root := object(value)
	if !onlyKeys(root, "branches", "plugins") || !reflect.DeepEqual(root["branches"], []any{branch}) {
		return false
	}
	plugins, ok := root["plugins"].([]any)
	if !ok || len(plugins) != 3 {
		return false
	}
	for index, name := range []string{"@semantic-release/commit-analyzer", "@semantic-release/release-notes-generator", "@semantic-release/github"} {
		entry := plugins[index]
		options := map[string]any{}
		if pair, ok := entry.([]any); ok && len(pair) == 2 {
			entry, options = pair[0], object(pair[1])
		}
		if entry != name || options == nil {
			return false
		}
		if index == 2 {
			if len(options) != 0 {
				return false
			}
			continue
		}
		keys := []string{"parserOpts"}
		if index == 0 {
			keys = append(keys, "releaseRules")
		}
		if !onlyKeys(options, keys...) {
			return false
		}
		if parser, exists := options["parserOpts"]; exists {
			if !equalFields(object(parser), map[string]any{"breakingHeaderPattern": `^(\w*)(?:\((.*)\))?!: (.*)$`}) ||
				!onlyKeys(object(parser), "breakingHeaderPattern") {
				return false
			}
		}
		if value, exists := options["releaseRules"]; exists {
			rules, ok := value.([]any)
			if !ok || len(rules) == 0 || len(rules) > 2 {
				return false
			}
			seen := map[string]bool{}
			for _, rule := range rules {
				kind := ""
				if equalFields(object(rule), map[string]any{"breaking": true, "release": "major"}) && onlyKeys(object(rule), "breaking", "release") {
					kind = "breaking"
				}
				if equalFields(object(rule), map[string]any{"type": "revert", "release": "patch"}) && onlyKeys(object(rule), "type", "release") {
					kind = "revert"
				}
				if kind == "" || seen[kind] {
					return false
				}
				seen[kind] = true
			}
		}
	}
	return true
}

// snapshot binds one observation to the original run, tag, source files and published release.
func (i *inspector) snapshot(ctx context.Context, in input, token string) (map[string]any, error) {
	result := map[string]any{}
	prefix := "/repos/" + in.Repository
	read := func(path string) (any, error) {
		value, _, err := i.get(ctx, prefix+path, token, false)
		return value, err
	}
	value, err := read("")
	if err != nil {
		return nil, fmt.Errorf("repository: %w", err)
	}
	repo := object(value)
	id, ok := repo["id"].(json.Number)
	branch := text(repo["default_branch"])
	if !ok || !positive(string(id)) || branch == "" || !equalFields(repo, map[string]any{
		"name": strings.TrimPrefix(in.Repository, "devantler-tech/"), "full_name": in.Repository,
		"visibility": "public", "private": false, "archived": false, "disabled": false}) || object(repo["owner"])["login"] != "devantler-tech" {
		return nil, errors.New("repository must be public, active and exactly identified")
	}
	result["repository"] = selected(repo, "id", "name", "full_name", "visibility", "private", "archived", "disabled", "default_branch")
	value, err = read("/actions/runs/" + in.RunID + "/attempts/" + in.RunAttempt)
	if err != nil {
		return nil, fmt.Errorf("original run: %w", err)
	}
	run := object(value)
	workflow, revision, qualified := strings.Cut(text(run["path"]), "@")
	// The API documents path@ref as well as the bare path observed on older runs.
	// A qualified path must independently agree with the already captured run identity.
	matchingRevision := !qualified || revision == branch || revision == "refs/heads/"+branch || revision == in.SourceSHA
	if !equalFields(run, map[string]any{"id": json.Number(in.RunID), "run_attempt": json.Number(in.RunAttempt),
		"event": "push", "status": "completed", "conclusion": "failure", "head_sha": in.SourceSHA, "head_branch": branch}) ||
		!workflowPattern.MatchString(workflow) || !matchingRevision {
		return nil, errors.New("original failed default-branch push identity does not match")
	}
	for _, key := range []string{"repository", "head_repository"} {
		if !equalFields(object(run[key]), map[string]any{"id": id, "full_name": in.Repository, "private": false}) {
			return nil, errors.New("original run repository identity does not match")
		}
	}
	refs, ok := run["referenced_workflows"].([]any)
	if !ok || len(refs) != 1 {
		return nil, errors.New("original run must identify exactly the expected immutable release producer")
	}
	producer := object(refs[0])
	expectedPath, expectedSHA, _ := strings.Cut(in.ProducerRef, "@")
	producerPath, producerRevision, qualified := strings.Cut(text(producer["path"]), "@")
	producerRef := text(producer["ref"])
	// Branch/tag paths are historical API metadata; the separate resolved SHA binds
	// the producer's immutable code. Never substitute the branch for that SHA.
	matchingProducerRef := producerRevision == expectedSHA ||
		(strings.HasPrefix(producerRef, "refs/heads/") || strings.HasPrefix(producerRef, "refs/tags/")) &&
			(producerRef == producerRevision || producerRef == "refs/heads/"+producerRevision || producerRef == "refs/tags/"+producerRevision)
	if !qualified || producerRevision == "" || producerPath != expectedPath || producer["sha"] != expectedSHA || !matchingProducerRef {
		return nil, errors.New("original run must identify exactly the expected immutable release producer")
	}
	result["run"] = selected(run, "id", "run_attempt", "event", "status", "conclusion", "head_sha", "head_branch", "path", "referenced_workflows")
	value, err = read("/git/ref/tags/" + in.Tag)
	if err != nil {
		return nil, fmt.Errorf("tag: %w", err)
	}
	tag := object(value)
	if tag["ref"] != "refs/tags/"+in.Tag {
		return nil, errors.New("tag ref does not match")
	}
	target := object(tag["object"])
	if !shaPattern.MatchString(text(target["sha"])) {
		return nil, errors.New("tag target is missing or malformed")
	}
	result["tag"] = selected(tag, "ref", "object")
	if target["type"] == "tag" {
		value, err = read("/git/tags/" + text(target["sha"]))
		if err != nil {
			return nil, fmt.Errorf("annotated tag: %w", err)
		}
		annotation := object(value)
		if annotation["sha"] != target["sha"] || annotation["tag"] != in.Tag {
			return nil, errors.New("annotated tag identity does not match")
		}
		result["annotation"] = selected(annotation, "sha", "tag", "object")
		target = object(annotation["object"])
	}
	if !equalFields(target, map[string]any{"type": "commit", "sha": in.SourceSHA}) {
		return nil, errors.New("tag does not resolve directly to the captured source")
	}
	value, err = read("/git/commits/" + in.SourceSHA)
	if err != nil {
		return nil, fmt.Errorf("source commit: %w", err)
	}
	commit := object(value)
	treeSHA := text(object(commit["tree"])["sha"])
	if commit["sha"] != in.SourceSHA || !shaPattern.MatchString(treeSHA) {
		return nil, errors.New("source commit or root tree identity does not match")
	}
	value, err = read("/git/trees/" + treeSHA)
	if err != nil {
		return nil, fmt.Errorf("source config inventory: %w", err)
	}
	tree := object(value)
	entries, ok := tree["tree"].([]any)
	if !ok || len(entries) == 0 || tree["sha"] != treeSHA || tree["truncated"] != false {
		return nil, errors.New("source config inventory is incomplete")
	}
	result["source_tree"] = treeSHA
	files := map[string]any{}
	seen := map[string]bool{}
	for _, entry := range entries {
		file := object(entry)
		name := text(file["path"])
		if name == "" || strings.Contains(name, "/") || seen[name] {
			return nil, errors.New("source config inventory has ambiguous identities")
		}
		seen[name] = true
		if strings.HasPrefix(name, ".releaserc") && name != ".releaserc" || strings.HasPrefix(name, "release.config.") {
			return nil, errors.New("alternate release configuration is unsupported")
		}
		if name != ".releaserc" && name != "package.json" {
			continue
		}
		if file["type"] != "blob" || file["mode"] != "100644" && file["mode"] != "100755" || !shaPattern.MatchString(text(file["sha"])) {
			return nil, errors.New("source configuration must be regular immutable files")
		}
		files[name] = selected(file, "path", "type", "mode", "sha")
	}
	if files[".releaserc"] == nil {
		return nil, errors.New("source has no supported JSON .releaserc")
	}
	result["files"] = files
	for _, name := range []string{".releaserc", "package.json"} {
		if files[name] == nil {
			continue
		}
		value, err = read("/contents/" + name + "?ref=" + in.SourceSHA)
		if err != nil {
			return nil, fmt.Errorf("source config: %w", err)
		}
		file := object(value)
		if !equalFields(file, map[string]any{"type": "file", "path": name, "encoding": "base64", "sha": object(files[name])["sha"]}) {
			return nil, errors.New("source configuration identity does not match inventory")
		}
		content, err := base64.StdEncoding.DecodeString(text(file["content"]))
		if err != nil || len(content) == 0 || len(content) > 65536 || file["size"] != json.Number(strconv.Itoa(len(content))) {
			return nil, errors.New("source configuration is incomplete or oversized")
		}
		// Git's SHA-1 object ID binds these bytes to the admitted commit's tree.
		// This follows Git's object format, not a signature or independent trust
		// decision; the authenticated fixed-origin API supplies the evidence.
		blob := append([]byte(fmt.Sprintf("blob %d%c", len(content), 0)), content...)
		if fmt.Sprintf("%x", sha1.Sum(blob)) != file["sha"] {
			return nil, errors.New("source configuration bytes do not match the captured Git blob")
		}
		parsed, err := strictJSON(content)
		if err != nil {
			return nil, errors.New("source configuration is malformed or ambiguous JSON")
		}
		if name == ".releaserc" && !configSupported(parsed, branch) {
			return nil, errors.New("source configuration is not supported GitHub-only JSON")
		}
		if name == "package.json" {
			if object(parsed) == nil {
				return nil, errors.New("package configuration is not an object")
			}
			if _, exists := object(parsed)["release"]; exists {
				return nil, errors.New("package release configuration is unsupported")
			}
		}
		result[name] = parsed
	}
	value, present, err := i.get(ctx, prefix+"/releases/tags/"+in.Tag, token, true)
	if err != nil {
		return nil, fmt.Errorf("publication: %w", err)
	}
	result["publication"] = "missing"
	if present {
		release := object(value)
		releaseID, ok := release["id"].(json.Number)
		_, dateError := time.Parse(time.RFC3339, text(release["published_at"]))
		// semantic-release records the branch here. The existing tag, verified
		// above on both passes, remains the authority for the original source.
		commitish := text(release["target_commitish"])
		if !ok || !positive(string(releaseID)) || dateError != nil || !equalFields(release, map[string]any{
			"tag_name": in.Tag, "draft": false, "prerelease": false}) ||
			commitish != in.SourceSHA && commitish != branch {
			return nil, errors.New("existing release is not a matching published stable source")
		}
		result["publication"] = selected(release, "id", "tag_name", "target_commitish", "draft", "prerelease", "published_at")
	}
	return result, nil
}

// Admission is one incident identity that two complete, agreeing observations confirmed.
// It carries no credential and grants no authority; a writer must still prove its own.
type Admission struct {
	Repository, Tag, SourceSHA, RunID, RunAttempt, ProducerRef, DefaultBranch string
	// Published reports a matching published stable release for the tag.
	Published bool
	identity  map[string]any
}

// SameIdentity reports whether two admissions observed the same repository, run, tag,
// source and configuration. Publication state is deliberately excluded.
func (a *Admission) SameIdentity(other *Admission) bool {
	return a != nil && other != nil && a.identity != nil && reflect.DeepEqual(a.identity, other.identity)
}

// admit validates the incident flags, then requires two complete observations to agree.
func (i *inspector) admit(ctx context.Context, args []string, token string) (*Admission, error) {
	in, err := parse(args, token)
	if err != nil {
		return nil, err
	}
	first, err := i.snapshot(ctx, in, token)
	if err != nil {
		return nil, err
	}
	second, err := i.snapshot(ctx, in, token)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(first, second) {
		return nil, errors.New("relevant observations changed between independent reads")
	}
	identity := map[string]any{}
	for key, value := range first {
		if key != "publication" {
			identity[key] = value
		}
	}
	return &Admission{Repository: in.Repository, Tag: in.Tag, SourceSHA: in.SourceSHA, RunID: in.RunID,
		RunAttempt: in.RunAttempt, ProducerRef: in.ProducerRef,
		DefaultBranch: text(object(first["repository"])["default_branch"]),
		Published:     first["publication"] != "missing", identity: identity}, nil
}

// Reader gives a separate publisher the inspector's GET-only admission and bounded reads.
// It has no write operation.
type Reader struct{ inspector *inspector }

// NewReader returns a GET-only reader bound to one fixed API origin.
func NewReader(client *http.Client, base string) *Reader {
	return &Reader{inspector: newInspector(client, base)}
}

// Admit runs the inspector's full admission with the supplied credential.
func (r *Reader) Admit(ctx context.Context, args []string, token string) (*Admission, error) {
	return r.inspector.admit(ctx, args, token)
}

// Get performs one bounded GET. When missing is true, a documented 404 is reported as absent.
func (r *Reader) Get(ctx context.Context, path, token string, missing bool) (any, bool, error) {
	return r.inspector.get(ctx, path, token, missing)
}

// ReadJSONBody reads one bounded JSON response body and rejects non-JSON media types,
// oversized bodies and ambiguous JSON. It does not judge the status code.
func ReadJSONBody(response *http.Response) (any, error) {
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponse+1))
	if err != nil || len(raw) > maxResponse {
		return nil, errors.New("incomplete or oversized API response")
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" && mediaType != "application/vnd.github+json" {
		return nil, errors.New("API response is not JSON")
	}
	value, err := strictJSON(raw)
	if err != nil {
		return nil, errors.New("malformed or ambiguous API JSON")
	}
	return value, nil
}

// PositiveID returns a JSON number's canonical decimal form when it is a positive identifier.
func PositiveID(value any) (string, bool) {
	number, ok := value.(json.Number)
	return string(number), ok && positive(string(number))
}

// run emits a diagnosis only after two complete observations agree; it never authorizes writes.
func run(args []string, token string, out io.Writer, service *inspector) error {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	in, err := service.admit(ctx, args, token)
	if err != nil {
		return err
	}
	diagnosis := "github-release-present"
	if !in.Published {
		diagnosis = "missing-github-release"
	}
	raw, err := json.Marshal(map[string]any{"diagnosis": diagnosis, "repository": in.Repository, "tag": in.Tag,
		"source_sha": in.SourceSHA, "run_id": in.RunID, "run_attempt": in.RunAttempt, "producer_ref": in.ProducerRef,
		"authorization": "none", "channel_metadata": "not-inspected", "publication_success": false,
		"publication_scope": "published-release-by-tag", "draft_inventory": "not-inspected"})
	if err != nil {
		return errors.New("could not encode diagnosis")
	}
	_, err = out.Write(append(raw, '\n'))
	return err
}

// Run executes the unchanged read-only command using the fixed production API.
func Run(args []string, token string, out io.Writer) error {
	return run(args, token, out, newInspector(nil, apiURL))
}
