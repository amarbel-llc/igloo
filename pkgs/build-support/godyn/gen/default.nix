# godyn-gen — the dev-time graph generator (go list -deps -json -> graph.json).
# Zero third-party deps (stdlib only), so a plain buildGoModule with
# vendorHash = null suffices — no gomod2nix.toml needed for this tool.
{ buildGoModule }:
buildGoModule {
  pname = "godyn-gen";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  meta = {
    description = "Dev-time graph generator for buildGodynModule (go list -deps -json -> graph.json)";
    mainProgram = "godyn-gen";
  };
}
