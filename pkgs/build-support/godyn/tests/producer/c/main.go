// Command c consumes producer p; q reaches it only through p's goFlakeInputs.
package main

import (
	"fmt"

	"example.com/p"
)

func main() { fmt.Println(p.Wrap()) }
