package main

import (
	"os"
	"testing"
)

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
