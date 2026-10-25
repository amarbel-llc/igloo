// Command mcommit is a go.nix module (FDR 0008) that prints the commit godyn
// stamps as -X main.commit. The flake check builds it with buildGoAuto from a
// source derivation that carries `rev` and asserts BOTH backends embed it
// (igloo#91: the bga backend lost it behind the manifest's rendered tree).
package main

import "fmt"

var commit = "unset"

func main() {
	fmt.Printf("commit=%s\n", commit)
}
