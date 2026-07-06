# Regression test for amarbel-llc/igloo#48: a go.mod mixing a
# single-line `require X Y` with a `require ( … )` block must parse.
# Build with: nix-build pkgs/build-support/gomod2nix/parser-mixed-require-test.nix
#
# `go mod tidy` legitimately emits this shape (indirect deps as
# standalone requires next to the grouped block) — live reproduction:
# amarbel-llc/crap@35203a6 go-crap/go.mod. Before the fix:
#   - single-line first, block second → "expected a set but found a
#     string" (the single-line require clobbered the default set with
#     a raw string; the block entry's `//`-merge then threw);
#   - block first, single-line second → SILENT data loss (the string
#     assignment clobbered the accumulated set).
{ pkgs ? import ../../.. { } }:
let
  inherit (import ./parser.nix) parseGoMod;

  # The reported shape: single-line indirect require, then a block.
  mixedSingleThenBlock = parseGoMod ''
    module example.com/consumer

    go 1.26

    require golang.org/x/text v0.34.0 // indirect

    require (
    	github.com/charmbracelet/bubbles v1.0.0
    	github.com/other/dep v0.2.0 // indirect
    )
  '';

  # Reverse order — also valid go.mod, previously lost the block set.
  mixedBlockThenSingle = parseGoMod ''
    module example.com/consumer

    go 1.26

    require (
    	github.com/charmbracelet/bubbles v1.0.0
    )

    require golang.org/x/text v0.34.0 // indirect
  '';

  # Pure single-line file (previously rescued by normaliseDirectives;
  # must keep working through the new accumulate-from-the-start path).
  pureSingleLine = parseGoMod ''
    module example.com/consumer

    go 1.26

    require golang.org/x/text v0.35.0
  '';

  # exclude has the same dual syntax; replace single-line must stay on
  # its dedicated branch; go/module stay scalar.
  kitchenSink = parseGoMod ''
    module example.com/consumer

    go 1.26

    exclude example.com/bad v0.9.0

    exclude (
    	example.com/worse v0.8.0
    )

    require golang.org/x/text v0.34.0

    replace example.com/bad => example.com/good v1.0.0
  '';

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "parser-mixed-require-tests"
  {
    _ignored = [
      # #48 reported shape: both forms land in one require set.
      (assert' "#48 single-then-block: single-line dep present"
        (mixedSingleThenBlock.require."golang.org/x/text" or null == "v0.34.0"))
      (assert' "#48 single-then-block: block deps present"
        (mixedSingleThenBlock.require."github.com/charmbracelet/bubbles" or null == "v1.0.0"))
      (assert' "#48 single-then-block: block indirect dep present"
        (mixedSingleThenBlock.require."github.com/other/dep" or null == "v0.2.0"))
      (assert' "#48 single-then-block: exactly the three deps"
        (builtins.length (builtins.attrNames mixedSingleThenBlock.require) == 3))

      # #48 reverse order: the block set survives the later single-line.
      (assert' "#48 block-then-single: block dep present"
        (mixedBlockThenSingle.require."github.com/charmbracelet/bubbles" or null == "v1.0.0"))
      (assert' "#48 block-then-single: single-line dep present"
        (mixedBlockThenSingle.require."golang.org/x/text" or null == "v0.34.0"))

      # Pure single-line file still yields a set.
      (assert' "#48 pure single-line: set shape preserved"
        (pureSingleLine.require."golang.org/x/text" or null == "v0.35.0"))

      # exclude mixes the same way; replace + scalars unaffected.
      (assert' "#48 exclude: single-line + block merge"
        (kitchenSink.exclude."example.com/bad" or null == "v0.9.0"
          && kitchenSink.exclude."example.com/worse" or null == "v0.8.0"))
      (assert' "#48 replace: single-line replace keeps its dedicated shape"
        (kitchenSink.replace."example.com/bad" or null == {
          goPackagePath = "example.com/good";
          version = "v1.0.0";
        }))
      (assert' "#48 scalars: module and go stay strings"
        (kitchenSink.module == "example.com/consumer" && kitchenSink.go == "1.26"))
    ];
  }
  ''
    touch $out
  ''
