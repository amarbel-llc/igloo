# Fixture for godyn's `generators` (FDR 0014): nothing generated is tracked. The
# facade pkgs/hello (stage "facade") is imported by internal/cfg, and
# internal/cfg's cfg_gen.go (stage "cfg") is imported by the main package.
{
  module = "example.com/genstub";
  go = "1.26";
}
