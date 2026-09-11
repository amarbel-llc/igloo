package main

import (
	"fmt"

	"example.com/cgo/cadd"
)

func main() {
	fmt.Println(cadd.Add(2, 3))
}
