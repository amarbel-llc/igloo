// D3 system-under-test: round-trips data through github.com/DataDog/zstd, a
// cgo module that vendors its own C source. Proves the resolver's cgo path
// (go tool cgo -> cc -> dynimport -> compile -> pack) + external linking.
package main

import (
	"bytes"
	"fmt"

	"github.com/DataDog/zstd"
)

func main() {
	orig := []byte("godyn cgo zstd round-trip works")
	comp, err := zstd.Compress(nil, orig)
	if err != nil {
		panic(err)
	}
	out, err := zstd.Decompress(nil, comp)
	if err != nil {
		panic(err)
	}
	if !bytes.Equal(orig, out) {
		panic("round-trip mismatch")
	}
	fmt.Printf("godyn-cgo ok: %d bytes -> %d compressed, round-trip OK: %q\n",
		len(orig), len(comp), string(out))
}
