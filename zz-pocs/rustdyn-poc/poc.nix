# rustdyn POC — FDR 0009 § Staged plan, stage 1. Throwaway (zz-pocs), not
# production code.
#
# Builds posh as ONE derivation per crate through nixpkgs' buildRustCrate
# (decision a), from a unit graph derived at eval time by `cargo metadata
# --offline` inside a derivation (decision b; import-from-derivation like
# godyn), with every crate content-addressed so a byte-identical rlib early-cuts
# its dependents. The buildRustPackage baseline builds the same tree.
#
#   nix build --impure --no-link -L --expr \
#     '(import ./poc.nix { poshSrc = /abs/scratch/posh; }).rustdyn'
#
# poshSrc is a writable copy of posh with vendor/galapagos populated (the
# justfile's `setup`); builds read it through filtered builtins.path copies, so
# an edit in one crate changes only that crate's source input.
#
# Known approximations, recorded for the README: a crate is one derivation
# (lib + bins + build script), coarser than cargo's units; dependency features
# are cargo metadata's unified set; a dependency's target `cfg()` is not
# evaluated (all deps included; posh's lock has no non-Linux crates); dev-deps
# and tests are out of scope; buildRustCrate ignores Cargo profiles (posh's
# release profile sets thin LTO and strip, which the baseline honours).
{
  system ? builtins.currentSystem,
  pkgs ? import ../.. { inherit system; },
  poshSrc,
  poshVersion ? "0.0.0-rustdyn-poc",
  poshGitSha ? "rustdyn-poc",
  contentAddressed ? true,
  # Cold-build probe: a token here adds `--cfg rustdyn_poc_cold_<token>` to
  # every crate's rustc flags, so every derivation changes and the whole
  # graph rebuilds from scratch without deleting anything from the store.
  coldToken ? null,
}:
let
  inherit (pkgs) lib;

  # The Rust-relevant part of the checkout: manifests, lock, version.env, the
  # member crates and the vendored galapagos path dependency. Nothing else.
  poshTree = builtins.path {
    path = poshSrc;
    name = "posh-src";
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString poshSrc + "/") (toString path);
        top = builtins.head (lib.splitString "/" rel);
      in
      lib.elem rel [
        "Cargo.toml"
        "Cargo.lock"
        "version.env"
      ]
      || (
        lib.elem top [
          "crates"
          "vendor"
        ]
        && baseNameOf path != "target"
      );
  };

  # Registry and git crates from Cargo.lock, one fixed-output fetch per crate;
  # git deps (hyphence, rust-crap) through builtins.fetchGit, as posh's own
  # flake does.
  vendorDir = pkgs.rustPlatform.importCargoLock {
    lockFile = poshSrc + "/Cargo.lock";
    allowBuiltinFetchGit = true;
  };

  # The resolver (godyn-gen's analog): cargo metadata, offline and locked, in
  # the vendored tree. Emits the raw metadata plus each vendored crate's real
  # store path, so the per-crate derivations source from THAT crate's fetch
  # rather than from the whole vendor directory.
  graphDrv =
    pkgs.runCommand "rustdyn-poc-graph"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.jq
        ];
      }
      ''
        cp -r ${poshTree} source
        chmod -R u+w source
        # cargo finds .cargo/config.toml by walking up from the manifest; the
        # vendor config names the directory "cargo-vendor-dir" beside .cargo.
        ln -s ${vendorDir} cargo-vendor-dir
        mkdir .cargo
        cp ${vendorDir}/.cargo/config.toml .cargo/config.toml
        export HOME=$PWD CARGO_HOME=$PWD/cargo-home
        mkdir -p $out
        (cd source && cargo metadata --format-version 1 --offline --locked) > $out/metadata.json
        jq -r '.packages[] | select(.source != null) | [.id, .manifest_path] | @tsv' $out/metadata.json \
          | while IFS=$'\t' read -r id manifest; do
              printf '%s\t%s\n' "$id" "$(realpath "$(dirname "$manifest")")"
            done \
          | jq -Rs 'split("\n") | map(select(length > 0) | split("\t") | { key: .[0], value: .[1] }) | from_entries' \
          > $out/srcpaths.json
        jq '{ packages: (.packages | length), members: (.workspace_members | length), nodes: (.resolve.nodes | length) }' \
          $out/metadata.json > $out/summary.json
      '';

  # readFile attaches string context for every store path a file mentions and
  # fromJSON refuses a string with context; the crate store paths get their
  # context back per crate through builtins.storePath in srcOf.
  readJSON = f: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile f));
  meta = readJSON "${graphDrv}/metadata.json";
  srcPaths = readJSON "${graphDrv}/srcpaths.json";
  wsRoot = meta.workspace_root;

  byId = lib.listToAttrs (map (p: lib.nameValuePair p.id p) meta.packages);
  nodeById = lib.listToAttrs (map (n: lib.nameValuePair n.id n) meta.resolve.nodes);
  isMember = p: lib.elem p.id meta.workspace_members;
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
  libTarget = p: lib.findFirst (t: lib.any (k: lib.elem k libKinds) t.kind) null p.targets;
  buildTarget = p: lib.findFirst (t: t.kind == [ "custom-build" ]) null p.targets;
  binTargets = p: lib.filter (t: t.kind == [ "bin" ]) p.targets;
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

  # Source per crate: a workspace or path crate is its own filtered directory
  # out of poshSrc (so only that crate's edits reach its derivation); a
  # vendored crate is the fetch the resolver resolved it to.
  srcOf =
    p:
    if p.source == null then
      builtins.path {
        path = poshSrc + "/${lib.removePrefix (wsRoot + "/") (manifestDir p)}";
        name = "rustdyn-poc-src-${p.name}";
        filter = path: _: baseNameOf path != "target";
      }
    else
      builtins.storePath srcPaths.${p.id};

  # Resolve-graph edges by dependency kind: null is a normal dependency,
  # "build" a build-script dependency; "dev" is skipped (no tests in this POC).
  depsOfKind = p: kind: lib.filter (d: lib.any (k: k.kind == kind) d.dep_kinds) nodeById.${p.id}.deps;

  mkCrate =
    p:
    let
      normal = depsOfKind p null;
      build = depsOfKind p "build";
      lt = libTarget p;
      bt = buildTarget p;
      renames = lib.listToAttrs (
        lib.concatMap (
          d:
          let
            dp = byId.${d.pkg};
          in
          lib.optional (d.name != externName dp) (lib.nameValuePair dp.name d.name)
        ) (normal ++ build)
      );
    in
    {
      crateName = p.name;
      inherit (p) version edition;
      # cargo's release profile default; buildRustCrate's own default is 1,
      # which would hand the per-crate side a slower rustc for nothing.
      codegenUnits = 16;
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
      crateRenames = renames;
    }
    // lib.optionalAttrs (lt != null) {
      libPath = relTo p lt.src_path;
      type = lt.crate_types;
    }
    // lib.optionalAttrs (p.links != null) { inherit (p) links; }
    // lib.optionalAttrs (coldToken != null) {
      extraRustcOpts = [
        "--cfg"
        "rustdyn_poc_cold_${coldToken}"
      ];
    }
    // lib.optionalAttrs contentAddressed {
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    }
    # posh's build scripts (posh-build) read these from the environment and
    # fall back to "unknown" for git, which is not on PATH in the sandbox.
    // lib.optionalAttrs (isMember p) {
      POSH_VERSION = poshVersion;
      POSH_GIT_SHA = poshGitSha;
    };

  crates = lib.mapAttrs (_: p: pkgs.buildRustCrate (mkCrate p)) byId;

  members = lib.filter isMember meta.packages;
  memberCrates = lib.listToAttrs (map (p: lib.nameValuePair p.name crates.${p.id}) members);

  # The install step: the members' binaries gathered into one bin/, like
  # godyn's layered install derivation (no postInstall here).
  rustdyn = pkgs.runCommandLocal "posh-rustdyn-${poshVersion}" { } ''
    mkdir -p $out/bin
    ${lib.concatMapStringsSep "\n" (p: "cp ${crates.${p.id}}/bin/* $out/bin/") (
      lib.filter (p: binTargets p != [ ]) members
    )}
  '';

  # Every crate output, one path per line, for the cold-build recipe (nixgc
  # reaps this file's closure, which is exactly the per-crate outputs).
  crateIndex = pkgs.writeText "rustdyn-poc-crate-index" (
    lib.concatMapStringsSep "\n" (c: "${c.out}\n${c.lib}") (lib.attrValues crates)
  );

  # Baseline: the fleet's builder on the same tree, build only (tests are a
  # separate measurement in both approaches and out of this POC's scope).
  brp = pkgs.rustPlatform.buildRustPackage {
    pname = "posh-brp";
    version = poshVersion;
    src = poshTree;
    cargoLock = {
      lockFile = poshSrc + "/Cargo.lock";
      allowBuiltinFetchGit = true;
    };
    doCheck = false;
    POSH_VERSION = poshVersion;
    POSH_GIT_SHA = poshGitSha;
  };
in
{
  inherit
    poshTree
    vendorDir
    graphDrv
    crates
    memberCrates
    crateIndex
    rustdyn
    brp
    ;
  summary = readJSON "${graphDrv}/summary.json";
  memberIds = meta.workspace_members;
}
