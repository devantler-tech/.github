package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGHAPIUsesReadOnlyCredentialOnlyForValueReadback(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte("#!/bin/sh\nprintf '%s:%s' \"$GH_TOKEN\" \"${GH_PROPERTY_READBACK_TOKEN-unset}\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("GH_TOKEN", "schema-writer")
	t.Setenv("GH_PROPERTY_READBACK_TOKEN", "portfolio-reader")
	for _, tc := range []struct{ method, path, want string }{
		{"GET", "orgs/devantler-tech/properties/values?per_page=100&page=1", "portfolio-reader:unset"},
		{"GET", "orgs/devantler-tech/properties/schema", "schema-writer:unset"},
		{"PATCH", "orgs/devantler-tech/properties/values", "schema-writer:unset"},
		{"DELETE", "orgs/devantler-tech/properties/schema/LintDocumentation", "schema-writer:unset"},
	} {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			out, err := ghAPI(tc.method, tc.path, nil)
			if err != nil || string(out) != tc.want {
				t.Fatalf("credential routing: got %q, error %v; want %q", out, err, tc.want)
			}
		})
	}
	t.Setenv("GH_PROPERTY_READBACK_TOKEN", "")
	if _, err := ghAPI("GET", "orgs/devantler-tech/properties/values?per_page=100&page=1", nil); err == nil {
		t.Fatal("missing read-only credential must block readback, never fall back to the writer")
	}
}

func fixture(t *testing.T) catalogue {
	t.Helper()
	c, err := load("../../custom-properties/catalogue.json")
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestRenderExplicitAssignments(t *testing.T) {
	c := fixture(t)
	out, err := render(c, "../..")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.Count(out, "kind: RepositoryCustomProperty\n"), 4*len(c.Repositories); got != want {
		t.Fatalf("expected %d repositories with four assignments (%d total), got %d", len(c.Repositories), want, got)
	}
	for _, forbidden := range []string{"crossplane.io/external-name", "LateInitialize", "- Delete", "LintDocumentation"} {
		if strings.Contains(out, forbidden) {
			t.Fatalf("unsafe or retired setting: %s", forbidden)
		}
	}
	if !strings.Contains(out, `propertyValue: ["false"]`) {
		t.Fatal("lost intentional auto-merge opt-out")
	}
}

func TestCatalogueRejectsMissingAndUnknownValues(t *testing.T) {
	for _, mutation := range []func(*catalogue){
		func(c *catalogue) { r := c.Repositories["ksail"]; r.AutoMerge = nil; c.Repositories["ksail"] = r },
		func(c *catalogue) { r := c.Repositories["ksail"]; r.Type = "Unknown"; c.Repositories["ksail"] = r },
		func(c *catalogue) { c.Properties[0].Explicit = false },
		func(c *catalogue) { c.Properties = append(c.Properties, c.Properties[0]) },
		func(c *catalogue) { c.Retire = append(c.Retire, "EnableAutoMerge") },
		func(c *catalogue) { r := c.Repositories["ksail"]; r.CopilotReview = nil; c.Repositories["ksail"] = r },
		func(c *catalogue) {
			r := c.Repositories["ksail"]
			value := true
			r.CopilotReview = &value
			c.Repositories["ksail"] = r
		},
	} {
		c := fixture(t)
		mutation(&c)
		if validate(c) == nil {
			t.Fatal("invalid catalogue accepted")
		}
	}
}

type fakeAPI struct {
	schema                       []property
	rule                         json.RawMessage
	failRead, failWrite, corrupt bool
	writes                       []string
	values                       map[string][]map[string]string
}

func (f *fakeAPI) call(method, path string, body []byte) ([]byte, error) {
	if method == "GET" {
		if f.failRead {
			return nil, errors.New("unavailable")
		}
		if path == "orgs/devantler-tech/properties/values?per_page=100&page=1" {
			rows := []map[string]any{}
			for name, values := range f.values {
				rows = append(rows, map[string]any{"repository_id": len(rows) + 1, "repository_name": name, "repository_full_name": "devantler-tech/" + name, "properties": values})
			}
			return json.Marshal(rows)
		}
		switch path {
		case "orgs/devantler-tech/properties/schema":
			return json.Marshal(f.schema)
		case "orgs/devantler-tech/rulesets?per_page=100&page=1":
			return []byte(`[{"id":1,"source_type":"Organization","source":"devantler-tech"}]`), nil
		case "orgs/devantler-tech/rulesets/1":
			if f.rule != nil {
				return f.rule, nil
			}
			return []byte(`{"id":1,"name":"required scanning","source_type":"Organization","source":"devantler-tech","conditions":{},"rules":[]}`), nil
		case "orgs/devantler-tech/actions/policies?per_page=100&page=1":
			return []byte(`{"total_count":0,"policies":[]}`), nil
		}
		return nil, errors.New("unexpected read: " + path)
	}
	f.writes = append(f.writes, method+" "+path)
	if f.failWrite {
		return nil, errors.New("write denied")
	}
	if method == "PATCH" && path == "orgs/devantler-tech/properties/values" {
		var request struct {
			Repositories []string            `json:"repository_names"`
			Properties   []map[string]string `json:"properties"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			return nil, err
		}
		if len(request.Repositories) != 1 || len(request.Properties) == 0 {
			return nil, errors.New("incomplete value request")
		}
		for _, p := range f.schema {
			if !p.Required || !p.Explicit {
				continue
			}
			found := false
			for _, v := range request.Properties {
				if v["property_name"] == p.Name {
					found = true
				}
			}
			if !found {
				return nil, errors.New("required explicit value missing from atomic request")
			}
		}
		if f.values == nil {
			f.values = map[string][]map[string]string{}
		}
		f.values[request.Repositories[0]] = request.Properties
		return []byte{}, nil
	}
	name := path[strings.LastIndex(path, "/")+1:]
	if method == "DELETE" {
		for i, p := range f.schema {
			if p.Name == name {
				f.schema = append(f.schema[:i], f.schema[i+1:]...)
				break
			}
		}
	} else {
		var p property
		if err := json.Unmarshal(body, &p); err != nil {
			return nil, err
		}
		if p.Name != "" {
			return nil, errors.New("property_name is not a PUT body field")
		}
		p.Name = name
		p.Source = "organization"
		if f.corrupt {
			p.Required = false
		}
		found := false
		for i, old := range f.schema {
			if old.Name == p.Name {
				f.schema[i] = p
				found = true
			}
		}
		if !found {
			f.schema = append(f.schema, p)
		}
	}
	return []byte(`{}`), nil
}

// Native GitHub rejects independent value creation when other required values
// are missing. Exercise the reconciler against that complete request boundary.
func TestBootstrapBeforeRetirement(t *testing.T) {
	for _, failure := range []string{"", "write", "readback", "wrong-value", "duplicate", "missing-private"} {
		t.Run(failure, func(t *testing.T) {
			c := fixture(t)
			f := &fakeAPI{schema: append([]property{}, c.Properties...)}
			for i := range f.schema {
				f.schema[i].Source = "organization"
			}
			for _, name := range c.Retire {
				f.schema = append(f.schema, property{Name: name, Type: "true_false", Source: "organization", Required: true, Explicit: true, Default: "false"})
			}
			patched := map[string]bool{}
			deleted := false
			api := func(method, path string, body []byte) ([]byte, error) {
				if method == "DELETE" {
					deleted = true
					if len(patched) != len(c.Repositories) {
						return nil, errors.New("retirement preceded complete initialization")
					}
				}
				if method == "PATCH" {
					if failure == "write" {
						return nil, errors.New("native write refused")
					}
					var request struct {
						Repositories []string            `json:"repository_names"`
						Properties   []map[string]string `json:"properties"`
					}
					if err := json.Unmarshal(body, &request); err != nil {
						return nil, err
					}
					if len(request.Repositories) != 1 {
						t.Fatal("bootstrap must bind one catalogue repository")
					}
					name := request.Repositories[0]
					if _, ok := c.Repositories[name]; !ok {
						t.Fatal("bootstrap escaped catalogue")
					}
					values := map[string]string{}
					for _, p := range request.Properties {
						values[p["property_name"]] = p["value"]
					}
					if values["AutomaticallyRequestCopilotCodeReview"] != "false" || values["ScanGitHubActions"] != "true" || values["Type"] != c.Repositories[name].Type {
						t.Fatal("unsafe or incomplete initial values")
					}
					if values["LintDocumentation"] != "false" {
						t.Fatal("retiring required value must remain explicit until removal")
					}
					patched[name] = true
				}
				if failure == "readback" && method == "GET" && strings.HasPrefix(path, "orgs/devantler-tech/properties/values?") {
					return []byte(`[]`), nil
				}
				if (failure == "wrong-value" || failure == "duplicate" || failure == "missing-private") && method == "GET" && strings.HasPrefix(path, "orgs/devantler-tech/properties/values?") {
					b, err := f.call(method, path, body)
					if err != nil {
						return nil, err
					}
					var rows []struct {
						ID         int                 `json:"repository_id"`
						Name       string              `json:"repository_name"`
						FullName   string              `json:"repository_full_name"`
						Properties []map[string]string `json:"properties"`
					}
					if err = json.Unmarshal(b, &rows); err != nil {
						return nil, err
					}
					if failure == "wrong-value" {
						rows[0].Properties[0]["value"] = "unexpected"
					} else if failure == "duplicate" {
						rows[0].Properties[0] = rows[0].Properties[1]
					} else {
						for i, row := range rows {
							if row.Name == "client-orders" {
								rows = append(rows[:i], rows[i+1:]...)
								break
							}
						}
					}
					return json.Marshal(rows)
				}
				return f.call(method, path, body)
			}
			err := reconcile(c, api)
			if failure == "" {
				if err != nil || len(patched) != len(c.Repositories) || !deleted {
					t.Fatalf("initialization did not complete: %v, patched=%d deleted=%v", err, len(patched), deleted)
				}
			} else if err == nil || deleted {
				t.Fatalf("failed bootstrap allowed retirement: %v deleted=%v", err, deleted)
			}
		})
	}
}

func TestTemplateClassificationsPreserveNativeCodeQLCoverage(t *testing.T) {
	c := fixture(t)
	for name, want := range map[string]string{"go-template": "Application", "dotnet-template": "Application", "platform-tenant-template": "Application", "platform-template": "Infrastructure"} {
		if got := c.Repositories[name].Type; got != want {
			t.Fatalf("%s classification %q would change existing native policy coverage; want %q", name, got, want)
		}
	}
}

func TestDisabledReviewConsumerCanRemainWithoutActivation(t *testing.T) {
	c := fixture(t)
	f := &fakeAPI{schema: []property{}, rule: json.RawMessage(`{"id":1,"name":"disabled review","source_type":"Organization","source":"devantler-tech","enforcement":"disabled","conditions":{"repository_property":{"include":[{"name":"AutomaticallyRequestCopilotCodeReview"}]}},"rules":[]}`)}
	if err := reconcile(c, f.call); err != nil {
		t.Fatal(err)
	}
	for _, p := range f.schema {
		if p.Name == "AutomaticallyRequestCopilotCodeReview" && p.Default == "false" {
			return
		}
	}
	t.Fatal("retained disabled-review switch lacks safe false default")
}

func TestReadbackRequiresCompleteOrganizationInventory(t *testing.T) {
	for _, failure := range []string{"", "unavailable-page", "duplicate-id", "duplicate-name", "foreign-owner"} {
		t.Run(failure, func(t *testing.T) {
			c := fixture(t)
			f := &fakeAPI{schema: append([]property{}, c.Properties...)}
			for i := range f.schema {
				f.schema[i].Source = "organization"
			}
			f.schema = append(f.schema, property{Name: "LintDocumentation", Type: "true_false", Source: "organization"})
			secondPage := false
			api := func(method, path string, body []byte) ([]byte, error) {
				if method == "GET" && path == "orgs/devantler-tech/properties/values?per_page=100&page=1" {
					b, err := f.call(method, path, body)
					if err != nil {
						return nil, err
					}
					var rows []map[string]any
					if err = json.Unmarshal(b, &rows); err != nil {
						return nil, err
					}
					for len(rows) < 100 {
						id := len(rows) + 1000
						name := fmt.Sprintf("archived-%d", id)
						rows = append(rows, map[string]any{"repository_id": id, "repository_name": name, "repository_full_name": "devantler-tech/" + name, "properties": []any{}})
					}
					return json.Marshal(rows)
				}
				if method == "GET" && path == "orgs/devantler-tech/properties/values?per_page=100&page=2" {
					secondPage = true
					if failure == "unavailable-page" {
						return nil, errors.New("unavailable page")
					}
					rows := []map[string]any{}
					if failure != "" {
						id := 2000
						name := "additional"
						owner := "devantler-tech/"
						if failure == "duplicate-id" {
							id = 1
						}
						if failure == "duplicate-name" {
							name = "client-orders"
						}
						if failure == "foreign-owner" {
							owner = "other/"
						}
						rows = append(rows, map[string]any{"repository_id": id, "repository_name": name, "repository_full_name": owner + name, "properties": []any{}})
					}
					return json.Marshal(rows)
				}
				return f.call(method, path, body)
			}
			err := reconcile(c, api)
			if !secondPage {
				t.Fatal("stopped before complete organization collection")
			}
			if failure == "" && err != nil {
				t.Fatal(err)
			}
			if failure != "" {
				if err == nil {
					t.Fatal("incomplete or ambiguous collection accepted")
				}
				for _, write := range f.writes {
					if strings.HasPrefix(write, "DELETE ") {
						t.Fatal("retirement preceded complete readback")
					}
				}
			}
		})
	}
}

func TestSchemaReconciliationAndRetry(t *testing.T) {
	c := fixture(t)
	f := &fakeAPI{schema: append([]property{}, c.Properties...)}
	for i := range f.schema {
		f.schema[i].Source = "organization"
	}
	f.schema = append(f.schema, property{Name: "LintDocumentation", Type: "true_false", Source: "organization"})
	if err := reconcile(c, f.call); err != nil {
		t.Fatal(err)
	}
	if len(f.writes) != len(c.Repositories)+1 || f.writes[len(f.writes)-1] != "DELETE orgs/devantler-tech/properties/schema/LintDocumentation" {
		t.Fatalf("unexpected changes: %v", f.writes)
	}
	f.writes = nil
	if err := reconcile(c, f.call); err != nil || len(f.writes) != len(c.Repositories) {
		t.Fatalf("retry did not reassert complete explicit assignments: %v %v", err, f.writes)
	}
	for _, write := range f.writes {
		if write != "PATCH orgs/devantler-tech/properties/values" {
			t.Fatalf("matching schema changed on retry: %s", write)
		}
	}
}

func TestSchemaCreatesAndUpdatesDefinitions(t *testing.T) {
	c := fixture(t)
	for _, existing := range []bool{false, true} {
		f := &fakeAPI{schema: []property{}}
		if existing {
			f.schema = append(f.schema, c.Properties...)
			for i := range f.schema {
				f.schema[i].Source = "organization"
				f.schema[i].Description = "old description"
			}
		}
		if err := reconcile(c, f.call); err != nil {
			t.Fatal(err)
		}
		if len(f.writes) != len(c.Properties)+len(c.Repositories) {
			t.Fatalf("expected definitions and complete assignments, got %v", f.writes)
		}
		for _, write := range f.writes[:len(c.Properties)] {
			if !strings.HasPrefix(write, "PUT ") {
				t.Fatalf("unexpected mutation: %s", write)
			}
		}
		if err := verifyDesired(c, f.schema, false); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSchemaFailsBeforeWrites(t *testing.T) {
	for _, f := range []*fakeAPI{
		{failRead: true},
		{schema: []property{}, rule: json.RawMessage(`{"id":1,"name":"consumer","source_type":"Organization","source":"devantler-tech","conditions":{"repository_property":{"include":[{"name":"LintDocumentation"}]}},"rules":[]}`)},
		{schema: []property{}, rule: json.RawMessage(`{"id":2,"name":"wrong identity","source_type":"Organization","source":"devantler-tech","conditions":{},"rules":[]}`)},
		{schema: []property{}, rule: json.RawMessage(`{"id":1,"name":"malformed conditions","source_type":"Organization","source":"devantler-tech","conditions":"unknown","rules":[]}`)},
		{schema: []property{{Name: "Unexpected", Source: "organization"}}},
		{schema: []property{{Name: "Type", Source: "enterprise"}}},
		{schema: []property{{Name: "LintDocumentation", Type: "string", Source: "organization"}}},
	} {
		if err := reconcile(fixture(t), f.call); err == nil {
			t.Fatal("incomplete or unsafe evidence accepted")
		}
		if len(f.writes) != 0 {
			t.Fatalf("wrote before completing admission: %v", f.writes)
		}
	}
}

func TestSchemaWriteAndReadbackFailures(t *testing.T) {
	for _, f := range []*fakeAPI{{schema: []property{}, failWrite: true}, {schema: []property{}, corrupt: true}} {
		if err := reconcile(fixture(t), f.call); err == nil {
			t.Fatal("failed mutation or mismatched readback accepted")
		}
		if len(f.writes) == 0 {
			t.Fatal("test never reached a schema mutation")
		}
	}
}

func TestLaterRulesetPageCannotHideConsumer(t *testing.T) {
	f := &fakeAPI{schema: []property{}}
	api := func(method, path string, body []byte) ([]byte, error) {
		if method != "GET" {
			return f.call(method, path, body)
		}
		if strings.Contains(path, "rulesets?per_page=100&page=") {
			first, last := 1, 100
			if strings.HasSuffix(path, "page=2") {
				first, last = 101, 101
			}
			rows := []map[string]any{}
			for id := first; id <= last; id++ {
				rows = append(rows, map[string]any{"id": id, "source_type": "Organization", "source": "devantler-tech"})
			}
			return json.Marshal(rows)
		}
		if strings.HasPrefix(path, "orgs/devantler-tech/rulesets/") {
			var id int
			if _, err := fmt.Sscanf(path, "orgs/devantler-tech/rulesets/%d", &id); err != nil {
				return nil, err
			}
			conditions := map[string]any{}
			if id == 101 {
				conditions["repository_property"] = map[string]any{"include": []any{map[string]any{"name": "LintDocumentation"}}}
			}
			return json.Marshal(map[string]any{"id": id, "name": "policy", "source_type": "Organization", "source": "devantler-tech", "conditions": conditions, "rules": []any{}})
		}
		return f.call(method, path, body)
	}
	if err := reconcile(fixture(t), api); err == nil || !strings.Contains(err.Error(), "consumer") {
		t.Fatalf("late consumer not detected: %v", err)
	}
	if len(f.writes) != 0 {
		t.Fatal("changed schema before completing all pages")
	}
}

func TestReadbackDuplicatesFail(t *testing.T) {
	c := fixture(t)
	got := []property{c.Properties[0], c.Properties[0], c.Properties[2]}
	for i := range got {
		got[i].Source = "organization"
	}
	if verifyDesired(c, got, false) == nil {
		t.Fatal("duplicate readback hid a missing property")
	}
}

func TestReviewedMainAdmission(t *testing.T) {
	good := map[string]string{"GITHUB_REPOSITORY": "devantler-tech/.github", "GITHUB_REF": "refs/heads/main", "GITHUB_WORKFLOW_REF": "devantler-tech/.github/.github/workflows/apply-custom-properties.yaml@refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch"}
	for key, value := range good {
		t.Setenv(key, value)
	}
	if !admitted() {
		t.Fatal("reviewed main refused")
	}
	for key := range good {
		t.Setenv(key, "untrusted")
		if admitted() {
			t.Fatalf("invalid %s admitted", key)
		}
		t.Setenv(key, good[key])
	}
}
