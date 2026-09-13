# buildGoAuto — pick the Go build backend by intent.
#
# The crossover finding (godyn POC) is that the axis is edit *locality*, not module
# size: godyn's per-package eval-time graph rebuilds only the dependency cone (wins
# the incremental dev/test loop, since a nix buildGoApplication has NO incremental
# and re-runs the whole `go build` on every edit), while buildGoApplication's single
# derivation wins cold / CI / release builds (no per-package overhead, in-process
# parallelism). A pure flake can't read the environment, so selection is an explicit
# `strategy` knob a consumer picks:
#
#   strategy = "native" | "dev"  -> buildGodynModule   (per-package CA, dev loop)
#   strategy = "bga"    | "ci"   -> buildGoApplication (whole module, cold/CI)
#
# Both backends are always built-reachable via passthru, so either can be forced
# without re-plumbing: `result.passthru.native`, `result.passthru.bga`.
{
  lib,
  stdenv,
  buildGodynModule,
  buildGoApplication,
  buildGoRace,
  godynSystems,
}:
{
  pname,
  src,
  graphFile ? null, # committed graph.json (godyn backend, single platform)
  graphFiles ? null, # { "<system>" = ./godyn-graph.<system>.json; … } — per-system graphs (igloo#33)
  modules ? null, # gomod2nix.toml — both backends (bga builds from it; godyn derives its vendorEnv)
  # RFC 0001 flake-input bridges, declared once for both backends (igloo#69). Generate
  # the godyn graph against the matching merged go.mod: `godyn-gen -gomod
  # <result.passthru.bga.passthru.mergedGoMod> …` (igloo#67).
  goFlakeInputs ? { },
  version ? null,
  ldflags ? [ ],
  ldflagsX ? { },
  # Install step, declared once for both backends: bga runs it as its own
  # postInstall; godyn in a separate install derivation (see buildGodynModule).
  postInstall ? "",
  nativeBuildInputs ? [ ],
  # subPackages: the main packages to build, declared once for both backends
  # (module-relative dirs); null = all of them.
  subPackages ? null,
  # Explicit binary names keyed by main-package dir ("cmd/foo", "."), declared once
  # and applied on BOTH backends (godyn natively, bga by renaming ahead of
  # postInstall); unnamed mains are named like `go install` on both.
  binaryNames ? { },
  # Go build tags, declared once for both backends (see buildGodynModule).
  tags ? [ ],
  # Tools on PATH for tests, declared once: bga's check phase, godyn's test runs.
  nativeCheckInputs ? [ ],
  # godyn-only test run trees (see buildGodynModule): bga's `go test` already runs
  # inside the module tree, so these only reach the godyn backend.
  testFiles ? { },
  testModuleTree ? false,
  testPreRun ? "",
  testFlags ? [ ],
  # -race on both backends: godyn natively (buildGodynModule race), bga through
  # buildGoRace (race binaries + `go test -race` checkPhase).
  race ? false,
  # cgo inputs, declared once for both backends (see buildGodynModule).
  buildInputs ? [ ],
  CGO_CFLAGS ? "",
  CGO_LDFLAGS ? "",
  # Default: godyn ("native") on every system in godynSystems — all systems igloo
  # supports — and buildGoApplication only elsewhere. Consumers don't pin a strategy
  # or hard-code a system; gates key off passthru.backend.
  strategy ? if lib.elem stdenv.hostPlatform.system godynSystems then "native" else "bga",
  # Escape hatches for backend-specific args that don't overlap:
  #   nativeArgs — extra buildGodynModule args (vendorEnv, cc, bridges, pwd, ...)
  #   bgaArgs    — extra buildGoApplication args (subPackages, go, GOTOOLCHAIN, ...)
  nativeArgs ? { },
  bgaArgs ? { },
}:
let
  common = {
    inherit
      pname
      src
      ldflags
      ldflagsX
      goFlakeInputs
      ;
  }
  // lib.optionalAttrs (version != null) { inherit version; }
  // lib.optionalAttrs (modules != null) { inherit modules; }
  // lib.optionalAttrs (postInstall != "") { inherit postInstall; }
  // lib.optionalAttrs (nativeBuildInputs != [ ]) { inherit nativeBuildInputs; }
  // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
  // lib.optionalAttrs (tags != [ ]) { inherit tags; }
  // lib.optionalAttrs (nativeCheckInputs != [ ]) { inherit nativeCheckInputs; }
  // lib.optionalAttrs (buildInputs != [ ]) { inherit buildInputs; }
  // lib.optionalAttrs (CGO_CFLAGS != "") { inherit CGO_CFLAGS; }
  // lib.optionalAttrs (CGO_LDFLAGS != "") { inherit CGO_LDFLAGS; };

  # bga names binaries like `go install`; rename the overridden ones first so the
  # caller's postInstall sees the final names, as it does under godyn.
  bgaRenames = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      d: name:
      let
        dir = lib.removeSuffix "/" (lib.removePrefix "./" d);
      in
      if dir == "." then
        ''mv "$out/bin/$(awk '$1 == "module" { n = split($2, p, "/"); print p[n]; exit }' go.mod)" "$out/bin/${name}"''
      else
        ''mv "$out/bin/${baseNameOf dir}" "$out/bin/${name}"''
    ) binaryNames
  );

  native = buildGodynModule (
    common
    // {
      inherit graphFile graphFiles;
    }
    // lib.optionalAttrs (binaryNames != { }) { inherit binaryNames; }
    // lib.optionalAttrs (testFiles != { }) { inherit testFiles; }
    // lib.optionalAttrs testModuleTree { inherit testModuleTree; }
    // lib.optionalAttrs (testPreRun != "") { inherit testPreRun; }
    // lib.optionalAttrs (testFlags != [ ]) { inherit testFlags; }
    // lib.optionalAttrs race { inherit race; }
    // nativeArgs
  );
  bgaBase = buildGoApplication (
    common
    // lib.optionalAttrs (binaryNames != { }) { postInstall = bgaRenames + "\n" + postInstall; }
    // bgaArgs
  );
  bga =
    if race then
      buildGoRace {
        base = bgaBase;
        inherit tags;
      }
    else
      bgaBase;

  backend =
    if
      lib.elem strategy [
        "native"
        "dev"
      ]
    then
      "native"
    else if
      lib.elem strategy [
        "bga"
        "ci"
      ]
    then
      "bga"
    else
      throw "buildGoAuto: unknown strategy '${strategy}' (one of: native, dev, bga, ci)";

  chosen = if backend == "native" then native else bga;
in
chosen.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit
      native
      bga
      strategy
      backend
      ;
  };
})
