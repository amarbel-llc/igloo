package main

import "testing"

func TestFixtureBurnedIn(t *testing.T) {
	if fixture != "burned" {
		t.Fatalf("fixture = %q, want testLdflagsX to set it", fixture)
	}
}
