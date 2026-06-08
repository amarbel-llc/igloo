{ }:
let
  sentinelPseudoVersion = "v0.0.0-00010101000000-000000000000";

  # Pick the synthetic require sentinel for a module path. Go rejects
  # `go mod edit -require=<path>@<version>` when <path> ends in a
  # major-version suffix (/v2, /v3, …) whose major differs from
  # <version>'s — `version "v0.0.0-…" invalid: should be v2, not v0`.
  # The synthetic require is immediately shadowed by a -replace to the
  # local src, so the only constraint is that the major match. Derive
  # the sentinel's major from a trailing /vN (N ≥ 2); keep the v0
  # sentinel for unsuffixed paths and for the implicit-v0/v1 majors
  # (which never carry a suffix). See amarbel-llc/igloo#38.
  sentinelFor =
    modPath:
    let
      majorMatch = builtins.match ".*/v([0-9]+)" modPath;
      major = if majorMatch == null then null else builtins.head majorMatch;
    in
    if major != null && builtins.fromJSON major >= 2 then
      "v${major}.0.0-00010101000000-000000000000"
    else
      sentinelPseudoVersion;

  # Normalize a goFlakeInputs value into { src, subPath } form.
  # Accepts:
  #   - a derivation or path (subPath defaults to "")
  #   - an attrset already in { src, subPath } form
  normalizeFlakeInput =
    value:
    if value ? src then
      {
        inherit (value) src;
        subPath = value.subPath or "";
      }
    else
      {
        src = value;
        subPath = "";
      };

  # Build a go.mod that includes synthetic require + replace lines for
  # each entry in goFlakeInputs. Pure-eval derivation, no network.
  mkMergedGoMod =
    {
      consumerGoMod,
      go,
      goFlakeInputs,
      runCommand,
    }:
    runCommand "merged-go.mod"
      {
        buildInputs = [ go ];
      }
      (
        let
          normalized = builtins.mapAttrs (_: normalizeFlakeInput) goFlakeInputs;
          editCommands = builtins.concatStringsSep "\n" (
            builtins.attrValues (
              builtins.mapAttrs (
                modPath: v:
                let
                  target = "${v.src}${if v.subPath == "" then "" else "/${v.subPath}"}";
                in
                ''
                  go mod edit -require=${modPath}@${sentinelFor modPath}
                  go mod edit -replace=${modPath}=${target}
                ''
              ) normalized
            )
          );
        in
        ''
          # Go 1.24+ refuses to run `go mod edit` when go.mod lives directly in
          # /build (the sandbox temp root). A subdirectory satisfies the check.
          mkdir -p work
          cd work
          cp ${consumerGoMod} ./go.mod
          chmod +w ./go.mod  # store-path cp preserves read-only; `go mod edit` needs write access
          ${editCommands}
          cp ./go.mod $out
        ''
      );

  # Build the CONTENT of a go.work overlay that `use`s the consumer module
  # plus each goFlakeInputs producer (absolute store paths). This is the
  # Design A merge primitive (igloo#39): an alternative to mkMergedGoMod's
  # require+replace injection. Each producer's identity — including any /vN
  # major — comes from its own go.mod, so there is NO synthetic version and
  # NO sentinel (sentinelFor is unnecessary in this mode).
  #
  # Returns a string, not a derivation: go.work is plain generated text, so
  # the caller materializes it into the build sandbox directly (e.g. a
  # postPatch `cat > go.work`). `consumerUsePath` is the consumer module's
  # location in the build tree — "." for the in-sandbox source root; a
  # subdir (e.g. "go") for a polyglot layout.
  #
  # NOTE (igloo#39 spikes): bridged producers are resolved from source via
  # `use`; they are NOT vendored and MUST NOT appear in vendor/modules.txt.
  # Their external transitive deps still vendor normally — the consumer's
  # modulesStruct (with bridged keys stripped by mergeGomod2nixTomls) drives
  # mkWorkspaceModulesTxt's externalEntries, and `go build -mod=vendor`
  # consumes the nix-prebuilt vendor tree. Module-level `replace` is ignored
  # in workspace mode, so any resolution override must live in this go.work.
  mkMergedGoWork =
    {
      goVersion,
      goFlakeInputs,
      consumerUsePath ? ".",
    }:
    let
      targetOf =
        v:
        let
          n = normalizeFlakeInput v;
        in
        "${n.src}${if n.subPath == "" then "" else "/${n.subPath}"}";
      useTargets = [ consumerUsePath ] ++ builtins.attrValues (builtins.mapAttrs (_: targetOf) goFlakeInputs);
      useBlock = builtins.concatStringsSep "\n" (map (p: "\t${p}") useTargets);
    in
    ''
      go ${goVersion}

      use (
      ${useBlock}
      )
    '';

  # Read `passthru.goFlakeInputs` from each direct producer in a
  # consumer's `goFlakeInputs` map and union the inherited entries.
  # Depth-1 only — the helper MUST NOT recurse into inherited entries'
  # own passthru. Multi-level transitivity is deferred to the FOD-regen
  # path tracked at amarbel-llc/nixpkgs#36; until that lands, deep
  # closures resolve by the consumer declaring each direct producer's
  # flake input and aligning shared deps via Nix flake `follows` (see
  # RFC 0001 § Multi-producer closures).
  #
  # Both entry shapes from § Consumer interface are supported:
  #   - bare derivation → look at `.passthru.goFlakeInputs`
  #   - { src; subPath; } record → look at `.src.passthru.goFlakeInputs`
  # Producers without a `passthru.goFlakeInputs` attribute contribute
  # the empty map, never throw.
  #
  # The returned map is the *inherited* layer only; the caller layers
  # consumer-declared entries on top via `inherited // consumer` so
  # consumer wins on conflict per RFC 0001 § Producer-side passthru
  # inheritance.
  inheritedGoFlakeInputs =
    goFlakeInputs:
    builtins.foldl' (
      acc: entry:
      let
        src = if entry ? src then entry.src else entry;
        inherited = src.passthru.goFlakeInputs or { };
      in
      acc // inherited
    ) { } (builtins.attrValues goFlakeInputs);

  # Union the consumer's gomod2nix.toml with each flake input's. On
  # conflict (same Go module path in both), consumer wins.
  #
  # `bridgedKeys` lists Go module paths handled by goFlakeInputs.
  # Those keys MUST be removed from the merged `mod` table — they're
  # wired into vendor/ via `localReplaceCommands` (which reads
  # goMod.replace), so any entry in `modulesStruct.mod` would cause
  # mkVendorEnv's symlink.go to pre-populate the same path that the
  # synthetic `ln -s` then collides with. The leak comes from both
  # sides: the consumer's own gomod2nix.toml (if they didn't remove
  # the line) AND producer flake-inputs that pin the same module as
  # a transitive dep. See amarbel-llc/nixpkgs#50.
  mergeGomod2nixTomls =
    {
      consumer,
      flakeInputs,
      bridgedKeys ? [ ],
    }:
    let
      # Build a single merged attrset across all flake-input mods.
      # `//` is right-wins; in this fold, later flake inputs override
      # earlier ones. (For now we assume flake-input collisions are
      # rare — they'd indicate a deeper conflict the consumer should
      # resolve manually.)
      flakeInputMerged =
        builtins.foldl' (acc: t: acc // (t.mod or { })) { } flakeInputs;
      mergedRaw = flakeInputMerged // (consumer.mod or { });
    in
    {
      schema = consumer.schema or 3;
      mod = builtins.removeAttrs mergedRaw bridgedKeys;
    };

  # Build the merged view of a Go module graph: consumer's go.mod and
  # gomod2nix.toml merged with each flake-input's same-named files.
  # Returns the parsed pieces both callers (buildGoApplication, mkGoEnv)
  # need.
  #
  # When goFlakeInputs is empty, returns the consumer's organic data
  # verbatim (mergedGoModFile = null, hasFlakeInputs = false), so the
  # call site behaves exactly as it did before goFlakeInputs existed.
  #
  # `parseGoMod` is supplied by the caller to avoid a circular import
  # between this file and parser.nix.
  mkMergedView =
    {
      pwd,
      modules,
      goFlakeInputs,
      go,
      runCommand,
      parseGoMod,
      # "replace" (default): inject require+replace into a merged go.mod.
      # "workspace": synthesize a go.work overlay (Design A, igloo#39) — no
      # require/replace/sentinel; bridged producers resolve from source.
      goFlakeInputsMode ? "replace",
    }:
    let
      goModPath = "${toString pwd}/go.mod";
      consumerGoMod =
        if pwd != null && builtins.pathExists goModPath then
          parseGoMod (builtins.readFile goModPath)
        else
          null;

      # #36: union depth-1 passthru.goFlakeInputs from each direct
      # producer, with consumer-declared entries winning on conflict.
      # When no producers expose passthru, `inherited` is empty and
      # the merge degenerates to the consumer's own goFlakeInputs.
      effectiveGoFlakeInputs = inheritedGoFlakeInputs goFlakeInputs // goFlakeInputs;
      normalizedFlakeInputs = builtins.mapAttrs (_: normalizeFlakeInput) effectiveGoFlakeInputs;
      hasFlakeInputs = normalizedFlakeInputs != { };

      # Replace mode only: a merged go.mod with synthetic require+replace.
      mergedGoModFile =
        if goFlakeInputsMode == "replace" && hasFlakeInputs && consumerGoMod != null then
          mkMergedGoMod {
            consumerGoMod = pwd + "/go.mod";
            inherit go runCommand;
            goFlakeInputs = effectiveGoFlakeInputs;
          }
        else
          null;

      # Workspace mode (Design A): synthesized go.work overlay content. The
      # consumer go.mod is left untouched; producers resolve from source via
      # `use`, so there is no sentinel. The caller materializes this into the
      # build sandbox (postPatch `cp`). See igloo#39.
      mergedGoWork =
        if goFlakeInputsMode == "workspace" && hasFlakeInputs && consumerGoMod != null then
          mkMergedGoWork {
            goVersion = consumerGoMod.go;
            goFlakeInputs = effectiveGoFlakeInputs;
            consumerUsePath = ".";
          }
        else
          null;

      goMod =
        if mergedGoModFile != null then
          parseGoMod (builtins.readFile mergedGoModFile)
        else
          consumerGoMod;

      consumerModulesStruct =
        if modules == null then { } else builtins.fromTOML (builtins.readFile modules);

      flakeInputTomls = builtins.attrValues (
        builtins.mapAttrs (
          _: v:
          let
            path = "${v.src}${if v.subPath == "" then "" else "/${v.subPath}"}/gomod2nix.toml";
          in
          if builtins.pathExists path then builtins.fromTOML (builtins.readFile path) else { mod = { }; }
        ) normalizedFlakeInputs
      );

      modulesStruct =
        if hasFlakeInputs then
          mergeGomod2nixTomls {
            consumer = consumerModulesStruct;
            flakeInputs = flakeInputTomls;
            # Strip bridged keys so symlink.go doesn't pre-populate
            # vendor/<X> for modules that localReplaceCommands then
            # wires synthetically. See amarbel-llc/nixpkgs#50.
            bridgedKeys = builtins.attrNames normalizedFlakeInputs;
          }
        else
          consumerModulesStruct;
    in
    {
      inherit
        consumerGoMod
        goMod
        modulesStruct
        mergedGoModFile
        mergedGoWork
        hasFlakeInputs
        normalizedFlakeInputs
        ;
    };
in
{
  inherit
    sentinelPseudoVersion
    sentinelFor
    mkMergedGoWork
    normalizeFlakeInput
    inheritedGoFlakeInputs
    mkMergedGoMod
    mergeGomod2nixTomls
    mkMergedView
    ;
}
