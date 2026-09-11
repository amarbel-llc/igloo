package main

import (
	"fmt"

	"example.com/cgopc/zv"
)

func main() {
	fmt.Println(zv.Mark(), zv.Mark2(), zv.Version() != "")
}
