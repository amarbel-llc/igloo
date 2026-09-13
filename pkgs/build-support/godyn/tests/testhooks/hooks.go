// Package hooks' tests need a writable HOME set up by testPreRun and must be
// filtered by testFlags (tommy's generate/fuzz-sweep shape).
package hooks

func Name() string { return "hooks" }
