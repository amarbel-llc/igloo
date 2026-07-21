# godyn v2 — buildGoAuto: pick the Go build backend by use case.
#
# The crossover sweep (README) showed the axis is edit *locality*, not module
# size: the native eval-time graph rebuilds only the dependency cone (wins the
# incremental dev/test loop, since a nix buildGoApplication has NO incremental and
# re-runs the whole `go build ./...` on every edit), while buildGoApplication's
# single derivation wins cold / CI / release builds (no per-package overhead,
# in-process parallelism). So selection is by intent:
#
#   strategy = "native" | "dev"  -> native eval-time graph (per-package CA)
#   strategy = "bga"    | "ci"   -> buildGoApplication (whole module)
#
# A pure flake can't read the environment, so `strategy` is an explicit knob; a
# consumer picks it (a dev shell / `just dev` uses native, a CI output uses bga).
# Both backends are always built-reachable via passthru, so either can be forced
# without re-plumbing: `result.passthru.native`, `result.passthru.bga`.
{
  lib,
  callPackage,
  buildGoApplication,
  go,
  stdlib,
  pname,
  src, # main module source (in-repo, for native's local packages)
  graphFile, # committed graph.json (native)
  modules, # gomod2nix.toml (buildGoApplication)
  vendorEnv ? null, # third-party vendor tree (native), null for all-local
  version ? "0",
  strategy ? "native",
}:
let
  native = callPackage ./native.nix {
    inherit
      go
      stdlib
      src
      graphFile
      vendorEnv
      pname
      ;
  };
  bga = buildGoApplication {
    inherit
      pname
      version
      src
      modules
      ;
  };

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
