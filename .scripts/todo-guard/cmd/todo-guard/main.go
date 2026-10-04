package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	guard "github.com/devantler-tech/dotgithub/scripts/todo-guard"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

func configuration() (*guard.Guard, error) {
	api, e := url.Parse(os.Getenv("INPUT_GITHUB_URL"))
	if e != nil || api.Scheme != "https" || api.Host == "" || api.User != nil || api.RawQuery != "" || api.Fragment != "" {
		return nil, errors.New("configured API origin invalid")
	}
	repo := os.Getenv("INPUT_REPO")
	if !regexp.MustCompile("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$").MatchString(repo) {
		return nil, errors.New("configured repository invalid")
	}
	sha := os.Getenv("INPUT_SHA")
	if !regexp.MustCompile("^[0-9a-f]{40}$").MatchString(sha) {
		return nil, errors.New("configured source commit invalid")
	}
	server, e := url.Parse(os.Getenv("INPUT_GITHUB_SERVER_URL"))
	if e != nil || server.Scheme != "https" || server.Host == "" || server.User != nil || server.Path != "" || server.RawQuery != "" || server.Fragment != "" {
		return nil, errors.New("configured repository origin invalid")
	}
	token := os.Getenv("INPUT_TOKEN")
	if token == "" {
		return nil, errors.New("issue authentication missing")
	}
	project := os.Getenv("INPUT_PROJECT")
	projectToken := os.Getenv("INPUT_PROJECTS_SECRET")
	if project != "" && (projectToken == "" || api.Host != "api.github.com" || api.Path != "") {
		return nil, errors.New("configured project authentication or API unsupported")
	}
	before, e := comparisonBase(os.Getenv("INPUT_BEFORE"), os.Getenv("INPUT_COMMITS"))
	if e != nil {
		return nil, e
	}
	if strings.ContainsAny(before, "?#\n\r") {
		return nil, errors.New("configured comparison ref invalid")
	}
	g := guard.New(guard.Config{API: api, Repository: repo, Server: server.String(), Token: token, SHA: sha, Before: before, Project: project, ProjectToken: projectToken}, nil)
	return g, nil
}
func comparisonBase(before, commits string) (string, error) {
	if before != strings.Repeat("0", 40) {
		return before, nil
	}
	var rows []struct {
		ID        string `json:"id"`
		Timestamp string `json:"timestamp"`
	}
	if e := json.Unmarshal([]byte(commits), &rows); e != nil {
		return "", errors.New("configured commit context invalid")
	}
	if len(rows) < 2 {
		return "", nil
	}
	for _, row := range rows {
		if !regexp.MustCompile("^[0-9a-f]{40}$").MatchString(row.ID) {
			return "", errors.New("configured commit identity invalid")
		}
		if _, e := time.Parse(time.RFC3339, row.Timestamp); e != nil {
			return "", errors.New("configured commit timestamp invalid")
		}
	}
	// Match the pinned scanner's stable lexical timestamp ordering.
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Timestamp < rows[j].Timestamp })
	return rows[0].ID, nil
}
func run() error {
	g, e := configuration()
	if e != nil {
		return e
	}
	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(signalCtx, 20*time.Minute)
	defer cancel()
	return guard.RunChild(ctx, g, []string{"/usr/bin/python3.11", "/app/main.py"}, os.Environ(), os.Stdout)
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "::error::"+e.Error())
		os.Exit(1)
	}
}
