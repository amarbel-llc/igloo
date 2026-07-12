# Regression test for amarbel-llc/igloo#58 — depth-N transitive resolution of
# passthru.goFlakeInputs with the mixed-rev conflict-guardrail. Exercises
# resolveGoFlakeInputs, which replaced the depth-1-only inheritedGoFlakeInputs
# (amends RFC 0001 § Depth-N with conflict-guardrail).
# Build with: nix-build pkgs/build-support/gomod2nix/transitive-inheritance-test.nix
{ pkgs ? import ../../.. { } }:
let
  inherit (pkgs.callPackage ./internals.nix { }) resolveGoFlakeInputs;

  mkProd = name: passthru: pkgs.runCommand name { passthru.goFlakeInputs = passthru; } "mkdir -p $out";

  # (a) Depth-2 chain: consumer bridges A; A bridges B; B bridges C (subPath).
  # C is two producers deep — unreachable under the old depth-1 limit.
  cSrc = pkgs.runCommand "chain-c-src" { } "mkdir -p $out/go-c";
  prodB = mkProd "chain-prod-b" { "example.com/c" = { src = cSrc; subPath = "go-c"; }; };
  prodA = mkProd "chain-prod-a" { "example.com/b" = prodB; };
  chain = resolveGoFlakeInputs { "example.com/a" = prodA; };

  # (b)/(c) two producers bridge the SAME module at DIFFERENT srcs.
  xSrcA = pkgs.runCommand "x-src-a" { } "mkdir -p $out";
  xSrcB = pkgs.runCommand "x-src-b" { } "mkdir -p $out";
  prodP = mkProd "prod-p" { "example.com/x" = xSrcA; };
  prodQ = mkProd "prod-q" { "example.com/x" = xSrcB; };

  # (b) A consumer declaration for X (depth 0) is authoritative — no conflict.
  declaredWins = resolveGoFlakeInputs {
    "example.com/p" = prodP; # inherits X = xSrcA
    "example.com/x" = xSrcB; # consumer picks xSrcB
  };

  # (c) No consumer declaration + two inherited srcs for X -> throw. tryEval
  # forcing the conflicting entry to WHNF triggers resolveOne's throw.
  conflict = builtins.tryEval (
    (resolveGoFlakeInputs {
      "example.com/p" = prodP;
      "example.com/q" = prodQ;
    })."example.com/x"
  );

  # (d) Cycle: A bridges B, B bridges A. passthru is metadata (not a build
  # input), so the mutual reference is fine; genericClosure dedups by
  # (modPath, src) so the walk terminates.
  cyclePair = rec {
    a = pkgs.runCommand "cycle-a" { passthru.goFlakeInputs = { "example.com/cb" = b; }; } "mkdir -p $out";
    b = pkgs.runCommand "cycle-b" { passthru.goFlakeInputs = { "example.com/ca" = a; }; } "mkdir -p $out";
  };
  cycle = resolveGoFlakeInputs { "example.com/ca" = cyclePair.a; };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "transitive-inheritance-test"
  {
    _ignored = [
      # (a) depth-2: A, its direct B, and B's transitive C all resolve.
      (assert' "#58 depth-2: consumer-declared A present" (builtins.hasAttr "example.com/a" chain))
      (assert' "#58 depth-2: depth-1 B inherited" (builtins.hasAttr "example.com/b" chain))
      (assert' "#58 depth-2: depth-2 C inherited (past the old depth-1 limit)"
        (builtins.hasAttr "example.com/c" chain))
      (assert' "#58 depth-2: C's subPath preserved through the chain"
        (chain."example.com/c".subPath == "go-c"))

      # (b) consumer declaration wins over the inherited P->X entry.
      (assert' "#58 consumer-wins: explicit X overrides an inherited src"
        (declaredWins."example.com/x".src == xSrcB))

      # (c) unaligned multi-rev conflict throws.
      (assert' "#58 conflict: two srcs for one module with no consumer decl throws"
        (conflict.success == false))

      # (d) cycle terminates and yields both modules.
      (assert' "#58 cycle: terminates with both modules"
        (builtins.hasAttr "example.com/ca" cycle && builtins.hasAttr "example.com/cb" cycle))
    ];
  }
  ''
    touch $out
  ''
