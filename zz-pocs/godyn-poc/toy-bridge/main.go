// toy-bridge: D4 system-under-test for the godyn flake-input bridge.
//
// Imports github.com/amarbel-llc/tommy/pkg/cst, a real fork module sourced not
// from a module-proxy FOD but from tommy's `go-pkgs` output via a synthesized
// `replace github.com/amarbel-llc/tommy => <store-path>` (RFC 0001). cst.Parse
// builds a CST whose leaf bytes reconcatenate to the original input, so a
// successful byte-exact round-trip proves the bridged source compiled + ran.
package main

import (
	"fmt"
	"os"

	"github.com/amarbel-llc/tommy/pkg/cst"
)

func main() {
	input := "# godyn bridge\ntitle = \"flake-input bridge\"\n\n[server]\nport = 8080\n"
	node, err := cst.Parse([]byte(input))
	if err != nil {
		fmt.Fprintln(os.Stderr, "parse:", err)
		os.Exit(1)
	}
	if got := string(node.Bytes()); got != input {
		fmt.Fprintf(os.Stderr, "round-trip mismatch:\nwant %q\ngot  %q\n", input, got)
		os.Exit(1)
	}
	fmt.Printf("godyn-bridge ok: tommy/pkg/cst round-trip preserved %d bytes via the flake-input bridge\n", len(input))
}
