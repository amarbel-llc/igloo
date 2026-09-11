package main

import (
	"fmt"

	"example.com/cgopc/zv"
)

func main() {
	fmt.Println(zv.Mark(), zv.Version() != "")
}
