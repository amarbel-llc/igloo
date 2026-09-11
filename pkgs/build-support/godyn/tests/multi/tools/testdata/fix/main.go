// Command fix lives under testdata/, which ./... skips: only an explicit
// subPackages entry selects it (clown's fixture mains).
package main

import "fmt"

func main() { fmt.Println("hello from testdata fixture") }
