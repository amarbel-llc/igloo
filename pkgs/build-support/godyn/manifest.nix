# go.nix — a Go module's nix manifest (FDR 0008): the only source of truth for the
# module path, the Go version, third-party requires (with the hashes their vendor
# tree fetches by), fleet modules (flake inputs) and replaces. go.mod,
# gomod2nix.toml and the package graph are rendered or derived from it inside nix.
{
  lib,
  stdenv,
  runCommandLocal,
}:
let
  gomod2nixInternals = import ../gomod2nix/internals.nix { };
  inherit (import ../gomod2nix/parser.nix) parseGoMod;

  fail = msg: throw "go.nix: ${msg}";
  names = lib.concatStringsSep ", ";
  checkKeys =
    what: allowed: attrs:
    let
      unknown = lib.subtractLists allowed (builtins.attrNames attrs);
    in
    if unknown != [ ] then
      fail "${what}: unknown field(s) ${names unknown} (known: ${names allowed})"
    else
      attrs;

  # A manifest (a path to go.nix, or its attrset), validated, with defaults filled.
  load =
    manifest:
    let
      m = checkKeys "top level" [ "module" "go" "require" "flakeInputs" "replace" ] (
        if builtins.isAttrs manifest then manifest else import manifest
      );
      require = m.require or { };
      flakeInputs = m.flakeInputs or { };
      both = builtins.filter (p: require ? ${p}) (builtins.attrNames flakeInputs);
      checkRequire =
        p: r:
        if !(r ? version && r ? hash) then
          fail "require.${p}: needs version and hash"
        else
          checkKeys "require.${p}" [ "version" "hash" "go" "indirect" ] r;
      checkFlakeInput =
        p: f:
        if !(f ? input) then
          fail "flakeInputs.${p}: needs input (a flake input name)"
        else
          checkKeys "flakeInputs.${p}" [ "input" "subPath" ] f;
      checkReplace =
        p: r:
        let
          checked = checkKeys "replace.${p}" [ "path" "module" "version" "oldVersion" ] r;
        in
        if (r ? path) == (r ? module) then
          fail "replace.${p}: needs exactly one of path or module"
        else if r ? module && !(r ? version) then
          fail "replace.${p}: a module replace needs version"
        else if r ? path && r ? version then
          fail "replace.${p}: a path replace takes no version"
        else
          checked;
    in
    if !(m ? module) then
      fail "missing module"
    else if !(m ? go) then
      fail "missing go"
    else if both != [ ] then
      fail "required and also a flake input: ${names both}"
    else
      {
        inherit (m) module go;
        require = lib.mapAttrs checkRequire require;
        flakeInputs = lib.mapAttrs checkFlakeInput flakeInputs;
        replace = lib.mapAttrs checkReplace (m.replace or { });
      };

  # go.mod text for a manifest. flakeInputTargets (module path -> replacement dir)
  # adds each fleet module as an RFC 0001 require (sentinel version) + replace pair;
  # null leaves them out, for builds where the goFlakeInputs merge adds them.
  renderGoMod =
    {
      manifest,
      flakeInputTargets ? null,
    }:
    let
      m = load manifest;
      fleet =
        if flakeInputTargets == null then
          { }
        else
          lib.mapAttrs (
            p: _: flakeInputTargets.${p} or (fail "renderGoMod: no target for flake input ${p}")
          ) m.flakeInputs;
      requireLines =
        lib.mapAttrsToList (
          p: r: "${p} ${r.version}${lib.optionalString (r.indirect or false) " // indirect"}"
        ) m.require
        ++ lib.mapAttrsToList (p: _: "${p} ${gomod2nixInternals.sentinelFor p}") fleet;
      replaceLines =
        lib.mapAttrsToList (
          p: r:
          "${p}${lib.optionalString (r ? oldVersion) " ${r.oldVersion}"} => ${
            r.path or "${r.module} ${r.version}"
          }"
        ) m.replace
        ++ lib.mapAttrsToList (p: target: "${p} => ${target}") fleet;
      block =
        directive: lines:
        lib.optionalString (lines != [ ])
          "\n${directive} (\n${lib.concatMapStrings (l: "\t${l}\n") (lib.sort lib.lessThan lines)})\n";
    in
    "module ${m.module}\n\ngo ${m.go}\n" + block "require" requireLines + block "replace" replaceLines;

  # gomod2nix.toml text for a manifest's third-party requires: what the vendor tree
  # fetches. A module-replaced require fetches its replacement; a path-replaced one
  # fetches nothing.
  renderGomod2nixToml =
    manifest:
    let
      m = load manifest;
      entry =
        p: r:
        let
          rp = m.replace.${p} or null;
        in
        if rp != null && rp ? path then
          ""
        else
          "\n[mod.${builtins.toJSON p}]\n  version = ${
            builtins.toJSON (if rp != null then rp.version else r.version)
          }\n  hash = ${builtins.toJSON r.hash}\n"
          + lib.optionalString (rp != null) "  replaced = ${builtins.toJSON rp.module}\n";
    in
    "schema = 3\n" + lib.concatStrings (lib.mapAttrsToList entry m.require);

  # goFlakeInputs for a manifest's fleet modules: each names a flake input publishing
  # packages.<system>.go-pkgs (the RFC 0001 producer convention); an override
  # { src; subPath?; } for a module wins (fixtures, unconventional producers).
  goFlakeInputsFor =
    {
      manifest,
      inputs,
      system,
      overrides ? { },
    }:
    let
      m = load manifest;
      unknown = builtins.filter (p: !(m.flakeInputs ? ${p})) (builtins.attrNames overrides);
      resolve =
        p: f:
        overrides.${p} or (
          let
            input =
              inputs.${f.input}
                or (fail "flakeInputs.${p}: no flake input named ${f.input} (inputs has: ${names (builtins.attrNames inputs)})");
            goPkgs =
              input.packages.${system}.go-pkgs
                or (fail "flakeInputs.${p}: input ${f.input} publishes no packages.${system}.go-pkgs (RFC 0001)");
          in
          {
            src = goPkgs;
            subPath = f.subPath or "";
          }
        );
    in
    if unknown != [ ] then
      fail "goFlakeInputOverrides for modules go.nix does not list: ${names unknown}"
    else
      lib.mapAttrs resolve m.flakeInputs;

  # The manifest for a go.mod's text — the core of ingest, and the go.mod half of the
  # FDR 0008 round trip. hashes: module path -> vendor hash for every third-party
  # require. flakeInputs: module path -> { input; subPath?; } for the fleet modules,
  # whose require + replace pairs the manifest does not store. Anything the manifest
  # does not model is rejected, never silently dropped.
  fromGoMod =
    {
      text,
      hashes,
      flakeInputs ? { },
      # module path -> its own Go language version (from gomod2nix.toml's goVersion)
      goVersions ? { },
    }:
    let
      g = parseGoMod text;
      # A module replaced to a store path is a bridged fleet module (declared or
      # inherited, RFC 0001): never recorded — the flake input is its version.
      bridged = builtins.attrNames (
        lib.filterAttrs (_: r: r ? path && lib.hasPrefix builtins.storeDir r.path) (g.replace or { })
      );
      lines = lib.splitString "\n" text;
      indirectRe = ".*//[[:space:]]*indirect[[:space:]]*";
      indirect = lib.concatMap (
        l:
        let
          mt = builtins.match "[[:space:]]*(require[[:space:]]+)?([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]*//[[:space:]]*indirect[[:space:]]*" l;
        in
        lib.optional (mt != null) (builtins.elemAt mt 1)
      ) lines;
      comments = builtins.filter (l: lib.hasInfix "//" l && builtins.match indirectRe l == null) lines;
      unmodeled = builtins.filter (d: g ? ${d} && g.${d} != { }) [
        "toolchain"
        "godebug"
        "exclude"
        "retract"
        "tool"
      ];
      fleetKeys = builtins.attrNames flakeInputs ++ bridged;
      require = removeAttrs g.require fleetKeys;
      missingHash = builtins.filter (p: !(hashes ? ${p})) (builtins.attrNames require);
      replaceFrom =
        _: r:
        (
          if r ? path then
            { inherit (r) path; }
          else
            {
              module = r.goPackagePath;
              inherit (r) version;
            }
        )
        // lib.optionalAttrs (r ? lhsVersion) { oldVersion = r.lhsVersion; };
    in
    if comments != [ ] then
      fail "fromGoMod: comments other than // indirect are not modeled: ${names comments}"
    else if unmodeled != [ ] then
      fail "fromGoMod: directives not modeled: ${names unmodeled}"
    else if missingHash != [ ] then
      fail "fromGoMod: no hash for ${names missingHash}"
    else
      {
        inherit (g) module go;
        require = lib.mapAttrs (
          p: v:
          {
            version = v;
            hash = hashes.${p};
          }
          // lib.optionalAttrs (goVersions ? ${p}) { go = goVersions.${p}; }
          // lib.optionalAttrs (lib.elem p indirect) { indirect = true; }
        ) require;
        replace = lib.mapAttrs replaceFrom (removeAttrs (g.replace or { }) fleetKeys);
      }
      // lib.optionalAttrs (flakeInputs != { }) { inherit flakeInputs; };

  # ingest: the manifest after an escape-hatch run (passthru.goRun's output —
  # go.mod plus gomod2nix.toml). Hashes and Go versions come from the toml; the
  # current manifest's flakeInputs are carried over (their require/replace pairs,
  # and any inherited bridge, are dropped from the go.mod). Pure, given the
  # output's path.
  ingest =
    {
      manifest,
      out,
    }:
    let
      m = load manifest;
      toml = builtins.fromTOML (builtins.readFile "${out}/gomod2nix.toml");
      mods = toml.mod or { };
      goVersions = lib.concatMapAttrs (
        p: v: lib.optionalAttrs (v ? goVersion) { ${p} = v.goVersion; }
      ) mods;
    in
    fromGoMod {
      text = builtins.readFile "${out}/go.mod";
      hashes = lib.mapAttrs (_: v: v.hash) mods;
      inherit goVersions;
      inherit (m) flakeInputs;
    };

  # ingest rendered as go.nix text — what passthru.ingest returns (null manifest:
  # the module is not a go.nix module).
  ingestGoNix =
    {
      pname,
      manifest,
      out,
    }:
    if manifest == null then
      throw "${pname}: ingest needs a manifest (go.nix)"
    else
      renderGoNix (ingest {
        inherit manifest out;
      });

  # go.nix source text for a manifest: plain data, sorted keys, ready to commit.
  renderGoNix =
    manifest:
    "# go.nix — this module's dependencies (FDR 0008); go.mod, gomod2nix.toml and\n"
    + "# the package graph are rendered or derived from it inside nix. Edit through\n"
    + "# the escape hatch (godyn-go) or by hand.\n"
    + lib.generators.toPretty { } (load manifest)
    + "\n";

  # Builder args with manifest (+ inputs, goFlakeInputOverrides) turned into plain
  # ones: a source tree carrying the rendered go.mod (the tracked tree must have
  # none), the rendered gomod2nix.toml, and goFlakeInputs. Args without manifest
  # pass through unchanged.
  withManifest =
    args:
    if !(args ? manifest) then
      args
    else
      let
        inherit (args) pname src manifest;
      in
      if (args.modules or null) != null || (args.goFlakeInputs or { }) != { } then
        throw "${pname}: manifest (go.nix) replaces modules and goFlakeInputs; pass only manifest"
      else if builtins.pathExists "${src}/go.mod" then
        throw "${pname}: a go.nix module must not track a go.mod (FDR 0008); remove it from ${toString src}"
      else
        # manifest stays: the builder keeps it for passthru.ingest
        removeAttrs args [
          "inputs"
          "goFlakeInputOverrides"
        ]
        // {
          src = runCommandLocal "${pname}-go-src" { } ''
            cp -r --no-preserve=mode ${src} $out
            cp ${
              builtins.toFile "go.mod" (renderGoMod {
                inherit manifest;
              })
            } $out/go.mod
          '';
          modules = builtins.toFile "gomod2nix.toml" (renderGomod2nixToml manifest);
          goFlakeInputs = goFlakeInputsFor {
            inherit manifest;
            inputs = args.inputs or { };
            system = args.system or stdenv.hostPlatform.system;
            overrides = args.goFlakeInputOverrides or { };
          };
        }
        // lib.optionalAttrs (src ? rev && !(args ? commit)) { commit = src.rev; };
in
{
  inherit
    load
    renderGoMod
    renderGomod2nixToml
    goFlakeInputsFor
    fromGoMod
    ingest
    ingestGoNix
    renderGoNix
    withManifest
    ;
}
