{
  description = "godyn-poc: native per-package Go builder via recursive-nix + CA + dynamic-derivations (throwaway POC).";

  inputs = {
    # Absolute path: `path:../..` re-roots to the /nix/store copy at eval
    # time (resolving to /nix, forbidden in pure mode). Absolute path dodges
    # that, same workaround as goflake-poc. Consuming igloo itself gives us
    # the overlay's `go` plus fetchGoModule etc. for later milestones.
    igloo.url = "path:/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany";

    # D4 bridge: tommy's source (a gitignored vendored clone under .tmp) as a
    # non-flake path input, so igloo's mkGoPkgs can produce its `go-pkgs`
    # output and the resolver can bridge it via a synthesized replace.
    tommy-src = {
      url = "path:/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany/.tmp/purse-first/vendor/github.com/amarbel-llc/tommy";
      flake = false;
    };
  };

  outputs =
    { self, igloo, tommy-src, ... }:
    let
      system = "x86_64-linux";
      pkgs = igloo.legacyPackages.${system};
      go = pkgs.go;

      # M1: the shared Go standard-library derivation (one per (go, goEnv)).
      stdlib = pkgs.callPackage ./stdlib.nix { inherit go; };

      # M2+: the recursive-nix / dynamic-derivations builder.
      mkDynamic = import ./dynamic.nix {
        inherit (pkgs)
          lib
          stdenv
          runCommandCC
          bash
          coreutils
          cacert
          nix
          ;
        inherit go;
        cc = pkgs.stdenv.cc;
      };

      # M2 system-under-test: a single stdlib-only main package.
      single = mkDynamic {
        src = ./toy-single;
        pname = "godyn-single";
        inherit stdlib;
      };

      # M3 system-under-test: main -> internal/greet -> internal/mathx, all
      # first-party. Exercises topo ordering + dep-archive importcfg wiring.
      multi = mkDynamic {
        src = ./toy;
        pname = "godyn";
        inherit stdlib;
      };

      # M4 system-under-test: greet imports a third-party module
      # (github.com/google/uuid) fetched via FOD + GOMODCACHE.
      m4mod = mkDynamic {
        src = ./toy-m4;
        pname = "godyn-m4";
        lockfile = ./toy-m4/godyn.lock;
        inherit stdlib;
      };

      # D3 system-under-test: main imports a cgo third-party module
      # (github.com/DataDog/zstd, self-contained C). Exercises the cgo path.
      cgomod = mkDynamic {
        src = ./toy-cgo;
        pname = "godyn-cgo";
        lockfile = ./toy-cgo/godyn.lock;
        inherit stdlib;
      };

      # D2: build-tag file selection. The same source builds two ways; variant()
      # comes from base.go (godyn_extra off) or extra.go (godyn_extra on).
      tagsoff = mkDynamic {
        src = ./toy-tags;
        pname = "godyn-tags-off";
        inherit stdlib;
      };
      tagson = mkDynamic {
        src = ./toy-tags;
        pname = "godyn-tags-on";
        tags = "godyn_extra";
        inherit stdlib;
      };

      # D4: tommy's RFC 0001 `go-pkgs` output (the producer side), built from
      # tommy's source via igloo's mkGoPkgs.
      tommyGoPkgs = (pkgs.mkGoPkgs {
        src = tommy-src;
        name = "tommy";
      }).go-pkgs;

      # D4 system-under-test: a main importing github.com/amarbel-llc/tommy/pkg/cst,
      # sourced from tommyGoPkgs through the bridge (replace -> store path), not a
      # module-proxy FOD. tommy's own build deps come from the lockfile.
      bridgemod = mkDynamic {
        src = ./toy-bridge;
        pname = "godyn-bridge";
        lockfile = ./toy-bridge/godyn.lock;
        bridges = {
          "github.com/amarbel-llc/tommy" = tommyGoPkgs;
        };
        inherit stdlib;
      };
    in
    {
      packages.${system} = {
        inherit stdlib;
        godyn-resolver = single.resolver;
        # Toolchain store paths exposed so the m5 measurement recipe can
        # resolve them via ambient `nix build` (no devshell needed).
        go-toolchain = go;
        bash = pkgs.bash;
        coreutils = pkgs.coreutils;
        # M2 intermediate: the wrapper whose $out is the link .drv.
        m2-wrapper = single.wrapper;
        # M2 final: outputOf(wrapper) -> the linked binary.
        m2 = single.target;
        # M3: multi first-party package graph.
        m3-wrapper = multi.wrapper;
        m3 = multi.target;
        # M4: third-party module via FOD.
        m4-wrapper = m4mod.wrapper;
        m4 = m4mod.target;
        # D3: cgo third-party module.
        cgo-wrapper = cgomod.wrapper;
        cgo = cgomod.target;
        # D2: build-tag file selection (same src, two tag sets).
        tags-off = tagsoff.target;
        tags-on = tagson.target;
        # D4: flake-input bridge (tommy via its go-pkgs output).
        tommy-go-pkgs = tommyGoPkgs;
        bridge-wrapper = bridgemod.wrapper;
        bridge = bridgemod.target;
      };

      # Only stdlib is a `nix flake check` gate (no recursive-nix). The dynamic
      # outputs are built explicitly via `nix build .#m2`.
      checks.${system} = {
        inherit stdlib;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          go
          pkgs.nix
        ];
      };
    };
}
