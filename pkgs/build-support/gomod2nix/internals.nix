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
  #
  # The `-replace` is unconditional. The `-require` is injected ONLY for
  # modules the consumer's go.mod does not already require: when the consumer
  # organically requires a bridged module (the normal case — that's how the
  # dependency is declared), its real version stands and NO sentinel is
  # emitted. The synthetic require (with the /vN-aware sentinel) is the
  # fallback for the rare module bridged without an organic require, where the
  # replace would otherwise have nothing to bind to. `consumerRequires` is the
  # set of module paths the consumer already requires. See amarbel-llc/igloo#39.
  mkMergedGoMod =
    {
      consumerGoMod,
      go,
      goFlakeInputs,
      runCommand,
      consumerRequires ? [ ],
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
                  requireCmd =
                    if builtins.elem modPath consumerRequires then
                      "" # consumer already requires it — keep the real version, no sentinel
                    else
                      "go mod edit -require=${modPath}@${sentinelFor modPath}";
                in
                ''
                  ${requireCmd}
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
      # The synthetic require is skipped for modules the consumer already
      # requires (their real version stands — no sentinel); see mkMergedGoMod.
      mergedGoModFile =
        if goFlakeInputsMode == "replace" && hasFlakeInputs && consumerGoMod != null then
          mkMergedGoMod {
            consumerGoMod = pwd + "/go.mod";
            inherit go runCommand;
            goFlakeInputs = effectiveGoFlakeInputs;
            consumerRequires = builtins.attrNames (consumerGoMod.require or { });
          }
        else
          null;

      # Workspace mode (Design A, igloo#39): the consumer go.mod is left
      # untouched (no sentinel). The caller (mkGoWorkVendorEnv in default.nix)
      # synthesizes a go.work of `use .` + `replace`s and runs `go work
      # vendor`; it needs `normalizedFlakeInputs`, `modulesStruct`, and the
      # consumer go version. This flag just signals which path to take.
      workspaceBridge = goFlakeInputsMode == "workspace" && hasFlakeInputs && consumerGoMod != null;

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
        workspaceBridge
        hasFlakeInputs
        normalizedFlakeInputs
        ;
    };
in
{
  inherit
    sentinelPseudoVersion
    sentinelFor
    normalizeFlakeInput
    inheritedGoFlakeInputs
    mkMergedGoMod
    mergeGomod2nixTomls
    mkMergedView
    ;
}
