# rustdyn's cargo.nix manifest (FDR 0009 stage 2.5, the go.nix twin): a
# workspace's Cargo.toml tables, member manifests and Cargo.lock as Nix data,
# rendered into the tree the builder reads and read back from one. The data
# model is TOML's, so the file carries cargo's own tables one to one; two keys
# are rustdyn's and rewritten by the renderer:
#   <dep> = { member = true; }            -> path = "<relative member dir>"
#   <dep> = { flakeInput = "<name>"; }    -> path = "<the input's crates output>/<subPath>"
# with `flakeInputs.<name> = { input; subPath ? ""; }` naming the flake input
# (RFC 0002). A tracked Cargo.toml or Cargo.lock beside a cargo.nix is refused.
# The escape hatch (cargoRun, ingest, rustdyn-cargo) runs cargo commands that
# need the network or rewrite the manifests inside an impure derivation and
# writes cargo.nix back.
{
  lib,
  stdenv,
  formats,
  runCommandLocal,
  cargo,
  git,
  cacert,
}:
let
  toml = formats.toml { };
  versionEnv = import ../version-env { inherit lib; };
  joinPath =
    base: sub:
    if sub == "" then
      base
    else if builtins.isPath base then
      base + "/${sub}"
    else
      "${base}/${sub}";
  depTables = [
    "dependencies"
    "dev-dependencies"
    "build-dependencies"
  ];
  splitDir = d: lib.filter (s: s != "" && s != ".") (lib.splitString "/" d);
  # The relative path from member dir `from` to member dir `to` ("../greet").
  relPath =
    from: to:
    let
      f = splitDir from;
      t = splitDir to;
      common = lib.foldl' (
        n: i:
        if n == i && i < lib.length f && i < lib.length t && lib.elemAt f i == lib.elemAt t i then
          n + 1
        else
          n
      ) 0 (lib.range 0 (lib.length f - 1));
      parts = lib.replicate (lib.length f - common) ".." ++ lib.drop common t;
    in
    if parts == [ ] then "." else lib.concatStringsSep "/" parts;
  # Apply `f name dep` to every dependency entry of a member manifest: the three
  # dependency tables at the top and under each `target.<cfg>`.
  mapDeps =
    f: mm:
    let
      onTables =
        tables:
        tables
        // lib.listToAttrs (
          map (t: lib.nameValuePair t (lib.mapAttrs f tables.${t})) (lib.filter (t: tables ? ${t}) depTables)
        );
    in
    onTables mm // lib.optionalAttrs (mm ? target) { target = lib.mapAttrs (_: onTables) mm.target; };
  packageTables = [
    "package"
    "dependencies"
    "dev-dependencies"
    "build-dependencies"
    "features"
    "lib"
    "bin"
    "target"
    "lints"
  ];
in
rec {
  load = m: if builtins.isAttrs m then m else import m;

  # The manifest with the fleet version filled into every member and lock entry
  # that leaves it out (version.env is the version source, eng-versioning(7)).
  # Nothing else changes: this is what `ingestRendered` of a rendered tree
  # compares equal to.
  normalize =
    manifest: version:
    let
      members = manifest.members or { };
      memberNames = lib.mapAttrsToList (_: m: m.package.name) members;
      fill =
        m: m // { package = m.package // lib.optionalAttrs (!(m.package ? version)) { inherit version; }; };
    in
    manifest
    // {
      members = lib.mapAttrs (_: fill) members;
      lock = (manifest.lock or { }) // {
        package = map (
          p: if lib.elem p.name memberNames && !(p ? version) then p // { inherit version; } else p
        ) ((manifest.lock or { }).package or [ ]);
      };
    };

  # The inverse: drop the versions equal to the fleet version so the file keeps
  # version.env as the one source (what ingest writes).
  denormalize =
    manifest: version:
    let
      members = manifest.members or { };
      memberNames = lib.mapAttrsToList (_: m: m.package.name) members;
      strip =
        m:
        m
        // {
          package =
            if (m.package.version or null) == version then removeAttrs m.package [ "version" ] else m.package;
        };
    in
    manifest
    // {
      members = lib.mapAttrs (_: strip) members;
      lock = (manifest.lock or { }) // {
        package = map (
          p:
          if lib.elem p.name memberNames && (p.version or null) == version then
            removeAttrs p [ "version" ]
          else
            p
        ) ((manifest.lock or { }).package or [ ]);
      };
    };

  # The rendered form: member and flake-input dependencies as path dependencies,
  # a root package folded into the workspace's Cargo.toml. `cratesOf name fi`
  # maps a flakeInputs entry to the store path its crate is sourced from.
  resolve =
    {
      manifest,
      version,
      cratesOf,
    }:
    let
      m = normalize manifest version;
      members = m.members or { };
      nameToDir = lib.listToAttrs (
        lib.mapAttrsToList (dir: mm: lib.nameValuePair mm.package.name dir) members
      );
      flakePathOf =
        name: fi:
        let
          sub = fi.subPath or "";
        in
        "${cratesOf name fi}" + lib.optionalString (sub != "" && sub != ".") "/${sub}";
      flakePaths = lib.mapAttrs flakePathOf (m.flakeInputs or { });
      rewriteDep =
        fromDir: name: dep:
        if !(lib.isAttrs dep) then
          dep
        else if dep.member or false then
          (removeAttrs dep [ "member" ])
          // {
            path = relPath fromDir (
              nameToDir.${dep.package or name}
                or (throw "rustdyn: dependency ${name} is marked `member = true` but no workspace member is named ${dep.package or name}")
            );
          }
        else if dep ? flakeInput then
          (removeAttrs dep [ "flakeInput" ])
          // {
            path =
              flakePaths.${dep.flakeInput}
                or (throw "rustdyn: dependency ${name} names flakeInput \"${dep.flakeInput}\", which cargo.nix's flakeInputs does not declare");
          }
        else
          dep;
      resolvedMembers = lib.mapAttrs (dir: mapDeps (rewriteDep dir)) members;
    in
    {
      # A member at the workspace root shares the root Cargo.toml.
      workspace = (m.workspace or { }) // (resolvedMembers."." or { });
      members = removeAttrs resolvedMembers [ "." ];
      inherit (m) lock;
      memberDirs = lib.attrNames (removeAttrs members [ "." ]);
      flakeInputs = m.flakeInputs or { };
      inherit flakePaths;
    };

  # The tree the builder reads: `srcRoot` plus the rendered Cargo.toml files and
  # Cargo.lock. A tracked Cargo.toml or Cargo.lock anywhere the renderer writes
  # is refused: cargo.nix is the manifest, and a stale tracked file would
  # silently lose to it.
  render =
    {
      pname,
      srcRoot,
      resolved,
    }:
    let
      targets = [
        "Cargo.toml"
        "Cargo.lock"
      ]
      ++ map (d: "${d}/Cargo.toml") resolved.memberDirs;
      tracked = lib.filter (p: builtins.pathExists (joinPath srcRoot p)) targets;
    in
    if tracked != [ ] then
      throw ''
        rustdyn: ${pname} has a cargo.nix manifest but its tree tracks ${lib.concatStringsSep ", " tracked}.
        cargo.nix is the manifest (FDR 0009 stage 2.5); remove the tracked file(s). To carry their
        content over first, ingest them: rustdyn-cargo -I . (or rustdynManifest.ingestTree).
      ''
    else
      runCommandLocal "${pname}-cargo-src" { } ''
        cp -r --no-preserve=mode ${srcRoot} $out
        cp ${toml.generate "Cargo.toml" resolved.workspace} $out/Cargo.toml
        cp ${toml.generate "Cargo.lock" resolved.lock} $out/Cargo.lock
        ${lib.concatMapStringsSep "\n" (
          d:
          "cp ${
            toml.generate "${lib.replaceStrings [ "/" ] [ "-" ] d}-Cargo.toml" resolved.members.${d}
          } $out/${d}/Cargo.toml"
        ) resolved.memberDirs}
      '';

  # Read a rendered (or any) cargo tree back into cargo.nix's shape: the root
  # Cargo.toml as `workspace`, each member's Cargo.toml under `members` (a root
  # package under "."), the lock as data; a path dependency that points at a
  # member folds back to `member = true`. `flakeInputs` cannot be recovered
  # from store paths here (see `ingestTree` and the escape hatch's `ingest`).
  ingestRendered =
    tree:
    let
      readToml = p: builtins.fromTOML (builtins.readFile p);
      root = readToml "${tree}/Cargo.toml";
      memberDirs = root.workspace.members or [ ];
      rawMembers = lib.listToAttrs (
        map (d: lib.nameValuePair d (readToml "${tree}/${d}/Cargo.toml")) memberDirs
      );
      allDirs = lib.attrNames rawMembers ++ lib.optional (root ? package) ".";
      foldDep =
        fromDir: _name: dep:
        if lib.isAttrs dep && dep ? path && lib.any (d: relPath fromDir d == dep.path) allDirs then
          (removeAttrs dep [ "path" ]) // { member = true; }
        else
          dep;
    in
    {
      workspace = removeAttrs root packageTables;
      members =
        lib.mapAttrs (dir: mapDeps (foldDep dir)) rawMembers
        // lib.optionalAttrs (root ? package) {
          "." = mapDeps (foldDep ".") (
            removeAttrs root (lib.subtractLists packageTables (lib.attrNames root))
          );
        };
      lock = readToml "${tree}/Cargo.lock";
      flakeInputs = { };
    };

  # Migration and the CLI's -I: a cargo tree (tracked Cargo.toml/Cargo.lock
  # today) as a cargo.nix, versions equal to the tree's version.env dropped and
  # the seed's flakeInputs carried over. `flakePaths` (store path -> flake
  # input name) folds already-rendered flake-input dependencies back.
  ingestTree =
    {
      tree,
      version ? null,
      seed ? { },
      flakePaths ? { },
    }:
    let
      v = versionEnv.resolveVersion {
        inherit version;
        dir = tree;
      };
      pathToFlake = lib.listToAttrs (lib.mapAttrsToList (name: p: lib.nameValuePair p name) flakePaths);
      foldFlake =
        _name: dep:
        if lib.isAttrs dep && dep ? path && pathToFlake ? ${dep.path} then
          (removeAttrs dep [ "path" ]) // { flakeInput = pathToFlake.${dep.path}; }
        else
          dep;
      ing = ingestRendered tree;
    in
    denormalize (
      ing
      // {
        members = lib.mapAttrs (_: mapDeps foldFlake) ing.members;
        flakeInputs = seed.flakeInputs or { };
      }
    ) v;

  # cargo.nix source text for a manifest (what rustdyn-cargo writes); nixfmt
  # reflows it on commit.
  renderCargoNix =
    manifest:
    ''
      # cargo.nix — the workspace manifest (rustdyn(7) CARGO.NIX MANIFEST): cargo's
      # tables as Nix; `member = true` and `flakeInput = "<name>"` are rustdyn's.
      # Written by rustdyn-cargo; edit by hand or re-run it.
    ''
    + lib.generators.toPretty { multiline = true; } manifest
    + "\n";

  # The entry point the builders call: with `manifest` present, resolve the
  # version, render the tree and return the builder's arguments pointing at it
  # (no `manifest`, `inputs` or `workspaceDir` left; `commit` from the original
  # source), with the escape hatch and ingest on the passthru; without one, the
  # arguments pass through unchanged.
  withCargoManifest =
    args:
    if !(args ? manifest) then
      args
    else
      let
        manifest = load args.manifest;
        workspaceDir = args.workspaceDir or "";
        srcRoot = joinPath args.src workspaceDir;
        version = versionEnv.resolveVersion {
          version = args.version or null;
          dir = srcRoot;
        };
        inputs = args.inputs or { };
        system = args.system or stdenv.hostPlatform.system;
        cratesOf =
          name: fi:
          let
            input =
              inputs.${fi.input or name}
                or (throw "rustdyn: flakeInputs.${name} needs input \"${fi.input or name}\", which the builder call's `inputs` does not provide (${lib.concatStringsSep ", " (lib.attrNames inputs)})");
          in
          input.packages.${system}.crates
            or (lib.warn "rustdyn: input ${fi.input or name} has no packages.${system}.crates output; using its tree" input);
        resolved = resolve { inherit manifest version cratesOf; };
        rendered = render {
          inherit (args) pname;
          inherit srcRoot resolved;
        };
        # The escape hatch (FDR 0008's goRun for cargo): run a cargo command that
        # needs the network (cargo add, cargo update, cargo generate-lockfile) or
        # rewrites the tree inside nix, against the rendered manifests, and hand
        # the results back. An impure derivation — network on, never cached,
        # never a pure derivation's input — so not a flake check. $out/tree holds
        # the manifests after the command (root and member Cargo.toml, Cargo.lock)
        # for `ingest`; $out/patch is `git diff --no-index --binary` of the
        # checkout against the rest of the tree (apply with `git apply -p2`).
        cargoRun =
          {
            command,
            nativeBuildInputs ? [ ],
          }:
          stdenv.mkDerivation {
            name = "${args.pname}-cargo-run";
            __impure = true;
            nativeBuildInputs = [
              cargo
              git
              cacert
            ]
            ++ (args.cargoRunInputs or [ ])
            ++ nativeBuildInputs;
            dontUnpack = true;
            dontInstall = true;
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/home" CARGO_HOME="$TMPDIR/cargo-home"
              export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt NIX_SSL_CERT_FILE=$SSL_CERT_FILE
              mkdir -p "$HOME" "$out/tree"
              cp -r --no-preserve=mode ${srcRoot} src
              cp -r --no-preserve=mode ${rendered} work
              (
                cd work
                ${command}
              )
              cp work/Cargo.toml work/Cargo.lock "$out/tree/"
              ${lib.concatMapStringsSep "\n" (d: ''
                mkdir -p "$out/tree/${d}"
                cp work/${d}/Cargo.toml "$out/tree/${d}/"
              '') resolved.memberDirs}
              # the manifests are ingest's, not the patch's
              rm -f work/Cargo.toml work/Cargo.lock ${
                lib.concatMapStringsSep " " (d: "work/${d}/Cargo.toml") resolved.memberDirs
              }
              git diff --no-index --binary src work > "$out/patch" || [ $? -eq 1 ]
              runHook postBuild
            '';
          };
        ingest =
          out:
          renderCargoNix (ingestTree {
            tree = "${out}/tree";
            inherit version;
            seed = manifest;
            inherit (resolved) flakePaths;
          });
      in
      removeAttrs args [
        "manifest"
        "inputs"
        "workspaceDir"
        "system"
        "cargoRunInputs"
      ]
      // {
        src = rendered;
        inherit version;
        commit = args.commit or (versionEnv.commitOf args.src);
        extraPassthru = (args.extraPassthru or { }) // {
          cargoManifest = manifest;
          cargoResolved = resolved;
          cargoSrc = rendered;
          inherit (resolved) flakeInputs;
          inherit cargoRun ingest;
        };
      };
}
