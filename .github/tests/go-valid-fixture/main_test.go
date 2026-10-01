package main

import "testing"

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
