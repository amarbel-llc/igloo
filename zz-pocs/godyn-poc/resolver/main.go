// godyn-resolver: a throwaway, native reimplementation of numtide/go2nix's
// "dynamic mode" resolve step, scoped to the godyn-poc. It runs INSIDE a
// recursive-nix wrapper derivation: it fetches third-party modules as
// fixed-output derivations, assembles a GOMODCACHE, discovers the Go package
// graph with `go list`, then emits one floating-CA derivation per package
// (compiled via `go tool compile`) plus a link derivation (`go tool link`),
// registering each with `nix derivation add` and realising it with
// `nix build`. The final link .drv is copied to $out; the Nix-side wrapper's
// `builtins.outputOf` resolves that to the binary.
//
// POC simplifications (vs. the real numtide resolver): shells out to the `nix`
// CLI rather than the daemon socket; references dependency COMPILE OUTPUTS by
// concrete CA store path (content-addressed, so isolation still holds); reads
// the module h1/ziphash from the lockfile instead of recomputing dirhash.
// Supports cgo (C + .S/.sx asm) and the flake-input bridge (--bridge); no
// cross-compilation / modinfo (out of scope per the plan).
package main

import (
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// ---- flags -----------------------------------------------------------------

type config struct {
	src       string
	stdlib    string
	goBin     string
	bash      string
	coreutils string
	cc        string // stdenv cc-wrapper store path (for cgo packages)
	cacert    string // for the module-fetch FODs (SSL_CERT_FILE)
	lockfile  string            // optional: third-party module pins
	bridges   map[string]string // modpath -> go-pkgs store path (flake-input bridge)
	tags      string            // optional: build tags (-tags) for go list file selection
	system    string
	pname     string
	out       string
	nixBin    string
	goVersion string
}

func main() {
	var c config
	flag.StringVar(&c.src, "src", "", "store path of module source")
	flag.StringVar(&c.stdlib, "stdlib", "", "stdlib derivation output")
	flag.StringVar(&c.goBin, "go", "", "go toolchain store path")
	flag.StringVar(&c.bash, "bash", "", "bash store path")
	flag.StringVar(&c.coreutils, "coreutils", "", "coreutils store path")
	flag.StringVar(&c.cc, "cc", "", "stdenv cc-wrapper store path (for cgo)")
	flag.StringVar(&c.cacert, "cacert", "", "cacert store path (for module FODs)")
	flag.StringVar(&c.lockfile, "lockfile", "", "third-party module lockfile (optional)")
	flag.StringVar(&c.tags, "tags", "", "build tags (comma-separated) for go list file selection")
	c.bridges = map[string]string{}
	flag.Func("bridge", "flake-input bridge: modpath=go-pkgs-store-path (repeatable)", func(s string) error {
		i := strings.IndexByte(s, '=')
		if i <= 0 {
			return fmt.Errorf("bad --bridge %q (want modpath=store-path)", s)
		}
		c.bridges[s[:i]] = s[i+1:]
		return nil
	})
	flag.StringVar(&c.system, "system", "x86_64-linux", "nix system")
	flag.StringVar(&c.pname, "pname", "godyn", "binary name")
	flag.StringVar(&c.out, "out", "", "wrapper $out (link .drv written here)")
	flag.StringVar(&c.nixBin, "nix", "nix", "path to nix binary")
	flag.StringVar(&c.goVersion, "go-version", "go1.26", "-lang version")
	flag.Parse()

	for _, req := range []struct{ name, val string }{
		{"src", c.src}, {"stdlib", c.stdlib}, {"go", c.goBin},
		{"bash", c.bash}, {"coreutils", c.coreutils}, {"out", c.out},
	} {
		if req.val == "" {
			fatalf("missing required flag --%s", req.name)
		}
	}
	if err := run(c); err != nil {
		fatalf("%v", err)
	}
}

// ---- core flow -------------------------------------------------------------

func run(c config) error {
	// 1. Fetch third-party modules (FODs) and assemble a GOMODCACHE.
	locks, err := parseLockfile(c.lockfile)
	if err != nil {
		return fmt.Errorf("lockfile: %w", err)
	}
	fodPaths := map[string]string{} // modKey -> extracted-tree store path
	for _, l := range locks {
		fp, err := c.buildFOD(l)
		if err != nil {
			return fmt.Errorf("fetch %s: %w", l.modKey(), err)
		}
		fodPaths[l.modKey()] = fp
		fmt.Fprintf(os.Stderr, "[godyn] fetched %s -> %s\n", l.modKey(), fp)
	}
	gomodcache, err := setupGOMODCACHE(fodPaths, locks)
	if err != nil {
		return fmt.Errorf("assembling GOMODCACHE: %w", err)
	}

	// 2. Discover the package graph.
	pkgs, modulePath, err := c.goListDeps(gomodcache)
	if err != nil {
		return fmt.Errorf("go list: %w", err)
	}

	// 3. Compile each non-stdlib package (local + third-party) in dependency
	//    order (`go list -deps` yields deps-before-dependents).
	compiled := map[string]string{} // import path -> "<caOut>/pkg.a"
	var mainPkg *pkg
	var order []*pkg
	for i := range pkgs {
		p := &pkgs[i]
		if p.stdlib {
			continue
		}
		order = append(order, p)
		if p.Name == "main" {
			mainPkg = p
		}
	}
	if mainPkg == nil {
		return fmt.Errorf("no package main found")
	}
	cgoUsed := false
	for _, p := range order {
		if len(p.CgoFiles) > 0 {
			cgoUsed = true
		}
		caOut, err := c.buildCompileDrv(p, compiled, fodPaths)
		if err != nil {
			return fmt.Errorf("compile %s: %w", p.ImportPath, err)
		}
		compiled[p.ImportPath] = caOut + "/pkg.a"
		fmt.Fprintf(os.Stderr, "[godyn] compiled %s -> %s\n", p.ImportPath, caOut)
	}

	// 4. Link.
	linkDrv, err := c.buildLinkDrv(mainPkg, modulePath, compiled, cgoUsed)
	if err != nil {
		return fmt.Errorf("link: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[godyn] link drv: %s\n", linkDrv)
	if err := copyFile(linkDrv, c.out); err != nil {
		return fmt.Errorf("writing link .drv to $out: %w", err)
	}
	return nil
}

// ---- lockfile + module fetch (FOD) -----------------------------------------

type moduleLock struct {
	path, version, narHash, h1, replace string
}

func (l moduleLock) fetchPath() string {
	if l.replace != "" {
		return l.replace
	}
	return l.path
}
func (l moduleLock) modKey() string { return l.path + "@" + l.version }

func parseLockfile(path string) ([]moduleLock, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []moduleLock
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 4 {
			return nil, fmt.Errorf("bad lockfile line: %q (want: path version nar-sri h1 [replace])", line)
		}
		l := moduleLock{path: f[0], version: f[1], narHash: f[2], h1: f[3]}
		if len(f) >= 5 {
			l.replace = f[4]
		}
		out = append(out, l)
	}
	return out, nil
}

// buildFOD registers and realises a fixed-output derivation that
// `go mod download`s the module and outputs its extracted source tree.
func (c config) buildFOD(l moduleLock) (string, error) {
	dirSuffix := escapeMod(l.fetchPath()) + "@" + escapeMod(l.version)
	cacertExport := ""
	if c.cacert != "" {
		cacertExport = "export SSL_CERT_FILE=" + shq(c.cacert+"/etc/ssl/certs/ca-bundle.crt") + "\n"
	}
	script := fmt.Sprintf(`set -euo pipefail
export HOME="$TMPDIR"
export PATH=%s/bin
export GOMODCACHE="$TMPDIR/modcache"
export GOSUMDB=off
export GONOSUMCHECK='*'
%s%s mod download %s
cp -r "$TMPDIR/modcache/"%s "$out"
`,
		shq(c.coreutils),
		cacertExport,
		shq(c.goBin+"/bin/go"),
		shq(l.fetchPath()+"@"+l.version),
		shq(dirSuffix),
	)
	drv := c.newFODDrv("gomod-"+sanitize(l.path)+"-"+l.version, script, l.narHash)
	drv.addInputSrc(c.coreutils)
	drv.addInputSrc(c.goBin)
	drv.addInputSrc(c.bash)
	if c.cacert != "" {
		drv.addInputSrc(c.cacert)
	}
	return c.registerAndBuild(drv)
}

// setupGOMODCACHE places each FOD's extracted tree at <epath>@<ever>/ and
// synthesises the minimal cache/download metadata `go list` checks.
func setupGOMODCACHE(fodPaths map[string]string, locks []moduleLock) (string, error) {
	if len(fodPaths) == 0 {
		return "", nil
	}
	byKey := map[string]moduleLock{}
	for _, l := range locks {
		byKey[l.modKey()] = l
	}
	root, err := os.MkdirTemp(buildTop(), "gomodcache-")
	if err != nil {
		return "", err
	}
	for modKey, fod := range fodPaths {
		l := byKey[modKey]
		ep := escapeMod(l.fetchPath())
		ev := escapeMod(l.version)

		extracted := filepath.Join(root, ep+"@"+ev)
		if err := os.MkdirAll(filepath.Dir(extracted), 0o755); err != nil {
			return "", err
		}
		// Symlink the whole extracted tree from the FOD store path.
		if err := os.Symlink(fod, extracted); err != nil {
			return "", err
		}

		dl := filepath.Join(root, "cache", "download", ep, "@v")
		if err := os.MkdirAll(dl, 0o755); err != nil {
			return "", err
		}
		gomod, err := os.ReadFile(filepath.Join(fod, "go.mod"))
		if os.IsNotExist(err) {
			gomod = []byte("module " + l.fetchPath() + "\n")
		} else if err != nil {
			return "", err
		}
		writes := []struct {
			name string
			data []byte
		}{
			{ev + ".mod", gomod},
			{ev + ".info", []byte(`{"Version":"` + l.version + `"}`)},
			{ev + ".ziphash", []byte(l.h1)},
			{ev + ".lock", nil},
		}
		for _, w := range writes {
			if err := os.WriteFile(filepath.Join(dl, w.name), w.data, 0o644); err != nil {
				return "", err
			}
		}
	}
	return root, nil
}

// escapeMod implements module.EscapePath/EscapeVersion: uppercase letters are
// rewritten to "!"+lowercase so the on-disk path is case-insensitive-safe.
func escapeMod(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if ch >= 'A' && ch <= 'Z' {
			b.WriteByte('!')
			b.WriteByte(ch + ('a' - 'A'))
		} else {
			b.WriteByte(ch)
		}
	}
	return b.String()
}

// ---- go list ---------------------------------------------------------------

type pkg struct {
	ImportPath string
	Name       string
	Dir        string
	GoFiles    []string
	CgoFiles   []string
	CFiles     []string
	HFiles     []string
	// Unsupported-in-POC source kinds; presence triggers a clear error.
	CXXFiles     []string
	SFiles       []string
	FFiles       []string
	SwigFiles    []string
	SwigCXXFiles []string
	Imports      []string
	Standard     bool
	Module     *struct {
		Path    string
		Main    bool
		Version string
		Replace *struct {
			Path    string
			Version string
		}
	}
	// computed
	local      bool
	stdlib     bool
	thirdParty bool
	bridged    bool // sourced from a flake-input go-pkgs store path via replace
	modKey     string
	subdir     string
}

func (c config) goListDeps(gomodcache string) ([]pkg, string, error) {
	top := buildTop()
	if gomodcache == "" {
		d, err := os.MkdirTemp(top, "gomodcache-empty-")
		if err != nil {
			return nil, "", err
		}
		gomodcache = d
	}
	// Flake-input bridge: go list (and downstream compiles) must see the
	// synthesized `replace <mod> => <store-path>` directives, so it runs in a
	// writable copy of the source with the edited go.mod, not the read-only
	// store path. Only the go.mod is rewritten; .go contents are untouched, so
	// staged local sources hash identically to a non-bridged build.
	listDir := c.src
	if len(c.bridges) > 0 {
		d, err := c.applyBridges()
		if err != nil {
			return nil, "", fmt.Errorf("applying bridges: %w", err)
		}
		listDir = d
	}
	// Build tags govern go list's file selection (GoFiles/CgoFiles/SFiles);
	// per-package compile then just compiles those files, so threading -tags
	// here is the only lever the POC needs for tag-gated builds.
	listArgs := []string{"list", "-json", "-deps"}
	if c.tags != "" {
		listArgs = append(listArgs, "-tags="+c.tags)
	}
	listArgs = append(listArgs, "./...")
	cmd := exec.Command(c.goBin+"/bin/go", listArgs...)
	cmd.Dir = listDir
	env := append(os.Environ(),
		"GOROOT="+c.goBin+"/share/go",
		"GOMODCACHE="+gomodcache,
		"GOFLAGS=-mod=mod",
		"GOPROXY=off",
		"GOWORK=off",
		"GOSUMDB=off",
		"GONOSUMCHECK=*",
		"GO111MODULE=on",
		"GODEBUG=embedfollowsymlinks=1",
		"GOCACHE="+filepath.Join(top, "golist-cache"),
		"HOME="+top,
	)
	// CGO_ENABLED governs whether `go list` includes CgoFiles; enable it when
	// a cc-wrapper is available so cgo packages are surfaced.
	if c.cc != "" {
		env = append(env, "CGO_ENABLED=1", "CC="+c.cc+"/bin/cc")
	} else {
		env = append(env, "CGO_ENABLED=0")
	}
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return nil, "", fmt.Errorf("%w\nstderr: %s", err, ee.Stderr)
		}
		return nil, "", err
	}

	var pkgs []pkg
	dec := json.NewDecoder(strings.NewReader(string(out)))
	for dec.More() {
		var p pkg
		if err := dec.Decode(&p); err != nil {
			return nil, "", fmt.Errorf("decoding go list json: %w", err)
		}
		pkgs = append(pkgs, p)
	}

	var modulePath string
	for i := range pkgs {
		p := &pkgs[i]
		switch {
		case p.Standard:
			p.stdlib = true
		case p.Module != nil && p.Module.Main:
			p.local = true
			modulePath = p.Module.Path
		case p.Module != nil && p.Module.Replace != nil && c.bridges[p.Module.Path] != "":
			// Bridged: source comes straight from the replace dir (a go-pkgs
			// store path), not a proxy FOD. p.Dir already points into it.
			p.bridged = true
		case p.Module != nil:
			// Third-party. The POC has no replaced third-party modules, so the
			// modKey is just the resolved path@version (matching the lockfile).
			p.thirdParty = true
			p.modKey = p.Module.Path + "@" + p.Module.Version
			sub := strings.TrimPrefix(p.ImportPath, p.Module.Path)
			sub = strings.TrimPrefix(sub, "/")
			if sub == "" {
				sub = "."
			}
			p.subdir = sub
		}
	}
	return pkgs, modulePath, nil
}

// ---- compile / link derivations -------------------------------------------

func (c config) buildCompileDrv(p *pkg, compiled map[string]string, fodPaths map[string]string) (string, error) {
	// Resolve the package's source dir + the store path to declare as input.
	var srcDir, srcInput string
	if p.local {
		staged, err := c.stageSource(p)
		if err != nil {
			return "", err
		}
		srcDir, srcInput = staged, staged
	} else if p.bridged {
		// Source is already in the store (the bridged module's go-pkgs output);
		// p.Dir points at the package inside it. Declare the store-object root
		// as the derivation input so the whole bridged tree is in the sandbox.
		srcDir = p.Dir
		srcInput = storeRoot(p.Dir)
	} else { // third-party
		fod, ok := fodPaths[p.modKey]
		if !ok {
			return "", fmt.Errorf("no FOD for module %s", p.modKey)
		}
		srcInput = fod
		srcDir = fod
		if p.subdir != "." {
			srcDir = fod + "/" + p.subdir
		}
	}

	var cfg strings.Builder
	cfg.WriteString("cat " + shq(c.stdlib+"/importcfg") + " > importcfg\n")
	for _, imp := range sortedKeys(compiled) {
		fmt.Fprintf(&cfg, "echo %s >> importcfg\n", shq("packagefile "+imp+"="+compiled[imp]))
	}

	pflag := p.ImportPath
	rewriteTarget := p.ImportPath
	if p.Name == "main" {
		pflag = "main"
		rewriteTarget = "main"
	}

	// Reject source kinds the POC's cgo path does not handle. C and GCC-style
	// .S/.sx assembly are supported (compiled with cc); Plan 9 .s asm, C++,
	// Fortran, and SWIG are not.
	if len(p.CXXFiles)+len(p.FFiles)+len(p.SwigFiles)+len(p.SwigCXXFiles) > 0 {
		return "", fmt.Errorf("package %s has unsupported sources (C++/Fortran/SWIG); the POC cgo path handles C + .S/.sx asm only", p.ImportPath)
	}
	var gccAsm []string
	for _, f := range p.SFiles {
		if strings.HasSuffix(f, ".S") || strings.HasSuffix(f, ".sx") {
			gccAsm = append(gccAsm, f)
		} else {
			return "", fmt.Errorf("package %s has Plan 9 asm %q; the POC cgo path handles .S/.sx gcc asm only", p.ImportPath, f)
		}
	}

	goFiles := make([]string, len(p.GoFiles))
	for i, f := range p.GoFiles {
		goFiles[i] = shq(srcDir + "/" + f)
	}

	cgo := len(p.CgoFiles) > 0
	var script string
	if cgo {
		if c.cc == "" {
			return "", fmt.Errorf("package %s needs cgo but no --cc was provided", p.ImportPath)
		}
		script = c.cgoCompileScript(p, srcDir, rewriteTarget, pflag, cfg.String(), goFiles, gccAsm)
	} else {
		script = fmt.Sprintf(`set -euo pipefail
export GOROOT=%s
export PATH=%s
mkdir -p "$out"
%s
go tool compile -importcfg importcfg -p %s -buildid "" \
  -trimpath="%s=>%s;${NIX_BUILD_TOP}=>" -nolocalimports -pack -lang=%s \
  -o "$out/pkg.a" %s
`,
			shq(c.goBin+"/share/go"),
			shq(c.coreutils+"/bin:"+c.goBin+"/bin"),
			cfg.String(),
			shq(pflag),
			srcDir, rewriteTarget,
			shq(c.goVersion),
			strings.Join(goFiles, " "),
		)
	}

	drv := c.newCADrv("godyn-compile-"+sanitize(p.ImportPath), script)
	drv.addInputSrc(srcInput)
	drv.addInputSrc(c.stdlib)
	drv.addInputSrc(c.goBin)
	drv.addInputSrc(c.bash)
	drv.addInputSrc(c.coreutils)
	if cgo {
		drv.addInputSrc(c.cc)
	}
	for _, imp := range sortedKeys(compiled) {
		drv.addInputSrc(strings.TrimSuffix(compiled[imp], "/pkg.a"))
	}
	return c.registerAndBuild(drv)
}

// cgoCompileScript ports numtide pkg/compile/cgo.go's pure-C path: cgo codegen,
// compile the C files, test-link + dynimport, compile the Go (generated +
// plain), then pack the C objects into the archive. Uses a placeholder template
// (no fmt verbs) for legibility. p.Name supplies the package name so no text
// tools beyond coreutils + cc + go are needed inside the drv.
func (c config) cgoCompileScript(p *pkg, srcDir, rewriteTarget, pflag, cfgCmds string, goFiles, gccAsm []string) string {
	cgoFiles := make([]string, len(p.CgoFiles))
	for i, f := range p.CgoFiles {
		cgoFiles[i] = shq(f) // basenames; cgo runs with cwd = srcDir
	}
	// Both C files and .S/.sx gcc assembly are compiled with cc -c.
	cFiles := make([]string, 0, len(p.CFiles)+len(gccAsm))
	for _, f := range append(append([]string{}, p.CFiles...), gccAsm...) {
		cFiles = append(cFiles, shq(srcDir+"/"+f))
	}
	tmpl := `set -euo pipefail
export GOROOT=@GOROOT@
export PATH=@PATH@
export CC=@CC@
export HOME="$NIX_BUILD_TOP"
mkdir -p "$out"
work="$NIX_BUILD_TOP/cgo-@UID@"; rm -rf "$work"; mkdir -p "$work"
@CFG@
RF=(-ffile-prefix-map="$work=/tmp/go-build" -ffile-prefix-map=@SRCDIR@=. -gno-record-gcc-switches)
( cd @SRCDIRQ@ && go tool cgo -objdir "$work" -importpath @PFLAG@ -- -I "$work" "${RF[@]}" @CGOFILES@ )
declare -a OFILES=()
n=0
for cf in "$work/_cgo_export.c" "$work"/*.cgo2.c @CFILES@; do
  [ -e "$cf" ] || continue
  o="$work/c$n.o"; n=$((n+1))
  "$CC" -c -I "$work" -I @SRCDIRQ@ -fPIC -pthread "${RF[@]}" "$cf" -o "$o"
  OFILES+=("$o")
done
"$CC" -c -I "$work" -I @SRCDIRQ@ -fPIC -pthread "${RF[@]}" "$work/_cgo_main.c" -o "$work/_cgo_main.o"
DYN=""
if "$CC" -o "$work/_cgo_.o" "$work/_cgo_main.o" "${OFILES[@]}" -lpthread 2>"$work/tl.err"; then
  ( cd @SRCDIRQ@ && go tool cgo -dynimport "$work/_cgo_.o" -dynout "$work/_cgo_import.go" -dynpackage @PNAMEQ@ )
  DYN="$work/_cgo_import.go"
else
  : > "$work/dynimportfail"; OFILES+=("$work/dynimportfail")
fi
LDF=""
if [ -e "$work/_cgo_flags" ]; then
  ldflags=""
  while IFS= read -r line; do case "$line" in _CGO_LDFLAGS=*) ldflags="${line#_CGO_LDFLAGS=}";; esac; done < "$work/_cgo_flags"
  if [ -n "$ldflags" ]; then
    { echo "package @PNAME@"; echo; for fl in $ldflags; do echo "//go:cgo_ldflag \"$fl\""; done; } > "$work/_cgo_ldflag.go"
    LDF="$work/_cgo_ldflag.go"
  fi
fi
go tool compile -importcfg importcfg -p @PFLAG@ -buildid "" \
  -trimpath="$work=>;@SRCDIR@=>@REWRITE@;$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=@GOVER@ \
  -o "$out/pkg.a" @GOFILES@ "$work/_cgo_gotypes.go" "$work"/*.cgo1.go ${DYN:+"$DYN"} ${LDF:+"$LDF"}
go tool pack r "$out/pkg.a" "${OFILES[@]}"
# NB: an if-block, not a trailing "test && cmd". As the script's final
# statement, a false bracket test makes 1 the script exit status (and prints
# nothing), so Nix fails the build even though pkg.a is already complete.
if [ -e "$work/_cgo_flags" ]; then go tool pack r "$out/pkg.a" "$work/_cgo_flags"; fi
`
	return strings.NewReplacer(
		"@GOROOT@", shq(c.goBin+"/share/go"),
		"@PATH@", shq(c.cc+"/bin:"+c.coreutils+"/bin:"+c.goBin+"/bin"),
		"@CC@", shq(c.cc+"/bin/cc"),
		"@UID@", sanitize(p.ImportPath),
		"@CFG@", cfgCmds,
		"@SRCDIRQ@", shq(srcDir),
		"@SRCDIR@", srcDir,
		"@PFLAG@", shq(pflag),
		"@CGOFILES@", strings.Join(cgoFiles, " "),
		"@CFILES@", strings.Join(cFiles, " "),
		"@PNAMEQ@", shq(p.Name),
		"@PNAME@", p.Name,
		"@REWRITE@", rewriteTarget,
		"@GOVER@", shq(c.goVersion),
		"@GOFILES@", strings.Join(goFiles, " "),
	).Replace(tmpl)
}

func (c config) buildLinkDrv(mainPkg *pkg, modulePath string, compiled map[string]string, cgoUsed bool) (string, error) {
	mainArchive := compiled[mainPkg.ImportPath]

	var cfg strings.Builder
	cfg.WriteString("cat " + shq(c.stdlib+"/importcfg") + " > importcfg.link\n")
	for _, imp := range sortedKeys(compiled) {
		if imp == mainPkg.ImportPath {
			continue
		}
		fmt.Fprintf(&cfg, "echo %s >> importcfg.link\n", shq("packagefile "+imp+"="+compiled[imp]))
	}

	// cgo binaries link externally: put the cc-wrapper on PATH and pass -extld
	// so go tool link drives the external linker over the packed C objects.
	pathDirs := c.coreutils + "/bin:" + c.goBin + "/bin"
	extld := ""
	if cgoUsed {
		pathDirs = c.cc + "/bin:" + pathDirs
		extld = " -extld " + shq(c.cc+"/bin/cc")
	}

	script := fmt.Sprintf(`set -euo pipefail
export PATH=%s
mkdir -p "$out/bin"
%s
GOTOOLDIR="$(GOROOT=%s go env GOTOOLDIR)"
export GOROOT=
"$GOTOOLDIR/link" -buildid=redacted -buildmode=exe%s -importcfg importcfg.link \
  -o "$out/bin/%s" %s
`,
		shq(pathDirs),
		cfg.String(),
		shq(c.goBin+"/share/go"),
		extld,
		c.pname,
		shq(mainArchive),
	)

	drv := c.newCADrv("godyn-link-"+sanitize(c.pname), script)
	drv.addInputSrc(c.stdlib)
	drv.addInputSrc(c.goBin)
	drv.addInputSrc(c.bash)
	drv.addInputSrc(c.coreutils)
	if cgoUsed {
		drv.addInputSrc(c.cc)
	}
	for _, imp := range sortedKeys(compiled) {
		drv.addInputSrc(strings.TrimSuffix(compiled[imp], "/pkg.a"))
	}
	_ = modulePath // modinfo out of scope for the POC
	return c.derivationAdd(drv)
}

func (c config) stageSource(p *pkg) (string, error) {
	tmp, err := os.MkdirTemp(buildTop(), "stage-")
	if err != nil {
		return "", err
	}
	for _, f := range p.GoFiles {
		data, err := os.ReadFile(filepath.Join(p.Dir, f))
		if err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(tmp, f), data, 0o644); err != nil {
			return "", err
		}
	}
	name := "godyn-src-" + sanitize(p.ImportPath)
	out, err := c.runNix(nil, "store", "add", "--name", name, tmp)
	if err != nil {
		return "", fmt.Errorf("nix store add %s: %w", name, err)
	}
	return out, nil
}

// applyBridges copies the module source to a writable temp dir and rewrites its
// go.mod with `require <mod>@<sentinel>` + `replace <mod> => <store-path>` for
// each --bridge entry — the igloo goFlakeInputs / localReplace mechanism (RFC
// 0001). A bridged module then resolves + compiles from a flake-input go-pkgs
// output instead of a module-proxy FOD. Returns the copy's path (where go list
// runs). The sentinel pseudo-version matches igloo internals.nix.
func (c config) applyBridges() (string, error) {
	dst, err := os.MkdirTemp(buildTop(), "bridge-src-")
	if err != nil {
		return "", err
	}
	if err := copyTree(c.src, dst); err != nil {
		return "", fmt.Errorf("copying source: %w", err)
	}
	const sentinel = "v0.0.0-00010101000000-000000000000"
	for _, mod := range sortedKeys(c.bridges) {
		target := c.bridges[mod]
		for _, args := range [][]string{
			{"mod", "edit", "-require=" + mod + "@" + sentinel},
			{"mod", "edit", "-replace=" + mod + "=" + target},
		} {
			cmd := exec.Command(c.goBin+"/bin/go", args...)
			cmd.Dir = dst
			cmd.Env = append(os.Environ(), "GOFLAGS=-mod=mod", "GO111MODULE=on", "HOME="+buildTop())
			if out, err := cmd.CombinedOutput(); err != nil {
				return "", fmt.Errorf("go %s: %w\n%s", strings.Join(args, " "), err, out)
			}
		}
	}
	return dst, nil
}

// copyTree recursively copies regular files + directories from src to dst,
// skipping symlinks and special files (Go module trees are plain files).
func copyTree(src, dst string) error {
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	for _, e := range entries {
		s, d := filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())
		switch {
		case e.IsDir():
			if err := copyTree(s, d); err != nil {
				return err
			}
		case e.Type().IsRegular():
			data, err := os.ReadFile(s)
			if err != nil {
				return err
			}
			if err := os.WriteFile(d, data, 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---- nix CLI ---------------------------------------------------------------

func (c config) registerAndBuild(d *derivation) (string, error) {
	drvPath, err := c.derivationAdd(d)
	if err != nil {
		return "", err
	}
	out, err := c.runNix(nil, "build", "--no-link", "-L", "--print-out-paths", drvPath+"^out")
	if err != nil {
		return "", fmt.Errorf("nix build %s: %w", drvPath, err)
	}
	return strings.TrimSpace(out), nil
}

func (c config) derivationAdd(d *derivation) (string, error) {
	data, err := d.toJSON(c.system, c.bash+"/bin/bash")
	if err != nil {
		return "", err
	}
	out, err := c.runNix(strings.NewReader(string(data)), "derivation", "add")
	if err != nil {
		return "", fmt.Errorf("nix derivation add %q: %w\nJSON: %s", d.name, err, data)
	}
	return strings.TrimSpace(out), nil
}

func (c config) runNix(stdin *strings.Reader, args ...string) (string, error) {
	full := append([]string{
		"--extra-experimental-features", "nix-command ca-derivations dynamic-derivations",
	}, args...)
	cmd := exec.Command(c.nixBin, full...)
	if stdin != nil {
		cmd.Stdin = stdin
	}
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return "", fmt.Errorf("%w\nstderr: %s", err, ee.Stderr)
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// ---- v4 derivation ---------------------------------------------------------

type derivation struct {
	name      string
	args      []string
	env       map[string]string
	inputSrcs map[string]struct{}
	fodHash   string // non-empty => fixed-output derivation
}

func (c config) newCADrv(name, script string) *derivation {
	return &derivation{
		name: name,
		args: []string{"-c", script},
		env: map[string]string{
			"name": name,
			"out":  outPlaceholder(),
		},
		inputSrcs: map[string]struct{}{},
	}
}

// newFODDrv builds a fixed-output derivation. Nix fills $out for FODs, so the
// env.out is left empty (matching numtide).
func (c config) newFODDrv(name, script, narHash string) *derivation {
	return &derivation{
		name:      name,
		args:      []string{"-c", script},
		env:       map[string]string{"name": name, "out": ""},
		inputSrcs: map[string]struct{}{},
		fodHash:   narHash,
	}
}

func (d *derivation) addInputSrc(p string) { d.inputSrcs[p] = struct{}{} }

func (d *derivation) toJSON(system, builder string) ([]byte, error) {
	srcs := make([]string, 0, len(d.inputSrcs))
	for s := range d.inputSrcs {
		srcs = append(srcs, storeBase(s))
	}
	sort.Strings(srcs)

	var output map[string]any
	if d.fodHash != "" {
		output = map[string]any{"method": "nar", "hash": d.fodHash}
	} else {
		output = map[string]any{"method": "nar", "hashAlgo": "sha256"}
	}
	doc := map[string]any{
		"name":    d.name,
		"version": 4,
		"outputs": map[string]any{"out": output},
		"inputs":  map[string]any{"srcs": srcs, "drvs": map[string]any{}},
		"system":  system,
		"builder": builder,
		"args":    d.args,
		"env":     d.env,
	}
	return json.Marshal(doc)
}

// ---- helpers ---------------------------------------------------------------

func buildTop() string { return os.Getenv("NIX_BUILD_TOP") }

func storeBase(p string) string { return strings.TrimPrefix(p, "/nix/store/") }

// storeRoot trims a path under /nix/store down to the store-object root
// (/nix/store/<hash>-<name>) — used to declare a bridged package's source store
// path (whose p.Dir points deep inside the go-pkgs output) as a drv input.
func storeRoot(p string) string {
	const prefix = "/nix/store/"
	if !strings.HasPrefix(p, prefix) {
		return p
	}
	if i := strings.IndexByte(p[len(prefix):], '/'); i >= 0 {
		return p[:len(prefix)+i]
	}
	return p
}

func sanitize(s string) string {
	r := strings.NewReplacer("/", "-", ".", "-", "_", "-")
	return strings.Trim(r.Replace(s), "-")
}

func sortedKeys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	slices.Sort(ks)
	return ks
}

func shq(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func outPlaceholder() string {
	h := sha256.Sum256([]byte("nix-output:out"))
	return "/" + nixBase32(h[:])
}

func nixBase32(hash []byte) string {
	const alphabet = "0123456789abcdfghijklmnpqrsvwxyz"
	size := len(hash)
	length := (size*8-1)/5 + 1
	var sb strings.Builder
	for n := length - 1; n >= 0; n-- {
		b := uint(n) * 5
		i := b / 8
		j := b % 8
		c := uint(hash[i]) >> j
		if int(i) < size-1 {
			c |= uint(hash[i+1]) << (8 - j)
		}
		sb.WriteByte(alphabet[c&0x1f])
	}
	return sb.String()
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "godyn-resolver: "+format+"\n", a...)
	os.Exit(1)
}
