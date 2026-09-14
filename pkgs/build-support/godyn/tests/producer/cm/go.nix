# Consumer c as a go.nix module (FDR 0008), in the shape a migrated fleet module
# takes when a producer's INHERITED bridge shadows one of its requires: q is
# recorded as a third-party require (as `godyn-go -I` records an organic
# `// indirect` require), but p bridges q, so the RFC 0001 merge replaces q to
# the bridge and strips it from the vendor table. The hash is deliberately
# bogus: the build only succeeds if that vendor entry is never fetched.
{
  module = "example.com/c";
  go = "1.26";
  require."example.com/q" = {
    version = "v0.0.0";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    indirect = true;
  };
  flakeInputs."example.com/p".input = "p";
}
