# mkGeneratedSrc: run generators in derivation space, in order, over a go.nix
# module, with no igloo change. Each stage is a command run by godyn's existing
# passthru.codegenCheck machinery (vendored tree, rendered go.mod, offline, pure);
# its codegenPatch is applied to the stage's src to give the next stage's src.
# So stage N sees the output of stages 1..N-1, and the final src is a plain
# store tree that buildGodynModule/buildGoAuto consume (graph derived by IFD).
#
# Finding (verified): buildGodynModule is strict in the package graph (it decides
# mainPkg from it), and deriving the graph runs `go list` over the module, which
# fails on a tree whose imports are not generated yet (here: cfg imports the
# not-yet-generated pkgs/greeter facade). A codegen stage never needs the graph,
# so stage modules are given an EMPTY committed graph; only the final module
# derives its graph, from the fully generated tree.
{ pkgs }:
{
  pname,
  src,
  manifest,
  inputs ? { },
  version ? "0.0.0",
  # [ { name; command; nativeBuildInputs ? [ ]; } ] in run order
  stages,
  subPackages ? null,
}:
let
  inherit (pkgs) lib;
  common = {
    inherit
      pname
      version
      manifest
      inputs
      ;
  };
  emptyGraph = builtins.toFile "empty-graph.json" "[]";
  stageModule = s: pkgs.buildGodynModule (common // { src = s; graphFile = emptyGraph; });
  step =
    s: stage:
    let
      patch =
        ((stageModule s).passthru.codegenCheck {
          inherit (stage) command;
          nativeBuildInputs = stage.nativeBuildInputs or [ ];
        }).passthru.codegenPatch;
    in
    pkgs.runCommandLocal "${pname}-gen-${stage.name}" { nativeBuildInputs = [ pkgs.git ]; } ''
      cp -r --no-preserve=mode ${s} $out
      cd $out
      if [ -s ${patch}/patch ]; then git apply -p2 ${patch}/patch; fi
    '';
  stageSrcs = lib.foldl' (acc: stage: acc ++ [ (step (lib.last acc) stage) ]) [ src ] stages;
  generated = lib.last stageSrcs;
in
{
  inherit generated stageSrcs;
  module = pkgs.buildGodynModule (
    common
    // {
      src = generated;
    }
    // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
  );
}
