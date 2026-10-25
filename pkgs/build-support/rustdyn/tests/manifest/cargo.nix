# The rustdyn `manifest` fixture: the `multi` workspace (greet lib <- app bin
# with a build script) with no tracked Cargo.toml or Cargo.lock — cargo.nix is
# the manifest (FDR 0009 stage 2.5). The tables are cargo's own, as Nix;
# `member = true` is the one Nix-only key here (rendered to a relative path
# dependency). `package.version` is left out of both members so the renderer
# fills it from version.env (1.2.3).
{
  workspace = {
    workspace = {
      resolver = "2";
      members = [
        "app"
        "greet"
      ];
    };
  };

  members = {
    greet = {
      package = {
        name = "greet";
        edition = "2021";
      };
    };
    app = {
      package = {
        name = "app";
        edition = "2021";
      };
      dependencies.greet = {
        member = true;
      };
    };
  };

  # Cargo.lock as data: two path packages, no registry crate (so this fixture
  # needs no network). Members' versions are filled in like package.version.
  lock = {
    version = 4;
    package = [
      {
        name = "app";
        dependencies = [ "greet" ];
      }
      { name = "greet"; }
    ];
  };

  flakeInputs = { };
}
