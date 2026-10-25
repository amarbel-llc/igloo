// Package vettests is clean under vet; its test file is not (igloo#90). The
// flake checks assert the test-variant run reports the finding while the
// package's own run stays green.
package vettests

func Name() string { return "vettests" }
