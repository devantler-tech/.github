package main

import (
	"bytes"
	stdctx "context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

type object map[string]any
type auditor struct {
	root            string
	sources         map[string]object
	active          map[string]bool
	leaves, skipped int
	scope           int
}

var fullSHA = regexp.MustCompile("^[0-9a-f]{40}$")
var secretNames = regexp.MustCompile("(?i)\\bsecrets\\s*(?:\\.\\s*([a-z_][a-z0-9_-]*)|\\[\\s*['\"]([^'\"]+)['\"]\\s*\\])")
var secretWord = regexp.MustCompile("(?i)\\bsecrets\\b")
var statusOverride = regexp.MustCompile("(?i)\\b(always|success|failure|cancelled)\\s*\\(")
var validScopes = map[string]bool{"actions": true, "attestations": true, "checks": true, "contents": true, "deployments": true, "discussions": true, "id-token": true, "issues": true, "models": true, "packages": true, "pages": true, "pull-requests": true, "repository-projects": true, "security-events": true, "statuses": true, "code-quality": true}

// asObject preserves empty mappings while refusing scalar or sequence substitutions.
func asObject(v any) object {
	if x, ok := v.(object); ok {
		return x
	}
	if x, ok := v.(map[string]any); ok {
		return x
	}
	return nil
}

// text retrieves a scalar without inventing values for structured data.
func text(v any) string {
	if x, ok := v.(string); ok {
		return x
	}
	return ""
}

// names accepts the documented scalar-or-sequence form of job dependencies.
func names(v any) ([]string, error) {
	if v == nil {
		return nil, nil
	}
	if s, ok := v.(string); ok {
		return []string{s}, nil
	}
	if a, ok := v.([]any); ok {
		out := make([]string, len(a))
		for i, v := range a {
			s, ok := v.(string)
			if !ok {
				return nil, fmt.Errorf("UNKNOWN invalid needs")
			}
			out[i] = s
		}
		return out, nil
	}
	return nil, fmt.Errorf("UNKNOWN invalid needs")
}

// keys makes graph traversal and diagnostics deterministic.
func keys(m object) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// validateYAML rejects duplicate/merged/aliased keys before decoding can hide provenance.
func validateYAML(n *yaml.Node) error {
	if n.Kind == yaml.AliasNode || n.Tag == "!!merge" {
		return fmt.Errorf("UNKNOWN YAML aliases and merge keys are unsupported")
	}
	if n.Kind == yaml.MappingNode {
		seen := map[string]bool{}
		for i := 0; i < len(n.Content); i += 2 {
			k := n.Content[i]
			if k.Kind != yaml.ScalarNode || k.Tag != "!!str" || seen[k.Value] {
				return fmt.Errorf("UNKNOWN duplicate or non-string YAML key at line %d", k.Line)
			}
			seen[k.Value] = true
		}
	}
	for _, c := range n.Content {
		if err := validateYAML(c); err != nil {
			return err
		}
	}
	return nil
}

// decode requires one complete, unambiguous YAML document.
func decode(b []byte) (object, error) {
	d := yaml.NewDecoder(bytes.NewReader(b))
	var n yaml.Node
	if err := d.Decode(&n); err != nil {
		return nil, fmt.Errorf("UNKNOWN YAML read: %w", err)
	}
	if err := validateYAML(&n); err != nil {
		return nil, err
	}
	var extra yaml.Node
	if err := d.Decode(&extra); err != io.EOF {
		return nil, fmt.Errorf("UNKNOWN YAML has extra or invalid documents")
	}
	var v any
	if err := n.Decode(&v); err != nil {
		return nil, fmt.Errorf("UNKNOWN YAML decode: %w", err)
	}
	m := asObject(v)
	if m == nil {
		return nil, fmt.Errorf("UNKNOWN expected document mapping")
	}
	return m, nil
}

// safePath normalizes local catalogue references without permitting a checkout escape.
func safePath(path string) (string, error) {
	path = strings.TrimPrefix(path, "./")
	path = filepath.ToSlash(filepath.Clean(path))
	if path == "." || strings.HasPrefix(path, "../") || filepath.IsAbs(path) || strings.ContainsAny(path, "\\?#%:\r\n") {
		return "", fmt.Errorf("UNKNOWN source path outside catalogue")
	}
	return path, nil
}

// readSource resolves local bytes or a complete owned immutable Git blob, never a mutable fallback.
func (a *auditor) readSource(path, revision string) (object, error) {
	path, err := safePath(path)
	if err != nil {
		return nil, err
	}
	key := revision + ":" + path
	if m, ok := a.sources[key]; ok {
		return m, nil
	}
	var b []byte
	if revision == "" {
		var realRoot, realPath string
		realRoot, err = filepath.EvalSymlinks(a.root)
		if err == nil {
			realPath, err = filepath.EvalSymlinks(filepath.Join(a.root, path))
		}
		if err == nil {
			var relative string
			relative, err = filepath.Rel(realRoot, realPath)
			if err == nil && (relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || filepath.IsAbs(relative)) {
				err = fmt.Errorf("source symlink outside catalogue")
			}
		}
		if err == nil {
			b, err = os.ReadFile(realPath)
		}
	} else {
		if !fullSHA.MatchString(revision) {
			return nil, fmt.Errorf("UNKNOWN mutable first-party source")
		}
		cmd := exec.Command("git", "-C", a.root, "show", revision+":"+path)
		b, err = cmd.Output()
		if err != nil {
			if os.Getenv("CATALOGUE_CREDENTIALS_OFFLINE") == "1" {
				return nil, fmt.Errorf("UNKNOWN unavailable immutable source")
			}
			ctx, cancel := stdctx.WithTimeout(stdctx.Background(), 30*time.Second)
			defer cancel()
			cmd = exec.CommandContext(ctx, "gh", "api", "repos/devantler-tech/.github/contents/"+path+"?ref="+revision)
			var raw []byte
			raw, err = cmd.Output()
			if err == nil {
				var answer struct{ Path, SHA, Encoding, Content string }
				err = json.Unmarshal(raw, &answer)
				if err == nil {
					if answer.Path != path || answer.Encoding != "base64" || !fullSHA.MatchString(answer.SHA) {
						err = fmt.Errorf("immutable source identity mismatch")
					} else {
						b, err = base64.StdEncoding.DecodeString(strings.ReplaceAll(answer.Content, "\n", ""))
						if err == nil {
							blob := append([]byte(fmt.Sprintf("blob %d%c", len(b), 0)), b...)
							sum := sha1.Sum(blob)
							if fmt.Sprintf("%x", sum) != answer.SHA {
								err = fmt.Errorf("immutable blob hash mismatch")
							}
						}
					}
				}
			}
		}
	}
	if err != nil {
		return nil, fmt.Errorf("UNKNOWN cannot resolve %s: %w", key, err)
	}
	m, err := decode(b)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", key, err)
	}
	a.sources[key] = m
	return m, nil
}

// reference binds first-party sources to local same-commit bytes or an exact owned SHA.
func reference(ref string, revision string, action bool) (string, string, bool, error) {
	if strings.HasPrefix(ref, "./") {
		p, e := safePath(ref)
		if action {
			p += "/action.yaml"
		}
		return p, revision, true, e
	}
	parts := strings.Split(ref, "@")
	if len(parts) != 2 || !fullSHA.MatchString(parts[1]) {
		return "", "", false, fmt.Errorf("UNKNOWN unresolved or mutable source")
	}
	segments := strings.Split(parts[0], "/")
	if len(segments) < 2 {
		return "", "", false, fmt.Errorf("UNKNOWN invalid source repository")
	}
	if strings.EqualFold(strings.Join(segments[:2], "/"), "devantler-tech/.github") {
		if len(segments) == 2 {
			if action {
				return "action.yaml", parts[1], true, nil
			}
			return "", "", false, fmt.Errorf("UNKNOWN missing reusable workflow path")
		}
		p, e := safePath(strings.Join(segments[2:], "/"))
		if action {
			p += "/action.yaml"
		}
		return p, parts[1], true, e
	}
	if !action {
		return "", "", false, fmt.Errorf("UNKNOWN external reusable workflow source")
	}
	return "", "", false, nil
}

// clone keeps call-specific inputs and secrets from leaking into a sibling traversal.
func clone(c context) context {
	n := context{}
	for k, v := range c {
		n[k] = v
	}
	return n
}

// resolveScalar evaluates only complete expressions; ordinary values retain their original type.
func resolveScalar(v any, c context) any {
	s, ok := v.(string)
	if ok && strings.Contains(s, "$"+"{{") {
		trimmed := strings.TrimSpace(s)
		parts, err := expressionParts(trimmed)
		if err != nil || len(parts) != 1 || !strings.HasPrefix(trimmed, "$"+"{{") || !strings.HasSuffix(trimmed, "}}") {
			return uncertain
		}
		return evaluate(trimmed, c)
	}
	return v
}

// inputs applies declaration defaults and explicit call values without turning unknowns into empty strings.
func inputs(declarations, provided object, parent context) context {
	c := clone(parent)
	for k := range c {
		if strings.HasPrefix(k, "inputs.") || k == "inputs" {
			delete(c, k)
		}
	}
	all := object{}
	for _, k := range keys(declarations) {
		d := asObject(declarations[k])
		v := any("")
		if d != nil {
			if x, ok := d["default"]; ok {
				v = resolveScalar(x, parent)
			} else if d["required"] == true {
				v = uncertain
			} else if d["type"] == "boolean" {
				v = false
			} else if d["type"] == "number" {
				v = 0
			}
		}
		if x, ok := provided[k]; ok {
			v = resolveScalar(x, parent)
		}
		if d != nil && d["type"] == nil && known(v) {
			if s, ok := stringValue(v); ok {
				v = s
			} else {
				v = uncertain
			}
		}
		c["inputs."+strings.ToLower(k)] = v
		all[k] = v
	}
	for _, k := range keys(provided) {
		if _, ok := declarations[k]; !ok {
			v := resolveScalar(provided[k], parent)
			c["inputs."+strings.ToLower(k)] = v
			all[k] = v
		}
	}
	c["inputs"] = all
	return c
}

// checkSecrets rejects live external values and bulk forwarding on a possibly reachable path.
func checkSecrets(v any, c context) error {
	switch x := v.(type) {
	case object:
		return checkSecrets(map[string]any(x), c)
	case string:
		parts, err := expressionParts(x)
		if err != nil {
			return err
		}
		for _, body := range parts {
			e := []string{"", body}
			if !secretWord.MatchString(e[1]) {
				continue
			}
			remaining := secretNames.ReplaceAllString(e[1], "")
			if secretWord.MatchString(remaining) {
				return fmt.Errorf("external secret: unresolved bulk or dynamic expression")
			}
			matches := secretNames.FindAllStringSubmatch(e[1], -1)
			if len(matches) == 0 {
				return fmt.Errorf("external secret: unresolved bulk expression")
			}
			safe := true
			for _, m := range matches {
				name := m[1] + m[2]
				if strings.EqualFold(name, "GITHUB_TOKEN") {
					continue
				}
				val, ok := c["secrets."+strings.ToLower(name)]
				if _, approved := val.(builtinToken); approved {
					continue
				}
				if !ok || !known(val) || val != "" {
					safe = false
				}
			}
			if !safe {
				value := evaluate("$"+"{{"+e[1]+"}}", c)
				if !known(value) || value != "" {
					return fmt.Errorf("external secret on reachable path")
				}
			}
		}
	case map[string]any:
		for _, k := range keys(x) {
			if err := checkSecrets(x[k], c); err != nil {
				return err
			}
		}
	case []any:
		for _, v := range x {
			if err := checkSecrets(v, c); err != nil {
				return err
			}
		}
	}
	return nil
}

// permissions requires explicit authority and classifies reporting/OIDC separately from repository mutation.
func permissions(v any) (object, error) {
	m := asObject(v)
	if m == nil {
		return nil, fmt.Errorf("UNKNOWN missing or scalar permissions")
	}
	for _, k := range keys(m) {
		level, ok := m[k].(string)
		if !validScopes[k] || !ok || (level != "read" && level != "write" && level != "none") {
			return nil, fmt.Errorf("UNKNOWN unclassified permission")
		}
	}
	return m, nil
}

// leafAuthority blocks repository writes while preserving code-quality, scanner reporting and OIDC proofs.
func leafAuthority(m object) error {
	for _, k := range keys(m) {
		if m[k] == "write" && k != "code-quality" && k != "security-events" && k != "id-token" {
			return fmt.Errorf("write authority: %s", k)
		}
	}
	return nil
}

// condition is unknown by default and false only after a complete expression proof.
func condition(v any, c context) any {
	if v == nil {
		return true
	}
	return truth(evaluate(v, c))
}

// workflow follows the full job dependency graph before auditing each possibly executed leaf.
func (a *auditor) workflow(path, revision string, c context, provided, secrets, ceiling object) error {
	key := revision + ":" + path
	if a.active[key] {
		return fmt.Errorf("UNKNOWN recursive workflow graph")
	}
	a.active[key] = true
	defer delete(a.active, key)
	w, err := a.readSource(path, revision)
	if err != nil {
		return err
	}
	if path != ".github/workflows/ci.yaml" || revision != "" {
		on := asObject(w["on"])
		value, declared := on["workflow_call"]
		call := asObject(value)
		if declared && value == nil {
			call = object{}
		}
		if call == nil {
			return fmt.Errorf("UNKNOWN missing workflow_call declaration: %s", key)
		}
		c = inputs(asObject(call["inputs"]), provided, c)
		for k := range c {
			if strings.HasPrefix(k, "secrets.") && k != "secrets.github_token" {
				delete(c, k)
			}
		}
		for _, k := range keys(asObject(call["secrets"])) {
			v := any("")
			if x, ok := secrets[k]; ok {
				v = x
			} else if asObject(asObject(call["secrets"])[k])["required"] == true {
				return fmt.Errorf("UNKNOWN missing required secret: %s", key)
			}
			c["secrets."+strings.ToLower(k)] = v
		}
	}
	for k := range c {
		if strings.HasPrefix(k, "needs.") || strings.HasPrefix(k, "steps.") {
			delete(c, k)
		}
	}
	a.scope++
	c["__catalogue_guard_scope"] = a.scope
	c["__workflow_revision"] = revision
	wp := ceiling
	if p, ok := w["permissions"]; ok {
		wp, err = permissions(p)
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
	}
	jobs := asObject(w["jobs"])
	if len(jobs) == 0 {
		return fmt.Errorf("UNKNOWN empty job observation: %s", key)
	}
	state := map[string]bool{}
	visiting := map[string]bool{}
	var skipped func(string) (bool, error)
	skipped = func(id string) (bool, error) {
		if v, ok := state[id]; ok {
			return v, nil
		}
		if visiting[id] {
			return false, fmt.Errorf("UNKNOWN cyclic needs")
		}
		j := asObject(jobs[id])
		if j == nil {
			return false, fmt.Errorf("UNKNOWN missing dependency job")
		}
		visiting[id] = true
		defer delete(visiting, id)
		needs, e := names(j["needs"])
		if e != nil {
			return false, e
		}
		jc := clone(c)
		blocked := false
		for _, n := range needs {
			s, e := skipped(n)
			if e != nil {
				return false, e
			}
			if s {
				blocked = true
				jc["needs."+strings.ToLower(n)+".result"] = "skipped"
				for _, o := range keys(asObject(asObject(jobs[n])["outputs"])) {
					jc["needs."+strings.ToLower(n)+".outputs."+strings.ToLower(o)] = ""
				}
			}
		}
		s := condition(j["if"], jc) == false || (blocked && !statusOverride.MatchString(text(j["if"])))
		state[id] = s
		return s, nil
	}
	for _, id := range keys(jobs) {
		s, e := skipped(id)
		if e != nil {
			return fmt.Errorf("%s/%s: %w", key, id, e)
		}
		if s {
			a.skipped++
			continue
		}
		j := asObject(jobs[id])
		if j["environment"] != nil {
			return fmt.Errorf("UNKNOWN environment-secret boundary: %s/%s", key, id)
		}
		jc := clone(c)
		needs, _ := names(j["needs"])
		for _, n := range needs {
			if state[n] {
				jc["needs."+strings.ToLower(n)+".result"] = "skipped"
				for _, o := range keys(asObject(asObject(jobs[n])["outputs"])) {
					jc["needs."+strings.ToLower(n)+".outputs."+strings.ToLower(o)] = ""
				}
			}
		}
		jp := wp
		if p, ok := j["permissions"]; ok {
			jp, e = permissions(p)
			if e != nil {
				return fmt.Errorf("%s/%s: %w", key, id, e)
			}
		}
		if jp == nil {
			return fmt.Errorf("UNKNOWN inherited authority: %s/%s", key, id)
		}
		if e = checkSecrets(w["env"], jc); e != nil {
			return fmt.Errorf("%s/%s: %w", key, id, e)
		}
		headFields := object{}
		for k, v := range j {
			if k != "steps" && k != "secrets" {
				headFields[k] = v
			}
		}
		if e = checkSecrets(headFields, jc); e != nil {
			return fmt.Errorf("%s/%s: %w", key, id, e)
		}
		if u := text(j["uses"]); u != "" {
			p, r, _, e := reference(u, revision, false)
			if e != nil {
				return fmt.Errorf("%s/%s: %w", key, id, e)
			}
			var passed object
			if sv, ok := j["secrets"]; ok {
				if _, ok := sv.(string); ok {
					return fmt.Errorf("%s/%s: external secret bulk inheritance", key, id)
				}
				passed = asObject(sv)
				if passed == nil {
					return fmt.Errorf("UNKNOWN invalid secret mapping")
				}
				if e = checkSecrets(passed, jc); e != nil {
					return fmt.Errorf("%s/%s: %w", key, id, e)
				}
				ps := object{}
				for _, n := range keys(passed) {
					ps[n] = resolveScalar(passed[n], jc)
				}
				passed = ps
			}
			if e = checkSecrets(j["with"], jc); e != nil {
				return fmt.Errorf("%s/%s: %w", key, id, e)
			}
			if e = a.workflow(p, r, jc, asObject(j["with"]), passed, jp); e != nil {
				return fmt.Errorf("%s/%s -> %w", key, id, e)
			}
		} else {
			if e = leafAuthority(jp); e != nil {
				return fmt.Errorf("%s/%s: %w", key, id, e)
			}
			steps, ok := j["steps"].([]any)
			if !ok || len(steps) == 0 {
				return fmt.Errorf("UNKNOWN empty executed job: %s/%s", key, id)
			}
			if e = a.steps(steps, revision, jc, map[string]binding{}); e != nil {
				return fmt.Errorf("%s/%s: %w", key, id, e)
			}
			a.leaves++
		}
	}
	return nil
}

// steps recursively checks executed composite actions with their actual input defaults.
func (a *auditor) steps(steps []any, revision string, c context, bindings map[string]binding) error {
	ids := map[string]bool{}
	for _, v := range steps {
		id := text(asObject(v)["id"])
		if id != "" {
			if ids[strings.ToLower(id)] {
				return fmt.Errorf("UNKNOWN duplicate step outcome identity")
			}
			ids[strings.ToLower(id)] = true
		}
	}
	for _, v := range steps {
		s := asObject(v)
		if s == nil {
			return fmt.Errorf("UNKNOWN malformed step")
		}
		if condition(s["if"], c) == false {
			continue
		}
		if e := checkSecrets(s, c); e != nil {
			return e
		}
		ref := text(s["uses"])
		if ref == "" {
			continue
		}
		if strings.HasPrefix(ref, "actions/checkout@") {
			bindCheckout(s, revision, c, bindings)
		}
		p, r, owned, e := actionReference(ref, revision, s, c, bindings)
		if e != nil {
			return e
		}
		if !owned {
			continue
		}
		key := r + ":" + p
		if a.active[key] {
			return fmt.Errorf("UNKNOWN recursive composite graph")
		}
		m, e := a.readSource(p, r)
		if e != nil {
			if (p == "action.yaml" || strings.HasSuffix(p, "/action.yaml")) && errors.Is(e, os.ErrNotExist) {
				p = strings.TrimSuffix(p, "action.yaml") + "action.yml"
				m, e = a.readSource(p, r)
			}
			if e != nil {
				return e
			}
		}
		runs := asObject(m["runs"])
		if runs == nil {
			return fmt.Errorf("UNKNOWN missing action implementation")
		}
		if text(runs["using"]) != "composite" {
			continue
		}
		nested, ok := runs["steps"].([]any)
		if !ok || len(nested) == 0 {
			return fmt.Errorf("UNKNOWN empty composite implementation")
		}
		ac := inputs(asObject(m["inputs"]), asObject(s["with"]), c)
		a.scope++
		ac["__catalogue_guard_scope"] = a.scope
		for k := range ac {
			if strings.HasPrefix(k, "needs.") || strings.HasPrefix(k, "steps.") {
				delete(ac, k)
			}
		}
		a.active[key] = true
		e = a.steps(nested, r, ac, bindings)
		delete(a.active, key)
		if e != nil {
			return e
		}
	}
	return nil
}

// Audit checks all root CI jobs in each event scope without executing candidate code.
func Audit(root string) error { return audit(root, false) }

// audit uses one complete source observation for both wiring and graph classification.
func audit(root string, requireWiring bool) error {
	a := auditor{root: root, sources: map[string]object{}, active: map[string]bool{}}
	w, err := a.readSource(".github/workflows/ci.yaml", "")
	if err != nil {
		return err
	}
	if requireWiring {
		if err := checkWiring(w); err != nil {
			return err
		}
	}
	trigger := asObject(w["on"])
	if len(trigger) == 0 {
		return fmt.Errorf("UNKNOWN missing CI event observation")
	}
	for _, event := range keys(trigger) {
		refs := []any{uncertain}
		if event == "push" {
			p := asObject(trigger[event])
			branches, ok := p["branches"].([]any)
			if ok && len(branches) > 0 {
				refs = nil
				for _, branch := range branches {
					s, ok := branch.(string)
					if !ok || strings.ContainsAny(s, "*?+[!\\") {
						refs = append(refs, uncertain)
					} else {
						refs = append(refs, "refs/heads/"+s)
					}
				}
				if p["tags"] != nil {
					refs = append(refs, uncertain)
				}
			}
		}
		for _, ref := range refs {
			c := context{"github.repository": "devantler-tech/.github", "github.event_name": event, "github.ref": ref, "github.event.repository.default_branch": uncertain, "secrets.github_token": builtinToken{}, "github.token": builtinToken{}}
			if err := a.workflow(".github/workflows/ci.yaml", "", c, nil, nil, nil); err != nil {
				return fmt.Errorf("%s: %w", event, err)
			}
		}
	}
	if a.leaves+a.skipped == 0 {
		return fmt.Errorf("UNKNOWN no executed leaf observation")
	}
	return nil
}

// main reports only source coordinates and authority classes, never credential values.
func main() {
	root := "."
	if len(os.Args) == 2 {
		root = os.Args[1]
	} else if len(os.Args) > 2 {
		fmt.Fprintln(os.Stderr, "usage: catalogue-credentials [root]")
		os.Exit(2)
	}
	if e := audit(root, true); e != nil {
		fmt.Fprintln(os.Stderr, e)
		if strings.Contains(e.Error(), "UNKNOWN") {
			os.Exit(2)
		}
		os.Exit(1)
	}
	fmt.Println("PASS: complete catalogue CI graph has no reachable repository-write credentials")
}

// expressionParts finds complete interpolation boundaries while respecting quoted braces.
func expressionParts(s string) ([]string, error) {
	var parts []string
	for {
		start := strings.Index(s, "$"+"{{")
		if start < 0 {
			return parts, nil
		}
		s = s[start+3:]
		quoted := byte(0)
		closed := false
		for i := 0; i < len(s); i++ {
			ch := s[i]
			if quoted != 0 {
				if ch == quoted {
					if i+1 < len(s) && s[i+1] == quoted {
						i++
						continue
					}
					quoted = 0
				}
				continue
			}
			if ch == '\'' || ch == '"' {
				quoted = ch
				continue
			}
			if ch == '}' && i+1 < len(s) && s[i+1] == '}' {
				parts = append(parts, s[:i])
				s = s[i+2:]
				closed = true
				break
			}
		}
		if !closed {
			return nil, fmt.Errorf("UNKNOWN incomplete interpolation boundary")
		}
	}
}

type binding struct {
	revision string
	valid    bool
	guard    string
	scope    any
	id       string
	ignored  bool
}

// bindCheckout records the source that actually occupies each runner checkout directory.
func bindCheckout(step object, revision string, c context, bindings map[string]binding) {
	w := asObject(step["with"])
	path := "."
	if p, ok := w["path"]; ok {
		value := resolveScalar(p, c)
		s, ok := value.(string)
		if !ok {
			clear(bindings)
			return
		}
		if s == "" || s == "." || s == "./" {
			s = "."
		} else {
			p, e := safePath(s)
			if e != nil {
				clear(bindings)
				return
			}
			s = p
		}
		path = s
	}
	b := binding{}
	repo := text(w["repository"])
	owned := repo == "" || strings.EqualFold(repo, "devantler-tech/.github") || repo == "$"+"{{ job.workflow_repository }}" || repo == "$"+"{{ github.repository }}"
	if owned && condition(step["if"], c) != false {
		ref, declared := w["ref"]
		raw := text(ref)
		switch {
		case !declared || raw == "$"+"{{ github.sha }}":
			b = binding{revision: "", valid: true}
		case raw == "$"+"{{ job.workflow_sha }}":
			if workflowRevision, ok := c["__workflow_revision"].(string); ok {
				b = binding{revision: workflowRevision, valid: true}
			}
		default:
			resolved := resolveScalar(ref, c)
			if s, ok := resolved.(string); ok && fullSHA.MatchString(s) {
				b = binding{revision: s, valid: true}
			}
		}
	}
	b.id = text(step["id"])
	b.scope = c["__catalogue_guard_scope"]
	b.ignored = step["continue-on-error"] != nil && step["continue-on-error"] != false
	if condition(step["if"], c) != true {
		b.guard = text(step["if"])
		b.scope = c["__catalogue_guard_scope"]
	}
	{
		for k := range bindings {
			if path == "." || k == path || strings.HasPrefix(k, path+"/") {
				delete(bindings, k)
			}
		}
	}
	bindings[path] = b
}

// actionReference resolves local actions from measured checkout provenance, never a path alias.
func actionReference(ref, revision string, step object, c context, bindings map[string]binding) (string, string, bool, error) {
	if !strings.HasPrefix(ref, "./") {
		return reference(ref, revision, true)
	}
	p, e := safePath(ref)
	if e != nil {
		return "", "", false, e
	}
	prefix := ""
	for dir := range bindings {
		if dir == "." || p == dir || strings.HasPrefix(p, dir+"/") {
			if len(dir) > len(prefix) {
				prefix = dir
			}
		}
	}
	if prefix == "" || !bindings[prefix].valid {
		return "", "", false, fmt.Errorf("UNKNOWN local action checkout provenance")
	}
	b := bindings[prefix]
	requiresOutcome := b.ignored || statusOverride.MatchString(text(step["if"])) || (b.guard != "" && !stableGuard(b.guard))
	if requiresOutcome {
		if b.scope != c["__catalogue_guard_scope"] || !checkoutSucceeded(b.id, step["if"], c) {
			return "", "", false, fmt.Errorf("UNKNOWN successful local action checkout provenance")
		}
	} else if b.guard != "" && (b.guard != text(step["if"]) || b.scope != c["__catalogue_guard_scope"]) {
		return "", "", false, fmt.Errorf("UNKNOWN conditional local action checkout provenance")
	}
	if prefix != "." {
		if p == prefix {
			return "action.yaml", bindings[prefix].revision, true, nil
		}
		p = strings.TrimPrefix(p, prefix+"/")
	}
	return p + "/action.yaml", bindings[prefix].revision, true, nil
}

// checkWiring requires both guard entrypoints in the failure-blocking required CI path.
func checkWiring(w object) error {
	fail := func() error {
		return fmt.Errorf("required guard wiring must execute both entrypoints and evaluate their job result")
	}
	jobs := asObject(w["jobs"])
	job := asObject(jobs["lint-ci-coverage-parity"])
	expected := "$" + "{{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}"
	if job == nil || text(job["if"]) != expected || job["needs"] != nil || (job["continue-on-error"] != nil && job["continue-on-error"] != false) {
		return fail()
	}
	steps, ok := job["steps"].([]any)
	if !ok {
		return fail()
	}
	for _, script := range []string{"test-catalogue-credentials.sh", "test-catalogue-credentials-controls.sh"} {
		count := 0
		for _, v := range steps {
			s := asObject(v)
			if text(s["run"]) == "bash .github/tests/"+script {
				count++
				if s["if"] != nil || (s["continue-on-error"] != nil && s["continue-on-error"] != false) || text(s["shell"]) != "bash" {
					return fail()
				}
			}
		}
		if count != 1 {
			return fail()
		}
	}
	required := asObject(jobs["ci-required-checks"])
	if text(required["if"]) != "$"+"{{ always() }}" || (required["continue-on-error"] != nil && required["continue-on-error"] != false) {
		return fail()
	}
	needs, e := names(required["needs"])
	if e != nil {
		return fail()
	}
	found := false
	for _, n := range needs {
		if n == "lint-ci-coverage-parity" {
			found = true
		}
	}
	if !found {
		return fail()
	}
	results := false
	for _, v := range slice(required["steps"]) {
		s := asObject(v)
		env := asObject(s["env"])
		if strings.Contains(text(env["JOB_RESULTS"]), "needs.lint-ci-coverage-parity.result") && strings.Contains(text(s["run"]), "$JOB_RESULTS") {
			if s["if"] != nil || (s["continue-on-error"] != nil && s["continue-on-error"] != false) || text(s["shell"]) != "bash" {
				return fail()
			}
			// Pin the reviewed failure reducer; arbitrary Bash mentions are not result admission.
			if fmt.Sprintf("%x", sha256.Sum256([]byte(text(s["run"])))) != "243b869868468d895f48d6d4021091c35cf407dc2f4f3430455d980db12fabef" {
				return fail()
			}
			results = true
		}
	}
	if !results {
		return fail()
	}
	return nil
}

// slice returns a sequence without accepting scalar substitutes.
func slice(v any) []any { s, _ := v.([]any); return s }

// stableGuard limits implication proofs to immutable call inputs and job/event facts.
func stableGuard(s string) bool {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "$"+"{{") && strings.HasSuffix(s, "}}") {
		s = strings.TrimSpace(s[3 : len(s)-2])
	}
	tokens, err := lex(s)
	if err != nil || len(tokens) == 0 {
		return false
	}
	for _, t := range tokens {
		if t.literal {
			continue
		}
		name := strings.ToLower(t.text)
		switch name {
		case "!", "&&", "||", "==", "!=", "(", ")", "[", "]", ",", "true", "false", "null", "format", "contains", "startswith", "tojson", "fromjson":
			continue
		}
		if strings.HasPrefix(name, "inputs.") || name == "inputs" || strings.HasPrefix(name, "needs.") || (strings.HasPrefix(name, "github.") && name != "github.action_status") {
			continue
		}
		return false
	}
	return true
}

// checkoutSucceeded proves admission false for every native non-success checkout outcome.
func checkoutSucceeded(id string, gate any, c context) bool {
	if id == "" {
		return false
	}
	for _, outcome := range []string{"failure", "cancelled", "skipped"} {
		probe := clone(c)
		probe["steps."+strings.ToLower(id)+".outcome"] = outcome
		if condition(gate, probe) != false {
			return false
		}
	}
	return true
}
