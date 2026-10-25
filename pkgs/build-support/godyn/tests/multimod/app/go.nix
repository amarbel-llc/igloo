# A go.nix module below the repository root (igloo#73): `app` is built with
# src = the repository (tests/multimod) and moduleDir = "app"; its sibling `sib`
# is a path replace that resolves inside the same tree. A path-replaced require
# carries no hash (nothing is fetched).
{
  module = "example.com/mm/app";
  go = "1.26";
  require."example.com/mm/sib" = {
    version = "v0.0.0-00010101000000-000000000000";
  };
  replace."example.com/mm/sib" = {
    path = "../sib";
  };
}
