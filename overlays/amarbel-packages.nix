# Packages added by amarbel-llc/igloo that don't exist in upstream.
# Lives here (not all-packages.nix) so upstream merges never conflict.
final: prev: {
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

  inherit
    (final.callPackage ../pkgs/build-support/gomod2nix { })
    buildGoApplication
    buildGoRace
    buildGoCover
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    goSourceFilter
    goSourceFilterMiddleware
    mkGoPkgs
    ;

  # godyn — per-package Go builder (one CA derivation per package; nix schedules
  # the merkle-delta on edits). buildGodynModule consumes a committed graph.json
  # (produced by godyn-gen) + a gomod2nix.toml/vendorEnv for third-party deps.
  inherit
    (final.callPackage ../pkgs/build-support/godyn { })
    buildGodynModule
    godyn-gen
    godynStdlib
    ;

  gomod2nix = final.callPackage ../pkgs/build-support/gomod2nix/cli {
    inherit (final) buildGoApplication go;
  };

  # Validates the scdoc man page sources under
  # pkgs/build-support/gomod2nix/. Exposed as a flake check so syntax
  # errors in *.7.scd are caught by the pre-merge hook rather than
  # silently shipped. See eng-manpages(7) § SCDOC PATTERN.
  gomod2nix-man = final.stdenvNoCC.mkDerivation {
    pname = "gomod2nix-man";
    version = final.gomod2nix.version or "0.0.0";
    src = ../pkgs/build-support/gomod2nix;
    nativeBuildInputs = [ final.scdoc ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/man/man1
      mkdir -p $out/share/man/man5
      mkdir -p $out/share/man/man7
      for f in $src/*.1.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man1/$(basename "$f" .scd)"
      done
      for f in $src/*.5.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man5/$(basename "$f" .scd)"
      done
      for f in $src/*.7.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man7/$(basename "$f" .scd)"
      done
    '';
  };

  # godyn(7) man page (scdoc), validated as a flake check so syntax errors are
  # caught by the pre-merge hook. Mirrors gomod2nix-man.
  godyn-man = final.stdenvNoCC.mkDerivation {
    pname = "godyn-man";
    version = "0.1.0";
    src = ../pkgs/build-support/godyn;
    nativeBuildInputs = [ final.scdoc ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/man/man7
      for f in $src/*.7.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man7/$(basename "$f" .scd)"
      done
    '';
  };
}
