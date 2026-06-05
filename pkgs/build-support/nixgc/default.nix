# nixgc — targeted Nix store GC CLI (extracted + generalized from spinclass's
# internal/nixgc, igloo#28). Zero third-party deps -> buildGoModule vendorHash=null.
{ buildGoModule }:
buildGoModule {
  pname = "nixgc";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  meta = {
    description = "Targeted Nix store garbage collection: reap the dead subgraph anchored at given store paths";
    mainProgram = "nixgc";
  };
}
