// Command cn consumes the nested pair a and a/sub from one producer tree.
package main

import (
	"fmt"

	"example.com/n/a"
	"example.com/n/a/sub"
)

func main() { fmt.Println(a.Name(), "+", sub.Name()) }
