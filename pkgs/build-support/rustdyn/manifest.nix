# rustdyn's cargo.nix manifest (FDR 0009 stage 2.5, the go.nix twin): a
# workspace's Cargo.toml tables, member manifests and Cargo.lock as Nix data,
# rendered into the tree the builder reads and read back from one. The data
# model is TOML's, so the file carries cargo's own tables one to one; two keys
# are rustdyn's and rewritten by the renderer:
#   <dep> = { member = true; }            -> path = "<relative member dir>"
#   <dep> = { flakeInput = "<name>"; }    -> path = "<the input's crates output>/<subPath>"
# with `flakeInputs.<name> = { input; subPath ? ""; }` naming the flake input
# (RFC 0002). A tracked Cargo.toml or Cargo.lock beside a cargo.nix is refused.
{
  lib,
  stdenv,
  formats,
  runCommandLocal,
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

  # The rendered form: member and flake-input dependencies as path dependencies,
  # a root package folded into the workspace's Cargo.toml. `cratesOf name` maps
  # a flakeInputs entry to the store path its crate is sourced from.
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
          let
            fi =
              m.flakeInputs.${dep.flakeInput}
                or (throw "rustdyn: dependency ${name} names flakeInput \"${dep.flakeInput}\", which cargo.nix's flakeInputs does not declare");
            sub = fi.subPath or "";
          in
          (removeAttrs dep [ "flakeInput" ])
          // {
            path = "${cratesOf dep.flakeInput fi}" + lib.optionalString (sub != "" && sub != ".") "/${sub}";
          }
        else
          dep;
      rewriteTables =
        fromDir: tables:
        tables
        // lib.listToAttrs (
          map (t: lib.nameValuePair t (lib.mapAttrs (rewriteDep fromDir) tables.${t})) (
            lib.filter (t: tables ? ${t}) depTables
          )
        );
      rewriteMember =
        dir: mm:
        rewriteTables dir mm
        // lib.optionalAttrs (mm ? target) {
          target = lib.mapAttrs (_: rewriteTables dir) mm.target;
        };
      resolvedMembers = lib.mapAttrs rewriteMember members;
    in
    {
      # A member at the workspace root shares the root Cargo.toml.
      workspace = (m.workspace or { }) // (resolvedMembers."." or { });
      members = removeAttrs resolvedMembers [ "." ];
      inherit (m) lock;
      memberDirs = lib.attrNames (removeAttrs members [ "." ]);
      flakeInputs = m.flakeInputs or { };
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
        content over first, ingest them: rustdyn-cargo ingest (or rustdynManifest.ingestRendered).
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
  # Cargo.toml as `workspace`, each member's Cargo.toml under `members`, the
  # lock as data; a path dependency that points at a member folds back to
  # `member = true`. `flakeInputs` cannot be recovered from store paths and is
  # left empty; the escape hatch merges the previous cargo.nix's table back.
  ingestRendered =
    tree:
    let
      readToml = p: builtins.fromTOML (builtins.readFile p);
      root = readToml "${tree}/Cargo.toml";
      memberDirs = root.workspace.members or [ ];
      rawMembers = lib.listToAttrs (
        map (d: lib.nameValuePair d (readToml "${tree}/${d}/Cargo.toml")) memberDirs
      );
      dirToName = lib.mapAttrs (_: mm: mm.package.name) rawMembers;
      # A relative path from `fromDir`, normalised against the member dirs.
      resolvesToMember = fromDir: p: lib.any (d: relPath fromDir d == p) (lib.attrNames rawMembers);
      foldDep =
        fromDir: _name: dep:
        if lib.isAttrs dep && dep ? path && resolvesToMember fromDir dep.path then
          (removeAttrs dep [ "path" ]) // { member = true; }
        else
          dep;
      foldTables =
        fromDir: tables:
        tables
        // lib.listToAttrs (
          map (t: lib.nameValuePair t (lib.mapAttrs (foldDep fromDir) tables.${t})) (
            lib.filter (t: tables ? ${t}) depTables
          )
        );
      foldMember =
        dir: mm:
        foldTables dir mm
        // lib.optionalAttrs (mm ? target) { target = lib.mapAttrs (_: foldTables dir) mm.target; };
    in
    {
      workspace = removeAttrs root [
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
      members =
        lib.mapAttrs foldMember rawMembers
        // lib.optionalAttrs (root ? package) {
          "." = foldMember "." (
            removeAttrs root [
              "workspace"
              "profile"
              "patch"
              "replace"
            ]
          );
        };
      lock = readToml "${tree}/Cargo.lock";
      flakeInputs = { };
      _dirToName = dirToName;
    };

  # The entry point the builders call: with `manifest` present, resolve the
  # version, render the tree and return the builder's arguments pointing at it
  # (no `manifest`, `inputs` or `workspaceDir` left; `commit` from the original
  # source); without one, the arguments pass through unchanged.
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
      in
      removeAttrs args [
        "manifest"
        "inputs"
        "workspaceDir"
        "system"
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
        };
      };
}
