package guard

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const issueQuery = "query($owner:String!,$repo:String!,$issue_number:Int!){repository(owner:$owner,name:$repo){issue(number:$issue_number){id}}}"
const addQuery = "mutation($projectId:ID!,$contentId:ID!){addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){item{id}}}"

func compactQuery(q string) string { return strings.Join(strings.Fields(q), "") }
func (g *guard) graphql(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" || r.URL.RawQuery != "" || r.URL.Fragment != "" || r.Host != "api.github.com" || g.cfg.ProjectToken == "" || r.Header.Get("Authorization") != "Bearer "+g.cfg.ProjectToken || g.diffPending {
		g.fail(w, "unexpected project credential or route")
		return
	}
	b, e := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if e != nil || len(b) > 1<<20 {
		g.fail(w, "project request incomplete")
		return
	}
	v, e := decode(b)
	m, ok := v.(map[string]any)
	if e != nil || !ok || len(m) != 2 {
		g.fail(w, "malformed project request")
		return
	}
	query, okQuery := m["query"].(string)
	variables, okVars := m["variables"].(map[string]any)
	if !okQuery || !okVars {
		g.fail(w, "malformed project document")
		return
	}
	parts := strings.Split(g.cfg.Project, "/")
	if len(parts) != 3 || (parts[0] != "organization" && parts[0] != "user") || parts[1] == "" || parts[2] == "" {
		g.fail(w, "configured project selector invalid")
		return
	}
	projectQuery := fmt.Sprintf("query($owner:String!){%s(login:$owner){projectsV2(first:10){nodes{idtitle}}}}", parts[0])
	doc := compactQuery(query)
	switch {
	case doc == projectQuery:
		if len(variables) != 1 || variables["owner"] != parts[1] {
			g.fail(w, "unbound project discovery")
			return
		}
		g.discoverProject(w, r, parts)
	case doc == issueQuery:
		owner, repo, _ := strings.Cut(g.cfg.Repository, "/")
		n, ok := integer(variables["issue_number"])
		if len(variables) != 3 || variables["owner"] != owner || variables["repo"] != repo || !ok || !g.issues[n] {
			g.fail(w, "unbound project issue read")
			return
		}
		p, data, e := g.projectFetch(r, query, variables)
		if e != nil {
			g.fail(w, "project issue read failed")
			return
		}
		id, ok := nested(data, "repository", "issue", "id").(string)
		if !ok || id == "" {
			g.fail(w, "project issue identity incomplete")
			return
		}
		g.issueIDs[id] = true
		writeResponse(w, p)
	case doc == addQuery:
		project, okProject := variables["projectId"].(string)
		issue, okIssue := variables["contentId"].(string)
		if len(variables) != 2 || !okProject || !okIssue || !g.projectIDs[project] || !g.issueIDs[issue] {
			g.fail(w, "unbound project mutation")
			return
		}
		g.mutationStarted = true
		p, data, e := g.projectFetch(r, query, variables)
		if e != nil {
			g.fail(w, "project addition failed")
			return
		}
		id, ok := nested(data, "addProjectV2ItemById", "item", "id").(string)
		if !ok || id == "" {
			g.fail(w, "project addition unverified")
			return
		}
		writeResponse(w, p)
	default:
		g.fail(w, "unexpected project document")
	}
}
func nested(v any, keys ...string) any {
	for _, key := range keys {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[key]
	}
	return v
}
func (g *guard) projectFetch(r *http.Request, query string, variables map[string]any) (response, map[string]any, error) {
	b, e := json.Marshal(map[string]any{"query": query, "variables": variables})
	if e != nil {
		return response{}, nil, e
	}
	p, e := g.fetch(r, &url.URL{Path: "/graphql"}, b)
	if e != nil || p.code != 200 {
		return response{}, nil, fmt.Errorf("incomplete project response")
	}
	v, e := decode(p.body)
	m, ok := v.(map[string]any)
	if e != nil || !ok {
		return response{}, nil, fmt.Errorf("malformed project response")
	}
	if errors, exists := m["errors"]; exists {
		rows, ok := errors.([]any)
		if !ok || len(rows) != 0 {
			return response{}, nil, fmt.Errorf("project API error")
		}
	}
	data, ok := m["data"].(map[string]any)
	if !ok {
		return response{}, nil, fmt.Errorf("project data incomplete")
	}
	return p, data, nil
}
func (g *guard) discoverProject(w http.ResponseWriter, r *http.Request, parts []string) {
	kind, owner, selector := parts[0], parts[1], parts[2]
	number, e := strconv.Atoi(selector)
	if e == nil {
		if number <= 0 || strconv.Itoa(number) != selector {
			g.fail(w, "numeric project selector invalid")
			return
		}
		query := fmt.Sprintf("query($owner:String!,$number:Int!){%s(login:$owner){projectV2(number:$number){id title number}}}", kind)
		p, data, e := g.projectFetch(r, query, map[string]any{"owner": owner, "number": number})
		if e != nil {
			g.fail(w, "numeric project read failed")
			return
		}
		project, ok := nested(data, kind, "projectV2").(map[string]any)
		id, okID := project["id"].(string)
		title, okTitle := project["title"].(string)
		gotNumber, okNumber := integer(project["number"])
		if !ok || !okID || id == "" || !okTitle || title == "" || !okNumber || gotNumber != number {
			g.fail(w, "numeric project identity incomplete")
			return
		}
		g.projectIDs[id] = true
		// The unchanged child matches titles; adapt only the verified selected identity.
		p.body, _ = json.Marshal(map[string]any{"data": map[string]any{kind: map[string]any{"projectsV2": map[string]any{"nodes": []any{map[string]any{"id": id, "title": selector}}}}}})
		writeResponse(w, p)
		return
	}
	query := fmt.Sprintf("query($owner:String!,$cursor:String){%s(login:$owner){projectsV2(first:100,after:$cursor){nodes{id title} pageInfo{hasNextPage endCursor}}}}", kind)
	cursor := any(nil)
	cursors := map[string]bool{}
	ids := map[string]bool{}
	nodes := []any{}
	selected := ""
	var first response
	for page := 0; page < 100; page++ {
		p, data, e := g.projectFetch(r, query, map[string]any{"owner": owner, "cursor": cursor})
		if e != nil {
			g.fail(w, "complete project discovery failed")
			return
		}
		if page == 0 {
			first = p
		}
		connection, ok := nested(data, kind, "projectsV2").(map[string]any)
		rows, okRows := connection["nodes"].([]any)
		info, okInfo := connection["pageInfo"].(map[string]any)
		hasNext, okNext := info["hasNextPage"].(bool)
		if !ok || !okRows || !okInfo || !okNext {
			g.fail(w, "project page incomplete")
			return
		}
		for _, row := range rows {
			node, ok := row.(map[string]any)
			id, okID := node["id"].(string)
			title, okTitle := node["title"].(string)
			if !ok || !okID || id == "" || !okTitle || title == "" || ids[id] {
				g.fail(w, "project identity contradictory")
				return
			}
			ids[id] = true
			nodes = append(nodes, row)
			if title == selector {
				if selected != "" {
					g.fail(w, "project title ambiguous")
					return
				}
				selected = id
			}
		}
		if !hasNext {
			if selected == "" {
				g.fail(w, "configured project not found")
				return
			}
			g.projectIDs[selected] = true
			first.body, _ = json.Marshal(map[string]any{"data": map[string]any{kind: map[string]any{"projectsV2": map[string]any{"nodes": nodes}}}})
			writeResponse(w, first)
			return
		}
		next, ok := info["endCursor"].(string)
		if !ok || next == "" || cursors[next] || len(rows) == 0 {
			g.fail(w, "project cursor incomplete")
			return
		}
		cursors[next] = true
		cursor = next
	}
	g.fail(w, "project page ceiling exceeded")
}
