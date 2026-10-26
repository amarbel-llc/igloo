package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

type Package struct {
	GoPackagePath string `json:"-"`
	Version       string `json:"version"`
	Hash          string `json:"hash"`
	ReplacedPath  string `json:"replaced,omitempty"`
}

type Sources map[string]string

func populateStruct(path string, data any) {
	pathVal := os.Getenv(path)
	if len(path) == 0 {
		panic(fmt.Sprintf("env var '%s' was unset", path))
	}
	path = pathVal

	b, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}

	err = json.Unmarshal(b, &data)
	if err != nil {
		panic(err)
	}
}

// populateOptional is populateStruct for an env var the caller may leave
// unset (an older mkVendorEnv passes no bridged modules).
func populateOptional(envName string, data any) {
	pathVal := os.Getenv(envName)
	if pathVal == "" {
		return
	}
	b, err := os.ReadFile(pathVal)
	if err != nil {
		panic(err)
	}
	if err := json.Unmarshal(b, data); err != nil {
		panic(err)
	}
}

func main() {
	sources := make(Sources)
	pkgs := make(map[string]*Package)

	populateStruct("sourcesPath", &sources)

	populateStruct("jsonPath", &pkgs)

	// Bridged modules (RFC 0001 goFlakeInputs): module path -> source tree.
	// They join the fetched modules' deepest-first pass, so a module whose
	// path nests under another bridged module's (go-mcp and
	// go-mcp/command/huh) lands inside the parent's materialized directory
	// instead of colliding with a symlink to the parent (spinclass#157).
	bridged := make(map[string]string)
	populateOptional("bridgedPath", &bridged)

	keys := make([]string, 0, len(pkgs)+len(bridged))
	for key := range pkgs {
		keys = append(keys, key)
	}
	for key, src := range bridged {
		if _, fetched := pkgs[key]; !fetched {
			keys = append(keys, key)
		}
		sources[key] = src
	}
	sort.Strings(keys)

	makeSymlinks(keys, sources)
}

// makeSymlinks places every module at vendor/<module path>, deepest path
// first: a module is a plain symlink to its source unless a deeper module
// already created directories under its path, in which case the directory is
// populated entry by entry around what is already there.
func makeSymlinks(keys []string, sources Sources) {
	// Iterate, in reverse order
	for i := len(keys) - 1; i >= 0; i-- {
		key := keys[i]
		src := sources[key]

		paths := []string{key}

		for _, path := range paths {
			vendorDir := filepath.Join("vendor", filepath.Dir(path))
			if err := os.MkdirAll(vendorDir, 0o755); err != nil {
				panic(err)
			}

			vendorPath := filepath.Join("vendor", path)
			if _, err := os.Lstat(vendorPath); err == nil {
				populateVendorPath(vendorPath, src)
				continue
			}

			// If the file doesn't already exist, just create a simple symlink
			err := os.Symlink(src, vendorPath)
			if err != nil {
				panic(err)
			}
		}
	}
}

// populateVendorPath fills an existing vendor directory with symlinks to
// src's entries. An entry that already exists is left alone: a real
// directory is descended into (a deeper module lives below it), a symlink or
// file was placed by a deeper module and is that module's.
func populateVendorPath(vendorPath string, src string) {
	entries, err := os.ReadDir(src)
	if err != nil {
		panic(err)
	}

	for _, e := range entries {
		innerSrc := filepath.Join(src, e.Name())
		dst := filepath.Join(vendorPath, e.Name())
		info, err := os.Lstat(dst)
		if err == nil {
			srcInfo, statErr := os.Stat(innerSrc)
			if info.IsDir() && statErr == nil && srcInfo.IsDir() {
				populateVendorPath(dst, innerSrc)
			}
			continue
		}
		if !os.IsNotExist(err) {
			panic(err)
		}
		if err := os.Symlink(innerSrc, dst); err != nil {
			panic(err)
		}
	}
}
