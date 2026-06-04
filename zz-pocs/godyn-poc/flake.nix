{
  description = "godyn-poc: native per-package Go builder via recursive-nix + CA + dynamic-derivations (throwaway POC).";

  inputs = {
    # Absolute path: `path:../..` re-roots to the /nix/store copy at eval
    # time (resolving to /nix, forbidden in pure mode). Absolute path dodges
    # that, same workaround as goflake-poc. Consuming igloo itself gives us
    # the overlay's `go` plus fetchGoModule etc. for later milestones.
    igloo.url = "path:/home/sasha/eng/repos/igloo/.worktrees/sharp-mahogany";
  };

  outputs =
    { self, igloo, ... }:
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
