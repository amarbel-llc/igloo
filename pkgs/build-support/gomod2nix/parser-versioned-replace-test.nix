# Regression test for amarbel-llc/igloo#51: version-restricted replace
# directives (`replace mod v1.0.0 => target`) must parse with the BARE
# module path as the key and the LHS version recorded on the value.
# Build with: nix-build pkgs/build-support/gomod2nix/parser-versioned-replace-test.nix
#
# Before the fix: block form crashed in parseReplace ("expected a list
# but found null"); single-line form silently fused path+version into
# the attrset key ("example.com/a v1.0.0"), invisible to consumers that
# match replaces by module path.
{ pkgs ? import ../../.. { } }:
let
  inherit (import ./parser.nix) parseGoMod;

  blockVersioned = parseGoMod ''
    module example.com/consumer

    go 1.26

    replace (
    	example.com/a v1.0.0 => example.com/b v1.1.0
    )
  '';

  singleVersioned = parseGoMod ''
    module example.com/consumer

    go 1.26

    replace example.com/a v1.0.0 => example.com/b v1.1.0
  '';

  singleVersionedToPath = parseGoMod ''
    module example.com/consumer

    go 1.26

    replace example.com/a v1.0.0 => ../local
  '';

  # Unversioned forms must keep their exact pre-#51 shapes.
  unversioned = parseGoMod ''
    module example.com/consumer

    go 1.26

    replace example.com/a => example.com/b v1.1.0

    replace (
    	example.com/c => ../go-lib
    )
  '';

  expectedVersioned = {
    goPackagePath = "example.com/b";
    version = "v1.1.0";
    lhsVersion = "v1.0.0";
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "parser-versioned-replace-tests"
  {
    _ignored = [
      # #51: bare module path as key, LHS version on the value.
      (assert' "#51 block versioned-LHS: bare-path key, lhsVersion recorded"
        (blockVersioned.replace."example.com/a" or null == expectedVersioned))
      (assert' "#51 single-line versioned-LHS: same shape as block"
        (singleVersioned.replace."example.com/a" or null == expectedVersioned))
      (assert' "#51: no fused path+version key remains"
        (! singleVersioned.replace ? "example.com/a v1.0.0"))
      (assert' "#51 versioned-LHS to local path"
        (singleVersionedToPath.replace."example.com/a" or null == {
          path = "../local";
          lhsVersion = "v1.0.0";
        }))

      # Pre-#51 shapes preserved exactly (no lhsVersion attr).
      (assert' "#51 unversioned module target unchanged"
        (unversioned.replace."example.com/a" or null == {
          goPackagePath = "example.com/b";
          version = "v1.1.0";
        }))
      (assert' "#51 unversioned local-path target unchanged"
        (unversioned.replace."example.com/c" or null == { path = "../go-lib"; }))
    ];
  }
  ''
    touch $out
  ''
