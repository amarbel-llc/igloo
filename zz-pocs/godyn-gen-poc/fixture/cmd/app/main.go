package main

import (
	"fmt"
	"os"

	"example.com/gen/internal/bravo/cfg"
)

func main() {
	doc, err := cfg.DecodeConfig([]byte("name = \"world\"\nshout = true\n"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(doc.Data().Greet())
}
