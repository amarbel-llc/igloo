// Command app lives in a repository that holds a second go.nix module, sib,
// which it imports through a path replace (igloo#73: purse-first's shape).
package main

import (
	"fmt"

	"example.com/mm/sib"
)

func main() {
	fmt.Println(sib.Hello())
}
