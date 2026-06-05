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
  buildGodynModule,
  buildGoApplication,
}:
{
  pname,
  src,
  graphFile, # committed graph.json (godyn backend)
  modules ? null, # gomod2nix.toml — both backends (bga builds from it; godyn derives its vendorEnv)
  version ? null,
  ldflags ? [ ],
  ldflagsX ? { },
  strategy ? "native",
  # Escape hatches for backend-specific args that don't overlap:
  #   nativeArgs — extra buildGodynModule args (vendorEnv, cc, bridges, pwd, ...)
  #   bgaArgs    — extra buildGoApplication args (subPackages, go, GOTOOLCHAIN, ...)
  nativeArgs ? { },
  bgaArgs ? { },
}:
let
  common =
    { inherit pname src ldflags ldflagsX; }
    // lib.optionalAttrs (version != null) { inherit version; }
    // lib.optionalAttrs (modules != null) { inherit modules; };

  native = buildGodynModule (common // { inherit graphFile; } // nativeArgs);
  bga = buildGoApplication (common // bgaArgs);

  backend =
    if lib.elem strategy [ "native" "dev" ] then
      "native"
    else if lib.elem strategy [ "bga" "ci" ] then
      "bga"
    else
      throw "buildGoAuto: unknown strategy '${strategy}' (one of: native, dev, bga, ci)";

  chosen = if backend == "native" then native else bga;
in
chosen.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit native bga strategy backend;
  };
})
