# buildGodynModule — the godyn per-package Go builder.
#
# Reads a committed graph.json (produced by godyn-gen) and turns it into ONE plain
# content-addressed derivation per Go package, wired together by nix string-context
# (each package's importcfg interpolates its deps' store paths -> nix records them
# as inputDrvs). There is NO recursive-nix, NO build-time resolver: nix's own
# scheduler sees the whole package DAG at eval time and rebuilds only the changed
# nodes on an edit (the merkle-delta), parallelising independent ones.
#
# Compile-kind (pure / cgo / asm) is derived per package from the file lists,
# orthogonally to source-kind (local in-repo / third-party vendorEnv / bridged
# go-pkgs). See docs: the godyn-{v2,dewey} POCs measured cgo, asm, bridge, FOD
# scope, and the 4-5x incremental-edit win over the recursive resolver.
{
  lib,
  runCommandLocal,
  go,
  stdlib,
  buildGoApplication,
  stdenv,
  jq,
  godyn-lint,
  godyn-gen,
  buildGoCheck,
  gomod2nixInternals,
}:
{
  pname,
  # Version embedding (parity with buildGoApplication, eng-versioning(7)): an
  # explicit `version` wins; else a `version.env` (declaring <PKG>_VERSION) in the
  # module dir is auto-read; else "dev". Drives -X main.version.
  version ? null,
  src, # the main module's source root (a flake input — local packages live under it)
  # The committed package graph (produced by godyn-gen). `go list`'s file/import
  # selection honors GOOS/GOARCH build constraints, so a graph is only valid for the
  # platform it was generated for (igloo#33). Single-platform consumers pass
  # graphFile; multi-platform consumers pass graphFiles keyed by system. godyn-gen
  # respects GOOS/GOARCH (+ CGO_ENABLED) from its environment, so every platform's
  # graph can be generated from ONE host:
  #   CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 godyn-gen . godyn-graph.aarch64-darwin.json
  graphFile ? null, # ./godyn-graph.json (single platform)
  graphFiles ? null, # { "<system>" = ./godyn-graph.<system>.json; … }
  # Per-package `go test` (igloo#32): a committed test graph produced by
  # `godyn-gen -tests` — one node per TESTED package carrying the test file lists,
  # the test variant's imports (a superset including test-only deps), and the
  # captured go-generated testmain source. Platform-specific exactly like the build
  # graph. When present, passthru gains tests.<importPath> (run derivations — a
  # failing test fails the build), testBins.<importPath> (the linked test binaries,
  # for manual -run/-v invocation) and checkAll (one manifest realising every run —
  # wire it into flake checks). Tests must be hermetic and deterministic (the nix
  # sandbox, as with buildGoModule doCheck); note a CA run caches a PASSING result,
  # so an unchanged test cone never re-runs.
  testGraphFile ? null,
  testGraphFiles ? null,
  # tests: with no testGraphFile(s), derive the test graph at eval time
  # (`godyn-gen -tests`, like the build graph; FDR 0008) and enable per-package
  # go test. Needs `modules`.
  tests ? false,
  # Third-party packages come from a gomod2nix vendor tree. Pass `modules`
  # (./gomod2nix.toml) to derive it via buildGoApplication, or pass a prebuilt
  # `vendorEnv` directly. null for an all-local module.
  modules ? null,
  vendorEnv ? null,
  # pwd: the module dir read for version.env (defaults to src). commit: embedded
  # as -X main.commit, from the flake input's rev unless overridden.
  pwd ? null,
  commit ?
    if src != null && src ? rev then
      src.rev
    else if src != null && src ? shortRev then
      src.shortRev
    else
      "unknown",
  # ldflags: extra `go tool link` flags as a LIST, e.g. [ "-s" "-w" ] or a raw
  # [ "-X pkg.sym=val" ]. ldflagsX: the structured convenience — an attrset
  # { "importpath.name" = "value"; } rendered to -X tokens (appended last, so
  # last-wins). main.version / main.commit are auto-injected ahead of both; an
  # ldflagsX key colliding with an already-set -X throws unless overwriteLdflagsX.
  ldflags ? [ ],
  ldflagsX ? { },
  overwriteLdflagsX ? false,
  # cc: a stdenv cc-wrapper, required iff any package is cgo (zstd etc.).
  cc ? null,
  # bridges: modpath -> go-pkgs SOURCE store path; a package whose module is bridged
  # is sourced from there instead of vendorEnv and COMPILED in this graph (RFC 0001
  # cross-flake go-pkgs). This is the godyn→godyn "source" composition (approach 2).
  bridges ? { },
  # goFlakeInputs: the RFC 0001 declaration buildGoApplication takes. Resolved the
  # same way (incl. bridges inherited via producers' passthru.goFlakeInputs) into
  # `bridges`, a { src; subPath; } value becoming <src>/<subPath>; an explicit
  # `bridges` entry wins (igloo#69). Generate the graph with `godyn-gen -gomod`
  # against the matching merged go.mod (igloo#67).
  goFlakeInputs ? { },
  # archiveBridges: modpath -> go-pkgs-of-ARCHIVES store path (laid out as
  # <importpath>/pkg.a, e.g. another godyn module's passthru.archiveGoPkgs). A package
  # whose module is archive-bridged is NOT compiled here — dependents LINK its
  # pre-built archive directly (the godyn→godyn "output" composition, approach 1).
  # The two converge to the same CA archive under a matched toolchain; prefer
  # `bridges` (no cross-flake toolchain lockstep). See zz-pocs/godyn-godyn/README.md.
  archiveBridges ? { },
  system ? stdenv.system,
  goVersion ? "go1.26",
  # vetTool: a unitchecker binary (golang.org/x/tools/go/analysis/unitchecker, the
  # `go vet -vettool` protocol) for the per-package vet lane; its mainProgram runs
  # once per package. null = the toolchain's own `go tool vet` analyzers.
  vetTool ? null,
  # lintTool: the unitchecker binary the per-package LINT lane runs (passthru.lint /
  # lintAll, and buildGodynLint). Default: godyn-lint — vet's passes plus
  # staticcheck's default checks, with golangci-lint style //nolint suppression.
  lintTool ? godyn-lint,
  # Install step, parity with buildGoApplication: postInstall runs after the link
  # with $out/bin/<pname> in place and cwd = a writable copy of src (as bga runs it
  # from the unpacked source); nativeBuildInputs are available to it. Main-package
  # graphs only. Set either and the result is a separate install derivation
  # layered on the CA link output, so editing the install script never re-links.
  postInstall ? "",
  nativeBuildInputs ? [ ],
  # lazySrc (experiment, #27): source local packages directly from the flake input
  # tree (src + "/dir") instead of a per-package `builtins.path` copy. WARNING:
  # trades per-package incrementality for the lazy read (a bare `src + "/dir"` is a
  # subpath of the whole-input store path, so any edit re-hashes the input and
  # rebuilds every package). Measured a no-op for lazy-trees; off by default.
  lazySrc ? false,
}:
let
  resolvedVendorEnv =
    if vendorEnv != null then
      vendorEnv
    else if modules != null then
      # The vendor tree is version-independent; let buildGoApplication resolve its
      # own version (don't thread godyn's null version through). goFlakeInputs goes
      # along so third-party pins come from the same merged gomod2nix.toml the bga
      # backend uses (producer tomls unioned, bridged keys stripped).
      (buildGoApplication {
        inherit
          pname
          src
          modules
          goFlakeInputs
          ;
      }).passthru.vendorEnv
    else
      null;

  # goFlakeInputs resolved exactly as buildGoApplication resolves them (incl.
  # bridges inherited via producers' passthru.goFlakeInputs), as source paths;
  # explicit `bridges` win.
  effectiveBridges =
    lib.mapAttrs (_: n: "${n.src}" + lib.optionalString (n.subPath != "") "/${n.subPath}") (
      gomod2nixInternals.resolveGoFlakeInputs goFlakeInputs
    )
    // bridges;

  # version.env auto-read + ldflags assembly — parity with buildGoApplication
  # (gomod2nix default.nix:794-870). Explicit version > version.env > "dev".
  effectivePwd = if pwd != null then pwd else src;
  versionEnvPath = "${toString effectivePwd}/version.env";
  versionFromEnv =
    if builtins.pathExists versionEnvPath then
      let
        m = builtins.match ".*_VERSION=([^[:space:]]+).*" (builtins.readFile versionEnvPath);
      in
      if m != null then builtins.elemAt m 0 else null
    else
      null;
  effectiveVersion =
    if version != null then
      version
    else if versionFromEnv != null then
      versionFromEnv
    else
      "dev";
  versionLdflags = [
    "-X main.version=${effectiveVersion}"
    "-X main.commit=${commit}"
  ];
  # Symbol (importpath.name) from a single `-X SYM=VAL` entry; null for non-X flags.
  ldflagXSymbol =
    entry:
    let
      m = builtins.match "-X[ =]([^=]+)=.*" entry;
    in
    if m != null then builtins.elemAt m 0 else null;
  claimedXSymbols = builtins.filter (s: s != null) (map ldflagXSymbol (versionLdflags ++ ldflags));
  ldflagsXCollisions = builtins.filter (k: builtins.elem k claimedXSymbols) (
    builtins.attrNames ldflagsX
  );
  ldflagsXFlags =
    if ldflagsXCollisions != [ ] && !overwriteLdflagsX then
      throw ''
        buildGodynModule: ldflagsX would overwrite -X symbol(s) already set by the
        auto-injected version/commit ldflags or the `ldflags` list:
          ${lib.concatStringsSep ", " ldflagsXCollisions}
        Pass `overwriteLdflagsX = true` to let ldflagsX win, or drop the key(s).''
    else
      lib.mapAttrsToList (name: value: "-X ${name}=${value}") ldflagsX;
  # Joined into the `go tool link` argv (unquoted in the script -> word-split, so
  # each `-X a.b=c` becomes the two tokens the linker wants).
  effectiveLdflagsStr = lib.concatStringsSep " " (versionLdflags ++ ldflags ++ ldflagsXFlags);

  # Resolve one of (single, per-system) graph file args; null when neither is set —
  # an error for the build graph, "no tests" for the test graph.
  resolveGraphFile =
    what: single: perSystem:
    if perSystem != null then
      (perSystem.${system} or (throw ''
        buildGodynModule(${pname}): ${what} has no graph for ${system} (have: ${lib.concatStringsSep ", " (builtins.attrNames perSystem)}).
        Generate it from any host: CGO_ENABLED=0 GOOS=<os> GOARCH=<arch> godyn-gen ${
          lib.optionalString (what == "testGraphFiles") "-tests "
        }. <out>.json'')
      )
    else
      single;

  resolvedGraphFile =
    let
      g = resolveGraphFile "graphFiles" graphFile graphFiles;
    in
    if g != null then g else deriveGraph "" "-godyn-graph";

  # No committed graph (FDR 0008, igloo#72): derive it at eval time by running
  # godyn-gen inside the buildGoApplication sandbox — merged go.mod for
  # goFlakeInputs, vendored deps, offline — for the current system, and import its
  # JSON. That is import-from-derivation, so evaluating another system's packages
  # needs a builder for that system (accepted in FDR 0008; igloo#75). cgo is on only
  # when a cc is given, matching what this builder can compile.
  deriveGraph =
    genFlags: pnameSuffix:
    if modules == null then
      throw "buildGodynModule(${pname}): pass graphFile/graphFiles, or modules (gomod2nix.toml) to derive the graph at eval time"
    else
      buildGoCheck {
        base = buildGoApplication {
          inherit
            pname
            src
            modules
            goFlakeInputs
            ;
          version = effectiveVersion; # an explicit version sidesteps igloo#70
        };
        inherit pnameSuffix;
        extraNativeBuildInputs = [ godyn-gen ];
        command = ''CGO_ENABLED=${if cc != null then "1" else "0"} godyn-gen ${genFlags} . "$out"'';
      };
  resolvedTestGraphFile =
    let
      t = resolveGraphFile "testGraphFiles" testGraphFile testGraphFiles;
    in
    if t != null then
      t
    else if tests then
      deriveGraph "-tests" "-godyn-test-graph"
    else
      null;

  graph = builtins.fromJSON (builtins.readFile resolvedGraphFile);
  byImport = lib.listToAttrs (map (p: lib.nameValuePair p.importPath p) graph);

  # A pre-existing read-only $out (a CA scratch path stranded by an interrupted
  # build) makes `mkdir -p "$out"` succeed silently while every subsequent write
  # fails EACCES with a cryptic compiler error (seen on darwin, igloo#33). Probe
  # once right after the mkdir and fail actionably instead.
  outWritableProbe = ''
    if ! { : > "$out/.godyn-writable"; } 2>/dev/null; then
      echo "godyn: $out exists but is not writable — a scratch output stranded by an interrupted build (igloo#33)." >&2
      echo "godyn: these strays are usually UNREGISTERED (owned by a _nixbld user, invalid per nix path-info)," >&2
      echo "godyn: so 'nix store delete' cannot remove them. Clear and retry with:" >&2
      echo "godyn:   nix path-info $out >/dev/null 2>&1 && nix store delete $out || sudo rm -rf $out" >&2
      exit 1
    fi
    rm -f "$out/.godyn-writable"
  '';
  importsOf =
    importPath:
    let
      i = byImport.${importPath}.imports;
    in
    if i == null then [ ] else i;
  sanitize = s: lib.replaceStrings [ "/" "." "_" ] [ "-" "-" "-" ] s;
  nl = xs: if xs == null then [ ] else xs; # go marshals empty slices as null

  # GOOS/GOARCH for the asm -D defines.
  sysParts = lib.splitString "-" system;
  goarch =
    let
      m = {
        x86_64 = "amd64";
        aarch64 = "arm64";
        i686 = "386";
      };
    in
    m.${builtins.elemAt sysParts 0} or (builtins.elemAt sysParts 0);
  goos = builtins.elemAt sysParts 1;
  goamd64 = lib.optionalString (goarch == "amd64") " -D GOAMD64_v1";

  # A module is bridged iff it is in effectiveBridges; its packages source from the
  # go-pkgs store path. (Import paths under <mod> map to <bridge>/<rest>.)
  bridgeOf =
    importPath:
    lib.findFirst (m: m == importPath || lib.hasPrefix "${m}/" importPath) null (
      builtins.attrNames effectiveBridges
    );

  # A package is archive-bridged iff its module is in `archiveBridges`: it is not
  # compiled here, and dependents link its archive at <go-pkgs>/<importpath>/pkg.a.
  archiveBridgeOf =
    importPath:
    lib.findFirst (m: m == importPath || lib.hasPrefix "${m}/" importPath) null (
      builtins.attrNames archiveBridges
    );
  archivePathOf = importPath: "${archiveBridges.${archiveBridgeOf importPath}}/${importPath}/pkg.a";

  # Transitive non-stdlib import closure of a package (go tool compile's importcfg
  # must carry every package whose export data is reachable). Go has no import
  # cycles, so the recursion terminates.
  transitiveDeps =
    importPath:
    let
      direct = importsOf importPath;
    in
    lib.unique (direct ++ lib.concatMap transitiveDeps direct);

  # go:embed -embedcfg JSON for a graph node's embeds against a source dir. godyn-gen
  # records each pattern's matched files (embedPatternFiles, resolved with cmd/go's
  # own rules — igloo#68); graphs from an older gen fall back to literal and
  # trailing-* matching. A pattern that resolves to nothing throws: go build would
  # reject it, and an empty embed.FS only surfaces as a runtime panic. Shared by the
  # package compile and the test variant compile (the variant includes the
  # package's goFiles, so its embeds come along).
  embedCfgJSON =
    srcDir: node:
    let
      embedFiles = nl (node.embedFiles or null);
      legacyMatch =
        pat:
        if lib.elem pat embedFiles then
          [ pat ]
        else
          builtins.filter (f: lib.hasPrefix (lib.removeSuffix "*" pat) f) embedFiles;
      filesFor =
        pat:
        let
          fs =
            if node ? embedPatternFiles then nl (node.embedPatternFiles.${pat} or null) else legacyMatch pat;
        in
        if fs == [ ] then
          throw "buildGodynModule(${pname}): //go:embed ${pat} in ${node.importPath} resolves to no files — regenerate the graph with a current godyn-gen (it records each pattern's files; older graphs only match literal and trailing-* patterns, igloo#68)"
        else
          fs;
    in
    builtins.toJSON {
      Patterns = lib.genAttrs (nl (node.embedPatterns or null)) filesFor;
      Files = lib.listToAttrs (map (f: lib.nameValuePair f "${srcDir}/${f}") embedFiles);
    };

  # importcfg lines for `cfgFile`: stdlib from the shared stdlib drv; each non-stdlib
  # transitive dep contributes one `packagefile <imp>=<archive>`. A compiled dep
  # interpolates `${pkgDrvs.${dep}}` (making dep an inputDrv → the merkle-delta); an
  # archive-bridged dep points at its pre-built archive (approach 1).
  cfgFor =
    importPath: cfgFile:
    lib.concatMapStringsSep "\n" (
      dep:
      let
        archive = if archiveBridgeOf dep != null then archivePathOf dep else "${pkgDrvs.${dep}}/pkg.a";
      in
      "echo 'packagefile ${dep}=${archive}' >> ${cfgFile}"
    ) (transitiveDeps importPath);

  # A local package's source root. dir "." MUST resolve to src itself: with a
  # string-typed src (what flake inputs provide), `src + "/."` keeps the "/."
  # suffix, so the source filters' strip-prefix (toString root + "/") never
  # matches the canonical paths nix hands the filter and every file is silently
  # dropped. Path literals canonicalize the "/." away, which is why path-literal
  # fixtures never caught this (the eng/conformist incident).
  pkgRootFor = dir: if dir == "." then src else src + "/${dir}";

  # The other half of the pkgRootFor invariant: the per-package file sets hold
  # paths RELATIVE to the package root, so every source filter strips the same
  # root prefix from the canonical paths nix hands it. A no-op strip (result
  # still absolute) means root and prefix disagree — the dir-"." bug class —
  # so fail loud at the disagreement instead of silently dropping every file
  # and surfacing as a distant "no such file" compile error.
  relToRoot =
    root: path:
    let
      rel = lib.removePrefix (toString root + "/") (toString path);
    in
    if lib.hasPrefix "/" rel then
      throw "godyn: source filter prefix mismatch: ${toString path} is not under ${toString root}"
    else
      rel;

  # The language version a package compiles at (-lang), like `go build`: its
  # module's go directive, recorded by godyn-gen (igloo#74). Go directives may carry
  # a patch level ("1.24.2") but -lang takes only major.minor, so truncate. Graphs
  # from an older gen lack the field and fall back to goVersion for the whole graph.
  langOf =
    p: if (p.goVersion or "") != "" then "go${lib.versions.majorMinor p.goVersion}" else goVersion;

  # A package's source directory, shared by its compile and vet derivations.
  srcDirFor =
    importPath: p:
    let
      brMod = bridgeOf importPath;
      # Everything the compile consumes, package-dir-relative (embedFiles may live in
      # subdirectories, so membership is by relative path, not basename). Filtering
      # srcDir to exactly this set is what gives finer-than-package merkle-delta: a
      # _test.go edit, a stray scratch file, or a nested subpackage's churn leaves
      # this builtins.path byte-identical, so the package and its whole dependent
      # cone stay cached.
      srcFiles =
        nl p.goFiles
        ++ nl p.cgoFiles
        ++ nl p.cFiles
        ++ nl p.hFiles
        ++ nl p.sFiles
        ++ nl (p.embedFiles or null);
      srcFileSet = lib.listToAttrs (map (f: lib.nameValuePair f true) srcFiles);
      pkgRoot = pkgRootFor p.dir;
    in
    # Local: in-repo subdir (per-package filtered builtins.path; lazySrc keeps its
    # documented unfiltered whole-input behavior). Bridged: the go-pkgs store path.
    # Third-party: the vendor tree by import path.
    if p.local then
      (
        if lazySrc then
          pkgRoot
        else
          builtins.path {
            path = pkgRoot;
            name = "godyn-src-${sanitize importPath}";
            filter = path: type: type == "directory" || builtins.hasAttr (relToRoot pkgRoot path) srcFileSet;
          }
      )
    else if brMod != null then
      "${effectiveBridges.${brMod}}"
      + lib.optionalString (importPath != brMod) "/${lib.removePrefix "${brMod}/" importPath}"
    else
      "${resolvedVendorEnv}/${importPath}";

  # Compile a node per package, EXCEPT archive-bridged ones (those are linked from a
  # pre-built archive, never compiled here). transitiveDeps still sees them (they stay
  # in the graph) so dependents' importcfgs can reference their archives.
  pkgDrvs = lib.mapAttrs (
    importPath: p:
    let
      srcDir = srcDirFor importPath p;
      lang = langOf p;

      # nl: a pure-cgo package (e.g. zstd) has all .go in cgoFiles, so goFiles is
      # marshalled null; coerce before the list map.
      goFilesStr = lib.concatMapStringsSep " " (f: "${srcDir}/${f}") (nl p.goFiles);
      pflag = if p.isMain then "main" else importPath; # -p main: linker wants main.main
      rewrite = pflag;
      cfg = cfgFor importPath "importcfg";

      # compile-kind (orthogonal to source-kind): cgo if CgoFiles; else asm if
      # Plan 9 .s; else pure. .S/.sx gcc asm is compiled with cc inside the cgo path.
      sFiles = nl p.sFiles;
      plan9Asm = builtins.filter (f: !(lib.hasSuffix ".S" f || lib.hasSuffix ".sx" f)) sFiles;
      gccAsm = builtins.filter (f: lib.hasSuffix ".S" f || lib.hasSuffix ".sx" f) sFiles;
      isCgo = nl p.cgoFiles != [ ];
      isAsm = !isCgo && plan9Asm != [ ];

      # go:embed: a package with //go:embed needs `go tool compile -embedcfg`. gen
      # emits embedFiles/embedPatterns (absent on graphs from an older gen -> []).
      hasEmbed = nl (p.embedPatterns or null) != [ ];
      embedcfgJSON = embedCfgJSON srcDir p;
      embedSetup = lib.optionalString hasEmbed "printf '%s' ${lib.escapeShellArg embedcfgJSON} > embedcfg.json\n";
      embedFlag = lib.optionalString hasEmbed "-embedcfg embedcfg.json ";

      # A cgo main links externally: -extld cc + cc on PATH when any package in the
      # (incl. self) closure is cgo. Libraries (no main) never link.
      mainCgo =
        p.isMain
        && lib.any (d: nl byImport.${d}.cgoFiles != [ ]) (transitiveDeps importPath ++ [ importPath ]);

      pureScript = ''
        export GOROOT=${go}/share/go
        mkdir -p "$out"
        ${outWritableProbe}
        cat ${stdlib}/importcfg > importcfg
        ${cfg}
        ${embedSetup}go tool compile -importcfg importcfg ${embedFlag}-p '${pflag}' -buildid "" \
          -trimpath="${srcDir}=>${rewrite};$NIX_BUILD_TOP=>" \
          -nolocalimports -pack -lang=${lang} \
          -o "$out/pkg.a" ${goFilesStr}
      '';

      asmList = lib.concatMapStringsSep " " (f: "${srcDir}/${f}") plan9Asm;
      asmScript = ''
        export GOROOT=${go}/share/go
        W="$NIX_BUILD_TOP"
        export HOME="$W" GOCACHE="$W/gocache"
        mkdir -p "$out"
        ${outWritableProbe}
        cat ${stdlib}/importcfg > importcfg
        ${cfg}
        : > "$W/go_asm.h"
        ASM=(-p '${pflag}' -trimpath "${srcDir}=>${rewrite}" -I "$W/" -I ${go}/share/go/pkg/include -D GOOS_${goos} -D GOARCH_${goarch}${goamd64})
        go tool asm "''${ASM[@]}" -gensymabis -o "$W/symabis" ${asmList}
        ${embedSetup}go tool compile -importcfg importcfg ${embedFlag}-p '${pflag}' -buildid "" \
          -trimpath="${srcDir}=>${rewrite};$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${lang} \
          -symabis "$W/symabis" -asmhdr "$W/go_asm.h" \
          -o "$out/pkg.a" ${goFilesStr}
        declare -a OBJ=()
        n=0
        for s in ${asmList}; do
          o="$W/asm$n.o"; n=$((n+1))
          go tool asm "''${ASM[@]}" -o "$o" "$s"
          OBJ+=("$o")
        done
        go tool pack r "$out/pkg.a" "''${OBJ[@]}"
      '';

      cgoFilesStr = lib.concatStringsSep " " (nl p.cgoFiles); # basenames; cgo runs cwd=srcDir
      cFilesStr = lib.concatMapStringsSep " " (f: "${srcDir}/${f}") (nl p.cFiles ++ gccAsm);
      cgoScript = ''
        export GOROOT=${go}/share/go
        export CC=${cc}/bin/cc
        export HOME="$NIX_BUILD_TOP"
        mkdir -p "$out"
        ${outWritableProbe}
        work="$NIX_BUILD_TOP/cgo-${sanitize importPath}"; rm -rf "$work"; mkdir -p "$work"
        cat ${stdlib}/importcfg > importcfg
        ${cfg}
        RF=(-ffile-prefix-map="$work=/tmp/go-build" -ffile-prefix-map=${srcDir}=. -gno-record-gcc-switches)
        ( cd ${srcDir} && go tool cgo -objdir "$work" -importpath '${importPath}' -- -I "$work" "''${RF[@]}" ${cgoFilesStr} )
        declare -a OFILES=()
        n=0
        for cf in "$work/_cgo_export.c" "$work"/*.cgo2.c ${cFilesStr}; do
          [ -e "$cf" ] || continue
          o="$work/c$n.o"; n=$((n+1))
          "$CC" -c -I "$work" -I ${srcDir} -fPIC -pthread "''${RF[@]}" "$cf" -o "$o"
          OFILES+=("$o")
        done
        "$CC" -c -I "$work" -I ${srcDir} -fPIC -pthread "''${RF[@]}" "$work/_cgo_main.c" -o "$work/_cgo_main.o"
        DYN=""
        if "$CC" -o "$work/_cgo_.o" "$work/_cgo_main.o" "''${OFILES[@]}" -lpthread 2>"$work/tl.err"; then
          ( cd ${srcDir} && go tool cgo -dynimport "$work/_cgo_.o" -dynout "$work/_cgo_import.go" -dynpackage '${p.name}' )
          DYN="$work/_cgo_import.go"
        else
          : > "$work/dynimportfail"; OFILES+=("$work/dynimportfail")
        fi
        LDF=""
        if [ -e "$work/_cgo_flags" ]; then
          cgoldflags=""
          while IFS= read -r line; do case "$line" in _CGO_LDFLAGS=*) cgoldflags="''${line#_CGO_LDFLAGS=}";; esac; done < "$work/_cgo_flags"
          if [ -n "$cgoldflags" ]; then
            { echo "package ${p.name}"; echo; for fl in $cgoldflags; do echo "//go:cgo_ldflag \"$fl\""; done; } > "$work/_cgo_ldflag.go"
            LDF="$work/_cgo_ldflag.go"
          fi
        fi
        ${embedSetup}go tool compile -importcfg importcfg ${embedFlag}-p '${pflag}' -buildid "" \
          -trimpath="$work=>;${srcDir}=>${rewrite};$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${lang} \
          -o "$out/pkg.a" ${goFilesStr} "$work/_cgo_gotypes.go" "$work"/*.cgo1.go ''${DYN:+"$DYN"} ''${LDF:+"$LDF"}
        go tool pack r "$out/pkg.a" "''${OFILES[@]}"
        # keep cgo's translated Go sources: the analysis lanes type-check them (igloo#71)
        mkdir -p "$out/cgo" && cp "$work/_cgo_gotypes.go" "$work"/*.cgo1.go "$out/cgo/"
        # if-block, not a trailing "test && cmd": a false bracket test as the last
        # statement makes 1 the exit status (silent) and fails the build.
        if [ -e "$work/_cgo_flags" ]; then go tool pack r "$out/pkg.a" "$work/_cgo_flags"; fi
      '';

      compile =
        if isCgo then
          cgoScript
        else if isAsm then
          asmScript
        else
          pureScript;

      link = lib.optionalString p.isMain ''
        mkdir -p "$out/bin"
        ${lib.optionalString mainCgo "export PATH=${cc}/bin:$PATH"}
        cat ${stdlib}/importcfg > importcfg.link
        ${cfgFor importPath "importcfg.link"}
        GOTOOLDIR="$(go env GOTOOLDIR)"
        export GOROOT=
        "$GOTOOLDIR/link" -buildid=redacted -buildmode=exe ${lib.optionalString mainCgo "-extld ${cc}/bin/cc"} ${effectiveLdflagsStr} -importcfg importcfg.link \
          -o "$out/bin/${pname}" "$out/pkg.a"
      '';
    in
    runCommandLocal "godyn-compile-${sanitize importPath}" {
      nativeBuildInputs = [ go ] ++ lib.optional (isCgo || mainCgo) cc;
      # Content-addressed: a byte-identical pkg.a after an edit keeps its store
      # hash, so dependents stay cached (early cutoff) — the merkle-delta.
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    } (compile + link)
  ) (lib.filterAttrs (importPath: _: archiveBridgeOf importPath == null) byImport);

  # ---- per-package analysis lanes (the unitchecker / `go vet -vettool` protocol) ----
  # One CA derivation per package per lane. The tool gets a vet.cfg naming the
  # package's sources, every import's export data (godyn's per-package archives plus
  # the stdlib importcfg), and each dependency's facts (that dependency's own output
  # in the same lane), and writes this package's facts to $out/vet.out — so
  # analyzers' cross-package facts chain along the same merkle-delta as the
  # compiles. Local packages report findings (any finding fails the build);
  # third-party and bridged ones run facts-only (VetxOnly). cgo packages are
  # skipped: analyzing them needs cgo's translated sources. Only non-test sources
  # are analyzed. Two lanes share this: vet (the toolchain's vet, or vetTool) and
  # lint (lintTool, godyn-lint by default).

  # The stdlib half of every vet.cfg, derived once from the stdlib importcfg.
  # "unsafe" has no archive but must resolve through ImportMap.
  vetStdCfg = runCommandLocal "godyn-vet-stdlib-cfg" { nativeBuildInputs = [ jq ]; } ''
    sed -n 's/^packagefile \([^=]*\)=\(.*\)$/\1\t\2/p' ${stdlib}/importcfg \
      | jq -R -n '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries
          | {PackageFile: ., ImportMap: (with_entries(.value = .key) + {unsafe: "unsafe"}),
             Standard: (with_entries(.value = true) + {unsafe: true})}' > $out
  '';

  # New-protocol tools (x/tools >= v0.50, tool.passthru.typedVetx) read every
  # import's TYPES from that import's vetx file rather than PackageFile, so the
  # stdlib needs vetx files too: run the tool facts-only over the stdlib in
  # dependency order, once per tool, and index the results (igloo#71). cgo is on,
  # matching godynStdlib: the stdlib's cgo packages are translated the way cmd/go's
  # runCgo does (including its runtime/* flags) and analyzed from the translated
  # sources; cgo-generated code imports runtime/cgo and syscall, so imports resolve
  # over each package's whole dependency set.
  stdVetxLane =
    lane: toolExe:
    runCommandLocal "godyn-${lane}-stdlib-vetx"
      {
        nativeBuildInputs = [
          go
          jq
          stdenv.cc
        ];
      }
      ''
        export GOROOT=${go}/share/go HOME="$TMPDIR" GOCACHE="$TMPDIR/gocache" \
          CGO_ENABLED=1 CC=cc GOTOOLCHAIN=local GOPROXY=off GOFLAGS=
        mkdir -p "$out"
        go list -e -deps -json std \
          | jq -s 'map(select(.ImportPath != "unsafe" and .Error == null and (((.GoFiles // []) + (.CgoFiles // [])) | length) > 0))' > pkgs.json
        jq -c '.[]' pkgs.json | while read -r pkg; do
          ip=$(jq -r .ImportPath <<<"$pkg")
          mkdir -p "$(dirname "$out/$ip")"
          cgoGo='[]'
          mapfile -t cgofiles < <(jq -r '(.CgoFiles // [])[]' <<<"$pkg")
          if [ ''${#cgofiles[@]} -gt 0 ]; then
            obj="$TMPDIR/cgo/$ip"
            mkdir -p "$obj"
            flags=()
            case "$ip" in
              runtime/cgo) flags=(-import_runtime_cgo=false -import_syscall=false) ;;
              runtime/race | runtime/msan | runtime/asan) flags=(-import_syscall=false) ;;
            esac
            mapfile -t cflags < <(jq -r '((.CgoCPPFLAGS // []) + (.CgoCFLAGS // []))[]' <<<"$pkg")
            ( cd "$(jq -r .Dir <<<"$pkg")" \
              && go tool cgo -objdir "$obj" -importpath "$ip" "''${flags[@]}" -- -I "$obj" "''${cflags[@]}" "''${cgofiles[@]}" )
            cgoGo=$(jq -n --arg obj "$obj" \
              '[$obj + "/_cgo_gotypes.go"] + ($ARGS.positional | map($obj + "/" + rtrimstr(".go") + ".cgo1.go"))' \
              --args "''${cgofiles[@]}")
          fi
          jq --arg out "$out" --arg lang ${goVersion} --argjson cgoGo "$cgoGo" '
            .Dir as $d | ((.Imports // []) + (.Deps // []) | unique) as $imps | {
              ID: .ImportPath,
              Compiler: "gc",
              ImportPath: .ImportPath,
              GoVersion: $lang,
              GoFiles: ([(.GoFiles // [])[] | $d + "/" + .] + $cgoGo),
              NonGoFiles: [(.SFiles // [])[] | $d + "/" + .],
              ImportMap: ((reduce $imps[] as $i ({}; .[$i] = $i)) + (.ImportMap // {})),
              PackageVetx: (reduce ($imps[] | select(. != "unsafe" and . != "C")) as $i ({}; .[$i] = $out + "/" + $i + ".vetx")),
              Standard: (reduce $imps[] as $i ({}; .[$i] = true)),
              VetxOnly: true,
              VetxOutput: ($out + "/" + .ImportPath + ".vetx")
            }' <<<"$pkg" > vet.cfg
          ${toolExe} vet.cfg
        done
        jq --arg out "$out" 'map({key: .ImportPath, value: ($out + "/" + .ImportPath + ".vetx")}) | from_entries' \
          pkgs.json > "$out/index.json"
        # each stdlib package's transitive stdlib deps: a run whose graph records
        # stdImports is handed only the vetx its imports reach
        jq 'map({key: .ImportPath, value: [(.Deps // [])[] | select(. != "unsafe" and . != "C")]}) | from_entries' \
          pkgs.json > "$out/deps.json"
      '';

  # A lane: { local = run derivations of the local packages by import path;
  # all = the manifest realising every one of them }. typedVetx: the tool speaks
  # the type-bearing vetx protocol, so its runs also get the stdlib vetx index.
  analysisLane =
    lane: toolExe: typedVetx:
    let
      stdVetx = stdVetxLane lane toolExe;
      mergeCfg =
        if typedVetx then
          "jq -s '.[2] as $idx | .[3] as $deps | (.[0] * .[1]) | (if .stdRoots == null then $idx else ([.stdRoots[] as $r | $r, ($deps[$r] // [])[]] | unique) as $closure | ($idx | with_entries(select(.key | IN($closure[])))) end) as $std | .PackageVetx = ($std + .PackageVetx) | del(.stdRoots)' ${vetStdCfg} \"$vetCfgPath\" ${stdVetx}/index.json ${stdVetx}/deps.json"
        else
          "jq -s '.[0] * .[1] | del(.stdRoots)' ${vetStdCfg} \"$vetCfgPath\"";
      drvs =
        lib.mapAttrs
          (
            importPath: p:
            let
              srcDir = srcDirFor importPath p;
              deps = transitiveDeps importPath;
              archiveOf = d: if archiveBridgeOf d != null then archivePathOf d else "${pkgDrvs.${d}}/pkg.a";
            in
            runCommandLocal "godyn-${lane}-${sanitize importPath}"
              {
                nativeBuildInputs = [
                  go
                  jq
                ];
                vetCfg = builtins.toJSON {
                  ID = importPath;
                  Compiler = "gc";
                  ImportPath = importPath;
                  GoVersion = langOf p;
                  # a cgo package is type-checked from cgo's translated sources, kept by
                  # its compile derivation (only reached for typed-vetx tools)
                  GoFiles =
                    map (f: "${srcDir}/${f}") (nl p.goFiles)
                    ++ lib.optionals (nl p.cgoFiles != [ ]) (
                      [ "${pkgDrvs.${importPath}}/cgo/_cgo_gotypes.go" ]
                      ++ map (f: "${pkgDrvs.${importPath}}/cgo/${lib.removeSuffix ".go" f}.cgo1.go") (nl p.cgoFiles)
                    );
                  NonGoFiles = map (f: "${srcDir}/${f}") (nl p.sFiles);
                  ImportMap = lib.genAttrs deps (d: d);
                  PackageFile = lib.genAttrs deps archiveOf;
                  PackageVetx = lib.genAttrs (builtins.filter (d: drvs ? ${d}) deps) (d: "${drvs.${d}}/vet.out");
                  # the stdlib the package's import closure reaches: its own and its
                  # graph deps' direct stdlib imports (expanded through the stdlib
                  # lane's deps.json at build time); null for graphs from an older gen,
                  # which get the whole stdlib index
                  stdRoots =
                    if p ? stdImports then
                      lib.unique (lib.concatMap (d: nl (byImport.${d}.stdImports or null)) ([ importPath ] ++ deps))
                    else
                      null;
                  VetxOnly = !p.local;
                  VetxOutput = "vet.out";
                };
                passAsFile = [ "vetCfg" ];
                __contentAddressed = true;
                outputHashMode = "recursive";
                outputHashAlgo = "sha256";
              }
              ''
                export GOROOT=${go}/share/go
                mkdir -p "$out"
                ${outWritableProbe}
                ${mergeCfg} > vet.cfg
                ${toolExe} vet.cfg
                ${lib.optionalString typedVetx ''jq --arg s "${stdVetx}" '[.PackageVetx[] | select(startswith($s))] | length' vet.cfg > "$out/stdvetx.count"''}
                [ -e vet.out ] || : > vet.out
                mv vet.out "$out/vet.out"
                ${lib.optionalString p.local ''echo "ok ${importPath}" > "$out/result"''}
              ''
          )
          (
            lib.filterAttrs (ip: p: archiveBridgeOf ip == null && (typedVetx || nl p.cgoFiles == [ ])) byImport
          );
      local = lib.filterAttrs (ip: _: byImport.${ip}.local) drvs;
    in
    {
      inherit local stdVetx;
      all = runCommandLocal "godyn-${pname}-${lane}" { } (
        ": > $out\n"
        + lib.concatMapStringsSep "\n" (ip: "cat ${local.${ip}}/result >> $out") (builtins.attrNames local)
      );
    };

  speaksTypedVetx = tool: tool != null && (tool.passthru.typedVetx or false);
  vetLane = analysisLane "vet" (
    if vetTool != null then lib.getExe vetTool else ''"$(go env GOTOOLDIR)/vet"''
  ) (speaksTypedVetx vetTool);
  lintLane = analysisLane "lint" (lib.getExe lintTool) (speaksTypedVetx lintTool);

  mainPkg = lib.findFirst (p: p.isMain) null graph;

  # Packages this graph actually compiles (archive-bridged ones are linked, not built).
  ownPkgs = builtins.filter (p: archiveBridgeOf p.importPath == null) graph;

  # Compile-only terminal for a library graph (no package main): a manifest that
  # depends on every compiled package archive (so building it realises the whole
  # graph) and lists the import paths.
  manifest = runCommandLocal "godyn-${pname}-manifest" { } (
    ": > $out\n"
    + lib.concatMapStringsSep "\n" (
      p: "test -s ${pkgDrvs.${p.importPath}}/pkg.a && echo '${p.importPath}' >> $out"
    ) ownPkgs
  );

  # This module's per-package compiled archives, laid out as <importpath>/pkg.a, so a
  # downstream module can link them via archiveBridges (approach 1). Symlinks into the
  # per-package CA derivations, so it stays incremental.
  archiveGoPkgs = runCommandLocal "godyn-${pname}-archives" { } (
    lib.concatMapStringsSep "\n" (
      p:
      ''mkdir -p "$out/${p.importPath}"; ln -s ${pkgDrvs.${p.importPath}}/pkg.a "$out/${p.importPath}/pkg.a"''
    ) ownPkgs
  );

  # ---- per-package go test (igloo#32) ----
  # Two CA derivations per tested package, from the `godyn-gen -tests` graph:
  # testBin compiles the `go list -test` package shape — the test VARIANT (package
  # sources + in-package _test.go, same import path), the external <ip>_test package
  # compiled against the VARIANT's archive (so test-only exports resolve), and the
  # captured go-generated testmain — then links <name>.test. testRun executes it
  # with cwd = the package source (testdata/ and golden files resolve), writing
  # "ok <ip>" to $out/result; a failing test fails the build. The bin/run boundary
  # caches the binary across re-runs and exposes it for manual -run/-v invocation.
  testGraph =
    if resolvedTestGraphFile != null then
      builtins.fromJSON (builtins.readFile resolvedTestGraphFile)
    else
      [ ];

  testDrvsFor =
    t:
    let
      inherit (t) importPath;
      base =
        byImport.${importPath}
          or (throw "buildGodynModule(${pname}): test-graph entry ${importPath} is not in the build graph — regenerate both graphs with godyn-gen");
      goFiles = nl t.goFiles;
      testGoFiles = nl t.testGoFiles;
      xTestGoFiles = nl t.xTestGoFiles;
      hasExt = xTestGoFiles != [ ];
      binName = "${baseNameOf importPath}.test";

      embedFiles = nl (base.embedFiles or null);
      hasEmbed = nl (base.embedPatterns or null) != [ ];

      pkgRoot = pkgRootFor t.dir;
      compileFiles = goFiles ++ testGoFiles ++ xTestGoFiles ++ embedFiles;
      compileFileSet = lib.listToAttrs (map (f: lib.nameValuePair f true) compileFiles);
      relTo = relToRoot pkgRoot;
      compileSrc = builtins.path {
        path = pkgRoot;
        name = "godyn-testsrc-${sanitize importPath}";
        filter = path: type: type == "directory" || builtins.hasAttr (relTo path) compileFileSet;
      };
      # The run's cwd: `go test` executes test binaries with cwd = the package dir,
      # so testdata/ (and everything the compile saw) must be present.
      runSrc = builtins.path {
        path = pkgRoot;
        name = "godyn-testcwd-${sanitize importPath}";
        filter =
          path: type:
          type == "directory"
          || builtins.hasAttr (relTo path) compileFileSet
          || lib.hasPrefix "testdata/" (relTo path);
      };

      # Dep closure for the variant/external/link importcfgs. Direct deps come from
      # the test graph (the variant's imports INCLUDE test-only deps); expand
      # through the build graph. A dep absent from the build graph is a test-only
      # third-party import — not yet supported.
      directDeps = lib.unique (nl t.imports ++ nl t.xTestImports);
      testDeps = lib.unique (
        directDeps ++ lib.concatMap (d: if byImport ? ${d} then transitiveDeps d else [ ]) directDeps
      );
      depLine =
        cfgFile: dep:
        let
          archive =
            if archiveBridgeOf dep != null then
              archivePathOf dep
            else if byImport ? ${dep} then
              "${pkgDrvs.${dep}}/pkg.a"
            else
              throw "buildGodynModule(${pname}): test dependency ${dep} of ${importPath} is not in the build graph (test-only third-party deps are not yet supported — igloo#32)";
        in
        "echo 'packagefile ${dep}=${archive}' >> ${cfgFile}";
      testCfg = cfgFile: lib.concatMapStringsSep "\n" (depLine cfgFile) testDeps;

      files = fs: lib.concatMapStringsSep " " (f: "${compileSrc}/${f}") fs;
      lang = langOf t;
      testmainSrc = builtins.toFile "godyn-testmain-${sanitize importPath}.go" t.testmain;

      variantEmbedSetup = lib.optionalString hasEmbed "printf '%s' ${lib.escapeShellArg (embedCfgJSON compileSrc base)} > \"$W/embedcfg.json\"\n";
      variantEmbedFlag = lib.optionalString hasEmbed ''-embedcfg "$W/embedcfg.json" '';

      bin =
        if nl base.cgoFiles != [ ] || nl base.sFiles != [ ] then
          throw "buildGodynModule(${pname}): tests for cgo/asm package ${importPath} are not yet supported (igloo#32)"
        else
          runCommandLocal "godyn-testbin-${sanitize importPath}"
            {
              nativeBuildInputs = [ go ];
              __contentAddressed = true;
              outputHashMode = "recursive";
              outputHashAlgo = "sha256";
            }
            ''
              export GOROOT=${go}/share/go
              mkdir -p "$out"
              ${outWritableProbe}
              W="$NIX_BUILD_TOP"

              # 1. the test VARIANT: package + in-package test sources, same import path.
              CFG="$W/ic.variant"; cat ${stdlib}/importcfg > "$CFG"
              ${testCfg ''"$CFG"''}
              ${variantEmbedSetup}go tool compile -importcfg "$CFG" ${variantEmbedFlag}-p '${importPath}' -buildid "" \
                -trimpath="${compileSrc}=>${importPath};$W=>" -nolocalimports -pack -lang=${lang} \
                -o "$W/variant.a" ${files (goFiles ++ testGoFiles)}

              ${lib.optionalString hasExt ''
                # 2. the external test package <ip>_test, against the VARIANT's archive.
                CFG="$W/ic.ext"; cat ${stdlib}/importcfg > "$CFG"
                ${testCfg ''"$CFG"''}
                echo "packagefile ${importPath}=$W/variant.a" >> "$CFG"
                go tool compile -importcfg "$CFG" -p '${importPath}_test' -buildid "" \
                  -trimpath="${compileSrc}=>${importPath}_test;$W=>" -nolocalimports -pack -lang=${lang} \
                  -o "$W/xtest.a" ${files xTestGoFiles}
              ''}

              # 3. the captured go-generated testmain.
              CFG="$W/ic.main"; cat ${stdlib}/importcfg > "$CFG"
              echo "packagefile ${importPath}=$W/variant.a" >> "$CFG"
              ${lib.optionalString hasExt ''echo "packagefile ${importPath}_test=$W/xtest.a" >> "$CFG"''}
              go tool compile -importcfg "$CFG" -p main -buildid "" \
                -trimpath="$W=>" -nolocalimports -pack -lang=${lang} \
                -o "$W/testmain.a" ${testmainSrc}

              # 4. link the test binary.
              CFG="$W/ic.link"; cat ${stdlib}/importcfg > "$CFG"
              echo "packagefile ${importPath}=$W/variant.a" >> "$CFG"
              ${lib.optionalString hasExt ''echo "packagefile ${importPath}_test=$W/xtest.a" >> "$CFG"''}
              ${testCfg ''"$CFG"''}
              GOTOOLDIR="$(go env GOTOOLDIR)"
              export GOROOT=
              "$GOTOOLDIR/link" -buildid=redacted -buildmode=exe -importcfg "$CFG" \
                -o "$out/${binName}" "$W/testmain.a"
            '';

      run =
        runCommandLocal "godyn-test-${sanitize importPath}"
          {
            __contentAddressed = true;
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
          }
          ''
            mkdir -p "$out"
            ${outWritableProbe}
            cd ${runSrc}
            if ${bin}/${binName} > "$NIX_BUILD_TOP/test.log" 2>&1; then
              echo "ok ${importPath}" > "$out/result"
            else
              echo "godyn-test FAIL ${importPath}:" >&2
              cat "$NIX_BUILD_TOP/test.log" >&2
              exit 1
            fi
          '';
    in
    {
      inherit bin run;
    };

  testPairs = lib.listToAttrs (map (t: lib.nameValuePair t.importPath (testDrvsFor t)) testGraph);
  testBins = lib.mapAttrs (_: v: v.bin) testPairs;
  testRuns = lib.mapAttrs (_: v: v.run) testPairs;

  # One manifest realising every test run — the flake-checks hook.
  checkAll = runCommandLocal "godyn-${pname}-tests" { } (
    ": > $out\n"
    + lib.concatMapStringsSep "\n" (t: "cat ${testRuns.${t.importPath}}/result >> $out") testGraph
  );

  terminal = if mainPkg != null then pkgDrvs.${mainPkg.importPath} else manifest;

  hasInstallStep = postInstall != "" || nativeBuildInputs != [ ];
  installed =
    if !hasInstallStep then
      terminal
    else if mainPkg == null then
      throw "buildGodynModule: postInstall/nativeBuildInputs need a main package; ${pname}'s graph has none"
    else
      runCommandLocal "${pname}-${effectiveVersion}" { inherit nativeBuildInputs postInstall; } ''
        mkdir -p "$out/bin"
        cp ${terminal}/bin/${pname} "$out/bin/${pname}"
        cp -r --no-preserve=mode ${src} source
        cd source
        runHook postInstall
      '';
in
# Surface the resolved version + assembled ldflags (parity with buildGoApplication,
# and so eval-time tests can assert without building); set mainProgram for `nix run`.
installed.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    version = effectiveVersion;
    ldflags = versionLdflags ++ ldflags ++ ldflagsXFlags;
    # For downstream godyn→godyn composition: archiveGoPkgs feeds a consumer's
    # archiveBridges (approach 1). The source route (approach 2) just uses this
    # module's `src` as a `bridges` value — no passthru needed.
    inherit archiveGoPkgs;
    # go test (igloo#32): run derivations by import path (a failing test fails the
    # build), the linked test binaries (manual -run/-v invocation), and the
    # all-tests manifest for flake checks. Empty when no test graph was passed.
    tests = testRuns;
    inherit testBins checkAll;
    # per-package vet and lint: run derivations for the local packages by import
    # path (a finding fails the build), and each lane's manifest for flake checks.
    vet = vetLane.local;
    vetAll = vetLane.all;
    lint = lintLane.local;
    lintAll = lintLane.all;
    # the lint tool's stdlib vetx lane (type-bearing vetx tools only; igloo#71)
    lintStdVetx = lintLane.stdVetx;
    # the graphs this build used: the committed files, or the derived ones (FDR 0008)
    graphFile = resolvedGraphFile;
    testGraphFile = resolvedTestGraphFile;
  };
  meta = (old.meta or { }) // lib.optionalAttrs (mainPkg != null) { mainProgram = pname; };
})
