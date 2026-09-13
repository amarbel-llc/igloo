// Command racefix reports whether it was built with -race (the race build tag).
package main

import "fmt"

func main() { fmt.Println(raceMode) }
