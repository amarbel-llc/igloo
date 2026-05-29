{
  pkgs,
  pocLibSrc,
}:
# Smoke test: mkGoEnv accepts goFlakeInputs and produces a derivation
# whose vendor tree was built from the merged module graph. The
# returned derivation also exposes passthru.mergedGoMod so consumers
# can wire it into their devshell entry hooks.
pkgs.mkGoEnv {
  pwd = ./.;
  goFlakeInputs = {
    "github.com/poc/lib" = pocLibSrc;
  };
}
