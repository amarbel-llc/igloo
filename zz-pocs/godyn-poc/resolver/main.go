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
// the module h1/ziphash from the lockfile instead of recomputing dirhash; no
// cgo / build tags / cross / modinfo (out of scope per the plan).
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
	cacert    string // for the module-fetch FODs (SSL_CERT_FILE)
	lockfile  string // optional: third-party module pins
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
	flag.StringVar(&c.cacert, "cacert", "", "cacert store path (for module FODs)")
	flag.StringVar(&c.lockfile, "lockfile", "", "third-party module lockfile (optional)")
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
	for _, p := range order {
		caOut, err := c.buildCompileDrv(p, compiled, fodPaths)
		if err != nil {
			return fmt.Errorf("compile %s: %w", p.ImportPath, err)
		}
		compiled[p.ImportPath] = caOut + "/pkg.a"
		fmt.Fprintf(os.Stderr, "[godyn] compiled %s -> %s\n", p.ImportPath, caOut)
	}

	// 4. Link.
	linkDrv, err := c.buildLinkDrv(mainPkg, modulePath, compiled)
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
	Imports    []string
	Standard   bool
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
	cmd := exec.Command(c.goBin+"/bin/go", "list", "-json", "-deps", "./...")
	cmd.Dir = c.src
	cmd.Env = append(os.Environ(),
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

	files := make([]string, len(p.GoFiles))
	for i, f := range p.GoFiles {
		files[i] = shq(srcDir + "/" + f)
	}

	script := fmt.Sprintf(`set -euo pipefail
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
		strings.Join(files, " "),
	)

	drv := c.newCADrv("godyn-compile-"+sanitize(p.ImportPath), script)
	drv.addInputSrc(srcInput)
	drv.addInputSrc(c.stdlib)
	drv.addInputSrc(c.goBin)
	drv.addInputSrc(c.bash)
	drv.addInputSrc(c.coreutils)
	for _, imp := range sortedKeys(compiled) {
		drv.addInputSrc(strings.TrimSuffix(compiled[imp], "/pkg.a"))
	}
	return c.registerAndBuild(drv)
}

func (c config) buildLinkDrv(mainPkg *pkg, modulePath string, compiled map[string]string) (string, error) {
	mainArchive := compiled[mainPkg.ImportPath]

	var cfg strings.Builder
	cfg.WriteString("cat " + shq(c.stdlib+"/importcfg") + " > importcfg.link\n")
	for _, imp := range sortedKeys(compiled) {
		if imp == mainPkg.ImportPath {
			continue
		}
		fmt.Fprintf(&cfg, "echo %s >> importcfg.link\n", shq("packagefile "+imp+"="+compiled[imp]))
	}

	script := fmt.Sprintf(`set -euo pipefail
export PATH=%s
mkdir -p "$out/bin"
%s
GOTOOLDIR="$(GOROOT=%s go env GOTOOLDIR)"
export GOROOT=
"$GOTOOLDIR/link" -buildid=redacted -buildmode=exe -importcfg importcfg.link \
  -o "$out/bin/%s" %s
`,
		shq(c.coreutils+"/bin:"+c.goBin+"/bin"),
		cfg.String(),
		shq(c.goBin+"/share/go"),
		c.pname,
		shq(mainArchive),
	)

	drv := c.newCADrv("godyn-link-"+sanitize(c.pname), script)
	drv.addInputSrc(c.stdlib)
	drv.addInputSrc(c.goBin)
	drv.addInputSrc(c.bash)
	drv.addInputSrc(c.coreutils)
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

// ---- nix CLI ---------------------------------------------------------------

func (c config) registerAndBuild(d *derivation) (string, error) {
	drvPath, err := c.derivationAdd(d)
	if err != nil {
		return "", err
	}
	out, err := c.runNix(nil, "build", "--no-link", "--print-out-paths", drvPath+"^out")
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
