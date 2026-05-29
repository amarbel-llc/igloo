goSourceFilter(7) ["amarbel-llc/igloo"]

# NAME

goSourceFilter - Go source-tree filter for the go-pkgs producer convention

# SYNOPSIS

```
packages.${system}.go-pkgs = pkgs.goSourceFilter {
  src = ./.;
  extras = [ "^doc/.*" "^VERSION$" ];
};
```

# DESCRIPTION

*pkgs.goSourceFilter* produces a **derivation** whose output is the
filtered tree of a Go project's source. The result satisfies the
strictest flake-output gate (*nix flake check* requires *isDerivation*
to be true; see amarbel-llc/nixpkgs#44) and is suitable for direct use
as a *packages.${system}.go-pkgs* flake output (per RFC 0001) and as
*src* to *buildGoApplication* via the *goFlakeInputs* bridge.
Internally the filter is built with *builtins.path* and wrapped in a
*runCommand* that copies the filtered tree into *$out*.

The default keep-set is the minimum required by the Go build system,
plus the canonical workspace files, plus the *gomod2nix.toml*
lockfile:

- *\*.go* — any Go source file
- *go.mod* / *go.sum* / *gomod2nix.toml* — matched by basename
  anywhere in the tree, so go.work-based workspaces' child module
  files (e.g. *libs/dewey/go.mod*) survive the filter
- *go.work* / *go.work.sum* — root-only (these only ever live at the
  workspace root; single-module producers don't ship these — the
  regexes match nothing in that case)

All other files are dropped. The *extras* argument adds additional
patterns; see *EXTRAS* below.

# ARGUMENTS

- *src* — a path or derivation containing the Go source tree.
- *extras* — list of POSIX extended-regex strings (default: empty)
  that augment the default keep-set. Patterns match the source-tree
  relative path of each file.

# EXTRAS

*extras* are applied via *builtins.path* internally (with a filter
predicate); the resulting filtered tree is then wrapped in a
*runCommand* derivation. Directories are always traversed (so the
filter composes on deep trees), and the regex list (default keep-set
plus *extras*) is matched against the source-tree-relative path of
each regular file via *builtins.match*. Patterns are *regex* strings,
not glob patterns; nixpkgs stdlib does not ship glob matching.

Examples:

```
# Keep the doc/ subtree
extras = [ "^doc/.*" ];

# Keep a single root file
extras = [ "^VERSION$" ];

# Keep all *.tmpl files
extras = [ ".*\\.tmpl$" ];

# Combine
extras = [ "^doc/.*" "^VERSION$" ".*\\.tmpl$" ];
```

# STORE PATH NAMING

*goSourceFilter* preserves *src.name*. The resulting store path is
named identically to *src*. Producers who want a more diagnostic name
can re-wrap with another *runCommand* so the renamed output is also a
derivation (passes *nix flake check*):

```
pkgs.runCommand "${src.name}-go-source" { } ''
  cp -r ${pkgs.goSourceFilter { inherit src; }} $out
''
```

# MIDDLEWARE WRAPPER

*pkgs.goSourceFilterMiddleware* is a 1-line *src -> src* wrapper
around *goSourceFilter*. It exists for composition with the (deferred)
*mkGoPkgsWithMiddleware* pipeline (provisional name; see
*RFC 0001 § Producers with codegen (deferred)*):

```
packages.${system}.go-pkgs = pkgs.mkGoPkgsWithMiddleware {
  src = self;
  middlewares = [
    pkgs.goSourceFilterMiddleware
    pkgs.dagnabitExportMiddleware  # example future middleware
  ];
};
```

# LIMITATIONS

- *extras* uses regex, not globs (no nixpkgs stdlib equivalent of
  *fnmatch*).
- Store-path naming preserves *src.name* by default; rename by
  re-wrapping with *runCommand* if desired (see STORE PATH NAMING).
- *goSourceFilter* operates on *src* as a single tree. Multi-module
  repos with separate Go modules in different subdirectories need
  per-module filter invocations.
- Empty directories with no matching descendants are preserved in
  the filtered output (a consequence of always-traversing directories);
  this is harmless for *go build*.

# SEE ALSO

*gomod2nix*(7), *lib.sources.sourceByRegex*,
*docs/rfcs/0001-flake-input-go_mod.md*.
