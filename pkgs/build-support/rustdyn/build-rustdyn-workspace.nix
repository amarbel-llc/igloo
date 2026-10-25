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
  jq,
  defaultCrateOverrides,
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
  # buildRustCrate knobs applied to every crate: nixpkgs' per-crate native-input
  # table (openssl-sys, libgit2-sys, ...), cargo's release-profile codegen units
  # (buildRustCrate's own default of 1 is far slower), release vs debug, extra
  # rustc flags.
  crateOverrides ? defaultCrateOverrides,
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
  # one CA run derivation per harness; `tests = true` makes checkAll realise
  # every run. testEnv is exported to the runs; nativeCheckInputs are on their
  # PATH.
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

  # The Cargo-relevant tree: everything under the workspace dir except build
  # output and the git dir. The resolver depends on all of it (any edit re-runs
  # cargo metadata, sub-second); member compiles depend only on their own dir.
  tree = builtins.path {
    path = srcRoot;
    name = "${pname}-cargo-tree";
    filter =
      path: _type:
      let
        b = baseNameOf path;
      in
      b != "target" && b != ".git";
  };

  # The resolver (godyn-gen's analog): cargo metadata, offline and locked, in
  # the vendored tree. Its JSON is imported at eval time (IFD, FDR 0008 §
  # Decision); passthru.graphFile hands the same JSON to dagnabit.
  graphDrv =
    runCommand "${pname}-rustdyn-graph"
      {
        nativeBuildInputs = [
          cargo
          jq
        ];
      }
      ''
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
        jq '{ packages: (.packages | length), members: (.workspace_members | length), nodes: (.resolve.nodes | length) }' \
          $out/metadata.json > $out/summary.json
      '';
  readJSON = f: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile f));
  graph = readJSON "${graphDrv}/metadata.json";
  wsRoot = graph.workspace_root;

  byId = lib.listToAttrs (map (p: lib.nameValuePair p.id p) graph.packages);
  nodeById = lib.listToAttrs (map (n: lib.nameValuePair n.id n) graph.resolve.nodes);
  isMember = p: lib.elem p.id graph.workspace_members;
  members = lib.filter isMember graph.packages;
  manifestDir = p: dirOf p.manifest_path;
  # A member's directory relative to the workspace root ("" for a root package).
  relDir = p: if manifestDir p == wsRoot then "" else lib.removePrefix (wsRoot + "/") (manifestDir p);
  relTo = p: path: lib.removePrefix (manifestDir p + "/") path;

  libKinds = [
    "lib"
    "rlib"
    "dylib"
    "cdylib"
    "staticlib"
    "proc-macro"
  ];
  libTarget = p: lib.findFirst (t: lib.any (k: lib.elem k libKinds) t.kind) null p.targets;
  buildTarget = p: lib.findFirst (t: t.kind == [ "custom-build" ]) null p.targets;
  binTargets = p: lib.filter (t: t.kind == [ "bin" ]) p.targets;
  testTargets = p: lib.filter (t: t.kind == [ "test" ]) p.targets;
  isProcMacro =
    p:
    let
      t = libTarget p;
    in
    t != null && lib.elem "proc-macro" t.kind;
  # The name rustc sees in --extern: the lib target's name (cargo already
  # underscores it), else the package name underscored.
  externName =
    p:
    let
      t = libTarget p;
    in
    lib.replaceStrings [ "-" ] [ "_" ] (if t == null then p.name else t.name);

  # Source per crate. A member is a filtered copy of its own directory under
  # src, so only that crate's edits reach its derivation. A vendored crate is a
  # small content-addressed copy of the vendor dir's <name>-<version> entry: a
  # lock change changes this copy derivation but not its output, so the compile
  # derivation resolves to the same inputs and keeps its realisation (and two
  # repos with the same crate converge on the same compile).
  memberSrc =
    p:
    builtins.path {
      path = joinPath srcRoot (relDir p);
      name = "${pname}-src-${p.name}";
      filter = path: _: baseNameOf path != "target";
    };
  vendoredSrc =
    p:
    runCommand "rustdyn-src-${p.name}-${p.version}" (caAttrs // { preferLocalBuild = true; }) ''
      cp -rL --no-preserve=mode ${vendorDir}/${p.name}-${p.version} $out
    '';
  srcOf = p: if p.source == null then memberSrc p else vendoredSrc p;

  # Resolve-graph edges by dependency kind: null is a normal dependency,
  # "build" a build-script dependency, "dev" a test-only one. A dependency's
  # target cfg() is not evaluated (every edge is included; FDR 0009 § 1).
  depsOfKind = p: kind: lib.filter (d: lib.any (k: k.kind == kind) d.dep_kinds) nodeById.${p.id}.deps;
  renamesOf =
    _p: deps:
    lib.listToAttrs (
      lib.concatMap (
        d:
        let
          dp = byId.${d.pkg};
        in
        lib.optional (d.name != externName dp) (lib.nameValuePair dp.name d.name)
      ) deps
    );

  # The buildRustCrate attribute set for one crate (its coarsest unit: lib,
  # bins and build script in one derivation). `withDev` adds the dev
  # dependencies, for the test variant.
  mkCrate =
    p: withDev:
    let
      normal = depsOfKind p null ++ lib.optionals withDev (depsOfKind p "dev");
      build = depsOfKind p "build";
      lt = libTarget p;
      bt = buildTarget p;
    in
    {
      crateName = p.name;
      inherit (p) version edition;
      rust = rustc;
      inherit cargo release codegenUnits;
      src = srcOf p;
      libName = externName p;
      features = nodeById.${p.id}.features;
      procMacro = isProcMacro p;
      # Only workspace members link binaries; a dependency's bins are noise.
      crateBin =
        if isMember p then
          map (t: {
            inherit (t) name;
            path = relTo p t.src_path;
          }) (binTargets p)
        else
          [ ];
      build = if bt != null then relTo p bt.src_path else "";
      dependencies = map (d: crates.${d.pkg}) normal;
      buildDependencies = map (d: crates.${d.pkg}) build;
      crateRenames = renamesOf p (normal ++ build);
      inherit extraRustcOpts;
    }
    // caAttrs
    // lib.optionalAttrs (lt != null) {
      libPath = relTo p lt.src_path;
      type = lt.crate_types;
    }
    // lib.optionalAttrs (p.links != null) { inherit (p) links; }
    // lib.optionalAttrs (isMember p) ({ inherit buildInputs; } // memberEnvAll);

  mkCrateDrv = attrs: (buildRustCrate attrs).override { inherit crateOverrides; };

  crates = lib.mapAttrs (
    _: p: mkCrateDrv (mkCrate p false // { name = "rustdyn-crate-${p.name}-${p.version}"; })
  ) byId;
  memberCrates = lib.listToAttrs (map (p: lib.nameValuePair p.name crates.${p.id}) members);

  # -- tests --
  # One derivation per member builds every harness (lib tests, tests/*.rs, the
  # bins' own unit tests) plus the real bins for CARGO_BIN_EXE_<name>, which
  # buildRustCrate bakes into the harnesses at compile time.
  testBins = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair p.name (
        mkCrateDrv (
          mkCrate p true
          // {
            buildTests = true;
            name = "rustdyn-testbin-${p.name}-${p.version}";
          }
        )
      )
    ) members
  );
  # The harness binaries buildRustCrate installs under $out/tests, by name:
  # the lib harness is <libname>-<metadata>, a tests/<t>.rs harness is <t>,
  # a bin's unit-test harness is the bin's name.
  harnessesOf =
    p:
    let
      tb = testBins.${p.name};
    in
    lib.optional (libTarget p != null) "${externName p}-${tb.metadata}"
    ++ map (t: t.name) (testTargets p)
    ++ map (t: t.name) (binTargets p);
  # A run: the harness executed from a copy of the member's source (cargo runs
  # tests with the package root as cwd and CARGO_MANIFEST_DIR set); pass/fail
  # is the build result, the log is the output. Content-addressed, so an
  # unchanged test cone never re-runs; flags make a different run.
  mkRun =
    p: harness: flags:
    runCommand "rustdyn-test-${p.name}-${harness}"
      (
        caAttrs
        // {
          nativeBuildInputs = nativeCheckInputs;
          passthru.harness = harness;
        }
        // testEnv
      )
      ''
        cp -r ${memberSrc p} src
        chmod -R u+w src
        cd src
        export CARGO_MANIFEST_DIR=$PWD
        set -o pipefail
        ${testBins.${p.name}}/tests/${harness} ${lib.escapeShellArgs flags} 2>&1 | tee "$NIX_BUILD_TOP/log"
        mkdir -p $out
        cp "$NIX_BUILD_TOP/log" $out/log
        echo "ok ${p.name}/${harness}" > $out/result
      '';
  testRuns = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair p.name (
        lib.listToAttrs (map (h: lib.nameValuePair h (mkRun p h [ ])) (harnessesOf p))
      )
    ) members
  );
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
      p = lib.findFirst (
        p: p.name == crate
      ) (throw "rustdyn: ${crate} is not a workspace member of ${pname}") members;
      hs = if harness != null then [ harness ] else harnessesOf p;
    in
    runCommandLocal "${pname}-rustdyn-test-with-${crate}" { } ''
      cat ${lib.concatMapStringsSep " " (h: "${mkRun p h testFlags}/result") hs} > $out
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
  lint = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair p.name (
        mkCrateDrv (
          mkCrate p false
          // {
            rust = clippyShim;
            capLints = "forbid";
            extraRustcOpts = extraRustcOpts ++ clippyArgs;
            name = "rustdyn-lint-${p.name}-${p.version}";
          }
        )
      )
    ) members
  );
  lintAll = runCommandLocal "${pname}-rustdyn-lint-all" { } ''
    ${lib.concatMapStringsSep "\n" (p: "echo 'ok ${p.name}' >> $out  # ${lint.${p.name}}") members}
  '';

  # -- install --
  memberBins = lib.concatMap (
    p:
    map (t: {
      inherit (t) name;
      crate = crates.${p.id};
    }) (binTargets p)
  ) members;
  installedBins =
    if bins == null then memberBins else lib.filter (b: lib.elem b.name bins) memberBins;
  installDrv = stdenv.mkDerivation {
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
        graph
        vendorDir
        testBins
        checkAll
        testWith
        lint
        lintAll
        ;
      graphFile = "${graphDrv}/metadata.json";
      # Per-member derivations and every crate by package id (for a lint lane or
      # dagnabit to hang off the same store paths).
      crates = memberCrates;
      allCrates = crates;
      members = map (p: p.name) members;
      memberDirs = lib.listToAttrs (map (p: lib.nameValuePair p.name (relDir p)) members);
      tests = testRuns;
    };
    meta = {
      mainProgram = pname;
    }
    // meta;
  };
in
# `tests = true` realises every run as part of the package.
if tests then
  installDrv.overrideAttrs (_old: {
    # A reference is enough: the runs are inputs of the install derivation, so
    # a failing test fails the package.
    rustdynCheckAll = checkAll;
  })
else
  installDrv
