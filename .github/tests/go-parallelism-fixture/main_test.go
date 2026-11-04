package main

import (
	"flag"
	"testing"
)

// The expected value is independent of workflow outputs and environment bindings.
func TestEightWorkersReachGo(t *testing.T) {
	got := flag.Lookup("test.parallel")
	if got == nil || got.Value.String() != "8" {
		t.Fatalf("test worker count = %v, want 8", got)
	}
	if value() != 7 {
		t.Fatal("fixture result changed")
	}
}
