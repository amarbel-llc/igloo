# Consumer of two bridged modules from ONE producer tree whose module paths
# nest (example.com/n/a and example.com/n/a/sub, at subPaths a and a/sub):
# purse-first's go-mcp + go-mcp/command/huh as spinclass bridges them
# (spinclass#157). The vendor tree must hold both.
{
  module = "example.com/cn";
  go = "1.26";
  flakeInputs."example.com/n/a" = {
    input = "n";
    subPath = "a";
  };
  flakeInputs."example.com/n/a/sub" = {
    input = "n";
    subPath = "a/sub";
  };
}
