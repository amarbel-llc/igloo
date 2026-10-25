# Packages added by amarbel-llc/igloo that don't exist in upstream.
# Lives here (not all-packages.nix) so upstream merges never conflict.
final: _: {
  fetchGgufModel = final.callPackage ../pkgs/build-support/fetch-gguf-model { };

  # Zig binary from nix-community/bun2nix, needed by fetchBunDeps.
  bun2nix-cache-entry-creator =
    final.callPackage ../pkgs/build-support/bun2nix/cache-entry-creator
      { };

  inherit
    (final.callPackage ../pkgs/build-support/bun2nix {
      cacheEntryCreator = final.bun2nix-cache-entry-creator;
    })
    buildBunBinary
    buildBunBinaries
    buildZxScript
    buildZxScriptFromFile
    eslintCache
    fetchBunDeps
    mkBunDerivation
    writeBunApplication
    writeBunScriptBin
    ;

  # Resolve + rewrite SRI hashes for ///!dep directives in zx scripts
  # consumed by buildZxScriptFromFile. Exposed flat (not nested under
  # bun2nix.update-zx-deps) to match the rest of this overlay.
  update-zx-deps = final.callPackage ../pkgs/build-support/bun2nix/update-zx-deps { };

  # Builder for the bun-dev shell. Downstream consumers (the bun fork
  # itself, anyone wanting a Bun build environment) call this with
  # extraPackages/extraShellHook/extraEnv knobs. The default
  # `devShells.<system>.bun-dev` in flake.nix calls it with no extras.
  mkBunDevShell = import ../pkgs/build-support/bun-dev-shell { pkgs = final; };

  inherit (final.callPackage ../pkgs/build-support/gomod2nix { })
    buildGoApplication
    buildGoRace
    buildGoCover
    buildGoCheck
    buildGoLint
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    mkGoLintCacheEnv
    goSourceFilter
    goSourceFilterMiddleware
    mkGoPkgs
    bridgeCapabilities
    ;

  # go-toolchain — version-parameterized Go toolchains (go-toolchain(7)).
  # mkGoToolchain builds a Go compiler for a registry version and returns it
  # with matching builders bound; the per-version `go_<x>_<y>_<z>` attrs are
  # aliased over it in overlays/pins/go.nix.
  inherit (final.callPackage ../pkgs/development/compilers/go-toolchain { })
    mkGoToolchain
    ;
  # goToolchain — the NEWEST registry entry as a bundle (`goToolchain.go`, plus
  # buildGoModule / buildGoApplication / mkGoEnv bound to it). This is the
  # toolchain igloo's own Go builders (godyn, buildGoApplication's default
  # selection) compile with. nixpkgs' `go` is left alone on purpose (FDR 0012),
  # so a registry bump rebuilds Go modules only, never the nixpkgs packages that
  # take `go` as an input.
  goToolchain = final.mkGoToolchain { };

  # godyn — per-package Go builder (one CA derivation per package; nix schedules
  # the merkle-delta on edits). buildGodynModule consumes a committed graph.json
  # (produced by godyn-gen) + a gomod2nix.toml/vendorEnv for third-party deps.
  inherit (final.callPackage ../pkgs/build-support/godyn { })
    buildGodynModule
    buildGodynLint
    buildGoAuto
    godyn-gen
    godyn-go
    godyn-test
    godyn-lint
    godynStdlib
    godynSystems
    ;

  # rustdyn — per-crate content-addressed Rust builder (FDR 0009), godyn's
  # counterpart for cargo workspaces: a graph from `cargo metadata` at eval
  # time, one CA buildRustCrate derivation per crate, per-crate test and clippy
  # lanes, the layered install derivation.
  inherit (final.callPackage ../pkgs/build-support/rustdyn { })
    buildRustdynWorkspace
    buildRustAuto
    rustdynManifest
    rustdynSystems
    rustdyn-cargo
    ;

  rustdyn-man = final.mkScdocMan {
    pname = "rustdyn-man";
    src = ../pkgs/build-support/rustdyn;
  };

  # nixgc — targeted Nix store GC CLI (extracted + generalized from spinclass's
  # internal/nixgc, igloo#28). Reaps the dead subgraph anchored at seed store
  # paths, keeping anything a live GC root holds.
  nixgc = final.callPackage ../pkgs/build-support/nixgc { };

  # mkScdocMan — render a directory's `*.<section>.scd` sources with scdoc into
  # share/man/man<section>. Each builder's man derivation below is one call;
  # wired as a flake check so a syntax error in a page fails the pre-merge hook
  # instead of silently shipping (eng-manpages(7) § SCDOC PATTERN).
  mkScdocMan =
    {
      pname,
      src,
      version ? "0.1.0",
      sections ? [ 7 ],
    }:
    final.stdenvNoCC.mkDerivation {
      inherit pname version src;
      nativeBuildInputs = [ final.scdoc ];
      dontUnpack = true;
      dontBuild = true;
      installPhase = final.lib.concatMapStringsSep "\n" (s: ''
        mkdir -p $out/share/man/man${s}
        for f in $src/*.${s}.scd; do
          [ -e "$f" ] || continue
          scdoc < "$f" > "$out/share/man/man${s}/$(basename "$f" .scd)"
        done
      '') (map toString sections);
    };

  nixgc-man = final.mkScdocMan {
    pname = "nixgc-man";
    src = ../pkgs/build-support/nixgc;
    sections = [ 1 ];
  };

  gomod2nix = final.callPackage ../pkgs/build-support/gomod2nix/cli {
    inherit (final) buildGoApplication go;
  };

  # gomod2nix(7), mkGoPkgs(7), goSourceFilter(7) and the CLI's pages.
  gomod2nix-man = final.mkScdocMan {
    pname = "gomod2nix-man";
    version = final.gomod2nix.version or "0.0.0";
    src = ../pkgs/build-support/gomod2nix;
    sections = [
      1
      5
      7
    ];
  };

  go-toolchain-man = final.mkScdocMan {
    pname = "go-toolchain-man";
    version = "0.0.0";
    src = ../pkgs/development/compilers/go-toolchain;
  };

  # vm-tests — NixOS VM integration checks for fleet repos (FDR 0011,
  # vm-tests(7)): mkVmChecks wraps pkgs.testers.runNixOSTest with the fleet's
  # defaults (Linux-only, no KVM, TCG sizing); vmTestPrelude is the shared
  # testScript prelude.
  inherit (final.callPackage ../pkgs/build-support/vm-tests { })
    mkVmChecks
    vmTestPrelude
    ;

  vm-tests-man = final.mkScdocMan {
    pname = "vm-tests-man";
    src = ../pkgs/build-support/vm-tests;
  };

  godyn-man = final.mkScdocMan {
    pname = "godyn-man";
    src = ../pkgs/build-support/godyn;
  };
}
