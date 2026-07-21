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
  # cc: a stdenv cc-wrapper, required iff any package is cgo (zstd etc.).
  cc ? null,
  # bridges: modpath -> go-pkgs store path; a package whose module is bridged is
  # sourced from there instead of vendorEnv (RFC 0001 cross-flake go-pkgs).
  bridges ? { },
  system ? "x86_64-linux",
  pname ? "godyntb",
  goVersion ? "go1.26",
  # lazySrc (experiment, #27): source local packages directly from the flake input
  # tree (src + "/dir") instead of a per-package `builtins.path` copy, so Determinate
  # lazy-trees can avoid materialising them. WARNING: a bare `src + "/dir"` is a
  # subpath of the whole-input store path, so an edit to ANY file re-hashes the
  # input and rebuilds EVERY package — it trades per-package incrementality for the
  # lazy read. Only for measuring whether builtins.path is what defeats lazy-trees.
  lazySrc ? false,
}:
let
  graph = builtins.fromJSON (builtins.readFile graphFile);
  byImport = lib.listToAttrs (map (p: lib.nameValuePair p.importPath p) graph);
  importsOf =
    importPath:
    let
      i = byImport.${importPath}.imports;
    in
    if i == null then [ ] else i;
  sanitize = s: lib.replaceStrings [ "/" "." "_" ] [ "-" "-" "-" ] s;
  nl = xs: if xs == null then [ ] else xs; # go marshals empty slices as null

  # GOOS/GOARCH for the asm -D defines (the resolver's goosArch).
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

  # A module is bridged iff it is in `bridges`; its packages source from the
  # go-pkgs store path. (Import paths under <mod> map to <bridge>/<rest>.)
  bridgeOf =
    importPath:
    lib.findFirst (m: m == importPath || lib.hasPrefix "${m}/" importPath) null (
      builtins.attrNames bridges
    );

  # Transitive non-stdlib import closure of a package (go tool compile's
  # importcfg must carry every package whose export data is reachable, not just
  # direct imports). Go has no import cycles, so the recursion terminates.
  transitiveDeps =
    importPath:
    let
      direct = importsOf importPath;
    in
    lib.unique (direct ++ lib.concatMap transitiveDeps direct);

  # importcfg lines for `cfgFile`: stdlib comes from the shared stdlib drv; each
  # non-stdlib transitive dep contributes one `packagefile <imp>=<drv>/pkg.a`.
  # Interpolating `${pkgDrvs.${dep}}` is what makes dep an inputDrv of this drv.
  cfgFor =
    importPath: cfgFile:
    lib.concatMapStringsSep "\n" (
      dep: "echo 'packagefile ${dep}=${pkgDrvs.${dep}}/pkg.a' >> ${cfgFile}"
    ) (transitiveDeps importPath);

  pkgDrvs = lib.mapAttrs (
    importPath: p:
    let
      brMod = bridgeOf importPath;
      # Local: in-repo subdir (per-package builtins.path). Bridged: the go-pkgs
      # store path. Third-party: the vendor tree by import path.
      srcDir =
        if p.local then
          (
            if lazySrc then
              src + "/${p.dir}"
            else
              builtins.path {
                path = src + "/${p.dir}";
                name = "godyn-v2-src-${sanitize importPath}";
              }
          )
        else if brMod != null then
          "${bridges.${brMod}}"
          + lib.optionalString (importPath != brMod) "/${lib.removePrefix "${brMod}/" importPath}"
        else
          "${vendorEnv}/${importPath}";

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

      # A cgo main links externally: -extld cc + cc on PATH when any package in
      # the (incl. self) closure is cgo. Libraries (no main) never link.
      mainCgo =
        p.isMain
        && lib.any (d: nl byImport.${d}.cgoFiles != [ ]) (transitiveDeps importPath ++ [ importPath ]);

      pureScript = ''
        export GOROOT=${go}/share/go
        mkdir -p "$out"
        cat ${stdlib}/importcfg > importcfg
        ${cfg}
        go tool compile -importcfg importcfg -p '${pflag}' -buildid "" \
          -trimpath="${srcDir}=>${rewrite};$NIX_BUILD_TOP=>" \
          -nolocalimports -pack -lang=${goVersion} \
          -o "$out/pkg.a" ${goFilesStr}
      '';

      asmList = lib.concatMapStringsSep " " (f: "${srcDir}/${f}") plan9Asm;
      asmScript = ''
        export GOROOT=${go}/share/go
        W="$NIX_BUILD_TOP"
        export HOME="$W" GOCACHE="$W/gocache"
        mkdir -p "$out"
        cat ${stdlib}/importcfg > importcfg
        ${cfg}
        : > "$W/go_asm.h"
        ASM=(-p '${pflag}' -trimpath "${srcDir}=>${rewrite}" -I "$W/" -I ${go}/share/go/pkg/include -D GOOS_${goos} -D GOARCH_${goarch}${goamd64})
        go tool asm "''${ASM[@]}" -gensymabis -o "$W/symabis" ${asmList}
        go tool compile -importcfg importcfg -p '${pflag}' -buildid "" \
          -trimpath="${srcDir}=>${rewrite};$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${goVersion} \
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
          ldflags=""
          while IFS= read -r line; do case "$line" in _CGO_LDFLAGS=*) ldflags="''${line#_CGO_LDFLAGS=}";; esac; done < "$work/_cgo_flags"
          if [ -n "$ldflags" ]; then
            { echo "package ${p.name}"; echo; for fl in $ldflags; do echo "//go:cgo_ldflag \"$fl\""; done; } > "$work/_cgo_ldflag.go"
            LDF="$work/_cgo_ldflag.go"
          fi
        fi
        go tool compile -importcfg importcfg -p '${pflag}' -buildid "" \
          -trimpath="$work=>;${srcDir}=>${rewrite};$NIX_BUILD_TOP=>" -nolocalimports -pack -lang=${goVersion} \
          -o "$out/pkg.a" ${goFilesStr} "$work/_cgo_gotypes.go" "$work"/*.cgo1.go ''${DYN:+"$DYN"} ''${LDF:+"$LDF"}
        go tool pack r "$out/pkg.a" "''${OFILES[@]}"
        # if-block, not a trailing "test && cmd": a false bracket test as the
        # last statement makes 1 the exit status (silent) and fails the build.
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
        "$GOTOOLDIR/link" -buildid=redacted -buildmode=exe ${lib.optionalString mainCgo "-extld ${cc}/bin/cc"} -importcfg importcfg.link \
          -o "$out/bin/${pname}" "$out/pkg.a"
      '';
    in
    runCommandLocal "godyn-v2-compile-${sanitize importPath}" {
      nativeBuildInputs = [ go ] ++ lib.optional (isCgo || mainCgo) cc;
      # Content-addressed: a byte-identical pkg.a after an edit keeps its store
      # hash, so dependents stay cached (early cutoff) — the merkle-delta.
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    } (compile + link)
  ) byImport;

  mainPkg = lib.findFirst (p: p.isMain) null graph;

  # Compile-only terminal for a library graph (no package main): a manifest that
  # depends on every package archive (so building it realises the whole graph)
  # and lists the import paths. Mirrors the resolver's buildManifestDrv.
  manifest = runCommandLocal "godyn-v2-${pname}-manifest" { } (
    ": > $out\n"
    + lib.concatMapStringsSep "\n" (
      p: "test -s ${pkgDrvs.${p.importPath}}/pkg.a && echo '${p.importPath}' >> $out"
    ) graph
  );
in
if mainPkg != null then pkgDrvs.${mainPkg.importPath} else manifest
