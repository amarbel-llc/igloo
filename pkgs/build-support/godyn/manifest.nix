# go.nix — a Go module's nix manifest (FDR 0008): the only source of truth for the
# module path, the Go version, third-party requires (with the hashes their vendor
# tree fetches by), fleet modules (flake inputs) and replaces. go.mod,
# gomod2nix.toml and the package graph are rendered or derived from it inside nix.
{
  lib,
  stdenv,
  runCommandLocal,
  git,
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
      replaces = m.replace or { };
      # A path-replaced require fetches nothing (the replacement is a directory in
      # the tree), so it carries no hash (igloo#73).
      pathReplaced = p: replaces ? ${p} && replaces.${p} ? path;
      checkRequire =
        p: r:
        if !(r ? version) then
          fail "require.${p}: needs version"
        else if !(r ? hash) && !(pathReplaced p) then
          fail "require.${p}: needs hash (only a path-replaced require has none)"
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
  # fleetRequires adds the sentinel require lines alone (no replace) — the shape
  # of a producer's go.mod, whose replaces `go` ignores anyway; the consumer's
  # merge supplies the replace.
  renderGoMod =
    {
      manifest,
      flakeInputTargets ? null,
      fleetRequires ? false,
    }:
    let
      m = load manifest;
      fleet =
        if flakeInputTargets != null then
          lib.mapAttrs (
            p: _: flakeInputTargets.${p} or (fail "renderGoMod: no target for flake input ${p}")
          ) m.flakeInputs
        else if fleetRequires then
          lib.mapAttrs (_: _: null) m.flakeInputs
        else
          { };
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
        ++ lib.mapAttrsToList (p: target: "${p} => ${target}") (lib.filterAttrs (_: t: t != null) fleet);
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
          }\n  hash = ${builtins.toJSON (r.hash or "")}\n"
          + lib.optionalString (r ? go) "  goVersion = ${builtins.toJSON r.go}\n"
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
      # The previous manifest's require entries. A module replaced to a store path
      # (an INHERITED bridge, RFC 0001 depth-N) has no hash in the toml — the
      # vendor tree never fetches it — so its previous entry is carried over
      # verbatim, keeping ingest's output identical to the migration's (which saw
      # the organic go.mod without replaces). Absent from carry, it is dropped.
      carry ? { },
    }:
    let
      g = parseGoMod text;
      # A module replaced to a store path is a bridged fleet module (declared or
      # inherited, RFC 0001): never recorded from the go.mod — the flake input is
      # its version — but an inherited one keeps its carried entry (dead data the
      # merge shadows; FDR 0008).
      bridged = builtins.attrNames (
        lib.filterAttrs (_: r: r ? path && lib.hasPrefix builtins.storeDir r.path) (g.replace or { })
      );
      carried = lib.filterAttrs (p: _: lib.elem p bridged && !(flakeInputs ? ${p})) carry;
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
        require =
          lib.mapAttrs (
            p: v:
            {
              version = v;
              hash = hashes.${p};
            }
            // lib.optionalAttrs (goVersions ? ${p}) { go = goVersions.${p}; }
            // lib.optionalAttrs (lib.elem p indirect) { indirect = true; }
          ) require
          // carried;
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
      carry = m.require;
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
  # A tree-relative directory with "." and ".." segments folded ("app/../sib" ->
  # "sib"); a path that climbs above the tree is an error.
  normDir =
    p:
    lib.concatStringsSep "/" (
      lib.foldl' (
        acc: s:
        if s == ".." then
          (if acc == [ ] then throw "manifest: path ${p} climbs above the source tree" else lib.init acc)
        else
          acc ++ [ s ]
      ) [ ] (builtins.filter (s: s != "" && s != ".") (lib.splitString "/" p))
    );

  withManifest =
    args:
    if !(args ? manifest) then
      args
    else
      let
        inherit (args) pname src manifest;
        # moduleDir (igloo#73): the module's directory inside src, when src is a
        # repository root holding several go.nix modules; "" is the root.
        moduleDir = normDir (args.moduleDir or "");
        inTree = f: if moduleDir == "" then f else "${moduleDir}/${f}";

        rendered = renderGoMod { inherit manifest; };
        # A src that already carries a go.mod is accepted only if it is this
        # manifest's own render (a producer's go-pkgs-test, whose go.mod also has
        # the fleet sentinel requires): then the tree is used as is.
        srcGoMod = "${src}/${inTree "go.mod"}";
        srcIsRendered =
          builtins.pathExists srcGoMod
          && lib.elem (builtins.readFile srcGoMod) [
            rendered
            (renderGoMod {
              inherit manifest;
              fleetRequires = true;
            })
          ];

        # Sibling modules (igloo#73): every module a path replace points at, inside
        # src, that carries a go.nix gets its go.mod rendered too — Go reads the
        # replacement's go.mod — recursively through the siblings' own path replaces.
        # Rendered with fleetRequires: a sibling's fleet modules are bridged by the
        # consuming module's merge, not re-resolved here.
        siblingDirsOf =
          dir: m:
          lib.mapAttrsToList (_: r: normDir "${dir}/${r.path}") (lib.filterAttrs (_: r: r ? path) m.replace);
        collectSiblings =
          seen: dirs:
          lib.foldl' (
            acc: d:
            if lib.elem d acc || d == moduleDir || !builtins.pathExists "${src}/${d}/go.nix" then
              acc
            else
              collectSiblings (acc ++ [ d ]) (siblingDirsOf d (load "${src}/${d}/go.nix"))
          ) seen dirs;
        siblingDirs = collectSiblings [ ] (siblingDirsOf moduleDir (load manifest));
        siblingGoMods = lib.concatMapStrings (
          d:
          "cp ${
            builtins.toFile "go.mod" (renderGoMod {
              manifest = "${src}/${d}/go.nix";
              fleetRequires = true;
            })
          } $out/${d}/go.mod\n"
        ) siblingDirs;
      in
      if (args.modules or null) != null || (args.goFlakeInputs or { }) != { } then
        throw "${pname}: manifest (go.nix) replaces modules and goFlakeInputs; pass only manifest"
      else if builtins.pathExists srcGoMod && !srcIsRendered then
        throw "${pname}: a go.nix module must not track a go.mod (FDR 0008); remove it from ${toString src}/${inTree "go.mod"}"
      else
        # manifest stays: the builder keeps it for passthru.ingest
        removeAttrs args [
          "inputs"
          "goFlakeInputOverrides"
        ]
        // {
          src =
            if srcIsRendered then
              src
            else
              runCommandLocal "${pname}-go-src" { } ''
                cp -r --no-preserve=mode ${src} $out
                cp ${builtins.toFile "go.mod" rendered} $out/${inTree "go.mod"}
                ${siblingGoMods}
              '';
          inherit moduleDir;
          modules = builtins.toFile "gomod2nix.toml" (renderGomod2nixToml manifest);
          goFlakeInputs = goFlakeInputsFor {
            inherit manifest;
            inputs = args.inputs or { };
            system = args.system or stdenv.hostPlatform.system;
            overrides = args.goFlakeInputOverrides or { };
          };
        }
        // lib.optionalAttrs (src ? rev && !(args ? commit)) { commit = src.rev; };

  # ---- go.nix staleness (igloo#98) ----
  # A flake update moves a bridged producer's go.mod and leaves go.nix alone; the
  # next escape-hatch run (any command, under -mod=mod) then has cmd/go's MVS raise
  # the requires and the go line to what the producers require, and ingest records
  # that. drift sees the gap offline, at eval time, before that run does.

  # Decimal strings without leading zeros (version numbers, numeric prerelease
  # identifiers), compared without integer overflow: by length, then as text.
  cmpNum =
    a: b:
    let
      la = builtins.stringLength a;
      lb = builtins.stringLength b;
    in
    if la != lb then
      (if la < lb then -1 else 1)
    else if a == b then
      0
    else if a < b then
      -1
    else
      1;
  # Element-wise; a list that runs out first is lower.
  cmpLists =
    cmp: as: bs:
    if as == [ ] || bs == [ ] then
      cmpNum (toString (builtins.length as)) (toString (builtins.length bs))
    else
      let
        c = cmp (builtins.head as) (builtins.head bs);
      in
      if c != 0 then c else cmpLists cmp (builtins.tail as) (builtins.tail bs);

  # Module versions, ordered as cmd/go orders them (golang.org/x/mod/semver):
  # major.minor.patch numerically, a release above its prereleases (pseudo-versions
  # included), numeric identifiers below alphanumeric ones, build metadata
  # (+incompatible) ignored.
  compareModuleVersions =
    a: b:
    let
      parse =
        v:
        let
          mt = builtins.match "v([0-9]+)\\.([0-9]+)\\.([0-9]+)(-([0-9A-Za-z.-]+))?(\\+[0-9A-Za-z.-]+)?" v;
        in
        if mt == null then
          fail "not a module version: ${v}"
        else
          {
            nums = lib.sublist 0 3 mt;
            pre = builtins.elemAt mt 4;
          };
      cmpIdent =
        x: y:
        let
          nx = builtins.match "[0-9]+" x != null;
          ny = builtins.match "[0-9]+" y != null;
        in
        if nx && ny then
          cmpNum x y
        else if nx != ny then
          (if nx then -1 else 1)
        else if x == y then
          0
        else if x < y then
          -1
        else
          1;
      pa = parse a;
      pb = parse b;
      c = cmpLists cmpNum pa.nums pb.nums;
    in
    if c != 0 then
      c
    else if pa.pre == pb.pre then
      0
    else if pa.pre == null then
      1
    else if pb.pre == null then
      -1
    else
      cmpLists cmpIdent (lib.splitString "." pa.pre) (lib.splitString "." pb.pre);

  # Go versions (a go line, a require's go), ordered as go/version orders them: a
  # language version below its prereleases below its releases, so
  # 1.26 < 1.26rc1 < 1.26.0 < 1.26.1.
  compareGoVersions =
    a: b:
    let
      parse =
        v:
        let
          mt = builtins.match "([0-9]+)(\\.([0-9]+))?(\\.([0-9]+)|(alpha|beta|rc)([0-9]+))?" v;
          at = builtins.elemAt mt;
        in
        if mt == null then
          fail "not a Go version: ${v}"
        else
          [
            (at 0)
            (if at 2 == null then "0" else at 2)
            (
              if at 4 != null then
                "4"
              else if at 5 != null then
                {
                  alpha = "1";
                  beta = "2";
                  rc = "3";
                }
                .${at 5}
              else
                "0"
            )
            (
              if at 4 != null then
                at 4
              else if at 6 != null then
                at 6
              else
                "0"
            )
          ];
    in
    cmpLists cmpNum (parse a) (parse b);

  # The highest of a list of { version; ... } by cmp; null for an empty list.
  maxBy =
    cmp: lib.foldl' (acc: x: if acc == null || cmp x.version acc.version > 0 then x else acc) null;

  # drift: go.nix against the go.mod files of its bridged producers — the declared
  # and inherited ones, as goFlakeInputs (module path -> { src; subPath?; }, what
  # goFlakeInputsFor returns) resolves (RFC 0001 depth-N); each producer's go.mod
  # is <src>/<subPath>/go.mod, a store path, read at eval time. For each
  # third-party require go.nix lists, the highest version a producer requires; for
  # the go line, the highest of go.nix's own, the producers' and the (raised)
  # requires' go versions. ONE level of requires: a raise cmd/go's MVS would make
  # through a third-party module's own go.mod, and a module a producer requires
  # that go.nix does not list, go unseen. A raise is repairable when a producer's
  # gomod2nix.toml pins exactly that version (its hash, its go) and go.nix does
  # not replace the module; expected is go.nix with every repairable raise made.
  drift =
    {
      manifest,
      goFlakeInputs,
    }:
    let
      m = load manifest;
      bridges = gomod2nixInternals.resolveGoFlakeInputs goFlakeInputs;
      producers = lib.concatLists (
        lib.mapAttrsToList (
          p: v:
          let
            dir = "${v.src}${lib.optionalString (v.subPath != "") "/${v.subPath}"}";
            g = parseGoMod (builtins.readFile "${dir}/go.mod");
            # the toml the vendor merge reads: a subPath producer without its
            # own falls back to its root's (igloo#49)
            toml = lib.findFirst builtins.pathExists null (
              [ "${dir}/gomod2nix.toml" ] ++ lib.optional (v.subPath != "") "${v.src}/gomod2nix.toml"
            );
          in
          lib.optional (builtins.pathExists "${dir}/go.mod") {
            module = p;
            go = g.go or null;
            # a fleet module's sentinel require is the producer's bridge, no version
            require = lib.filterAttrs (r: ver: ver != gomod2nixInternals.sentinelFor r) g.require;
            pins = if toml == null then { } else (builtins.fromTOML (builtins.readFile toml)).mod or { };
          }
        ) bridges
      );
      raiseOf =
        p: r:
        let
          wants = lib.concatMap (
            pr:
            lib.optional (pr.require ? ${p}) {
              version = pr.require.${p};
              inherit (pr) module;
            }
          ) producers;
          top = maxBy compareModuleVersions wants;
          pin = lib.findFirst (e: e != null && e.version == top.version && e ? hash) null (
            map (pr: pr.pins.${p} or null) producers
          );
        in
        # an inherited bridge go.nix still lists is dead data the merge shadows
        if bridges ? ${p} || top == null || compareModuleVersions top.version r.version <= 0 then
          null
        else
          {
            have = r.version;
            want = top.version;
            requiredBy = map (w: w.module) (builtins.filter (w: w.version == top.version) wants);
            problem =
              if m.replace ? ${p} then
                "go.nix replaces it"
              else if pin == null then
                "no bridged producer's gomod2nix.toml pins ${top.version}"
              else
                null;
            entry = {
              inherit (top) version;
              inherit (pin) hash;
            }
            // lib.optionalAttrs (pin ? goVersion) { go = pin.goVersion; }
            // lib.optionalAttrs (r.indirect or false) { indirect = true; };
          };
      requires = lib.filterAttrs (_: x: x != null) (lib.mapAttrs raiseOf m.require);
      raised =
        m.require // lib.mapAttrs (_: x: x.entry) (lib.filterAttrs (_: x: x.problem == null) requires);
      goSources =
        lib.concatMap (
          pr:
          lib.optional (pr.go != null) {
            version = pr.go;
            from = "${pr.module}'s go.mod";
          }
        ) producers
        ++ lib.concatLists (
          lib.mapAttrsToList (
            p: r:
            lib.optional (r ? go) {
              version = r.go;
              from = "${p} ${r.version}";
            }
          ) raised
        );
      goTop = maxBy compareGoVersions goSources;
      go =
        if goTop == null || compareGoVersions goTop.version m.go <= 0 then
          null
        else
          {
            have = m.go;
            want = goTop.version;
            from = map (s: s.from) (builtins.filter (s: s.version == goTop.version) goSources);
          };
    in
    {
      inherit requires go;
      producers = map (pr: pr.module) producers;
      stale = requires != { } || go != null;
      repairable = lib.all (x: x.problem == null) (builtins.attrValues requires);
      expected = m // {
        go = if go == null then m.go else go.want;
        require = raised;
      };
      report = lib.concatStringsSep "\n" (
        lib.optional (go != null) "go: ${go.have} -> ${go.want} (${names go.from})"
        ++ lib.mapAttrsToList (
          p: x:
          "require.${p}: ${x.have} -> ${x.want} (required by ${names x.requiredBy}'s go.mod)"
          + lib.optionalString (x.problem != null) "; no repair patch: ${x.problem}"
        ) requires
      );
    };

  # The go.nix staleness check (igloo#98): fails while drift finds go.nix behind
  # its bridged producers, naming each raise and the repair (godyn-go -- go mod
  # tidy). passthru.codegenPatch (igloo#80's repair-lane shape, as codegenCheck's)
  # rewrites go.nix to drift's expected manifest — relative to the directory
  # holding go.nix, `git apply -p2` — when every raise is repairable and manifest
  # is a file; otherwise it is empty and only the escape hatch repairs.
  # codegenPrefix is that directory relative to the repo root, when the caller
  # knows it (the manifest's own path carries no reliable repo root).
  driftCheck =
    {
      pname,
      manifest,
      goFlakeInputs,
      codegenPrefix ? null,
    }:
    let
      d = drift { inherit manifest goFlakeInputs; };
      file = if builtins.isAttrs manifest then null else baseNameOf (toString manifest);
      patchable = d.stale && d.repairable && file != null;
      patch = runCommandLocal "${pname}-manifest-drift-patch" { nativeBuildInputs = [ git ]; } (
        if patchable then
          ''
            mkdir -p "$out" src work
            cp ${manifest} src/${file}
            printf '%s' ${lib.escapeShellArg (renderGoNix d.expected)} > work/${file}
            git diff --no-index --binary src work > "$out/patch" || [ $? -eq 1 ]
          ''
        else
          ''
            mkdir -p "$out"
            : > "$out/patch"
          ''
      );
      say = msg: "echo ${lib.escapeShellArg "godyn go.nix drift (${pname}): ${msg}"}";
    in
    if manifest == null then
      throw "${pname}: manifestDrift needs a manifest (go.nix)"
    else
      runCommandLocal "${pname}-manifest-drift"
        {
          passthru = {
            codegenPatch = patch;
            inherit codegenPrefix;
            codegenIncludes = [ ];
            drift = d;
          };
        }
        (
          if !d.stale then
            "touch $out"
          else
            ''
              {
                printf '%s\n' ${lib.escapeShellArg d.report}
                ${say "go.nix is behind what its bridged producers' go.mod files require (a flake input moved, go.nix did not; igloo#98)"}
                ${say "repair from the directory holding go.nix: godyn-go -- go mod tidy"}
                ${lib.optionalString patchable (say "or, from that directory: git apply -p2 ${patch}/patch")}
                ${lib.optionalString (patchable && codegenPrefix != null) (
                  say "or, from the repo root: git apply -p2 --directory=${codegenPrefix} ${patch}/patch"
                )}
              } >&2
              exit 1
            ''
        );
in
{
  inherit
    compareModuleVersions
    compareGoVersions
    drift
    driftCheck
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
