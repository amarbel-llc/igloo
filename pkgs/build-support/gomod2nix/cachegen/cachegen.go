package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func main() {
	// Read package paths from command line args or stdin
	var pkgs []string

	if len(os.Args) > 1 {
		// Read from command line arguments
		for _, arg := range os.Args[1:] {
			pkg := strings.TrimSpace(arg)
			if pkg != "" {
				pkgs = append(pkgs, pkg)
			}
		}
	} else {
		// Read from stdin
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line != "" {
				pkgs = append(pkgs, line)
			}
		}
		if err := scanner.Err(); err != nil {
			panic(err)
		}
	}

	// Generate Go file with blank imports
	fmt.Println("package main")
	fmt.Println()
	fmt.Println("import (")

	for _, pkgPath := range pkgs {
		// Use blank import to ensure package is compiled without being used
		fmt.Printf("\t_ %q\n", pkgPath)
	}

	fmt.Println(")")
	fmt.Println()
	fmt.Println("func main() {}")
}
