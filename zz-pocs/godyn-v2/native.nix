# godyn v2 — approach A: the eval-time native package graph.
#
# Reads the committed graph.json (produced by gen/, the gomod2nix-style dev-time
# generator) and turns it into ONE plain derivation per Go package, wired
# together by nix string-context (each package's importcfg interpolates its
# deps' store paths -> nix records them as inputDrvs). There is NO recursive-nix,
# NO dynamic-derivations, NO build-time resolver: nix's own scheduler sees the
# whole package DAG at eval time and builds only the changed nodes on an edit
# (the merkle-delta), parallelising independent ones.
{
  lib,
  runCommandLocal,
  go,
  stdlib,
  src, # the main module's source root (in-repo, for local packages)
  graphFile, # ./graph.json
  # vendorEnv: a gomod2nix vendor tree (sources by import path) supplying
  # third-party packages. null for an all-local module (the toy).
  vendorEnv ? null,
  pname ? "godyntb",
  goVersion ? "go1.26",
}:
let
  graph = builtins.fromJSON (builtins.readFile graphFile);
  byImport = lib.listToAttrs (map (p: lib.nameValuePair p.importPath p) graph);
  importsOf = importPath: let i = byImport.${importPath}.imports; in if i == null then [ ] else i;
  sanitize = s: lib.replaceStrings [ "/" "." "_" ] [ "-" "-" "-" ] s;

  # Transitive non-stdlib import closure of a package (go tool compile's
  # importcfg must carry every package whose export data is reachable, not just
  # direct imports). Go has no import cycles, so the recursion terminates.
  transitiveDeps = importPath:
    let direct = importsOf importPath;
    in lib.unique (direct ++ lib.concatMap transitiveDeps direct);

  # importcfg lines for `cfgFile`: stdlib comes from the shared stdlib drv; each
  # non-stdlib transitive dep contributes one `packagefile <imp>=<drv>/pkg.a`.
  # Interpolating `${pkgDrvs.${dep}}` is what makes dep an inputDrv of this drv.
  cfgFor = importPath: cfgFile:
    lib.concatMapStringsSep "\n"
      (dep: "echo 'packagefile ${dep}=${pkgDrvs.${dep}}/pkg.a' >> ${cfgFile}")
      (transitiveDeps importPath);

  pkgDrvs = lib.mapAttrs (importPath: p:
    let
      # Local packages: the in-repo module subdir (per-package builtins.path, so
      # an edit to one package changes only its drv input). Third-party: the
      # vendor tree by import path (one shared input; local edits don't touch it,
      # so the whole third-party closure stays cached).
      srcDir =
        if p.local then
          builtins.path {
            path = src + "/${p.dir}";
            name = "godyn-v2-src-${sanitize importPath}";
          }
        else
          "${vendorEnv}/${importPath}";
      goFiles = lib.concatMapStringsSep " " (f: "${srcDir}/${f}") p.goFiles;

      # A package main must compile under -p main (the linker looks for
      # main.main), not its import path.
      pflag = if p.isMain then "main" else importPath;

      compile = ''
        export GOROOT=${go}/share/go
        mkdir -p "$out"
        cat ${stdlib}/importcfg > importcfg
        ${cfgFor importPath "importcfg"}
        go tool compile -importcfg importcfg -p '${pflag}' -buildid "" \
          -trimpath="${srcDir}=>${pflag};$NIX_BUILD_TOP=>" \
          -nolocalimports -pack -lang=${goVersion} \
          -o "$out/pkg.a" ${goFiles}
      '';

      # The main package additionally links a binary over its archive + the full
      # transitive closure of dep archives.
      link = lib.optionalString p.isMain ''
        mkdir -p "$out/bin"
        cat ${stdlib}/importcfg > importcfg.link
        ${cfgFor importPath "importcfg.link"}
        GOTOOLDIR="$(go env GOTOOLDIR)"
        export GOROOT=
        "$GOTOOLDIR/link" -buildid=redacted -buildmode=exe -importcfg importcfg.link \
          -o "$out/bin/${pname}" "$out/pkg.a"
      '';
    in
    runCommandLocal "godyn-v2-compile-${sanitize importPath}"
      {
        nativeBuildInputs = [ go ];
        # Content-addressed: a package whose output (pkg.a) is byte-identical
        # after an edit (e.g. a comment) keeps the same store hash, so its
        # dependents' inputDrvs are unchanged and nix early-cuts the cascade —
        # the merkle-delta's killer property. Matches godyn-poc's CA drvs.
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
      }
      (compile + link)
  ) byImport;

  mainPkg = lib.findFirst (p: p.isMain) null graph;

  # Compile-only terminal for a library graph (no package main): a manifest that
  # depends on every package archive (so building it realises the whole graph)
  # and lists the import paths. Mirrors the resolver's buildManifestDrv.
  manifest = runCommandLocal "godyn-v2-${pname}-manifest" { } (
    ": > $out\n"
    + lib.concatMapStringsSep "\n"
      (p: "test -s ${pkgDrvs.${p.importPath}}/pkg.a && echo '${p.importPath}' >> $out")
      graph
  );
in
if mainPkg != null then pkgDrvs.${mainPkg.importPath} else manifest
