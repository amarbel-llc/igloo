# Regression test for amarbel-llc/igloo#50: single-line use/tool/retract
# directives must accumulate like block entries (post-#48 residue).
# Build with: nix-build pkgs/build-support/gomod2nix/parser-single-line-directives-test.nix
#
# Before the fix:
#   - parseGoWork crashed on ANY single-line `use` ("expected a set but
#     found a string") — the exact shape `go work init ./a` emits;
#   - go.mod mixing single-line + block `tool` or `retract` crashed the
#     same way (single-line first) or silently lost the block set
#     (block first).
{ pkgs ? import ../../.. { } }:
let
  inherit (import ./parser.nix) parseGoMod parseGoWork;

  # What `go work init ./a` emits: one single-line use.
  workSingleUse = parseGoWork ''
    go 1.26

    use ./moduleA
  '';

  # Multiple single-line uses (`go work use` appends this way too).
  workTwoSingleUses = parseGoWork ''
    go 1.26

    use ./moduleA
    use ./moduleB
  '';

  # Mixed single-line + block use.
  workMixedUse = parseGoWork ''
    go 1.26

    use ./moduleA

    use (
    	./moduleB
    )
  '';

  # Mixed tool, single-line first (previously: crash).
  toolSingleThenBlock = parseGoMod ''
    module example.com/consumer

    go 1.26

    tool example.com/single/cmd/one

    tool (
    	example.com/block/cmd/two
    )
  '';

  # Mixed tool, block first (previously: silent loss of the block set).
  toolBlockThenSingle = parseGoMod ''
    module example.com/consumer

    go 1.26

    tool (
    	example.com/block/cmd/two
    )

    tool example.com/single/cmd/one
  '';

  # Mixed retract (producer yanking releases).
  retractMixed = parseGoMod ''
    module example.com/producer

    go 1.26

    retract v1.0.5

    retract (
    	v1.0.0
    	v1.0.1
    )
  '';

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "parser-single-line-directives-tests"
  {
    _ignored = [
      # #50 use: parseGoWork returns a LIST of paths in every form.
      (assert' "#50 use: one single-line use parses (go work init shape)"
        (workSingleUse.use == [ "./moduleA" ]))
      (assert' "#50 use: repeated single-line uses accumulate"
        (workTwoSingleUses.use == [ "./moduleA" "./moduleB" ]))
      (assert' "#50 use: single-line + block merge"
        (workMixedUse.use == [ "./moduleA" "./moduleB" ]))

      # #50 tool: both forms land in one set, either order.
      (assert' "#50 tool: single-then-block keeps both"
        (toolSingleThenBlock.tool ? "example.com/single/cmd/one"
          && toolSingleThenBlock.tool ? "example.com/block/cmd/two"))
      (assert' "#50 tool: block-then-single keeps both"
        (toolBlockThenSingle.tool ? "example.com/single/cmd/one"
          && toolBlockThenSingle.tool ? "example.com/block/cmd/two"))

      # #50 retract: both forms land in one set.
      (assert' "#50 retract: single-line + block merge"
        (retractMixed.retract ? "v1.0.5"
          && retractMixed.retract ? "v1.0.0"
          && retractMixed.retract ? "v1.0.1"))

      # Scalars unaffected.
      (assert' "#50 scalars: module and go stay strings"
        (toolSingleThenBlock.module == "example.com/consumer"
          && toolSingleThenBlock.go == "1.26"))
    ];
  }
  ''
    touch $out
  ''
