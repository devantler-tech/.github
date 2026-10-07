// The external kubectl boundary is synthetic; selection, supervision, and the
// caller's failure verdict execute the real production Bash script.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type call struct {
	Verb     string
	Target   string
	Previous bool
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
	os.Exit(1)
}
func check(ok bool, format string, args ...any) {
	if !ok {
		fail(format, args...)
	}
}
func appendLine(path, line string) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		panic(err)
	}
	if _, err := fmt.Fprintln(f, line); err != nil {
		_ = f.Close()
		panic(err)
	}
	if err := f.Close(); err != nil {
		panic(err)
	}
}
func inventory() ([]map[string]any, []map[string]any) {
	count, _ := strconv.Atoi(os.Getenv("DIAG_HISTORY"))
	pods := []map[string]any{}
	jobs := []map[string]any{}
	for _, name := range []string{"kustomize-controller", "helm-controller", "source-controller"} {
		pods = append(pods, map[string]any{"metadata": map[string]any{"namespace": "flux-system", "name": name, "creationTimestamp": "2026-10-07T00:00:00Z", "labels": map[string]any{"app": name}}, "status": map[string]any{"phase": "Running", "containerStatuses": []map[string]any{{"restartCount": 0, "state": map[string]any{"running": map[string]any{}}}}}})
	}
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("history-%04d", i)
		created := time.Unix(1700000000+int64(i), 0).UTC().Format(time.RFC3339)
		meta := map[string]any{"namespace": "demo", "name": name, "uid": "uid-" + name, "creationTimestamp": created}
		jobs = append(jobs, map[string]any{"metadata": meta, "status": map[string]any{"succeeded": 1, "conditions": []map[string]any{{"type": "Complete", "status": "True"}}}})
		pods = append(pods, map[string]any{"metadata": map[string]any{"namespace": "demo", "name": name, "creationTimestamp": created, "labels": map[string]any{"job-name": name}, "ownerReferences": []map[string]any{{"kind": "Job", "name": name, "uid": "uid-" + name}}}, "status": map[string]any{"phase": "Succeeded", "containerStatuses": []map[string]any{{"restartCount": 0, "state": map[string]any{"terminated": map[string]any{"exitCode": 0, "reason": "Completed"}}}}}})
	}
	if os.Getenv("DIAG_FAILURES") == "true" {
		for _, name := range []string{"crasher", "failed-job", "healthy"} {
			meta := map[string]any{"namespace": "demo", "name": name, "creationTimestamp": "2026-10-07T00:00:00Z"}
			status := map[string]any{"phase": "Running", "containerStatuses": []map[string]any{{"restartCount": 0, "state": map[string]any{"running": map[string]any{}}}}}
			if name == "crasher" {
				status["containerStatuses"] = []map[string]any{{"restartCount": 5, "state": map[string]any{"waiting": map[string]any{"reason": "CrashLoopBackOff"}}}}
			}
			if name == "failed-job" {
				meta["labels"] = map[string]any{"job-name": name}
				meta["ownerReferences"] = []map[string]any{{"kind": "Job", "name": name, "uid": "uid-failed"}}
				status["phase"] = "Failed"
				status["containerStatuses"] = []map[string]any{{"restartCount": 1, "state": map[string]any{"terminated": map[string]any{"exitCode": 1, "reason": "Error"}}}}
				jobs = append(jobs, map[string]any{"metadata": meta, "status": map[string]any{"failed": 1, "conditions": []map[string]any{{"type": "Failed", "status": "True"}}}})
			}
			pods = append(pods, map[string]any{"metadata": meta, "status": status})
		}
		jobs = append(jobs, map[string]any{"metadata": map[string]any{"namespace": "demo", "name": "false-failed-condition", "creationTimestamp": "2099-01-01T00:00:00Z"}, "status": map[string]any{"conditions": []map[string]any{{"type": "Failed", "status": "False"}}}})
	}
	if os.Getenv("DIAG_MODE") == "many-failures" {
		for i := 0; i < 100; i++ {
			name := fmt.Sprintf("error-%04d", i)
			meta := map[string]any{"namespace": "demo", "name": name, "uid": "uid-" + name, "creationTimestamp": time.Unix(1791331200+int64(i), 0).UTC().Format(time.RFC3339)}
			jobs = append(jobs, map[string]any{"metadata": meta, "status": map[string]any{"failed": 1, "conditions": []map[string]any{{"type": "Failed", "status": "True"}}}})
			pods = append(pods, map[string]any{"metadata": meta, "status": map[string]any{"phase": "Failed", "containerStatuses": []map[string]any{{"restartCount": 1, "state": map[string]any{"terminated": map[string]any{"exitCode": 1, "reason": "Error"}}}}}})
		}
	}
	if os.Getenv("DIAG_MODE") == "mixed-current" {
		for i := 0; i < 20; i++ {
			name := fmt.Sprintf("active-%04d", i)
			created := time.Unix(1800000000+int64(i), 0).UTC().Format(time.RFC3339)
			meta := map[string]any{"namespace": "demo", "name": name, "uid": "uid-" + name, "creationTimestamp": created, "labels": map[string]any{"job-name": name}, "ownerReferences": []map[string]any{{"kind": "Job", "name": name, "uid": "job-uid-" + name}}}
			pods = append(pods, map[string]any{"metadata": meta, "status": map[string]any{"phase": "Running", "containerStatuses": []map[string]any{{"restartCount": 0, "state": map[string]any{"running": map[string]any{}}}}}})
			jobs = append(jobs, map[string]any{"metadata": map[string]any{"namespace": "demo", "name": name, "uid": "job-uid-" + name, "creationTimestamp": created}, "status": map[string]any{"active": 1}})
		}
	}
	return pods, jobs
}
func stall() {
	appendLine(os.Getenv("DIAG_CHILD_PIDS"), strconv.Itoa(os.Getpid()))
	child := exec.Command("bash", "-c", `trap '' TERM; sleep 20 & printf '%s\n' "$!" >> "$DIAG_CHILD_PIDS"; wait`)
	child.Stdout = os.Stdout
	child.Stderr = os.Stderr
	if err := child.Start(); err != nil {
		panic(err)
	}
	appendLine(os.Getenv("DIAG_CHILD_PIDS"), strconv.Itoa(child.Process.Pid))
	_ = child.Wait()
}
func fakeKubectl() {
	args := []string{}
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "--request-timeout=") {
			continue
		}
		args = append(args, arg)
	}
	if len(args) == 0 {
		os.Exit(70)
	}
	joined := strings.Join(args, " ")
	c := call{Verb: args[0], Target: joined, Previous: strings.Contains(joined, "--previous")}
	if c.Verb == "logs" {
		for i := 0; i < len(args)-2; i++ {
			if args[i] == "-n" {
				c.Target = args[i+1] + "/" + args[i+2]
				break
			}
		}
		if strings.Contains(joined, "app=") {
			c.Target = strings.Split(joined, "app=")[1]
			c.Target = strings.Fields(c.Target)[0]
		}
		c.Target = strings.Replace(c.Target, "flux-system/deployment/", "flux-system/", 1)
	}
	encoded, _ := json.Marshal(c)
	appendLine(os.Getenv("DIAG_CALLS"), string(encoded))
	mode := os.Getenv("DIAG_MODE")
	if mode == "stall-all" || (mode == "stall-controller" && (c.Target == "kustomize-controller" || c.Target == "flux-system/kustomize-controller")) {
		stall()
		return
	}
	pods, jobs := inventory()
	switch {
	case joined == "get pods -A -o json":
		if mode == "read-failure" {
			fmt.Fprintln(os.Stderr, "fixture API unavailable")
			os.Exit(29)
		}
		if mode == "malformed" {
			fmt.Println(`{"items":"not-an-inventory"}`)
			return
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"items": pods})
	case joined == "get jobs -A -o json":
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"items": jobs})
	case strings.HasPrefix(joined, "get pods -A -l job-name"):
		for _, pod := range pods {
			meta := pod["metadata"].(map[string]any)
			labels, _ := meta["labels"].(map[string]any)
			if labels["job-name"] != nil {
				fmt.Printf("%s\t%s\n", meta["namespace"], meta["name"])
			}
		}
	case c.Verb == "logs":
		fmt.Println("useful log evidence " + c.Target)
	case c.Verb == "describe":
		fmt.Println("useful describe evidence " + joined)
	case c.Verb == "get" && (strings.HasPrefix(joined, "get nodes ") || strings.HasPrefix(joined, "get kustomizations.") || strings.HasPrefix(joined, "get helmreleases.") || strings.HasPrefix(joined, "get ocirepositories.") || strings.HasPrefix(joined, "get pods -n flux-system ") || joined == "get pods -A -o wide" || strings.HasPrefix(joined, "get events ")):
		fmt.Println("useful inventory evidence")
	default:
		appendLine(os.Getenv("DIAG_UNEXPECTED"), joined)
		fmt.Fprintln(os.Stderr, "unexpected fixture command: "+joined)
		os.Exit(70)
	}
}
func script(path string) string {
	body, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	lines := strings.Split(string(body), "\n")
	in := false
	blocks := 0
	extracted := []string{}
	for _, line := range lines {
		if line == "      run: |" {
			blocks++
			in = true
			continue
		}
		if in && line != "" && !strings.HasPrefix(line, "        ") {
			in = false
		}
		if in {
			extracted = append(extracted, strings.TrimPrefix(line, "        "))
		}
	}
	check(blocks == 1, "expected one actual action run block, found %d", blocks)
	return strings.Join(extracted, "\n") + "\n"
}

type result struct {
	calls    []call
	output   string
	duration time.Duration
	code     int
	children []int
}

type process struct {
	parent int
	state  string
}

func processes() (map[int]process, error) {
	data, err := exec.Command("ps", "-axo", "pid=,ppid=,stat=").Output()
	if err != nil {
		return nil, err
	}
	all := map[int]process{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 3 {
			return nil, fmt.Errorf("invalid process observation")
		}
		pid, pidErr := strconv.Atoi(fields[0])
		parent, parentErr := strconv.Atoi(fields[1])
		if pidErr != nil || parentErr != nil || pid <= 0 || parent < 0 {
			return nil, fmt.Errorf("invalid process identity")
		}
		all[pid] = process{parent, fields[2]}
	}
	if _, present := all[os.Getpid()]; !present {
		return nil, fmt.Errorf("incomplete process observation")
	}
	return all, nil
}

func run(source, mode string, history int, failures bool, request, deadline string, kustomizations string) result {
	dir, err := os.MkdirTemp("", "diagnose-contract-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	exe, err := os.Executable()
	if err != nil {
		panic(err)
	}
	if err = os.Symlink(exe, filepath.Join(dir, "kubectl")); err != nil {
		panic(err)
	}
	path := filepath.Join(dir, "action.bash")
	if err = os.WriteFile(path, []byte(source), 0600); err != nil {
		panic(err)
	}
	callsFile := filepath.Join(dir, "calls")
	childFile := filepath.Join(dir, "children")
	unexpected := filepath.Join(dir, "unexpected")
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", path)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	cmd.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"), "RUNNER_TEMP="+dir, "DIAG_CALLS="+callsFile, "DIAG_CHILD_PIDS="+childFile, "DIAG_UNEXPECTED="+unexpected, "DIAG_MODE="+mode, "DIAG_HISTORY="+strconv.Itoa(history), "DIAG_FAILURES="+strconv.FormatBool(failures), "KUSTOMIZATIONS="+kustomizations, "REQUEST_TIMEOUT_SECONDS="+request, "COLLECTION_TIMEOUT_SECONDS="+deadline)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	started := time.Now()
	err = cmd.Start()
	if err != nil {
		panic(err)
	}
	// Observe only descendants of this disposable action process. This catches
	// abandoned watchdog sleeps as well as the deliberately stalled API helper.
	observed := map[int]bool{}
	var mu sync.Mutex
	var observationErr error
	stop := make(chan struct{})
	joined := make(chan struct{})
	go func() {
		defer close(joined)
		for {
			all, readErr := processes()
			mu.Lock()
			if readErr != nil {
				observationErr = readErr
				mu.Unlock()
				return
			}
			for pid := range all {
				for parent, depth := all[pid].parent, 0; parent > 1 && depth < 32; parent, depth = all[parent].parent, depth+1 {
					if parent == cmd.Process.Pid || observed[parent] {
						observed[pid] = true
						break
					}
				}
			}
			mu.Unlock()
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	err = cmd.Wait()
	close(stop)
	<-joined
	r := result{output: output.String(), duration: time.Since(started)}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			r.code = exit.ExitCode()
		} else {
			r.code = -1
		}
	}
	data, _ := os.ReadFile(callsFile)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		var c call
		if err = json.Unmarshal(scanner.Bytes(), &c); err != nil {
			panic(err)
		}
		r.calls = append(r.calls, c)
	}
	data, _ = os.ReadFile(childFile)
	for _, field := range strings.Fields(string(data)) {
		pid, parseErr := strconv.Atoi(field)
		check(parseErr == nil && pid > 1, "invalid synthetic child identity %q", field)
		r.children = append(r.children, pid)
	}
	for pid := range observed {
		r.children = append(r.children, pid)
	}
	data, _ = os.ReadFile(unexpected)
	all, readErr := processes()
	if readErr != nil || observationErr != nil {
		for _, pid := range r.children {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
		fail("process observation unavailable: observer=%v final=%v", observationErr, readErr)
	}
	alive := []int{}
	for _, pid := range r.children {
		state, present := all[pid]
		if present && !strings.HasPrefix(state.state, "Z") {
			_ = syscall.Kill(pid, syscall.SIGKILL)
			alive = append(alive, pid)
		}
	}
	check(len(alive) == 0, "diagnostic children still running after action returned: %v", alive)
	check(len(data) == 0, "unexpected commands: %s", data)
	return r
}
func logs(r result) []call {
	out := []call{}
	for _, c := range r.calls {
		if c.Verb == "logs" {
			out = append(out, c)
		}
	}
	return out
}
func has(r result, target string) bool {
	for _, c := range r.calls {
		if c.Verb == "logs" && c.Target == target {
			return true
		}
	}
	return false
}
func main() {
	if filepath.Base(os.Args[0]) == "kubectl" {
		fakeKubectl()
		return
	}
	check(len(os.Args) >= 2, "action path required")
	source := script(os.Args[1])
	selected := "all"
	if len(os.Args) > 2 {
		selected = os.Args[2]
	}
	if selected == "mutants" {
		body, err := os.ReadFile(os.Args[1])
		if err != nil {
			panic(err)
		}
		type mutation struct {
			name, from, to, scenario, reason string
			count                            int
		}
		mutations := []mutation{
			{"failure priority", "sort_by(if failing then 1 else 0 end,\n                .metadata.creationTimestamp", "sort_by(.metadata.creationTimestamp", "priority", "new healthy Jobs crowded actual failures out of the Pod cap", 1},
			{"historical cap", "(.[:5][] | [.metadata.namespace,.metadata.name] | @tsv)", "(.[] | [.metadata.namespace,.metadata.name] | @tsv)", "fanout", "unbounded retained Job fan-out", 1},
			{"current Pod cap", "pods: .[:20]", "pods: .", "many-failures", "current-failure fan-out unbounded", 1},
			{"failed Job cap", "(.[:10][] | if", "(.[] | if", "many-failures", "failed Job descriptions or omission reporting unbounded", 1},
			{"request timer", "sleep \"$budget\"", "sleep \"$COLLECTION_TIMEOUT_SECONDS\"", "stalled", "stalled read exceeds collection bound", 1},
			{"descendant cleanup", "kill -KILL -- \"-$active_pid\"", "kill -KILL -- \"$active_pid\"", "stalled", "diagnostic children still running", 2},
			{"unavailable evidence", "echo \"::warning::$label unavailable: command failed or timed out (status $status).\"", ":", "unavailable", "evidence silently treated as empty", 1},
			{"maximum deadline", "(( COLLECTION_TIMEOUT_SECONDS > 120 ))", "(( COLLECTION_TIMEOUT_SECONDS > 999 ))", "limits", "invalid bounds authorized collection", 1},
			{"false Failed condition", ".type == \"Failed\" and .status == \"True\"", ".type == \"Failed\"", "failures", "false Failed condition classified as current failure", 1},
		}
		dir, err := os.MkdirTemp("", "diagnose-mutants-")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)
		exe, err := os.Executable()
		if err != nil {
			panic(err)
		}
		for _, m := range mutations {
			check(strings.Count(string(body), m.from) == m.count, "mutation %s source anchor changed", m.name)
			path := filepath.Join(dir, "action.yaml")
			if err = os.WriteFile(path, []byte(strings.ReplaceAll(string(body), m.from, m.to)), 0600); err != nil {
				panic(err)
			}
			output, err := exec.Command(exe, path, m.scenario).CombinedOutput()
			var exit *exec.ExitError
			check(errors.As(err, &exit) && exit.ExitCode() == 1 && strings.Contains(string(output), m.reason), "mutation %s not rejected for its own reason: %s (%v)", m.name, output, err)
			fmt.Println("PASS rejects mutation: " + m.name)
		}
		return
	}
	if selected == "all" {
		dir, err := os.MkdirTemp("", "diagnose-observer-control-")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)
		if err = os.WriteFile(filepath.Join(dir, "ps"), []byte("#!/usr/bin/env bash\nexit 29\n"), 0700); err != nil {
			panic(err)
		}
		exe, err := os.Executable()
		if err != nil {
			panic(err)
		}
		child := exec.Command(exe, os.Args[1], "stalled")
		child.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"))
		output, err := child.CombinedOutput()
		var exit *exec.ExitError
		check(errors.As(err, &exit) && exit.ExitCode() == 1 && strings.Contains(string(output), "process observation unavailable"), "unavailable process observer accepted cleanup proof: %s (%v)", output, err)
		fmt.Println("PASS unavailable process observation cannot prove cleanup")
	}
	if selected == "baseline" {
		for _, sample := range [][2]int{{0, 3}, {100, 103}, {1000, 1003}} {
			n := sample[0]
			r := run(source, "normal", n, false, "1", "5", "infrastructure apps")
			check(r.code == 0, "baseline action did not complete: %s", r.output)
			check(len(logs(r)) == sample[1], "baseline fixture is inconsistent: history=%d logs=%d", n, len(logs(r)))
			fmt.Printf("BASELINE history=%d logs=%d duration_ms=%d\n", n, len(logs(r)), r.duration.Milliseconds())
		}
		return
	}
	if selected == "all" || selected == "fanout" {
		for _, n := range []int{0, 100, 1000} {
			r := run(source, "normal", n, false, "1", "5", "infrastructure apps")
			fmt.Printf("OBSERVATION history=%d logs=%d duration_ms=%d\n", n, len(logs(r)), r.duration.Milliseconds())
			check(r.code == 0, "best-effort collection returned %d: %s", r.code, r.output)
			check(len(logs(r)) <= 23, "unbounded retained Job fan-out: %d Jobs caused %d log requests", n, len(logs(r)))
			if n > 0 {
				check(has(r, fmt.Sprintf("demo/history-%04d", n-1)), "newest completed Job evidence absent")
				check(!has(r, "demo/history-0000"), "oldest historical Job collected despite newer evidence")
				check(strings.Contains(strings.ToLower(r.output), "omitted"), "historical omissions not reported")
			}
		}
		fmt.Println("PASS bounded historical fan-out and newest evidence")
	}
	if selected == "all" || selected == "failures" {
		r := run(source, "normal", 1000, true, "1", "5", "infrastructure apps")
		check(r.code == 0 && has(r, "demo/crasher") && has(r, "demo/failed-job"), "current failure evidence missing: %s", r.output)
		check(!has(r, "demo/healthy"), "healthy ordinary Pod logs collected")
		check(len(logs(r)) <= 27, "failure diagnostics have unbounded historical fan-out")
		for _, target := range []string{"demo/crasher", "demo/failed-job"} {
			previous, current := false, false
			for _, c := range logs(r) {
				if c.Target == target {
					if c.Previous {
						previous = true
					} else {
						current = true
					}
				}
			}
			check(previous && current, "previous/current evidence absent for %s", target)
		}
		described := false
		for _, c := range r.calls {
			if c.Verb == "describe" {
				check(!strings.Contains(c.Target, "false-failed-condition"), "false Failed condition classified as current failure")
				if strings.Contains(c.Target, "job -n demo failed-job") {
					described = true
				}
			}
		}
		check(described, "current failed Job description missing")
		fmt.Println("PASS current failures retain previous/current logs")
	}
	if selected == "all" || selected == "many-failures" {
		r := run(source, "many-failures", 1000, true, "1", "5", "infrastructure apps")
		check(r.code == 0 && len(logs(r)) <= 48, "current-failure fan-out unbounded: %d logs", len(logs(r)))
		check(has(r, "demo/error-0099") && !has(r, "demo/error-0000"), "large failure set did not prioritize newest evidence")
		jobDescribes := 0
		for _, c := range r.calls {
			if c.Verb == "describe" && strings.HasPrefix(c.Target, "describe job ") {
				jobDescribes++
			}
		}
		check(jobDescribes <= 10 && strings.Contains(strings.ToLower(r.output), "omitted"), "failed Job descriptions or omission reporting unbounded")
		fmt.Printf("PASS large failure set logs=%d job_descriptions=%d\n", len(logs(r)), jobDescribes)
	}
	if selected == "all" || selected == "priority" {
		r := run(source, "mixed-current", 1000, true, "1", "5", "infrastructure apps")
		check(r.code == 0 && has(r, "demo/crasher") && has(r, "demo/failed-job"), "new healthy Jobs crowded actual failures out of the Pod cap")
		check(has(r, "demo/active-0019") && !has(r, "demo/active-0000"), "active Jobs not ordered newest-first within their secondary class")
		firstFailure, firstActive := len(r.calls), len(r.calls)
		for i, c := range r.calls {
			if c.Verb == "logs" && (c.Target == "demo/crasher" || c.Target == "demo/failed-job") && i < firstFailure {
				firstFailure = i
			}
			if c.Verb == "logs" && strings.Contains(c.Target, "demo/active-") && i < firstActive {
				firstActive = i
			}
		}
		check(firstFailure < firstActive && len(logs(r)) <= 48 && strings.Contains(strings.ToLower(r.output), "omitted"), "failure-first ordering, cap or omission report missing")
		fmt.Println("PASS older failures outrank newer healthy active Jobs")
	}
	if selected == "all" || selected == "stalled" {
		r := run(source, "stall-controller", 0, true, "1", "3", "infrastructure apps")
		fmt.Printf("OBSERVATION stalled_request duration_ms=%d logs=%d observed_children=%d\n", r.duration.Milliseconds(), len(logs(r)), len(r.children))
		check(r.code == 0 && r.duration < 2500*time.Millisecond, "stalled read exceeds collection bound: code=%d duration=%s", r.code, r.duration)
		check(has(r, "demo/crasher"), "stalled controller prevented useful current failure evidence")
		check(strings.Contains(r.output, "kustomize-controller logs unavailable"), "stalled request not reported as unavailable")
		check(len(r.children) >= 2, "stalled child fixture did not execute")
		fmt.Println("PASS stalled request bounded and descendants stopped")
	}
	if selected == "all" || selected == "deadline" {
		r := run(source, "stall-all", 1000, true, "2", "2", "infrastructure apps")
		fmt.Printf("OBSERVATION collection_deadline duration_ms=%d requests=%d observed_children=%d\n", r.duration.Milliseconds(), len(r.calls), len(r.children))
		check(r.code == 0 && r.duration < 3500*time.Millisecond, "overall deadline exceeded: code=%d duration=%s", r.code, r.duration)
		check(len(r.calls) <= 2, "continued collection after overall deadline: %d requests", len(r.calls))
		check(strings.Contains(strings.ToLower(r.output), "deadline"), "overall deadline omitted from report")
		fmt.Println("PASS overall deadline prevents further requests")
	}
	if selected == "all" || selected == "unavailable" {
		for _, mode := range []string{"read-failure", "malformed"} {
			r := run(source, mode, 100, true, "1", "5", "infrastructure apps")
			want := "Pod inventory unavailable"
			if mode == "malformed" {
				want = "Pod selection unavailable"
			}
			check(r.code == 0 && strings.Contains(r.output, want), "%s evidence silently treated as empty: %s", mode, r.output)
			check(has(r, "flux-system/kustomize-controller"), "inventory failure erased independent controller evidence")
		}
		fmt.Println("PASS failed and malformed inventories report unavailable evidence")
	}
	if selected == "all" || selected == "limits" {
		for _, values := range [][2]string{{"0", "5"}, {"-1", "5"}, {"1", "0"}, {"1", "121"}, {"x", "5"}, {"31", "5"}} {
			r := run(source, "normal", 0, false, values[0], values[1], "apps")
			check(r.code == 0 && len(r.calls) == 0 && strings.Contains(strings.ToLower(r.output), "unavailable"), "invalid bounds authorized collection: %v", values)
		}
		r := run(source, "normal", 0, false, "1", "5", strings.Repeat("apps ", 1000))
		describes := 0
		for _, c := range r.calls {
			if c.Verb == "describe" {
				describes++
			}
		}
		check(describes <= 10 && strings.Contains(strings.ToLower(r.output), "omitted"), "unbounded Kustomization fan-out: %d", describes)
		fmt.Println("PASS invalid limits fail closed and describe fan-out is bounded")
	}
	fmt.Println("PASS diagnose-flux behavioral contract")
}
