// Package asmpkg exposes Add, whose body lives in asm_amd64.s — so the package
// has GoFiles (this declaration) + SFiles (the Plan 9 asm), forcing native.nix
// down the asm compile-kind branch (gensymabis → compile -symabis -asmhdr →
// assemble → pack).
package asmpkg

// Add returns a + b. Implemented in asm_amd64.s.
func Add(a, b int64) int64
