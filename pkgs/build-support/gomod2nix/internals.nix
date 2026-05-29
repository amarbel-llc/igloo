{ }:
let
  sentinelPseudoVersion = "v0.0.0-00010101000000-000000000000";

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
                  go mod edit -require=${modPath}@${sentinelPseudoVersion}
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

      mergedGoModFile =
        if hasFlakeInputs && consumerGoMod != null then
          mkMergedGoMod {
            consumerGoMod = pwd + "/go.mod";
            inherit go runCommand;
            goFlakeInputs = effectiveGoFlakeInputs;
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
        hasFlakeInputs
        normalizedFlakeInputs
        ;
    };
in
{
  inherit
    sentinelPseudoVersion
    normalizeFlakeInput
    inheritedGoFlakeInputs
    mkMergedGoMod
    mergeGomod2nixTomls
    mkMergedView
    ;
}
