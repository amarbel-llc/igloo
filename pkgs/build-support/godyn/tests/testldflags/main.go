// Command testld prints a variable only its TEST binary gets burned in via -X
// (madder's prebuilt-fixture TestMain shape: a package main under test).
package main

import "fmt"

var fixture = "unset"

func main() { fmt.Println(fixture) }
