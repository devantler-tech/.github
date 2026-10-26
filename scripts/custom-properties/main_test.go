package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

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
	if strings.Count(out, "kind: RepositoryCustomProperty\n") != 69 {
		t.Fatal("expected 23 repositories with three assignments")
	}
	for _, forbidden := range []string{"crossplane.io/external-name", "LateInitialize", "- Delete", "AutomaticallyRequestCopilotCodeReview", "LintDocumentation"} {
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
}

func (f *fakeAPI) call(method, path string, body []byte) ([]byte, error) {
	if method == "GET" {
		if f.failRead {
			return nil, errors.New("unavailable")
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

func TestSchemaReconciliationAndNoop(t *testing.T) {
	c := fixture(t)
	f := &fakeAPI{schema: append([]property{}, c.Properties...)}
	for i := range f.schema {
		f.schema[i].Source = "organization"
	}
	f.schema = append(f.schema, property{Name: c.Retire[0], Source: "organization"}, property{Name: c.Retire[1], Source: "organization"})
	if err := reconcile(c, f.call); err != nil {
		t.Fatal(err)
	}
	if len(f.writes) != 2 || !strings.HasPrefix(f.writes[0], "DELETE ") {
		t.Fatalf("unexpected changes: %v", f.writes)
	}
	f.writes = nil
	if err := reconcile(c, f.call); err != nil || len(f.writes) != 0 {
		t.Fatalf("matching retry changed state: %v %v", err, f.writes)
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
		if len(f.writes) != len(c.Properties) {
			t.Fatalf("expected one PUT per definition, got %v", f.writes)
		}
		for _, write := range f.writes {
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
