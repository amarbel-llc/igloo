# The sibling module of tests/multimod/app (igloo#73): a library with its own
# go.nix, reached by app's `replace … => ../sib`. Its go.mod is rendered into
# the tree by app's build.
{
  module = "example.com/mm/sib";
  go = "1.26";
}
