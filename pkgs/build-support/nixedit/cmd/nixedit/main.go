// Command nixedit is the command-line face of the nixedit package: targeted,
// byte-preserving surgery on a flake.nix (igloo#64; lifted from doppelgang's
// internal/0/nixedit, whose lint --fix drove the same operations in-process).
//
// Every subcommand reads one flake.nix and either prints the result (default)
// or rewrites the file in place with -w. Exit status 2 means the shallow Nix
// grammar could not parse the file (nixedit.ErrUnparseable) and nothing was
// changed; callers fall back to report-only, as doppelgang does.
//
//	nixedit apply            [-w] FLAKE LINE...        splice follows bindings (`inputs.X.inputs.Y.follows = "Z"`); LINEs from stdin when none given
//	nixedit delete           [-w] FLAKE ATTRPATH...    remove follows bindings by full attr-path
//	nixedit overrides             FLAKE                list follows overrides, one full attr-path per line
//	nixedit input-names           FLAKE                list the top-level input names
//	nixedit input-url             FLAKE INPUT          print an input's url (exit 1 when absent)
//	nixedit set-input-url    [-w] FLAKE INPUT URL      pin an input's url, splicing the binding when missing
//	nixedit outputs-formals       FLAKE                print the outputs signature shape (closed|ellipsis|simple-arg|absent) and its names
//	nixedit widen-outputs    [-w] FLAKE                append `...` to a closed outputs formals set
//	nixedit canonical             FLAKE                report canonical-form opt-in and scattered inputs
//	nixedit canonical-fix    [-w] FLAKE                relocate scattered follows and migrate the legacy sentinel
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	nixedit "code.linenisgreat.com/igloo/pkgs/build-support/nixedit"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(64)
	}
	sub, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet("nixedit "+sub, flag.ExitOnError)
	write := fs.Bool("w", false, "rewrite the flake.nix in place instead of printing the result")
	if err := fs.Parse(args); err != nil {
		os.Exit(64)
	}
	rest := fs.Args()
	if len(rest) < 1 {
		usage()
		os.Exit(64)
	}
	path := rest[0]
	src, err := os.ReadFile(path)
	if err != nil {
		fatal(err)
	}

	var out []byte
	changed := true
	switch sub {
	case "apply":
		lines := rest[1:]
		if len(lines) == 0 {
			lines = readLines(os.Stdin)
		}
		var applied []string
		out, applied, err = nixedit.Apply(src, lines)
		report(err)
		changed = len(applied) > 0
		for _, l := range applied {
			fmt.Fprintln(os.Stderr, "applied:", l)
		}
	case "delete":
		var removed []string
		out, removed, err = nixedit.DeleteBindings(src, rest[1:])
		report(err)
		changed = len(removed) > 0
		for _, r := range removed {
			fmt.Fprintln(os.Stderr, "removed:", r)
		}
	case "overrides":
		list, err := nixedit.Overrides(src)
		report(err)
		printLines(list)
		return
	case "input-names":
		names, err := nixedit.InputNames(src)
		report(err)
		printLines(names)
		return
	case "input-url":
		if len(rest) != 2 {
			usage()
			os.Exit(64)
		}
		url, present, err := nixedit.InputURL(src, rest[1])
		report(err)
		if !present {
			os.Exit(1)
		}
		fmt.Println(url)
		return
	case "set-input-url":
		if len(rest) != 3 {
			usage()
			os.Exit(64)
		}
		out, changed, err = nixedit.SetInputURL(src, rest[1], rest[2])
		report(err)
	case "outputs-formals":
		shape, names, err := nixedit.OutputsFormals(src)
		report(err)
		fmt.Println(shape.String(), strings.Join(names, " "))
		return
	case "widen-outputs":
		out, changed, err = nixedit.WidenOutputsFormals(src)
		report(err)
	case "canonical":
		rep, err := nixedit.CanonicalForm(src)
		report(err)
		fmt.Printf("enabled=%v legacy-sentinel=%v scattered=%s\n", rep.Enabled, rep.LegacySentinel, strings.Join(rep.Scattered, ","))
		return
	case "canonical-fix":
		out, changed, err = canonicalFix(src)
		report(err)
	default:
		usage()
		os.Exit(64)
	}

	if !changed {
		fmt.Fprintln(os.Stderr, "nixedit: nothing to change")
	}
	if *write {
		if changed {
			if err := os.WriteFile(path, out, 0o644); err != nil {
				fatal(err)
			}
		}
		return
	}
	if _, err := os.Stdout.Write(out); err != nil {
		fatal(err)
	}
}

// canonicalFix is the delete-then-reapply-then-migrate pipeline doppelgang's
// lint --fix runs (and the package's own tests exercise as runCanonicalFormFix).
func canonicalFix(src []byte) (out []byte, changed bool, err error) {
	del, add, err := nixedit.CanonicalFormFixTargets(src)
	if err != nil {
		return nil, false, err
	}
	out = src
	if len(del) > 0 {
		if out, _, err = nixedit.DeleteBindings(out, del); err != nil {
			return nil, false, err
		}
		if out, _, err = nixedit.Apply(out, add); err != nil {
			return nil, false, err
		}
		changed = true
	}
	var migrated bool
	if out, migrated, err = nixedit.MigrateLegacySentinel(out); err != nil {
		return nil, false, err
	}
	return out, changed || migrated, nil
}

func readLines(r io.Reader) []string {
	var lines []string
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		if l := strings.TrimSpace(sc.Text()); l != "" {
			lines = append(lines, l)
		}
	}
	return lines
}

func printLines(list []string) {
	for _, l := range list {
		fmt.Println(l)
	}
}

// report exits with the documented status for a parse failure and with 1 for
// anything else; a nil error returns.
func report(err error) {
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, "nixedit:", err)
	if errors.Is(err, nixedit.ErrUnparseable) {
		os.Exit(2)
	}
	os.Exit(1)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "nixedit:", err)
	os.Exit(1)
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage: nixedit SUBCOMMAND [-w] FLAKE [ARGS...]
  apply FLAKE LINE...        delete FLAKE ATTRPATH...   overrides FLAKE
  input-names FLAKE          input-url FLAKE INPUT      set-input-url FLAKE INPUT URL
  outputs-formals FLAKE      widen-outputs FLAKE        canonical FLAKE
  canonical-fix FLAKE
-w rewrites FLAKE in place; without it the result is printed. Exit 2: not parseable.`)
}
