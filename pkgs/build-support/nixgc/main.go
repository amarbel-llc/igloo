// Command nixgc performs targeted Nix store garbage collection: given a set of
// seed store paths, it computes the dead subgraph anchored at them and deletes it
// in one `nix-store --delete`, relying on Nix's own liveness refusal as the safety
// net. Anything reachable from a live GC root is kept.
//
// Extracted + generalized from spinclass's internal/nixgc (igloo#28): spinclass
// reaps the closure of worktree-resident GC roots; this CLI takes arbitrary seed
// paths and adds a --with-referrers expansion so it also handles content-addressed
// builds, where a dead output is referenced by a sibling .drv reachable only via
// `nix-store --referrers`, not via the requisite closure.
//
// Usage:
//
//	nixgc reap [--with-referrers] [--dry-run] [-v] <store-path>...
//
// The seeds are typically a build's output (or .drv) path. Deletion order puts
// referrers (.drv files) before referents (outputs), which is required for CA
// outputs.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "reap" {
		fmt.Fprintln(os.Stderr, "usage: nixgc reap [--with-referrers] [--dry-run] [-v] <store-path>...")
		os.Exit(2)
	}
	var withReferrers, dryRun, verbose bool
	var seeds []string
	for _, a := range os.Args[2:] {
		switch a {
		case "--with-referrers":
			withReferrers = true
		case "--dry-run", "-n":
			dryRun = true
		case "-v", "--verbose":
			verbose = true
		default:
			if strings.HasPrefix(a, "-") {
				fatalf("unknown flag %q", a)
			}
			seeds = append(seeds, a)
		}
	}
	if len(seeds) == 0 {
		fatalf("no seed store paths given")
	}
	if _, err := exec.LookPath("nix-store"); err != nil {
		fatalf("nix-store not on PATH")
	}
	if err := reap(seeds, withReferrers, dryRun, verbose); err != nil {
		fatalf("%v", err)
	}
}

// reap computes the dead subgraph anchored at the seeds and deletes it.
func reap(seeds []string, withReferrers, dryRun, verbose bool) error {
	// 1. Everything reachable from a live GC root — the keep set. Subtracting it
	//    up front sidesteps nix-store --delete's fail-fast on the first still-live
	//    path in the batch (spinclass issue #73).
	roots, err := gcRootStorePaths()
	if err != nil {
		return fmt.Errorf("reading gc roots: %w", err)
	}
	alive, err := closureOf(roots)
	if err != nil {
		return fmt.Errorf("expanding live closure: %w", err)
	}
	aliveSet := toSet(alive)

	// 2. The seeds' requisite closure (reverse-requisites: rooted paths first,
	//    deps last), minus anything kept alive. Target the dead OUTPUTS (non-.drv)
	//    only — never the dependency .drvs in the closure (deleting those would
	//    force re-instantiating the base derivation graph for no gain). Seed a
	//    build's .drv to pull its CA output paths (its inputSrcs) into the
	//    closure; seed the output too / instead for the input-addressed case.
	seedClosure, err := closureOf(seeds)
	if err != nil {
		return fmt.Errorf("expanding seed closure: %w", err)
	}
	var deadOutputs []string
	for _, p := range filterOut(seedClosure, aliveSet) {
		if !strings.HasSuffix(p, ".drv") {
			deadOutputs = append(deadOutputs, p)
		}
	}
	deadSet := toSet(deadOutputs)

	// 3. CA: a dead output is referenced by sibling .drv(s) not in its closure.
	//    BFS over --referrers, collecting the dead referrers (the .drvs) so the
	//    outputs become deletable. Stop at live paths (the safety boundary).
	var drvFirst []string
	if withReferrers {
		refs, err := deadReferrers(deadOutputs, aliveSet, deadSet)
		if err != nil {
			return fmt.Errorf("expanding referrers: %w", err)
		}
		drvFirst = refs // referrers (.drv) must precede their referent outputs
	}

	if os.Getenv("NIXGC_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "[nixgc] roots=%d alive=%d seedClosure=%d deadOutputs=%d referrers=%d\n",
			len(roots), len(alive), len(seedClosure), len(deadOutputs), len(drvFirst))
	}

	// 4. Final delete order: referrers first, then the dead outputs (rooted-first).
	deletable := dedupe(append(append([]string{}, drvFirst...), deadOutputs...))
	if len(deletable) == 0 {
		fmt.Println("nixgc: nothing to reap (all seed paths are live or already gone)")
		return nil
	}

	if dryRun {
		fmt.Printf("nixgc: would delete %d path(s):\n", len(deletable))
		for _, p := range deletable {
			fmt.Println("  " + p)
		}
		return nil
	}

	return deleteBatch(deletable, verbose)
}

// gcRootStorePaths returns the store path of every GC root (`nix-store --gc
// --print-roots`), skipping censored ({...}) and malformed lines.
func gcRootStorePaths() ([]string, error) {
	out, err := run("--gc", "--print-roots")
	if err != nil {
		return nil, err
	}
	var paths []string
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.Contains(line, "{") {
			continue
		}
		idx := strings.Index(line, " -> ")
		if idx < 0 {
			continue
		}
		store := strings.TrimSpace(line[idx+len(" -> "):])
		if store != "" {
			paths = append(paths, store)
		}
	}
	return paths, nil
}

// closureOf returns the deduped requisite closure of paths in delete-safe order:
// `nix-store --query --requisites` prints deps first and the path itself last, so
// we reverse to put rooted paths before their dependencies.
func closureOf(paths []string) ([]string, error) {
	if len(paths) == 0 {
		return nil, nil
	}
	out, err := run(append([]string{"--query", "--requisites"}, paths...)...)
	if err != nil {
		return nil, err
	}
	var ordered []string
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		if p := strings.TrimSpace(sc.Text()); p != "" {
			ordered = append(ordered, p)
		}
	}
	// reverse + dedupe (first/highest occurrence wins)
	seen := map[string]bool{}
	res := make([]string, 0, len(ordered))
	for i := len(ordered) - 1; i >= 0; i-- {
		if !seen[ordered[i]] {
			seen[ordered[i]] = true
			res = append(res, ordered[i])
		}
	}
	return res, nil
}

// deadReferrers does a BFS over `nix-store --query --referrers`, collecting paths
// that reference any dead path and are themselves dead (not in aliveSet, not
// already in the dead closure). These are the sibling .drv files that block CA
// output deletion; returned referrers-first.
func deadReferrers(deadOrdered []string, aliveSet, deadSet map[string]bool) ([]string, error) {
	found := map[string]bool{}
	var result []string
	queue := append([]string{}, deadOrdered...)
	for len(queue) > 0 {
		out, err := run(append([]string{"--query", "--referrers"}, queue...)...)
		if err != nil {
			return nil, err
		}
		var next []string
		sc := bufio.NewScanner(strings.NewReader(out))
		for sc.Scan() {
			p := strings.TrimSpace(sc.Text())
			if p == "" || aliveSet[p] || deadSet[p] || found[p] {
				continue
			}
			found[p] = true
			result = append(result, p)
			next = append(next, p) // its referrers may also be dead
		}
		queue = next
	}
	return result, nil
}

// deleteBatch deletes paths via `nix-store --delete`, retrying the remainder after
// each batch. nix-store fail-fasts on the first un-deletable path (a still-live
// path, or a TOCTOU root that materialised after the plan), aborting the batch and
// leaving the rest unprocessed. Each round we drop the paths nix reported as
// deleted or kept and retry the remainder, so progress continues past a refusal
// until nothing more can be deleted. Genuinely-live paths settle into Kept.
func deleteBatch(paths []string, verbose bool) error {
	sizes := pathSizes(paths)
	remaining := append([]string{}, paths...)
	var totReclaimed, totKept int
	var totFreed int64
	keptSet := map[string]bool{}

	for len(remaining) > 0 {
		cmd := exec.Command("nix-store", append([]string{"--delete"}, remaining...)...)
		var buf strings.Builder
		cmd.Stdout = &buf
		cmd.Stderr = &buf
		_ = cmd.Run()
		out := buf.String()
		if verbose {
			fmt.Fprint(os.Stderr, out)
		}

		deleted := quotedAfter(out, "deleting '")
		var kept []string
		kept = append(kept, quotedAfter(out, "cannot delete path '")...)
		kept = append(kept, quotedAfter(out, "Cannot delete path '")...)

		done := toSet(deleted)
		for _, p := range kept {
			done[p] = true
			keptSet[p] = true
		}
		for _, p := range deleted {
			totFreed += sizes[p]
		}
		totReclaimed += len(deleted)

		if len(deleted) == 0 {
			// No progress this round — the remainder is all blocked/live. Stop.
			break
		}
		var next []string
		for _, p := range remaining {
			if !done[p] {
				next = append(next, p)
			}
		}
		remaining = next
	}
	totKept = len(keptSet)

	fmt.Printf("nixgc: reaped %d path(s), %s freed; %d kept (live)\n",
		totReclaimed, humanize(totFreed), totKept)
	if len(remaining) > 0 {
		// remaining had no progress in the final round and weren't classified as
		// kept — surface them so a stuck closure is visible rather than silent.
		blocked := 0
		for _, p := range remaining {
			if !keptSet[p] {
				blocked++
			}
		}
		if blocked > 0 {
			fmt.Printf("nixgc: %d path(s) could not be deleted (blocked by a live referrer)\n", blocked)
		}
	}
	return nil
}

// pathSizes maps store path -> NAR size via `nix-store --query --size`. Best
// effort: returns an empty map (size 0) on any failure.
func pathSizes(paths []string) map[string]int64 {
	sizes := map[string]int64{}
	out, err := run(append([]string{"--query", "--size"}, paths...)...)
	if err != nil {
		return sizes
	}
	sc := bufio.NewScanner(strings.NewReader(out))
	i := 0
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if i < len(paths) {
			if n, err := strconv.ParseInt(line, 10, 64); err == nil {
				sizes[paths[i]] = n
			}
		}
		i++
	}
	return sizes
}

func quotedAfter(s, prefix string) []string {
	var res []string
	for start := 0; ; {
		idx := strings.Index(s[start:], prefix)
		if idx < 0 {
			break
		}
		a := start + idx + len(prefix)
		c := strings.Index(s[a:], "'")
		if c < 0 {
			break
		}
		res = append(res, s[a:a+c])
		start = a + c + 1
	}
	return res
}

func run(args ...string) (string, error) {
	out, err := exec.Command("nix-store", args...).Output()
	return string(out), err
}

func toSet(xs []string) map[string]bool {
	s := make(map[string]bool, len(xs))
	for _, x := range xs {
		s[x] = true
	}
	return s
}

func filterOut(xs []string, drop map[string]bool) []string {
	res := make([]string, 0, len(xs))
	for _, x := range xs {
		if !drop[x] {
			res = append(res, x)
		}
	}
	return res
}

func dedupe(xs []string) []string {
	seen := map[string]bool{}
	res := make([]string, 0, len(xs))
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			res = append(res, x)
		}
	}
	return res
}

func humanize(n int64) string {
	if n < 1024 {
		return fmt.Sprintf("%d B", n)
	}
	v := float64(n)
	for _, u := range []string{"KiB", "MiB", "GiB", "TiB"} {
		v /= 1024
		if v < 1024 {
			return fmt.Sprintf("%.1f %s", v, u)
		}
	}
	return fmt.Sprintf("%.1f PiB", v/1024)
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "nixgc: "+format+"\n", a...)
	os.Exit(1)
}
