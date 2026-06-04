module godyn-bridge

go 1.26

require github.com/amarbel-llc/tommy v0.0.0

// tommy's own build-closure deps, pinned so go list resolves the module graph
// offline; the resolver injects `replace tommy => <go-pkgs store path>`.
require (
	github.com/dave/jennifer v1.7.1 // indirect
	golang.org/x/mod v0.34.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/tools v0.43.0 // indirect
)
