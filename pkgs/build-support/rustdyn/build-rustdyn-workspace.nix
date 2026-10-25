# buildRustdynWorkspace — one content-addressed derivation per crate of a Cargo
# workspace, wired by store paths the way godyn wires importcfg, from a graph
# `cargo metadata --offline --locked` derives at eval time (FDR 0009, decisions
# a/b/e). nixpkgs' buildRustCrate is the per-crate rustc driver; this file only
# maps the metadata onto it and layers the fleet's conventions on top: version
# through build-script env, per-harness test runs, a clippy lane that re-lints
# only the edited cone, and an install derivation that never relinks.
{
  lib,
  stdenv,
  runCommand,
  runCommandLocal,
  buildRustCrate,
  rustPlatform,
  rustc,
  cargo,
  clippy,
}:
let
  defaultRustc = rustc;
  defaultCargo = cargo;
  defaultClippy = clippy;
in
{
  pname,
  # The repository root (a flake input or a path). The workspace's Cargo.toml and
  # Cargo.lock live at `src`, or under `workspaceDir` when the Rust tree is a
  # subdirectory (tap's `rust/`, hyphence's `rust/`).
  src,
  workspaceDir ? "",
  # Version embedding (godyn's rule): an explicit `version` wins; else a
  # `version.env` in the workspace dir (declaring <PKG>_VERSION) is auto-read;
  # else "dev". `commit` from the flake input's rev unless overridden. Both reach
  # every workspace member's build (and its build script) as RUSTDYN_VERSION /
  # RUSTDYN_COMMIT and <PNAME>_VERSION / <PNAME>_COMMIT; `memberEnv` adds any
  # consumer-specific names (posh reads POSH_GIT_SHA).
  version ? null,
  commit ? (if lib.isAttrs src then (src.rev or src.shortRev or "unknown") else "unknown"),
  memberEnv ? { },
  # The lock: Cargo.lock at the workspace root unless given. Git dependencies
  # need `outputHashes` or `allowBuiltinFetchGit`, as for buildRustPackage.
  cargoLock ? null,
  outputHashes ? { },
  allowBuiltinFetchGit ? false,
  # The toolchain (decision d): igloo's nixpkgs rustc/cargo/clippy unless the
  # consumer pins its own (rust-overlay users pass theirs).
  rustc ? defaultRustc,
  cargo ? defaultCargo,
  clippy ? defaultClippy,
  # buildRustCrate knobs applied to every crate: a per-crate native-input table
  # (null keeps buildRustCrate's own, nixpkgs' defaultCrateOverrides: openssl-sys,
  # libgit2-sys, ...), cargo's release-profile codegen units (buildRustCrate's
  # own default of 1 is far slower), release vs debug, extra rustc flags.
  crateOverrides ? null,
  codegenUnits ? 16,
  release ? true,
  extraRustcOpts ? [ ],
  # Native inputs for the workspace members' compiles (not their dependencies —
  # those come from crateOverrides).
  buildInputs ? [ ],
  # Which member binaries the install derivation gathers (null = every bin
  # target of every member) and how to rename them.
  bins ? null,
  binaryNames ? { },
  # The install step: runs over the gathered binaries in its own derivation
  # with these native inputs, then stdenv's fixup — editing it never relinks.
  nativeBuildInputs ? [ ],
  postInstall ? "",
  # Tests (decision h): per member, one derivation building the lib harness,
  # each tests/*.rs harness and the member's bins (for CARGO_BIN_EXE_*), then
  # one CA run derivation per harness; `tests = true` makes the package depend
  # on checkAll (every run). testEnv is exported to the runs; nativeCheckInputs
  # are on their PATH.
  tests ? false,
  testEnv ? { },
  nativeCheckInputs ? [ ],
  # Lint: clippy-driver in rustc's place for the members (dependencies stay the
  # normal rlibs). `cargo clippy -- -D warnings` parity by default.
  clippyArgs ? [
    "-D"
    "warnings"
  ],
  meta ? { },
}:
let
  # A path literal stays a path and a flake input (a store-path string with
  # context) stays a string: both keep the "copy / depend on this" semantics an
  # interpolation needs. `toString` would drop that, and importCargoLock's
  # `ln -s ${lockFile}` would then dangle inside the sandbox (V: the brp twin
  # failed in cargoSetupPostUnpackHook when this was a toString).
  joinPath =
    base: sub:
    if sub == "" then
      base
    else if builtins.isPath base then
      base + "/${sub}"
    else
      "${base}/${sub}";
  srcRoot = joinPath src workspaceDir;
  lockFile = if cargoLock != null then cargoLock else joinPath srcRoot "Cargo.lock";

  # version.env auto-read, godyn's rule (build-godyn-module.nix).
  versionEnvPath = joinPath srcRoot "version.env";
  versionFromEnv =
    if builtins.pathExists versionEnvPath then
      let
        m = builtins.match ".*_VERSION=([^[:space:]]+).*" (builtins.readFile versionEnvPath);
      in
      if m != null then builtins.elemAt m 0 else null
    else
      null;
  resolvedVersion =
    if version != null then
      version
    else if versionFromEnv != null then
      versionFromEnv
    else
      "dev";
  pnameUpper = lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] pname);
  # The environment every member build (and its build script) sees; also what
  # buildRustAuto hands to the buildRustPackage backend.
  memberEnvAll = {
    RUSTDYN_VERSION = resolvedVersion;
    RUSTDYN_COMMIT = commit;
    "${pnameUpper}_VERSION" = resolvedVersion;
    "${pnameUpper}_COMMIT" = commit;
  }
  // memberEnv;

  caAttrs = {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };

  # Registry and git crates from the lock, one fixed-output fetch per crate, as
  # buildRustPackage assembles them.
  vendorDir = rustPlatform.importCargoLock {
    inherit lockFile outputHashes allowBuiltinFetchGit;
  };

  # What cargo metadata reads: manifests, the lock, cargo config and the Rust
  # source names that drive target discovery. Everything else (docs, data,
  # build output, the git dir) stays out, so a README edit does not re-run the
  # eval-time resolver. Member compiles depend only on their own directory.
  tree = builtins.path {
    path = srcRoot;
    name = "${pname}-cargo-tree";
    filter =
      path: type:
      let
        b = baseNameOf path;
      in
      if type == "directory" then
        b != "target" && b != ".git"
      else
        lib.elem b [
          "Cargo.toml"
          "Cargo.lock"
          "config.toml"
        ]
        || lib.hasSuffix ".rs" b;
  };

  # The resolver (godyn-gen's analog): cargo metadata, offline and locked, in
  # the vendored tree. Its JSON is imported at eval time (IFD, FDR 0008 §
  # Decision); passthru.graphFile hands the same JSON to dagnabit.
  graphDrv = runCommand "${pname}-rustdyn-graph" { nativeBuildInputs = [ cargo ]; } ''
    cp -r ${tree} source
    chmod -R u+w source
    # cargo finds .cargo/config.toml by walking up from the manifest; the
    # vendor config names the directory "cargo-vendor-dir" beside .cargo.
    ln -s ${vendorDir} cargo-vendor-dir
    mkdir .cargo
    cp ${vendorDir}/.cargo/config.toml .cargo/config.toml
    export HOME=$PWD CARGO_HOME=$PWD/cargo-home
    mkdir -p $out
    (cd source && cargo metadata --format-version 1 --offline --locked) > $out/metadata.json
  '';
  readJSON = f: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile f));
  graph = readJSON "${graphDrv}/metadata.json";
  wsRoot = graph.workspace_root;

  nodeById = lib.listToAttrs (map (n: lib.nameValuePair n.id n) graph.resolve.nodes);
  memberIds = lib.genAttrs graph.workspace_members (_: true);
  manifestDir = p: dirOf p.manifest_path;
  relTo = p: path: lib.removePrefix (manifestDir p + "/") path;

  libKinds = [
    "lib"
    "rlib"
    "dylib"
    "cdylib"
    "staticlib"
    "proc-macro"
  ];
  # Everything the per-crate derivations need from one package, computed once.
  describe =
    p:
    let
      lt = lib.findFirst (t: lib.any (k: lib.elem k libKinds) t.kind) null p.targets;
      bt = lib.findFirst (t: t.kind == [ "custom-build" ]) null p.targets;
      node = nodeById.${p.id};
      depsOfKind = kind: lib.filter (d: lib.any (k: k.kind == kind) d.dep_kinds) node.deps;
    in
    {
      pkg = p;
      inherit (p) name version;
      member = memberIds ? ${p.id};
      # The member's directory relative to the workspace root ("" for a root package).
      dir = if manifestDir p == wsRoot then "" else lib.removePrefix (wsRoot + "/") (manifestDir p);
      inherit lt bt;
      # The name rustc sees in --extern: the lib target's name (cargo already
      # underscores it), else the package name underscored.
      extern = lib.replaceStrings [ "-" ] [ "_" ] (if lt == null then p.name else lt.name);
      procMacro = lt != null && lib.elem "proc-macro" lt.kind;
      bins = lib.filter (t: t.kind == [ "bin" ]) p.targets;
      testTargets = lib.filter (t: t.kind == [ "test" ]) p.targets;
      inherit (node) features;
      # Resolve-graph edges by kind: null is a normal dependency, "build" a
      # build-script dependency, "dev" a test-only one. A dependency's target
      # cfg() is not evaluated (every edge is included; FDR 0009 § 1).
      normalDeps = depsOfKind null;
      buildDeps = depsOfKind "build";
      devDeps = depsOfKind "dev";
    };
  byId = lib.listToAttrs (map (p: lib.nameValuePair p.id (describe p)) graph.packages);
  members = lib.filter (c: c.member) (lib.attrValues byId);
  byMember = lib.listToAttrs (map (c: lib.nameValuePair c.name c) members);

  # Source per crate. A member is a filtered copy of its own directory under
  # src (hashed once per member, shared by its compile, test and lint variants),
  # so only that crate's edits reach its derivation. A vendored crate is a
  # small content-addressed copy of the vendor dir's <name>-<version> entry: a
  # lock change changes this copy derivation but not its output, so the compile
  # derivation resolves to the same inputs and keeps its realisation (and two
  # repos with the same crate converge on the same compile).
  memberSrcs = lib.mapAttrs (
    _: c:
    builtins.path {
      path = joinPath srcRoot c.dir;
      name = "${pname}-src-${c.name}";
      filter = path: _: baseNameOf path != "target";
    }
  ) byMember;
  vendoredSrc =
    c:
    runCommand "rustdyn-src-${c.name}-${c.version}" (caAttrs // { preferLocalBuild = true; }) ''
      cp -rL --no-preserve=mode ${vendorDir}/${c.name}-${c.version} $out
    '';
  srcOf = c: if c.member then memberSrcs.${c.name} else vendoredSrc c;

  renamesOf =
    deps:
    lib.listToAttrs (
      lib.concatMap (
        d:
        let
          dc = byId.${d.pkg};
        in
        lib.optional (d.name != dc.extern) (lib.nameValuePair dc.name d.name)
      ) deps
    );

  # The buildRustCrate attribute set for one crate (its coarsest unit: lib,
  # bins and build script in one derivation). `kind` names the derivation
  # (crate | testbin | lint); `withDev` adds the dev dependencies for tests.
  mkCrate =
    kind: withDev: c:
    let
      normal = c.normalDeps ++ lib.optionals withDev c.devDeps;
    in
    {
      name = "rustdyn-${kind}-${c.name}-${c.version}";
      crateName = c.name;
      inherit (c.pkg) version edition;
      rust = rustc;
      inherit cargo release codegenUnits;
      src = srcOf c;
      libName = c.extern;
      inherit (c) features procMacro;
      # Only workspace members link binaries; a dependency's bins are noise.
      crateBin =
        if c.member then
          map (t: {
            inherit (t) name;
            path = relTo c.pkg t.src_path;
          }) c.bins
        else
          [ ];
      build = if c.bt != null then relTo c.pkg c.bt.src_path else "";
      dependencies = map (d: crates.${d.pkg}) normal;
      buildDependencies = map (d: crates.${d.pkg}) c.buildDeps;
      crateRenames = renamesOf (normal ++ c.buildDeps);
      inherit extraRustcOpts;
    }
    // caAttrs
    // lib.optionalAttrs (c.lt != null) {
      libPath = relTo c.pkg c.lt.src_path;
      type = c.lt.crate_types;
    }
    // lib.optionalAttrs (c.pkg.links != null) { inherit (c.pkg) links; }
    // lib.optionalAttrs c.member ({ inherit buildInputs; } // memberEnvAll);

  mkCrateDrv =
    attrs:
    if crateOverrides == null then
      buildRustCrate attrs
    else
      (buildRustCrate attrs).override { inherit crateOverrides; };
  forMembers = f: lib.mapAttrs (_: f) byMember;

  crates = lib.mapAttrs (_: c: mkCrateDrv (mkCrate "crate" false c)) byId;
  memberCrates = forMembers (c: crates.${c.pkg.id});

  # -- tests --
  # One derivation per member builds every harness (lib tests, tests/*.rs, the
  # bins' own unit tests) plus the real bins for CARGO_BIN_EXE_<name>, which
  # buildRustCrate bakes into the harnesses at compile time.
  testBins = forMembers (c: mkCrateDrv (mkCrate "testbin" true c // { buildTests = true; }));
  # The harness binaries buildRustCrate installs under $out/tests, by name:
  # the lib harness is <libname>-<metadata>, a tests/<t>.rs harness is <t>,
  # a bin's unit-test harness is the bin's name.
  harnessesOf =
    c:
    lib.optional (c.lt != null) "${c.extern}-${testBins.${c.name}.metadata}"
    ++ map (t: t.name) (c.testTargets ++ c.bins);
  # A run: the harness executed from a writable copy of the member's source
  # (cargo runs tests with the package root as cwd and CARGO_MANIFEST_DIR set);
  # pass/fail is the build result, the log is the output. Content-addressed, so
  # an unchanged test cone never re-runs; flags make a different run.
  mkRun =
    c: harness: flags:
    runCommand "rustdyn-test-${c.name}-${harness}"
      (
        caAttrs
        // {
          nativeBuildInputs = nativeCheckInputs;
          passthru.harness = harness;
        }
        // testEnv
      )
      ''
        cp -r ${memberSrcs.${c.name}} src
        chmod -R u+w src
        cd src
        export CARGO_MANIFEST_DIR=$PWD
        set -o pipefail
        ${testBins.${c.name}}/tests/${harness} ${lib.escapeShellArgs flags} 2>&1 | tee "$NIX_BUILD_TOP/log"
        mkdir -p $out
        cp "$NIX_BUILD_TOP/log" $out/log
        echo "ok ${c.name}/${harness}" > $out/result
      '';
  testRuns = forMembers (c: lib.genAttrs (harnessesOf c) (h: mkRun c h [ ]));
  allRuns = lib.concatMap lib.attrValues (lib.attrValues testRuns);
  checkAll = runCommandLocal "${pname}-rustdyn-check-all" { } ''
    cat ${lib.concatMapStringsSep " " (r: "${r}/result") allRuns} > $out
  '';
  testWith =
    {
      crate,
      harness ? null,
      testFlags ? [ ],
    }:
    let
      c = byMember.${crate} or (throw "rustdyn: ${crate} is not a workspace member of ${pname}");
      hs = if harness != null then [ harness ] else harnessesOf c;
    in
    runCommandLocal "${pname}-rustdyn-test-with-${crate}" { } ''
      cat ${lib.concatMapStringsSep " " (h: "${mkRun c h testFlags}/result") hs} > $out
    '';

  # -- lint --
  # clippy-driver standing in for rustc: a drop-in that accepts rustc's command
  # line and registers clippy's lints. The shim resolves the sysroot from the
  # real rustc so clippy-driver does not call back into itself through PATH.
  clippyShim = runCommandLocal "rustc-clippy-${rustc.version or "unknown"}" { } ''
    mkdir -p $out/bin
    cat > $out/bin/rustc <<EOF
    #!${stdenv.shell}
    export SYSROOT="\''${SYSROOT:-\$(${rustc}/bin/rustc --print sysroot)}"
    exec ${clippy}/bin/clippy-driver "\$@"
    EOF
    chmod +x $out/bin/rustc
    ln -s ${rustc}/bin/rustdoc $out/bin/rustdoc
  '';
  # buildRustCrate caps lints at `allow` unless told otherwise; `forbid` leaves
  # them at their declared levels so -D warnings fails the build.
  lint = forMembers (
    c:
    mkCrateDrv (
      mkCrate "lint" false c
      // {
        rust = clippyShim;
        capLints = "forbid";
        extraRustcOpts = extraRustcOpts ++ clippyArgs;
      }
    )
  );
  lintAll = runCommandLocal "${pname}-rustdyn-lint-all" { lints = lib.attrValues lint; } ''
    ${lib.concatMapStringsSep "\n" (c: "echo 'ok ${c.name}' >> $out") members}
  '';

  # -- install --
  memberBins = lib.concatMap (
    c:
    map (t: {
      inherit (t) name;
      crate = crates.${c.pkg.id};
    }) c.bins
  ) members;
  installedBins =
    if bins == null then memberBins else lib.filter (b: lib.elem b.name bins) memberBins;
in
stdenv.mkDerivation (
  {
    inherit pname;
    version = resolvedVersion;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    inherit nativeBuildInputs postInstall;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      ${lib.concatMapStringsSep "\n" (
        b: "cp ${b.crate}/bin/${b.name} $out/bin/${binaryNames.${b.name} or b.name}"
      ) installedBins}
      runHook postInstall
    '';
    passthru = {
      backend = "rustdyn";
      version = resolvedVersion;
      inherit
        commit
        lockFile
        graph
        vendorDir
        testBins
        checkAll
        testWith
        lint
        lintAll
        ;
      env = memberEnvAll;
      graphFile = "${graphDrv}/metadata.json";
      # Per-member derivations and every crate by package id (for a lint lane or
      # dagnabit to hang off the same store paths).
      crates = memberCrates;
      allCrates = crates;
      members = map (c: c.name) members;
      memberDirs = forMembers (c: c.dir);
      tests = testRuns;
    };
    meta = {
      mainProgram = pname;
    }
    // meta;
  }
  # `tests = true`: the runs are declared inputs of the install derivation, so a
  # failing test fails the package.
  // lib.optionalAttrs tests { rustdynCheckAll = checkAll; }
)
