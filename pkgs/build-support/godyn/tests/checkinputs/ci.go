// Package ci's test shells out to a tool that must come from nativeCheckInputs
// (clown's git-backed tests shape).
package ci

func Name() string { return "ci" }
