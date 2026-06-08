/**
  gomod2nix build-support library.

  Exposes helpers for packaging Go applications that use
  gomod2nix.toml lockfiles as Nix derivations. The public surface is:

  - `buildGoApplication` — build a Go application from a gomod2nix.toml lockfile
  - `buildGoRace` — race-instrumented variant of an existing buildGoApplication derivation
  - `buildGoCover` — coverage-instrumented variant that runs an integration command under $GOCOVERDIR
  - `mkGoEnv` — create a vendor environment for use in devshells
  - `mkVendorEnv` — low-level: assemble a vendor/ directory from fetched modules
  - `mkGoCacheEnv` — pre-warm the Go build cache as a derivation

  The `go` argument defaults to the Go version specified in `go.mod` (via
  `selectGo`) and can be overridden: `buildGoApplication { go = pkgs.go_1_24; }`.

  The `gomod2nix` CLI is auto-injected from `pkgs.gomod2nix` via `callPackage`
  and is propagated through `mkGoEnv` so any devShell that includes the env
  gets the CLI on PATH (needed by `go-sync-wrap.sh` and `updateScript`).
*/
{
  buildEnv,
  buildPackages,
  cacert,
  fetchgit,
  git,
  gnutar,
  gomod2nix ? throw "gomod2nix: pkgs.gomod2nix must be available — ensure amarbel-llc/igloo is your nixpkgs input",
  jq,
  lib,
  makeSetupHook,
  pkgsBuildBuild,
  rsync,
  runCommand,
  runtimeShell,
  stdenv,
  stdenvNoCC,
  writeScript,
  writeText,
  zstd,
}:
let

  hooks = import ./hooks/default.nix {
    inherit
      lib
      makeSetupHook
      buildPackages
      stdenv
      ;
  };

  inherit (hooks)
    goConfigHook
    goBuildHook
    goCheckHook
    goInstallHook
    ;

  inherit (builtins)
    elemAt
    hasAttr
    readFile
    split
    substring
    toJSON
    ;
  inherit (lib)
    concatStringsSep
    fetchers
    filterAttrs
    mapAttrs
    mapAttrsToList
    optional
    optionalAttrs
    optionalString
    pathExists
    removePrefix
    ;

  inherit (import ./parser.nix) parseGoMod parseGoWork;

  internals = import ./internals.nix { };
  inherit (internals)
    mkMergedView
    ;

  sourceFilter = import ./source-filter.nix { inherit lib runCommand; };
  inherit (sourceFilter) goSourceFilter goSourceFilterMiddleware;

  goPkgsHelper = import ./mk-go-pkgs.nix { inherit lib runCommand; };
  inherit (goPkgsHelper) mkGoPkgs;

  # Resolve a caller-supplied (pwd, src) pair into an effective pwd, with
  # eval-time validation. Both `mkGoEnv` and `buildGoApplication` route
  # through this so the polyglot footgun (calling with `src = self` for a
  # repo whose Go module lives in `/go`) fails loudly instead of crashing
  # downstream with an opaque "go.mod: file not found" or vendor-env
  # symlink error.
  #
  # Resolution rules:
  #   - pwd given  → use it
  #   - pwd null but src given → pwd defaults to src (single-module case)
  #   - both null  → throw
  #   - effective pwd lacks go.mod AND go.work → throw (polyglot footgun)
  resolvePwd =
    { caller, pwd, src }:
    let
      p =
        if pwd != null then
          pwd
        else if src != null then
          src
        else
          throw ''
            ${caller}: `pwd` is required. Either pass `pwd` explicitly,
            or set `src` (in which case `pwd` defaults to `src`). `pwd`
            MUST be a directory containing go.mod or go.work.
          '';
      hasGoMod = pathExists "${toString p}/go.mod";
      hasGoWork = pathExists "${toString p}/go.work";
    in
    if hasGoMod || hasGoWork then
      p
    else
      throw ''
        ${caller}: pwd = ${toString p}
        MUST contain go.mod or go.work, but neither was found.

        Polyglot repos with Go in a subdirectory need an explicit pwd
        pointing at THAT subdirectory (whatever its actual name is in
        your repo):

          pwd = src + "/<your-go-subdir>";

        For example, a repo whose Go module lives in `./go/` would use
        `pwd = src + "/go"`; one with Go under `./backend/` would use
        `pwd = src + "/backend"`. The literal string above is a
        placeholder, not the path to use.

        The subdirectory's go.mod/go.sum/gomod2nix.toml MUST also be in
        the filtered source tree (see goSourceFilter / mkGoPkgs).
      '';

  # Internal only build-time attributes
  internal =
    let
      mkInternalPkg =
        name: src:
        pkgsBuildBuild.runCommand "gomod2nix-${name}"
          {
            inherit (pkgsBuildBuild.go) GOOS GOARCH;
            nativeBuildInputs = [ pkgsBuildBuild.go ];
          }
          ''
            export HOME=$(mktemp -d)
            go build -o "$HOME/bin" ${src}
            mv "$HOME/bin" "$out"
          '';
    in
    {
      # Create a symlink tree of vendored sources
      symlink = mkInternalPkg "symlink" ./symlink/symlink.go;

      # Install development dependencies from tools.go
      install = mkInternalPkg "symlink" ./install/install.go;

      # Generate dummy import file for cache warming
      cachegen = mkInternalPkg "cachegen" ./cachegen/cachegen.go;
    };

  fetchGoModule =
    {
      hash,
      goPackagePath,
      version,
      go,
    }:
    stdenvNoCC.mkDerivation {
      name = "${baseNameOf goPackagePath}_${version}";
      builder = ./fetch.sh;
      inherit goPackagePath version;
      nativeBuildInputs = [
        cacert
        git
        go
        jq
      ];
      outputHashMode = "recursive";
      outputHashAlgo = null;
      outputHash = hash;
      impureEnvVars = fetchers.proxyImpureEnvVars ++ [ "GOPROXY" ];
    };

  # Generate vendor/modules.txt content for workspace builds.
  # Format: ## workspace header, workspace module entries, external module entries with package lists.
  mkWorkspaceModulesTxt =
    pwd: goWork: modulesStruct:
    let
      # Bridged producers (Design A, igloo#39) appear as absolute /nix/store
      # `use` targets. They resolve from source and are NOT vendored or listed
      # in modules.txt, so skip them here — only in-tree (relative) `use`
      # targets get a workspace entry. This also avoids `${pwd}/${usePath}`
      # mangling an absolute path into a non-existent readFile.
      inTreeUse = builtins.filter (usePath: !lib.hasPrefix "/" usePath) goWork.use;

      # Parse all (in-tree) workspace modules' go.mod files
      workspaceModules = map (
        usePath:
        let
          moduleGoMod = parseGoMod (readFile "${toString pwd}/${usePath}/go.mod");
        in
        {
          path = usePath;
          modulePath = moduleGoMod.module;
          goVersion = moduleGoMod.go;
          requires = builtins.attrNames (moduleGoMod.require or { });
        }
      ) inTreeUse;

      # Collect all module paths that are required by any workspace module
      allRequired = builtins.concatLists (map (m: m.requires) workspaceModules);

      # Only list workspace modules that are dependencies of other workspace modules
      dependedModules = builtins.filter (m: builtins.elem m.modulePath allRequired) workspaceModules;

      workspaceEntries = map (m: ''
        echo '# ${m.modulePath} v0.0.0 => ${m.path}' >> vendor/modules.txt
        echo '## explicit; go ${m.goVersion}' >> vendor/modules.txt
      '') dependedModules;

      # External module entries: # module version + ## explicit; go X.Y + package list.
      # Every module in any workspace go.mod's require block must get an explicit
      # marker, even if no workspace source imports any of its packages (e.g. indirect
      # deps whose only importers are build-tag-gated, like mousetrap via cobra on linux).
      # Otherwise `go build -mod=vendor` rejects the vendor tree as inconsistent.
      externalEntries = mapAttrsToList (
        name: meta:
        let
          vendorPkgs = meta.vendorPackages or [ ];
          pkgLines = concatStringsSep "\n" (map (p: "echo '${p}' >> vendor/modules.txt") vendorPkgs);
        in
        ''
          echo '# ${name} ${meta.version}' >> vendor/modules.txt
          echo '## explicit; go ${meta.goVersion or "1.21"}' >> vendor/modules.txt
          ${pkgLines}
        ''
      ) (modulesStruct.mod or { });
    in
    [
      ''
        echo '## workspace' > vendor/modules.txt
      ''
    ]
    ++ workspaceEntries
    ++ externalEntries;

  mkVendorEnv =
    {
      go,
      modulesStruct,
      defaultPackage ? "",
      goMod,
      pwd,
      goWork ? null,
    }:
    let
      localReplaceCommands =
        let
          localReplaceAttrs = filterAttrs (n: v: hasAttr "path" v) goMod.replace;
          commands = (
            mapAttrsToList (name: value: (''
              mkdir -p $(dirname vendor/${name})
              ln -s ${
                if lib.hasPrefix "/" value.path then
                  value.path # absolute /nix/store path (from goFlakeInputs)
                else
                  toString (pwd + "/${value.path}") # organic relative path; legacy behavior
              } vendor/${name}
            '')) localReplaceAttrs
          );
        in
        # In workspace mode, workspace module symlinks are not needed in vendor/
        # (Go resolves them from the source tree)
        if goWork != null then
          [ ]
        else if goMod != null then
          commands
        else
          [ ];

      workspaceVendorCommands =
        if goWork != null then mkWorkspaceModulesTxt pwd goWork modulesStruct else [ ];

      sources = mapAttrs (
        goPackagePath: meta:
        fetchGoModule {
          goPackagePath = meta.replaced or goPackagePath;
          inherit (meta) version hash;
          inherit go;
        }
      ) (modulesStruct.mod or { });
    in
    runCommand "vendor-env"
      {
        nativeBuildInputs = [ go ];
        json = toJSON (filterAttrs (n: _: n != defaultPackage) (modulesStruct.mod or { }));

        sources = toJSON (filterAttrs (n: _: n != defaultPackage) sources);

        passthru = {
          inherit sources;
        };

        passAsFile = [
          "json"
          "sources"
        ];
      }
      (''
        mkdir vendor

        export GOCACHE=$TMPDIR/go-cache
        export GOPATH="$TMPDIR/go"

        ${internal.symlink}
        ${concatStringsSep "\n" localReplaceCommands}
        ${concatStringsSep "\n" workspaceVendorCommands}

        mv vendor $out
      '');

  mkGoCacheEnv =
    {
      go,
      modulesStruct,
      goMod,
      vendorEnv,
      depFilesPath,
      isWorkspace ? false,
      # Build environment parameters (should match buildGoApplication)
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      CGO_ENABLED ? go.CGO_ENABLED,
      tags ? [ ],
      ldflags ? [ ],
      allowGoReference ? false,
    }:
    let
      # Check if cachePackages is defined in modulesStruct
      cachePackages = modulesStruct.cachePackages or [ ];
      hasCachePackages = cachePackages != [ ];
    in
    stdenv.mkDerivation {
      name = "go-cache-env";

      dontUnpack = true;

      nativeBuildInputs = [
        rsync
        go
        goConfigHook
        gnutar
        zstd
      ]
      ++ nativeBuildInputs;

      inherit buildInputs;

      inherit (go) GOOS GOARCH;
      inherit CGO_ENABLED;

      # Pass allowGoReference to hook for GOFLAGS configuration
      allowGoReference = if allowGoReference then "1" else "";

      # Pass tags and ldflags (used by hooks)
      inherit tags ldflags;

      goVendorDir = vendorEnv;

      # Change the working directory in prePatch so GoConfigHook sets up
      # vendor/ at the right location
      prePatch =
        if isWorkspace then
          ''
            # Reconstruct workspace structure for cache compilation
            cp -r ${depFilesPath} source
            chmod -R +w source
            cd source
          ''
        else
          ''
            # Create a working directory (Go ignores go.mod in /build)
            mkdir -p source
            cd source

            # Copy go.mod and go.sum from filtered source
            cp ${depFilesPath}/go.mod ./go.mod
            cp ${depFilesPath}/go.sum ./go.sum 2>/dev/null || touch go.sum
          '';

      configurePhase = ''
        # Set up GOCACHE directory (will compress to $out later)
        mkdir -p "$GOCACHE"
      '';

      buildPhase = ''
        runHook preBuild

        ${
          if hasCachePackages then
            ''
              echo "Building ${toString (builtins.length cachePackages)} packages to populate cache..."

              # Generate cache.go that imports all packages
              printf '%s\n' ${lib.escapeShellArgs cachePackages} | ${internal.cachegen} > cache.go

              cat cache.go

              # Build cache.go - Go will build all dependencies using its scheduler
              go build -v -mod=vendor cache.go || true

              echo "Cache population complete"
            ''
          else
            ''
              echo "No cache packages defined, skipping cache population"
            ''
        }

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        echo "Compressing Go build cache..."
        mkdir -p "$out"
        tar -cf - -C "$GOCACHE" . | zstd -T$NIX_BUILD_CORES -o "$out/cache.tar.zst"

        echo "Cache compressed to $out/cache.tar.zst"

        runHook postInstall
      '';
    };

  # Return a Go attribute and error out if the Go version is older than was specified in go.mod.
  selectGo =
    attrs: goMod:
    attrs.go or (
      if goMod == null then
        buildPackages.go
      else
        (
          let
            goVersion = goMod.go;
            goAttrs = lib.reverseList (
              builtins.filter (
                attr:
                lib.hasPrefix "go_" attr
                && (
                  let
                    try = builtins.tryEval buildPackages.${attr};
                  in
                  try.success && try.value ? version
                )
                && lib.versionAtLeast buildPackages.${attr}.version goVersion
              ) (lib.attrNames buildPackages)
            );
            goAttr = elemAt goAttrs 0;
          in
          (
            if goAttrs != [ ] then
              buildPackages.${goAttr}
            else
              throw "go.mod specified Go version ${goVersion}, but no compatible Go attribute could be found."
          )
        )
    );

  # Strip extra data that Go adds to versions, and fall back to a version based on the date if it's a placeholder value.
  # This is data that Nix can't handle in the version attribute.
  stripVersion =
    version:
    let
      parts = elemAt (split "(\\+|-)" (removePrefix "v" version));
      v = parts 0;
      d = parts 2;
    in
    if v != "0.0.0" then
      v
    else
      "unstable-"
      + (concatStringsSep "-" [
        (substring 0 4 d)
        (substring 4 2 d)
        (substring 6 2 d)
      ]);

  mkGoEnv =
    {
      pwd ? null,
      src ? null,
      toolsGo ? null,
      modules ? null,
      goFlakeInputs ? { },
      # "replace" (default) | "workspace" — must match the buildGoApplication
      # call for the same consumer so devshell and build agree (igloo#39).
      goFlakeInputsMode ? "replace",
      allowGoReference ? false,
      ...
    }@attrs:
    let
      effectivePwd = resolvePwd {
        caller = "mkGoEnv";
        inherit pwd src;
      };
      effectiveToolsGo = if toolsGo != null then toolsGo else effectivePwd + "/tools.go";
      effectiveModules = if modules != null then modules else effectivePwd + "/gomod2nix.toml";

      # Pick the Go toolchain off the consumer's organic go.mod (the
      # synthetic require/replace lines from goFlakeInputs don't change
      # the Go version requirement). This matches buildGoApplication's
      # chicken-and-egg handling of selectGo vs. mkMergedGoMod.
      consumerGoModForVersion = parseGoMod (readFile "${toString effectivePwd}/go.mod");
      go = selectGo attrs consumerGoModForVersion;

      # Mirror buildGoApplication's merge: when goFlakeInputs is empty
      # this returns the consumer's organic go.mod and gomod2nix.toml
      # verbatim, preserving the pre-goFlakeInputs behaviour byte-for-byte.
      merged = mkMergedView {
        pwd = effectivePwd;
        modules = effectiveModules;
        inherit
          goFlakeInputs
          goFlakeInputsMode
          go
          runCommand
          parseGoMod
          ;
      };
      inherit (merged) goMod modulesStruct mergedGoModFile mergedGoWork;

      # Workspace-bridge mode (Design A, igloo#39): the synthesized go.work
      # drives the vendor env (localReplaceCommands skipped, modules.txt
      # workspace-shaped). null in replace mode → mkVendorEnv unchanged.
      effectiveGoWork = if mergedGoWork != null then parseGoWork mergedGoWork else null;

      vendorEnv = mkVendorEnv {
        inherit
          go
          goMod
          modulesStruct
          ;
        goWork = effectiveGoWork;
        pwd = effectivePwd;
      };

      goSyncWrapper = writeScript "go" ''
        #!${runtimeShell}
        ${go}/bin/go "$@"
        _exit=$?
        if [ $_exit -eq 0 ]; then
          case "''${1:-} ''${2:-}" in
            "get "* | "mod tidy" | "mod init" | "mod edit" | "work sync")
              echo "[gomod2nix] regenerating gomod2nix.toml..." >&2
              ${gomod2nix}/bin/gomod2nix generate
              ;;
          esac
        fi
        exit $_exit
      '';

    in
    stdenv.mkDerivation (
      removeAttrs attrs [
        "pwd"
        "src"
        "toolsGo"
        "modules"
        "goFlakeInputs"
        "goFlakeInputsMode"
        "allowGoReference"
      ]
      // {
        name = "${baseNameOf goMod.module}-env";

        dontUnpack = true;
        dontConfigure = true;
        dontInstall = true;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        # Pass allowGoReference to hook for GOFLAGS configuration
        allowGoReference = if allowGoReference then "1" else "";

        nativeBuildInputs = [
          rsync
          goConfigHook
        ];

        propagatedBuildInputs = [ go gomod2nix ];

        # Pass vendor directory to the setup hook
        goVendorDir = vendorEnv;

        preferLocalBuild = true;

        buildPhase = ''
          mkdir -p $out/bin

          export GOPATH="$out"

          install -m755 ${goSyncWrapper} $out/bin/go

        ''
        + optionalString (pathExists effectiveToolsGo) ''
          mkdir source
          cp ${
            if mergedGoModFile != null then mergedGoModFile else effectivePwd + "/go.mod"
          } source/go.mod
          cp ${effectivePwd + "/go.sum"} source/go.sum
          cp ${effectiveToolsGo} source/tools.go
          ${optionalString (mergedGoWork != null)
            "cp ${writeText "merged-go.work" mergedGoWork} source/go.work"
          }
          cd source

          rsync -a -K --ignore-errors ${vendorEnv}/ vendor

          ${internal.install}
        '';

        # Devshell parity with buildGoApplication: surface the merged
        # go.mod (replace mode) or go.work (workspace mode) so flake
        # consumers can wire it into the user's working tree (e.g. via a
        # shellHook that copies it on entry). The vendor tree already
        # reflects the merged module graph above. mkGoEnv intentionally does
        # NOT mutate the user's working directory.
        passthru =
          (attrs.passthru or { })
          // {
            inherit vendorEnv;
          }
          // optionalAttrs (mergedGoModFile != null) {
            mergedGoMod = mergedGoModFile;
          }
          // optionalAttrs (mergedGoWork != null) {
            # Workspace mode (igloo#39): consumers materialize this as go.work
            # in their tree (shellHook `cp`) so gopls/go resolve the bridge.
            mergedGoWork = writeText "merged-go.work" mergedGoWork;
          };
      }
    );

  buildGoApplication =
    {
      modules ? null,
      src ? null,
      pwd ? null,
      goFlakeInputs ? { },
      # "replace" (default) — require+replace+sentinel merged go.mod.
      # "workspace" — Design A go.work overlay, sentinel-free (igloo#39).
      goFlakeInputsMode ? "replace",
      nativeBuildInputs ? [ ],
      allowGoReference ? false,
      meta ? { },
      passthru ? { },
      tags ? [ ],
      ldflags ? [ ],
      ldflagsX ? { },
      overwriteLdflagsX ? false,
      commit ?
        if src != null && src ? rev then
          src.rev
        else if src != null && src ? shortRev then
          src.shortRev
        else
          "unknown",
      disableGoCache ? false,

      ...
    }@attrs:
    let
      effectivePwd = resolvePwd {
        caller = "buildGoApplication";
        inherit pwd src;
      };
      effectiveSrc = if src != null then src else effectivePwd;
      effectiveModules = if modules != null then modules else effectivePwd + "/gomod2nix.toml";

      # Detect workspace: check for go.work at pwd
      goWorkPath = "${toString effectivePwd}/go.work";
      hasWorkspace = pathExists goWorkPath;
      goWork = if hasWorkspace then parseGoWork (readFile goWorkPath) else null;

      # Parse the consumer's organic go.mod (no goFlakeInputs synthesis yet).
      # We need this first to select Go (chicken-and-egg: mkMergedGoMod needs go).
      goModPath = "${toString effectivePwd}/go.mod";
      consumerGoMod =
        if pathExists goModPath then parseGoMod (readFile goModPath) else null;

      # For Go version selection, prefer consumer go.mod, fall back to go.work.
      # Synthetic require/replace lines from goFlakeInputs don't change the Go
      # version requirement, so we use the consumer's organic go.mod here.
      goModForVersion =
        if consumerGoMod != null then
          consumerGoMod
        else if goWork != null then
          {
            go = goWork.go;
            module = "workspace";
          }
        else
          null;

      go = selectGo attrs goModForVersion;

      # Compute the merged view (consumer + goFlakeInputs). Returns the
      # consumer's data verbatim when goFlakeInputs is empty.
      merged = mkMergedView {
        pwd = effectivePwd;
        modules = effectiveModules;
        inherit
          goFlakeInputs
          goFlakeInputsMode
          go
          runCommand
          parseGoMod
          ;
      };
      inherit (merged) goMod modulesStruct mergedGoModFile mergedGoWork;

      # Design A (igloo#39): in workspace-bridge mode the synthesized go.work
      # overlay supersedes any pathExists-detected consumer go.work. The
      # cache derivation reconstructs an in-tree `source/`, which can't yet
      # carry out-of-tree (store-path) `use` targets, so the cache is disabled
      # for bridge builds — a documented follow-up, not a correctness gap.
      effectiveGoWork = if mergedGoWork != null then parseGoWork mergedGoWork else goWork;
      effectiveDisableGoCache = disableGoCache || mergedGoWork != null;

      defaultPackage = modulesStruct.goPackagePath or "";

      vendorEnv =
        if modulesStruct != { } then
          mkVendorEnv {
            inherit
              defaultPackage
              go
              modulesStruct
              ;
            goWork = effectiveGoWork;
            pwd = effectivePwd;
            goMod = if goMod != null then goMod else { replace = { }; };
          }
        else
          null;

      # Filter source to only dependency files for cache derivation
      # Use fetched source when building from goPackagePath
      # When pwd is set but doesn't contain go.mod (goMod == null), use src instead
      depFilesSrc =
        if defaultPackage != "" then
          vendorEnv.passthru.sources.${defaultPackage}
        else if goMod != null then
          effectivePwd
        else
          effectiveSrc;

      depFilesPath =
        if (!effectiveDisableGoCache && modulesStruct != { } && depFilesSrc != null) then
          if hasWorkspace then
            # For workspaces, include go.work and all module go.mod/go.sum files
            lib.cleanSourceWith {
              src = effectivePwd;
              filter =
                path: type:
                let
                  baseName = baseNameOf path;
                  relPath = removePrefix ((toString effectivePwd) + "/") (toString path);
                in
                baseName == "go.work"
                || baseName == "go.mod"
                || baseName == "go.sum"
                || baseName == "gomod2nix.toml"
                # Allow intermediate directories for workspace modules
                || (
                  type == "directory"
                  && builtins.any (
                    u:
                    let
                      cleanU = removePrefix "./" u;
                    in
                    lib.hasPrefix relPath cleanU || lib.hasPrefix cleanU relPath
                  ) goWork.use
                );
              name = "go-workspace-dep-files";
            }
          else
            lib.cleanSourceWith {
              src = depFilesSrc;
              filter =
                path: type:
                let
                  baseName = baseNameOf path;
                in
                baseName == "go.mod" || baseName == "go.sum" || baseName == "gomod2nix.toml";
              name = "go-dep-files";
            }
        else
          null;

      cacheEnv =
        if (!effectiveDisableGoCache && modulesStruct != { } && depFilesPath != null) then
          mkGoCacheEnv {
            inherit
              go
              modulesStruct
              vendorEnv
              depFilesPath
              tags
              ldflags
              allowGoReference
              ;
            isWorkspace = hasWorkspace;
            CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
            goMod = if goMod != null then goMod else { replace = { }; };
          }
        else
          null;

      pname = attrs.pname or baseNameOf defaultPackage;

      # version.env auto-read (eng-versioning(7) § VERSION EMBEDDING,
      # amarbel-llc/nixpkgs#31). When the build's module dir carries a
      # `version.env` declaring `export <PACKAGE>_VERSION=<sem>`, read it
      # at eval time and treat it as the version source of truth. This
      # frees consumers from repeating the readFile/match boilerplate in
      # their flake — having the file is sufficient. `export` is optional
      # (the leading `.*` absorbs it); the value is captured as a single
      # whitespace-delimited token. Polyglot repos keep one version.env
      # per package dir, so reading at `effectivePwd` (the go.mod dir)
      # picks up the package-local file. Returns null when the file is
      # absent or carries no `*_VERSION=` line, so resolution falls
      # through cleanly.
      versionEnvPath = "${toString effectivePwd}/version.env";
      versionFromEnv =
        if pathExists versionEnvPath then
          let
            m = builtins.match ".*_VERSION=([^[:space:]]+).*" (readFile versionEnvPath);
          in
          if m != null then elemAt m 0 else null
        else
          null;

      # Resolution order: an explicitly passed `version` wins (backward
      # compatible — explicit beats implicit), then version.env, then the
      # gomod2nix.toml module version, then "dev".
      effectiveVersion =
        if attrs ? version then
          attrs.version
        else if versionFromEnv != null then
          versionFromEnv
        else if defaultPackage != "" then
          stripVersion (modulesStruct.mod.${defaultPackage}).version
        else
          "dev";

      versionLdflags = [
        "-X main.version=${effectiveVersion}"
        "-X main.commit=${commit}"
      ];

      # Symbol name (importpath.name) from a single `-X SYM=VAL` (or
      # `-X=SYM=VAL`) ldflag entry; null for non-`-X` flags (-s, -w,
      # -extldflags, …). Handles the one-`-X`-per-list-element convention
      # nixpkgs uses; an exotic element packing multiple `-X` into one string
      # only reports its first symbol (fail-open — the common case is covered).
      ldflagXSymbol =
        entry:
        let
          m = builtins.match "-X[ =]([^=]+)=.*" entry;
        in
        if m != null then elemAt m 0 else null;

      claimedXSymbols = builtins.filter (s: s != null) (
        map ldflagXSymbol (versionLdflags ++ ldflags)
      );

      ldflagsXCollisions = builtins.filter (k: builtins.elem k claimedXSymbols) (
        builtins.attrNames ldflagsX
      );

      ldflagsXFlags =
        if ldflagsXCollisions != [ ] && !overwriteLdflagsX then
          throw ''
            buildGoApplication: ldflagsX would overwrite -X symbol(s) already set
            by the auto-injected version/commit ldflags or the `ldflags` list:

              ${concatStringsSep ", " ldflagsXCollisions}

            Pass `overwriteLdflagsX = true` to let ldflagsX win (its flags are
            appended last, so Go's linker uses them), or drop the colliding key(s).
          ''
        else
          mapAttrsToList (name: value: "-X ${name}=${value}") ldflagsX;

      # Only used by the final build. Passing these to mkGoCacheEnv would
      # invalidate the cache hash on every commit without changing contents.
      effectiveLdflags = versionLdflags ++ ldflags ++ ldflagsXFlags;

    in
    stdenv.mkDerivation (
      optionalAttrs (defaultPackage != "") {
        inherit pname;
        version = stripVersion (modulesStruct.mod.${defaultPackage}).version;
        src = vendorEnv.passthru.sources.${defaultPackage};
      }
      // optionalAttrs (hasAttr "subPackages" modulesStruct) {
        subPackages = modulesStruct.subPackages;
      }
      // (removeAttrs attrs [
        "goFlakeInputs"
        "goFlakeInputsMode"
        "ldflagsX"
        "overwriteLdflagsX"
      ])
      // optionalAttrs (!(attrs ? version) && versionFromEnv != null) {
        # Keep the derivation `version` attr in lockstep with the
        # `-X main.version` ldflag when version.env is the source. Placed
        # after the attrs spread so it overrides the gomod2nix-derived
        # default, but guarded on `!(attrs ? version)` so an explicit
        # caller version still wins.
        version = versionFromEnv;
      }
      // {
        nativeBuildInputs = [
          go
          goConfigHook
          goBuildHook
          goCheckHook
          goInstallHook
        ]
        ++ nativeBuildInputs;

        inherit (go) GOOS GOARCH;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        # Pass allowGoReference to hook for GOFLAGS configuration
        allowGoReference = if allowGoReference then "1" else "";

        goVendorDir = if vendorEnv != null then vendorEnv else "";
        goCacheDir = if cacheEnv != null then cacheEnv else "";
        inherit tags;
        ldflags = effectiveLdflags;
        modRoot = attrs.modRoot or "";

        # When goFlakeInputs is non-empty, swap the source's organic go.mod
        # for the merged one (with synthetic require/replace lines pointing
        # at /nix/store paths). postPatch runs after unpack/patch and before
        # configurePhase/goConfigHook, naturally expressing a source-tree
        # modification and avoiding preBuild-concatenation surface for
        # buildGoRace / buildGoCover wrappers.
        postPatch =
          optionalString (mergedGoModFile != null) ''
            cp --no-preserve=mode ${mergedGoModFile} go.mod
          ''
          # Workspace mode (Design A, igloo#39): drop in the synthesized
          # go.work overlay instead of editing go.mod. Materializing it here
          # (before goConfigHook in postPatchHooks) puts go.work alongside the
          # consumer go.mod at the build root, so the rsynced vendor/ + the
          # hook's `-mod=vendor` build run in workspace mode. The producer
          # store paths the go.work references are pulled into the build
          # closure via writeText's string context.
          + optionalString (mergedGoWork != null) ''
            cp --no-preserve=mode ${writeText "merged-go.work" mergedGoWork} go.work
          ''
          + (attrs.postPatch or "");

        doCheck = attrs.doCheck or true;

        strictDeps = true;

        disallowedReferences = optional (!allowGoReference) go;

        passthru = {
          inherit go vendorEnv hooks;
          goCacheEnv = cacheEnv;
        }
        // optionalAttrs (mergedGoModFile != null) {
          # Exposed for debugging goFlakeInputs builds. Read with
          # `nix build .#foo.passthru.mergedGoMod && cat result`.
          mergedGoMod = mergedGoModFile;
        }
        // optionalAttrs (hasAttr "goPackagePath" modulesStruct) {

          updateScript =
            let
              generatorArgs =
                if hasAttr "subPackages" modulesStruct then
                  concatStringsSep " " (
                    map (subPackage: modulesStruct.goPackagePath + "/" + subPackage) modulesStruct.subPackages
                  )
                else
                  modulesStruct.goPackagePath;

            in
            writeScript "${pname}-updater" ''
              #!${runtimeShell}
              cd ${toString effectivePwd}
              exec ${gomod2nix}/bin/gomod2nix generate ${generatorArgs}
            '';

        }
        // passthru;

        inherit meta;
      }
    );

  # Race-instrumented variant of an existing buildGoApplication-derived
  # derivation. Sets CGO_ENABLED, appends `-race` to buildFlagsArray (so
  # the `go install` that produces $out/bin/* picks it up), and overrides
  # checkPhase to also pass `-race` to `go test`. The caller's existing
  # checkPhase tags / -p handling are preserved by passing them in via
  # the `tags` arg — propagation from `old.tags` is unreliable when the
  # base derivation inlines tags directly into its checkPhase.
  buildGoRace =
    {
      base,
      tags ? [ ],
      pnameSuffix ? "-race",
    }:
    base.overrideAttrs (old: {
      pname = "${old.pname}${pnameSuffix}";
      CGO_ENABLED = 1;
      # buildFlagsArray must be set as a true bash array via preBuild,
      # not as a nix list attr — see buildGoCover.preBuild for details.
      preBuild = (old.preBuild or "") + ''
        buildFlagsArray+=("-race")
      '';
      checkPhase = ''
        runHook preCheck
        go test ${
          if tags == [ ] then "" else "-tags ${concatStringsSep "," tags}"
        } -race -p $NIX_BUILD_CORES ./...
        runHook postCheck
      '';
    });

  # Coverage-instrumented variant of an existing buildGoApplication-derived
  # derivation. Builds the binary with `go build -cover -covermode=atomic`,
  # then runs `coverIntegrationCommand` (a phase fragment supplied by the
  # caller) under a fresh $GOCOVERDIR. After the integration command, the
  # helper:
  #   - copies the binary covdata fragments to $out/covdata/  (mergeable)
  #   - converts them to textfmt at $out/coverage.out         (inspectable)
  #
  # The caller's `coverIntegrationCommand` runs against
  # `$out/bin/<binary>` with $GOCOVERDIR already exported. It is
  # responsible for whatever test plumbing it needs (binary-path env
  # vars, staging files, etc.).
  #
  # `extraNativeInstallCheckInputs` is a separate arg because adding
  # them via `nativeInstallCheckInputs = old.nativeInstallCheckInputs
  # ++ [...]` inside `overrideAttrs` doesn't always propagate them onto
  # PATH at install-check time when the base derivation merges
  # installCheck attrs from another attrset.
  buildGoCover =
    {
      base,
      coverIntegrationCommand,
      pnameSuffix ? "-cli-cover",
      extraNativeInstallCheckInputs ? [ ],
    }:
    base.overrideAttrs (old: {
      pname = "${old.pname}${pnameSuffix}";

      # buildFlagsArray must be set as a true bash array, not via a
      # nix list attr — stdenv serializes list attrs to the env as
      # space-joined strings, which goBuildHook's `declare -p` treats
      # as a single argv entry. That breaks for multi-flag values like
      # `-cover -covermode=atomic`. Setting it in preBuild puts it in
      # the bash environment as an actual array, which `declare -p`
      # round-trips correctly.
      preBuild = (old.preBuild or "") + ''
        buildFlagsArray+=("-cover" "-covermode=atomic")
      '';

      # If the base derivation invokes the instrumented binary during
      # postInstall, the cover runtime emits "GOCOVERDIR not set, no
      # coverage data emitted" to stderr. Coverage data from a
      # postInstall run isn't useful here (the real capture happens in
      # installCheckPhase), so route fragments to a discardable scratch
      # dir before running the existing postInstall.
      postInstall = ''
        export GOCOVERDIR="$(mktemp -d)"
      ''
      + (old.postInstall or "");

      doInstallCheck = true;
      nativeInstallCheckInputs =
        (old.nativeInstallCheckInputs or [ ]) ++ extraNativeInstallCheckInputs;
      installCheckPhase = ''
        runHook preInstallCheck

        gocover_data="$(mktemp -d)"
        export GOCOVERDIR="$gocover_data"

        ${coverIntegrationCommand}

        mkdir -p $out/covdata $out
        cp -r "$gocover_data"/* $out/covdata/
        go tool covdata textfmt -i="$gocover_data" -o="$out/coverage.out"

        runHook postInstallCheck
      '';
    });

in
{
  inherit
    buildGoApplication
    buildGoRace
    buildGoCover
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    goSourceFilter
    goSourceFilterMiddleware
    mkGoPkgs
    hooks
    ;
}
