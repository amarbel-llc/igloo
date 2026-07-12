{ }:
let
  sentinelPseudoVersion = "v0.0.0-00010101000000-000000000000";

  # Eval-time capability signal for the goFlakeInputs bridge
  # (amarbel-llc/igloo#56): a monotonic `version` plus greppable `features`
  # tags so a consumer can answer "is fix X present at my igloo pin?" by
  # eval alone — via the overlay-level `bridgeCapabilities` or a build's
  # `passthru.bridge` — instead of walking this file's git history.
  #
  # MAINTENANCE: when the bridge gains an observable behavior, add a
  # `features` tag AND bump `version`. Tags are stable identifiers keyed to
  # the issue that introduced the behavior.
  bridgeCapabilities = {
    version = 2;
    features = [
      "per-vn-sentinel" # #38 — major-aware require sentinel
      "conditional-require" # #39/82f3d8e — organic require kept, sentinel-free
      "transitive-passthru-inheritance" # #58 — depth-N passthru inheritance (was depth-1, #36)
      "inheritance-conflict-guardrail" # #58 — hard error on unaligned multi-rev inheritance
      "gomod2nix-toml-union" # #50 — union + bridged-key strip
      "workspace-root-toml-fallback" # #49 — subPath producer falls back to root toml
      "coverage-warning" # #45 — advisory uncovered-require trace
      "workspace-mode" # #39 — experimental go.work overlay
      "failure-annotation" # #55 — annotated go mod edit failures
    ];
  };

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
      # Consumer-declared module paths (vs depth-1-inherited ones), used
      # only to label provenance in the annotated failure message. Defaults
      # to every key so direct callers passing a flat map read as
      # all-declared. See amarbel-llc/igloo#55.
      declaredKeys ? builtins.attrNames goFlakeInputs,
    }:
    runCommand "merged-go.mod"
      {
        buildInputs = [ go ];
      }
      (
        let
          normalized = builtins.mapAttrs (_: normalizeFlakeInput) goFlakeInputs;
          provenanceOf =
            modPath:
            if builtins.elem modPath declaredKeys then
              "consumer-declared"
            else
              "inherited (via a bridged producer passthru.goFlakeInputs)";
          editCommands = builtins.concatStringsSep "\n" (
            builtins.attrValues (
              builtins.mapAttrs (
                modPath: v:
                let
                  target = "${v.src}${if v.subPath == "" then "" else "/${v.subPath}"}";
                  provenance = provenanceOf modPath;
                  sentinel = sentinelFor modPath;
                  # The synthetic require is injected only for modules the
                  # consumer does not organically require (its real version
                  # otherwise stands). See amarbel-llc/igloo#39.
                  requireBlock =
                    if builtins.elem modPath consumerRequires then
                      "" # consumer already requires it — keep the real version, no sentinel
                    else
                      ''
                        if ! go mod edit -require=${modPath}@${sentinel}; then
                          gomod2nix_bridge_fail '${modPath}' '${provenance}' 'require' '${sentinel}'
                        fi
                      '';
                in
                ''
                  # ${modPath} (${provenance})
                  ${requireBlock}
                  if ! go mod edit -replace=${modPath}=${target}; then
                    gomod2nix_bridge_fail '${modPath}' '${provenance}' 'replace' '${target}'
                  fi
                ''
              ) normalized
            )
          );
        in
        ''
          # Annotate any `go mod edit` failure inside the bridge with the
          # offending bridged module, its provenance, the synthesized
          # sentinel, and where to inspect the merged go.mod — instead of the
          # bare `go mod edit` stderr through the IFD. See amarbel-llc/igloo#55.
          gomod2nix_bridge_fail() {
            local mod="$1" provenance="$2" op="$3" detail="$4"
            {
              echo "gomod2nix goFlakeInputs bridge: 'go mod edit -$op' failed for bridged module '$mod'."
              echo "  provenance: $provenance"
              if [ "$op" = require ]; then
                echo "  synthetic require sentinel: $detail (injected because the consumer does not organically require this module)"
                echo "  a 'should be vN, not vM' error here means the module's /vN major and the sentinel major disagree (see amarbel-llc/igloo#38)."
              else
                echo "  replace target: $detail"
              fi
              echo "  NOTE: if the failing module differs from one you bridged, your own go.mod may carry an"
              echo "        invalid organic require that 'go mod edit' re-validates while editing this one."
              echo "  inspect the merged go.mod:  nix build .#<pkg>.passthru.mergedGoMod && cat result"
            } >&2
            exit 1
          }

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

  # Resolve a consumer's `goFlakeInputs` into the COMPLETE effective map by
  # walking each producer's `passthru.goFlakeInputs` transitively (depth-N),
  # returning normalized `{ <modPath> = { src; subPath; }; }` entries — or
  # throwing on an unaligned multi-rev conflict. This amends the former
  # depth-1 limit (RFC 0001 § Depth-N with conflict-guardrail,
  # amarbel-llc/igloo#58).
  #
  # Resolution rule (order-independent — does NOT rely on traversal order):
  #   - A consumer-declared entry (depth 0, unique per module path) is
  #     authoritative and wins over any inherited entry for the same module.
  #   - Otherwise every inherited src for a module MUST agree. Two distinct
  #     srcs for one module with no consumer declaration is a mixed-rev
  #     closure — throw with a `follows` directive instead of silently
  #     picking one (this is exactly the hazard the depth-1 limit avoided;
  #     the guardrail lets recursion be safe).
  #
  # Cycle-safe via `builtins.genericClosure`: the closure dedups by
  # (modPath, src), so a producer cycle (A bridges B, B bridges A) revisits
  # an already-seen node and terminates.
  #
  # Both entry shapes (bare derivation, `{ src; subPath; }` record) are
  # accepted at every level; a producer without `passthru.goFlakeInputs`
  # contributes nothing and never throws.
  resolveGoFlakeInputs =
    consumerGoFlakeInputs:
    let
      toNode =
        depth: modPath: value:
        let
          n = normalizeFlakeInput value;
          # `\n` cannot appear in a module path, store path, or subPath, so it
          # is a collision-free separator for the genericClosure dedup key.
          srcId = "${toString n.src}\n${n.subPath}";
        in
        {
          key = "${modPath}\n${srcId}";
          inherit modPath depth;
          inherit (n) src subPath;
        };

      startSet = builtins.attrValues (builtins.mapAttrs (toNode 0) consumerGoFlakeInputs);

      closure =
        if startSet == [ ] then
          [ ]
        else
          builtins.genericClosure {
            inherit startSet;
            operator =
              node:
              builtins.attrValues (
                builtins.mapAttrs (toNode (node.depth + 1)) (node.src.passthru.goFlakeInputs or { })
              );
          };

      byModPath = builtins.foldl' (
        acc: node: acc // { ${node.modPath} = (acc.${node.modPath} or [ ]) ++ [ node ]; }
      ) { } closure;

      resolveOne =
        modPath: nodes:
        let
          consumerNodes = builtins.filter (n: n.depth == 0) nodes;
        in
        # Consumer declaration wins (unique per module path).
        if consumerNodes != [ ] then
          { inherit (builtins.head consumerNodes) src subPath; }
        # genericClosure deduped by (modPath, src), so >1 node here means >1
        # distinct src for this module — an unaligned mixed-rev conflict.
        else if builtins.length nodes == 1 then
          { inherit (builtins.head nodes) src subPath; }
        else
          throw (
            "gomod2nix goFlakeInputs: module '${modPath}' is bridged at "
            + "${toString (builtins.length nodes)} different revs via inherited "
            + "passthru.goFlakeInputs, with no consumer declaration to pick one:\n"
            + builtins.concatStringsSep "\n" (
              map (n: "  - ${toString n.src}${if n.subPath == "" then "" else "/${n.subPath}"}") nodes
            )
            + "\nAlign the producers' shared view with a Nix flake `follows` "
            + "(e.g. inputs.<producer>.inputs.<shared>.follows = \"<shared>\"), or "
            + "declare '${modPath}' explicitly in goFlakeInputs — a direct "
            + "declaration wins over any inherited one. See RFC 0001 § Depth-N "
            + "with conflict-guardrail (amarbel-llc/igloo#58)."
          );
    in
    builtins.mapAttrs resolveOne byModPath;

  # Advisory coverage check (amarbel-llc/igloo#45, RFC 0001 § Chains
  # deeper than one level, duty C): for each bridged producer whose
  # go.mod is readable at eval, report its "private-looking" requires
  # that nothing in the consumer's effective bridge map covers.
  #
  # "Private-looking" is a self-configuring heuristic: a require whose
  # host/org prefix (first two path elements) matches the prefix of any
  # bridged module. Bridged modules are exactly the ones this fork
  # cannot fetch from a proxy, so their org prefixes are the private
  # namespace(s) in play — no hardcoded org list.
  #
  # A require escapes the report when it is covered by the effective
  # map (bridged, directly or via depth-1 inheritance) or listed in
  # `pinnedModules` (present in the merged gomod2nix.toml `mod` table,
  # i.e. fetchable and pinned like any external). Producers without a
  # readable go.mod contribute nothing and never throw — same tolerance
  # as the gomod2nix.toml union.
  #
  # Returns a list of { producer, missing } for producers with at least
  # one uncovered require. Pure; the caller decides how to surface it
  # (mkMergedView emits an eval-time trace warning).
  goFlakeInputsCoverageGaps =
    {
      effectiveGoFlakeInputs,
      parseGoMod,
      pinnedModules ? [ ],
    }:
    let
      normalized = builtins.mapAttrs (_: normalizeFlakeInput) effectiveGoFlakeInputs;
      bridgedPaths = builtins.attrNames normalized;

      # host/org prefix: the first two path elements ("github.com/org").
      # Falls back to the whole path for single-element module paths.
      prefixOf =
        modPath:
        let
          m = builtins.match "([^/]+/[^/]+).*" modPath;
        in
        if m == null then modPath else builtins.head m;

      privatePrefixes = builtins.foldl' (
        acc: p: if builtins.elem (prefixOf p) acc then acc else acc ++ [ (prefixOf p) ]
      ) [ ] bridgedPaths;

      gapsFor =
        producerPath: v:
        let
          goModPath = "${v.src}${if v.subPath == "" then "" else "/${v.subPath}"}/go.mod";
          requires =
            if builtins.pathExists goModPath then
              builtins.attrNames ((parseGoMod (builtins.readFile goModPath)).require or { })
            else
              [ ];
        in
        {
          producer = producerPath;
          missing = builtins.filter (
            r:
            builtins.elem (prefixOf r) privatePrefixes
            && !builtins.elem r bridgedPaths
            && !builtins.elem r pinnedModules
          ) requires;
        };
    in
    builtins.filter (g: g.missing != [ ]) (
      builtins.attrValues (builtins.mapAttrs gapsFor normalized)
    );

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

      # Resolve the consumer's goFlakeInputs transitively (depth-N) across each
      # producer's passthru.goFlakeInputs — consumer-declared entries are
      # authoritative and any unaligned multi-rev conflict throws. Degenerates
      # to the consumer's own map when no producer exposes passthru. See
      # resolveGoFlakeInputs (RFC 0001 § Depth-N with conflict-guardrail, #58).
      effectiveGoFlakeInputs = resolveGoFlakeInputs goFlakeInputs;
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
            # Consumer's pre-inheritance keys, so mkMergedGoMod's failure
            # annotation labels depth-1-inherited entries correctly (#55).
            declaredKeys = builtins.attrNames goFlakeInputs;
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
            moduleToml = "${v.src}${if v.subPath == "" then "" else "/${v.subPath}"}/gomod2nix.toml";
            # go.work workspace producers keep ONE shared lockfile at
            # the workspace root, so a subPath slice often has no toml
            # of its own. Fall back to the root lockfile so the
            # producer's pins (e.g. purse-first's tommy pin, required
            # by the bridged dewey module) reach subPath consumers.
            # A toml at the subPath itself stays authoritative.
            # See amarbel-llc/igloo#49.
            rootToml = "${v.src}/gomod2nix.toml";
            path =
              if builtins.pathExists moduleToml then
                moduleToml
              else if v.subPath != "" && builtins.pathExists rootToml then
                rootToml
              else
                null;
          in
          if path != null then builtins.fromTOML (builtins.readFile path) else { mod = { }; }
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

      # #45 advisory coverage: private-looking producer requires that
      # neither the effective map nor the merged mod table covers. A
      # non-empty result surfaces as an eval-time trace warning below;
      # the data itself is exposed for tests and tooling.
      coverageGaps =
        if hasFlakeInputs then
          goFlakeInputsCoverageGaps {
            inherit effectiveGoFlakeInputs parseGoMod;
            pinnedModules = builtins.attrNames (modulesStruct.mod or { });
          }
        else
          [ ];

      coverageWarning = builtins.concatStringsSep "; " (
        map (
          g:
          "bridged producer ${g.producer} requires private module(s) not covered by the "
          + "effective goFlakeInputs: ${builtins.concatStringsSep ", " g.missing}"
        ) coverageGaps
      );

      # Eval-time bridge introspection (amarbel-llc/igloo#56/#57): the
      # capability signal plus a per-module report — provenance, the
      # sentinel-vs-organic decision, and subPath — and the coverage gaps.
      # Pure eval (no IFD), so a consumer runs `nix eval
      # .#<pkg>.passthru.bridge --json` without a build. The per-module
      # sentinel/organic decision mirrors mkMergedGoMod's (sentinelFor + the
      # consumerRequires check) so the report matches the merged go.mod.
      bridgeReport =
        let
          declaredKeys = builtins.attrNames goFlakeInputs;
          consumerRequires = builtins.attrNames (consumerGoMod.require or { });
        in
        {
          inherit (bridgeCapabilities) version features;
          mode = goFlakeInputsMode;
          modules = builtins.mapAttrs (
            modPath: v: {
              provenance = if builtins.elem modPath declaredKeys then "declared" else "inherited";
              inherit (v) subPath;
              organicRequire = builtins.elem modPath consumerRequires;
              sentinel =
                if goFlakeInputsMode != "replace" || builtins.elem modPath consumerRequires then
                  null
                else
                  sentinelFor modPath;
            }
          ) normalizedFlakeInputs;
          inherit coverageGaps;
        };

      result = {
        inherit
          consumerGoMod
          goMod
          modulesStruct
          mergedGoModFile
          workspaceBridge
          hasFlakeInputs
          normalizedFlakeInputs
          coverageGaps
          bridgeReport
          ;
      };
    in
    if coverageGaps == [ ] then
      result
    else
      builtins.trace (
        "warning: gomod2nix goFlakeInputs coverage (RFC 0001 duty C, amarbel-llc/igloo#45): "
        + coverageWarning
        + ". Declare them in goFlakeInputs or pin them in gomod2nix.toml; "
        + "the vendor step may otherwise fail to resolve them."
      ) result;
in
{
  inherit
    sentinelPseudoVersion
    sentinelFor
    normalizeFlakeInput
    resolveGoFlakeInputs
    goFlakeInputsCoverageGaps
    mkMergedGoMod
    mergeGomod2nixTomls
    mkMergedView
    bridgeCapabilities
    ;
}
