{ buildGoApplication, pocLibSrc }:

buildGoApplication {
  pname = "goflake-poc-via-gomod2nix";
  version = "0.1.0";
  src = ./.;
  pwd = ./.;
  modules = ./gomod2nix.toml;
  subPackages = [ "." ];

  goFlakeInputs = {
    "github.com/poc/lib" = pocLibSrc;
  };
}
