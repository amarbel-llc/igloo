# Wraps the update-zx-deps.ts script in a Bun-invoking shell launcher.
#
# The script resolves and rewrites SRI hashes for ///!dep directives in
# zx scripts consumed by buildZxScriptFromFile. Two modes:
#
#   update-zx-deps <script.ts>           # resolve + rewrite in place
#   update-zx-deps --check <script.ts>   # verify hashes are current;
#                                        # nonzero exit if not (CI mode)
#
# The .ts script intentionally bypasses the buildBunBinary lint pass:
# it uses process.exit() throughout, which is the correct shape for a
# user-facing CLI but would fail n/no-process-exit. Wrapping via
# writeShellApplication + `exec bun <storepath>` runs the script under
# bun at invocation time without going through the lint pipeline.
#
# Ported from amarbel-llc/bun:scripts/update-zx-deps.ts as part of
# amarbel-llc/nixpkgs#57.
{
  pkgs,
  bun ? pkgs.bun,
}:

pkgs.writeShellApplication {
  name = "update-zx-deps";
  runtimeInputs = [ bun ];
  text = ''
    exec bun ${./update-zx-deps.ts} "$@"
  '';
}
