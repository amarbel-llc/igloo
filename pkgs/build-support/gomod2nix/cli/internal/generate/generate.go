// Package generate provides functions to import Go package sources and generate package metadata for Nix.
package generate

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/nix-community/go-nix/pkg/nar"
	"github.com/nix-community/gomod2nix/internal/lib"
	schema "github.com/nix-community/gomod2nix/internal/schema"
	log "github.com/sirupsen/logrus"
	"golang.org/x/mod/modfile"
)

type goModDownload struct {
	Path     string
	Version  string
	Info     string
	GoMod    string
	Zip      string
	Dir      string
	Sum      string
	GoModSum string
}

// readGoVersionFromMod reads the "go" directive from a go.mod file.
func readGoVersionFromMod(goModPath string) string {
	data, err := os.ReadFile(goModPath)
	if err != nil {
		return ""
	}
	mod, err := modfile.Parse(goModPath, data, nil)
	if err != nil || mod.Go == nil {
		return ""
	}
	return mod.Go.Version
}

func sourceFilter(name string, nodeType nar.NodeType) bool {
	return strings.ToLower(filepath.Base(name)) != ".ds_store"
}

func collectReplaces(mod *modfile.File) map[string]string {
	replace := make(map[string]string)
	for _, repl := range mod.Replace {
		replace[repl.New.Path] = repl.Old.Path
	}
	return replace
}

func commonWorkspace(directory string) ([]*goModDownload, map[string]string, error) {
	goWorkPath := filepath.Join(directory, "go.work")

	log.WithFields(log.Fields{
		"workPath": goWorkPath,
	}).Info("Parsing go.work")

	data, err := os.ReadFile(goWorkPath)
	if err != nil {
		return nil, nil, err
	}

	work, err := modfile.ParseWork(goWorkPath, data, nil)
	if err != nil {
		return nil, nil, err
	}

	// Collect replace directives from all child go.mod files
	replace := make(map[string]string)
	for _, use := range work.Use {
		modDir := filepath.Join(directory, use.Path)
		modPath := filepath.Join(modDir, "go.mod")
		modData, err := os.ReadFile(modPath)
		if err != nil {
			log.WithFields(log.Fields{
				"modPath": modPath,
			}).Warn("Skipping unreadable go.mod in workspace module")
			continue
		}
		mod, err := modfile.Parse(modPath, modData, nil)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to parse %s: %w", modPath, err)
		}
		for k, v := range collectReplaces(mod) {
			replace[k] = v
		}
	}

	// go.work-level replaces take precedence
	for _, repl := range work.Replace {
		replace[repl.New.Path] = repl.Old.Path
	}

	modDownloads, err := downloadMods(directory)
	if err != nil {
		return nil, nil, err
	}

	return modDownloads, replace, nil
}

func downloadMods(directory string) ([]*goModDownload, error) {
	log.Info("Downloading dependencies")

	cmd := exec.Command("go", "mod", "download", "--json")
	cmd.Dir = directory
	stdout, err := cmd.Output()
	if err != nil {
		if exiterr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("failed to run 'go mod download --json: %s\n%s", exiterr, exiterr.Stderr)
		}
		return nil, fmt.Errorf("failed to run 'go mod download --json': %s", err)
	}

	var modDownloads []*goModDownload
	dec := json.NewDecoder(bytes.NewReader(stdout))
	for {
		var dl *goModDownload
		err := dec.Decode(&dl)
		if err == io.EOF {
			break
		}
		modDownloads = append(modDownloads, dl)
	}

	log.Info("Done downloading dependencies")
	return modDownloads, nil
}

func HasGoWork(directory string) bool {
	_, err := os.Stat(filepath.Join(directory, "go.work"))
	return err == nil
}

func common(directory string) ([]*goModDownload, map[string]string, error) {
	if HasGoWork(directory) {
		return commonWorkspace(directory)
	}

	goModPath := filepath.Join(directory, "go.mod")

	log.WithFields(log.Fields{
		"modPath": goModPath,
	}).Info("Parsing go.mod")

	data, err := os.ReadFile(goModPath)
	if err != nil {
		return nil, nil, err
	}

	mod, err := modfile.Parse(goModPath, data, nil)
	if err != nil {
		return nil, nil, err
	}

	replace := collectReplaces(mod)

	modDownloads, err := downloadMods(directory)
	if err != nil {
		return nil, nil, err
	}

	return modDownloads, replace, nil
}

func ImportPkgs(directory string, numWorkers int) error {
	modDownloads, _, err := common(directory)
	if err != nil {
		return err
	}

	executor := lib.NewParallelExecutor(numWorkers)
	for _, dl := range modDownloads {
		executor.Add(func() error {
			log.WithFields(log.Fields{
				"goPackagePath": dl.Path,
			}).Info("Importing sources")

			pathName := filepath.Base(dl.Path) + "_" + dl.Version

			cmd := exec.Command(
				"nix-instantiate",
				"--eval",
				"--expr",
				fmt.Sprintf(`
builtins.filterSource (name: type: baseNameOf name != ".DS_Store") (
  builtins.path {
    path = "%s";
    name = "%s";
  }
)
`, dl.Dir, pathName),
			)
			cmd.Stderr = os.Stderr

			err = cmd.Start()
			if err != nil {
				fmt.Println(cmd)
				return err
			}

			err = cmd.Wait()
			if err != nil {
				fmt.Println(cmd)
				return err
			}

			return nil
		})
	}

	return executor.Wait()
}

func GeneratePkgs(directory string, goMod2NixPath string, numWorkers int) ([]*schema.Package, error) {
	modDownloads, replace, err := common(directory)
	if err != nil {
		return nil, err
	}

	executor := lib.NewParallelExecutor(numWorkers)
	var mux sync.Mutex

	cache := schema.ReadCache(goMod2NixPath)

	packages := []*schema.Package{}
	addPkg := func(pkg *schema.Package) {
		mux.Lock()
		packages = append(packages, pkg)
		mux.Unlock()
	}

	for _, dl := range modDownloads {
		goPackagePath, hasReplace := replace[dl.Path]
		if !hasReplace {
			goPackagePath = dl.Path
		}

		cached, ok := cache[goPackagePath]
		if ok && cached.Version == dl.Version {
			addPkg(cached)
			continue
		}

		executor.Add(func() error {
			log.WithFields(log.Fields{
				"goPackagePath": goPackagePath,
			}).Info("Calculating NAR hash")

			h := sha256.New()
			err := nar.DumpPathFilter(h, dl.Dir, sourceFilter)
			if err != nil {
				return err
			}
			digest := h.Sum(nil)

			pkg := &schema.Package{
				GoPackagePath: goPackagePath,
				Version:       dl.Version,
				Hash:          "sha256-" + base64.StdEncoding.EncodeToString(digest),
				GoVersion:     readGoVersionFromMod(dl.GoMod),
			}
			if hasReplace {
				pkg.ReplacedPath = dl.Path
			}

			addPkg(pkg)

			log.WithFields(log.Fields{
				"goPackagePath": goPackagePath,
			}).Info("Done calculating NAR hash")

			return nil
		})
	}

	err = executor.Wait()
	if err != nil {
		return nil, err
	}

	sort.Slice(packages, func(i, j int) bool {
		return packages[i].GoPackagePath < packages[j].GoPackagePath
	})

	return packages, nil
}

// GenerateCacheDeps generates a list of all imported packages
// (excluding standard library and the current module's packages) for cache optimization.
func workspaceModulePaths(directory string) ([]string, error) {
	goWorkPath := filepath.Join(directory, "go.work")
	data, err := os.ReadFile(goWorkPath)
	if err != nil {
		return nil, err
	}
	work, err := modfile.ParseWork(goWorkPath, data, nil)
	if err != nil {
		return nil, err
	}

	var paths []string
	for _, use := range work.Use {
		modPath := filepath.Join(directory, use.Path, "go.mod")
		modData, err := os.ReadFile(modPath)
		if err != nil {
			continue
		}
		mod, err := modfile.Parse(modPath, modData, nil)
		if err != nil {
			continue
		}
		paths = append(paths, mod.Module.Mod.Path)
	}
	return paths, nil
}

// GenerateVendorPackages returns a map from module path to the list of packages
// imported from that module. Used to generate vendor/modules.txt for workspaces.
func GenerateVendorPackages(directory string, moduleNames []string) (map[string][]string, error) {
	log.Info("Generating vendor package lists")

	// In workspace mode, list all packages across all workspace modules
	listArgs := []string{"list", "-deps", "-f", "{{.ImportPath}}"}
	if HasGoWork(directory) {
		// Use all workspace module patterns
		goWorkPath := filepath.Join(directory, "go.work")
		data, err := os.ReadFile(goWorkPath)
		if err != nil {
			return nil, err
		}
		work, err := modfile.ParseWork(goWorkPath, data, nil)
		if err != nil {
			return nil, err
		}
		for _, use := range work.Use {
			listArgs = append(listArgs, use.Path+"/...")
		}
	} else {
		listArgs = append(listArgs, "./...")
	}

	cmd := exec.Command("go", listArgs...)
	cmd.Dir = directory
	stdout, err := cmd.Output()
	if err != nil {
		if exiterr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("failed to run 'go list -deps': %s\n%s", exiterr, exiterr.Stderr)
		}
		return nil, fmt.Errorf("failed to run 'go list -deps': %w", err)
	}

	// Sort module names by length descending for longest-prefix match
	sortedModules := make([]string, len(moduleNames))
	copy(sortedModules, moduleNames)
	sort.Slice(sortedModules, func(i, j int) bool {
		return len(sortedModules[i]) > len(sortedModules[j])
	})

	result := make(map[string][]string)
	seen := make(map[string]bool)

	for _, line := range strings.Split(string(stdout), "\n") {
		pkg := strings.TrimSpace(line)
		if pkg == "" {
			continue
		}
		if seen[pkg] {
			continue
		}
		seen[pkg] = true

		// Find which module this package belongs to (longest prefix match)
		for _, mod := range sortedModules {
			if pkg == mod || strings.HasPrefix(pkg, mod+"/") {
				result[mod] = append(result[mod], pkg)
				break
			}
		}
	}

	// Sort package lists for determinism
	for mod := range result {
		sort.Strings(result[mod])
	}

	return result, nil
}

func GenerateCacheDeps(directory string) ([]string, error) {
	var moduleExcludes []string

	if HasGoWork(directory) {
		paths, err := workspaceModulePaths(directory)
		if err != nil {
			return nil, fmt.Errorf("failed to read workspace modules: %w", err)
		}
		moduleExcludes = paths
	} else {
		goModPath := filepath.Join(directory, "go.mod")

		log.Info("Parsing go.mod to get current module path")

		data, err := os.ReadFile(goModPath)
		if err != nil {
			return nil, fmt.Errorf("failed to read go.mod: %w", err)
		}

		mod, err := modfile.Parse(goModPath, data, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to parse go.mod: %w", err)
		}

		moduleExcludes = []string{mod.Module.Mod.Path}
	}

	log.WithFields(log.Fields{
		"excludedModules": moduleExcludes,
	}).Debug("Generating cache dependencies")

	cmd := exec.Command("go", "list", "-mod=readonly", "-f", "{{.ImportPath}}", "all")
	cmd.Dir = directory
	stdout, err := cmd.Output()
	if err != nil {
		if exiterr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("failed to run 'go list': %s\n%s", exiterr, exiterr.Stderr)
		}
		return nil, fmt.Errorf("failed to run 'go list': %w", err)
	}

	lines := strings.Split(string(stdout), "\n")
	var filteredPackages []string
	seen := make(map[string]bool)

	for _, line := range lines {
		pkg := strings.TrimSpace(line)
		if pkg == "" || pkg == "std" {
			continue
		}

		// Skip packages belonging to the current module / workspace modules
		skip := false
		for _, mod := range moduleExcludes {
			if pkg == mod || strings.HasPrefix(pkg, mod+"/") {
				skip = true
				break
			}
		}
		if skip {
			continue
		}

		// Skip internal packages — Go forbids importing another module's
		// internal packages, and stdlib internal/ packages can't be imported
		// at all. Public packages that depend on them will transitively
		// compile them into the cache.
		if strings.Contains(pkg, "/internal") || strings.HasPrefix(pkg, "internal/") {
			continue
		}

		// Skip Go's vendored stdlib copies (can't be imported directly)
		if strings.HasPrefix(pkg, "vendor/") {
			continue
		}

		if !seen[pkg] {
			seen[pkg] = true
			filteredPackages = append(filteredPackages, pkg)
		}
	}

	sort.Strings(filteredPackages)

	return filteredPackages, nil
}
