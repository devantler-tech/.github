// Organization schema and explicit Crossplane assignments for .github#773.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
)

type property struct {
	Name        string   `json:"property_name"`
	Type        string   `json:"value_type"`
	Required    bool     `json:"required"`
	Explicit    bool     `json:"require_explicit_values"`
	Default     string   `json:"default_value"`
	Description string   `json:"description"`
	Allowed     []string `json:"allowed_values,omitempty"`
	Editable    string   `json:"values_editable_by"`
	Source      string   `json:"source_type,omitempty"`
}
type repository struct {
	Type          string `json:"type"`
	AutoMerge     *bool  `json:"auto_merge"`
	ScanActions   *bool  `json:"scan_actions"`
	CopilotReview *bool  `json:"copilot_review"`
}
type catalogue struct {
	Properties   []property            `json:"properties"`
	Retire       []string              `json:"retire"`
	Repositories map[string]repository `json:"repositories"`
}

var names = []string{"Type", "EnableAutoMerge", "ScanGitHubActions", "AutomaticallyRequestCopilotCodeReview"}
var types = []string{"Application", "Infrastructure", "Library", "Marketplace", "Metadata", "Documentation"}

func load(path string) (catalogue, error) {
	var c catalogue
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err = d.Decode(&c); err != nil {
		return c, err
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return c, errors.New("catalogue must contain one JSON object")
	}
	return c, validate(c)
}

func validate(c catalogue) error {
	if len(c.Properties) != len(names) || len(c.Repositories) < 10 || !reflect.DeepEqual(c.Retire, []string{"LintDocumentation"}) {
		return errors.New("expected four managed properties, the retired documentation switch and the complete portfolio")
	}
	seen := map[string]bool{}
	for _, p := range c.Properties {
		if !slices.Contains(names, p.Name) || seen[p.Name] || !p.Required || !p.Explicit || p.Description == "" || p.Editable != "org_and_repo_actors" || p.Source != "" {
			return errors.New("invalid or duplicate property definition")
		}
		seen[p.Name] = true
		if p.Name == "Type" {
			if p.Type != "single_select" || !slices.Contains(p.Allowed, p.Default) || len(p.Allowed) != len(types) {
				return errors.New("invalid Type definition")
			}
			for _, v := range types {
				if !slices.Contains(p.Allowed, v) {
					return errors.New("missing Type option")
				}
			}
		} else {
			want := "true"
			if p.Name == "AutomaticallyRequestCopilotCodeReview" {
				want = "false"
			}
			if p.Type != "true_false" || p.Default != want || len(p.Allowed) != 0 {
				return errors.New("invalid policy switch definition")
			}
		}
	}
	validRepo := regexp.MustCompile(`^(\.github|[a-z0-9][a-z0-9-]*)$`)
	for name, r := range c.Repositories {
		if !validRepo.MatchString(name) || !slices.Contains(types, r.Type) || r.AutoMerge == nil || r.ScanActions == nil || r.CopilotReview == nil {
			return fmt.Errorf("missing or invalid explicit values for %q", name)
		}
		if !*r.ScanActions {
			return errors.New("workflow scanning remains enabled across the portfolio")
		}
		if *r.CopilotReview {
			return errors.New("automatic Copilot review is enabled; copilot_review must be false across the portfolio")
		}
	}
	return nil
}

func render(c catalogue, root string) (string, error) {
	b, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	cmd := exec.Command("bash", filepath.Join(root, "scripts/generate-repository-properties.sh"))
	cmd.Stdin = bytes.NewReader(b)
	out, err := cmd.Output()
	return string(out), err
}

type apiFunc func(method, path string, body []byte) ([]byte, error)

func ghAPI(method, path string, body []byte) ([]byte, error) {
	args := []string{"api", "--hostname", "github.com", "--method", method, path}
	if body != nil {
		args = append(args, "--input", "-")
	}
	cmd := exec.Command("gh", args...)
	cmd.Stdin = bytes.NewReader(body)
	// Do not copy credential/service diagnostics into the public Actions log.
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("GitHub %s %s failed; no success is inferred", method, path)
	}
	return out, nil
}

func readSchema(api apiFunc) ([]property, error) {
	b, err := api("GET", "orgs/devantler-tech/properties/schema", nil)
	if err != nil {
		return nil, err
	}
	var schema []property
	if err = json.Unmarshal(b, &schema); err != nil || schema == nil {
		return nil, errors.New("unreadable property schema")
	}
	return schema, nil
}

// Every native policy is read in full before the first schema mutation. A failed,
// malformed or incomplete inventory never authorizes retiring a switch.
func noConsumers(api apiFunc, retired []string) error {
	seen := map[int]bool{}
	for page := 1; page <= 100; page++ {
		path := fmt.Sprintf("orgs/devantler-tech/rulesets?per_page=100&page=%d", page)
		b, err := api("GET", path, nil)
		if err != nil {
			return err
		}
		var rows []struct {
			ID         int    `json:"id"`
			SourceType string `json:"source_type"`
			Source     string `json:"source"`
		}
		if json.Unmarshal(b, &rows) != nil || rows == nil {
			return errors.New("malformed ruleset inventory")
		}
		for _, r := range rows {
			if r.ID <= 0 || seen[r.ID] || (r.SourceType != "Organization" && r.SourceType != "Enterprise") || r.Source == "" {
				return errors.New("invalid ruleset identity")
			}
			seen[r.ID] = true
			b, err = api("GET", fmt.Sprintf("orgs/devantler-tech/rulesets/%d", r.ID), nil)
			if err != nil {
				return err
			}
			var full struct {
				ID         int               `json:"id"`
				Name       string            `json:"name"`
				SourceType string            `json:"source_type"`
				Source     string            `json:"source"`
				Conditions json.RawMessage   `json:"conditions"`
				Rules      []json.RawMessage `json:"rules"`
			}
			if json.Unmarshal(b, &full) != nil || full.ID != r.ID || full.Name == "" || full.SourceType != r.SourceType || full.Source != r.Source || !jsonObject(full.Conditions) || full.Rules == nil {
				return errors.New("incomplete ruleset detail")
			}
			if err = rejectConsumers(b, retired); err != nil {
				return err
			}
		}
		if len(rows) < 100 {
			break
		}
		if page == 100 {
			return errors.New("ruleset inventory exceeded its bound")
		}
	}
	if len(seen) == 0 {
		return errors.New("organization ruleset inventory unexpectedly empty")
	}
	seen = map[int]bool{}
	total := -1
	for page := 1; page <= 100; page++ {
		b, err := api("GET", fmt.Sprintf("orgs/devantler-tech/actions/policies?per_page=100&page=%d", page), nil)
		if err != nil {
			return err
		}
		var list struct {
			Total    *int `json:"total_count"`
			Policies []struct {
				ID int `json:"id"`
			} `json:"policies"`
		}
		if json.Unmarshal(b, &list) != nil || list.Total == nil || *list.Total < 0 || list.Policies == nil || (total >= 0 && total != *list.Total) {
			return errors.New("malformed workflow-policy inventory")
		}
		total = *list.Total
		for _, p := range list.Policies {
			if p.ID <= 0 || seen[p.ID] {
				return errors.New("duplicate workflow-policy identity")
			}
			seen[p.ID] = true
			b, err = api("GET", fmt.Sprintf("orgs/devantler-tech/actions/policies/%d", p.ID), nil)
			if err != nil {
				return err
			}
			var full struct {
				ID         int               `json:"id"`
				Name       string            `json:"name"`
				Conditions json.RawMessage   `json:"conditions"`
				Rules      []json.RawMessage `json:"rules"`
			}
			if json.Unmarshal(b, &full) != nil || full.ID != p.ID || full.Name == "" || !jsonObject(full.Conditions) || full.Rules == nil {
				return errors.New("incomplete workflow-policy detail")
			}
			if err = rejectConsumers(b, retired); err != nil {
				return err
			}
		}
		if len(seen) == total {
			return nil
		}
		if len(seen) > total || len(list.Policies) < 100 {
			return errors.New("incomplete workflow-policy inventory")
		}
	}
	return errors.New("workflow-policy inventory exceeded its bound")
}

func rejectConsumers(b []byte, retired []string) error {
	var value any
	if err := json.Unmarshal(b, &value); err != nil {
		return err
	}
	var walk func(any) bool
	walk = func(v any) bool {
		switch v := v.(type) {
		case string:
			return slices.Contains(retired, v)
		case []any:
			for _, child := range v {
				if walk(child) {
					return true
				}
			}
		case map[string]any:
			for _, child := range v {
				if walk(child) {
					return true
				}
			}
		}
		return false
	}
	if walk(value) {
		return errors.New("a retired property still has a native policy consumer; nothing was applied")
	}
	return nil
}

func jsonObject(b []byte) bool {
	var object map[string]json.RawMessage
	return json.Unmarshal(b, &object) == nil && object != nil
}

func admitted() bool {
	return os.Getenv("GITHUB_REPOSITORY") == "devantler-tech/.github" && os.Getenv("GITHUB_REF") == "refs/heads/main" && os.Getenv("GITHUB_WORKFLOW_REF") == "devantler-tech/.github/.github/workflows/apply-custom-properties.yaml@refs/heads/main" && slices.Contains([]string{"push", "schedule", "workflow_dispatch"}, os.Getenv("GITHUB_EVENT_NAME"))
}

func normalized(p property) property { p.Source = ""; return p }

func verifyDesired(c catalogue, got []property, allowRetired bool) error {
	seen := map[string]bool{}
	for _, p := range got {
		if p.Source != "organization" || seen[p.Name] {
			return errors.New("ambiguous schema readback")
		}
		seen[p.Name] = true
		if allowRetired && slices.Contains(c.Retire, p.Name) {
			if p.Type != "true_false" {
				return errors.New("retired property type changed during reconciliation")
			}
			continue
		}
		match := false
		for _, want := range c.Properties {
			if reflect.DeepEqual(normalized(p), want) {
				match = true
			}
		}
		if !match {
			return errors.New("schema readback differs")
		}
	}
	for _, name := range names {
		if !seen[name] {
			return errors.New("schema readback is missing a managed property")
		}
	}
	return nil
}

type assignment struct {
	Name  string `json:"property_name"`
	Value string `json:"value"`
}

// GitHub requires all explicit values together when initializing a repository.
// Keep the still-live retiring switch in that request until every repository
// has been initialized and independently read back. Crossplane owns later drift.
func initializeValues(c catalogue, schema []property, api apiFunc) error {
	retiring := false
	for _, p := range schema {
		if p.Name == "LintDocumentation" {
			retiring = true
		}
	}
	repos := make([]string, 0, len(c.Repositories))
	for name := range c.Repositories {
		repos = append(repos, name)
	}
	slices.Sort(repos)
	wanted := map[string][]assignment{}
	for _, name := range repos {
		r := c.Repositories[name]
		values := []assignment{
			{"Type", r.Type},
			{"EnableAutoMerge", fmt.Sprint(*r.AutoMerge)},
			{"ScanGitHubActions", fmt.Sprint(*r.ScanActions)},
			{"AutomaticallyRequestCopilotCodeReview", fmt.Sprint(*r.CopilotReview)},
		}
		if retiring {
			values = append(values, assignment{"LintDocumentation", "false"})
		}
		body, err := json.Marshal(struct {
			Repositories []string     `json:"repository_names"`
			Properties   []assignment `json:"properties"`
		}{[]string{name}, values})
		if err != nil {
			return err
		}
		if _, err = api("PATCH", "orgs/devantler-tech/properties/values", body); err != nil {
			return err
		}
		wanted[name] = values
	}
	// The App is repository-restricted. Read the organization collection with
	// organization property authority, including private catalogue entries.
	seenIDs := map[int64]bool{}
	seenRepos := map[string]bool{}
	for page := 1; page <= 100; page++ {
		b, err := api("GET", fmt.Sprintf("orgs/devantler-tech/properties/values?per_page=100&page=%d", page), nil)
		if err != nil {
			return err
		}
		var rows []struct {
			ID         int64        `json:"repository_id"`
			Name       string       `json:"repository_name"`
			FullName   string       `json:"repository_full_name"`
			Properties []assignment `json:"properties"`
		}
		if json.Unmarshal(b, &rows) != nil || rows == nil {
			return errors.New("unreadable organization property values")
		}
		for _, row := range rows {
			if row.ID <= 0 || row.Name == "" || row.FullName != "devantler-tech/"+row.Name || seenIDs[row.ID] || seenRepos[row.Name] {
				return errors.New("ambiguous repository identity in property readback")
			}
			seenIDs[row.ID], seenRepos[row.Name] = true, true
			values, managed := wanted[row.Name]
			if !managed {
				continue
			}
			if len(row.Properties) != len(values) {
				return errors.New("repository property readback is incomplete")
			}
			seen := map[string]string{}
			for _, value := range row.Properties {
				if _, duplicate := seen[value.Name]; duplicate {
					return errors.New("duplicate repository property readback")
				}
				seen[value.Name] = value.Value
			}
			for _, want := range values {
				if value, ok := seen[want.Name]; !ok || value != want.Value {
					return errors.New("repository property readback differs")
				}
			}
		}
		if len(rows) < 100 {
			for name := range wanted {
				if !seenRepos[name] {
					return errors.New("catalogue repository missing from property readback")
				}
			}
			return nil
		}
	}
	return errors.New("property readback exceeded its page bound")
}

func reconcile(c catalogue, api apiFunc) error {
	if err := validate(c); err != nil {
		return err
	}
	live, err := readSchema(api)
	if err != nil {
		return err
	}
	byName := map[string]property{}
	for _, p := range live {
		if p.Source != "organization" || byName[p.Name].Name != "" || (!slices.Contains(names, p.Name) && !slices.Contains(c.Retire, p.Name)) {
			return errors.New("unexpected or externally owned property; nothing was applied")
		}
		byName[p.Name] = p
		if slices.Contains(c.Retire, p.Name) && p.Type != "true_false" {
			return errors.New("retired property type changed; nothing was applied")
		}
	}
	for _, p := range c.Properties {
		if old, ok := byName[p.Name]; ok && old.Type != p.Type {
			return errors.New("property type changed; nothing was applied")
		}
	}
	if err = noConsumers(api, c.Retire); err != nil {
		return err
	}
	for _, p := range c.Properties {
		if reflect.DeepEqual(normalized(byName[p.Name]), p) {
			continue
		}
		body, err := json.Marshal(p)
		if err != nil {
			return err
		}
		var request map[string]any
		if err = json.Unmarshal(body, &request); err != nil {
			return err
		}
		delete(request, "property_name") // selected by the endpoint, not a PUT body field
		body, err = json.Marshal(request)
		if err != nil {
			return err
		}
		if _, err = api("PUT", "orgs/devantler-tech/properties/schema/"+p.Name, body); err != nil {
			return err
		}
		fmt.Println("UPDATED schema", p.Name)
	}
	// Verify replacements before retirement, then refresh native consumers.
	// GitHub provides no transaction with other organization owners.
	got, err := readSchema(api)
	if err != nil {
		return err
	}
	if err = verifyDesired(c, got, true); err != nil {
		return err
	}
	if err = initializeValues(c, got, api); err != nil {
		return err
	}
	if err = noConsumers(api, c.Retire); err != nil {
		return err
	}
	for _, name := range c.Retire {
		if _, ok := byName[name]; !ok {
			continue
		}
		if _, err = api("DELETE", "orgs/devantler-tech/properties/schema/"+name, nil); err != nil {
			return err
		}
		fmt.Println("RETIRED schema", name)
	}
	got, err = readSchema(api)
	if err != nil {
		return err
	}
	if len(got) != len(c.Properties) {
		return errors.New("schema readback count differs")
	}
	if err = verifyDesired(c, got, false); err != nil {
		return err
	}
	fmt.Println("VERIFIED: four organization properties and complete explicit repository values; Crossplane maintains assignments")
	return nil
}

func run() error {
	root := flag.String("root", ".", "repository root")
	renderFlag := flag.Bool("render", false, "render explicit assignments")
	check := flag.Bool("check", false, "check committed generated assignments")
	apply := flag.Bool("apply-schema", false, "reconcile schema from reviewed-main Actions only")
	flag.Parse()
	modes := 0
	for _, v := range []bool{*renderFlag, *check, *apply} {
		if v {
			modes++
		}
	}
	if modes != 1 || flag.NArg() != 0 {
		return errors.New("select exactly one of --render, --check or --apply-schema")
	}
	c, err := load(filepath.Join(*root, "custom-properties/catalogue.json"))
	if err != nil {
		return err
	}
	if *renderFlag {
		out, err := render(c, *root)
		if err != nil {
			return err
		}
		fmt.Print(out)
		return nil
	}
	if *check {
		b, err := os.ReadFile(filepath.Join(*root, "deploy/repository-properties/properties.yaml"))
		if err != nil {
			return err
		}
		out, err := render(c, *root)
		if err != nil {
			return err
		}
		if string(b) != out {
			return errors.New("generated assignments differ; regenerate with --render")
		}
		return nil
	}
	if !admitted() {
		return errors.New("schema writes require the reviewed-main organization configuration workflow")
	}
	return reconcile(c, ghAPI)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "custom-properties:", err)
		os.Exit(1)
	}
}
