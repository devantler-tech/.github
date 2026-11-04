package main

import (
	"errors"
	"flag"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
)

// Native default callers must retain Go's own scheduling.
func TestDefaultParallelismReachesGo(t *testing.T) {
	want := strconv.Itoa(runtime.GOMAXPROCS(0))
	got := flag.Lookup("test.parallel")
	if got == nil || got.Value.String() != want {
		t.Fatalf("test worker count = %v, want %s", got, want)
	}
}

// Validation helpers must not become files the consumer's own tests can inspect.
func TestValidationHelperOutsideConsumerWorkspace(t *testing.T) {
	// Bind the cached verdict to collection mode and immutable helper source.
	// Go does not track filesystem observations outside this fixture module.
	t.Logf("validation context: %s/%s", os.Getenv("GO_DISK_WORKFLOW_SHA"), os.Getenv("MEASURE_DISK_USAGE"))
	_, err := os.Stat(filepath.Join("..", "..", "..", ".devantler-tech-go-disk"))
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("disk measurement helper remains in the consumer workspace: %v", err)
	}
}

// TestCacheSubject keeps non-Go test inputs observable when compilation is reused.
func TestCacheSubject(t *testing.T) {
	data, err := os.ReadFile("cache-subject.txt")
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "valid\n" {
		t.Fatalf("current cache subject = %q, want valid", data)
	}
}

func TestAdd(t *testing.T) {
	for _, tt := range []struct{ a, b, want int }{
		{2, 3, 5},
		{-2, 3, 1},
		{0, 0, 0},
	} {
		if got := add(tt.a, tt.b); got != tt.want {
			t.Fatalf("add(%d, %d) = %d, want %d", tt.a, tt.b, got, tt.want)
		}
	}
}
