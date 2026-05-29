# Build environment for amarbel-llc/bun. Direct port of the Bun
# fork's devShells.default so the Bun fork can re-export
# `nixpkgs.devShells.${system}.bun-dev` and drop its own copy.
# FORTIFY_SOURCE is incompatible with Bun's build assumptions —
# disable it.
#
# Exposed as a builder function so downstream consumers can extend
# the package list, shell hook, or environment without rewriting the
# whole composition. The default `devShells.<system>.bun-dev` in
# flake.nix calls this with no extras.
{ pkgs }:

{
  # Extra packages added to the shell's PATH and library closure.
  extraPackages ? [ ],

  # Extra shell hook text appended to the bun-dev hook. Runs after
  # the bun-specific CC/CXX/AR/RANLIB exports.
  extraShellHook ? "",

  # Extra env vars merged into the mkShell call (attrset). Use for
  # overriding defaults like CMAKE_BUILD_TYPE = "Release". Avoid
  # using this to override structural attrs (`packages`, `shellHook`,
  # `hardeningDisable`) -- those have dedicated knobs.
  extraEnv ? { },
}:

let
  # LLVM 21 — matches Bun's bootstrap.sh target.
  llvm = pkgs.llvm_21;
  clang = pkgs.clang_21;
  lld = pkgs.lld_21;

  # Node 24 — matches bootstrap.sh.
  nodejs = pkgs.nodejs_24;

  bunDevPackages =
    [
      # Core build tools
      pkgs.cmake
      pkgs.ninja
      pkgs.pkg-config
      pkgs.ccache

      # Compilers / toolchain
      clang
      llvm
      lld
      pkgs.gcc
      pkgs.rustc
      pkgs.cargo
      pkgs.go

      # Bun itself (for `bun bd`)
      pkgs.bun

      # Node.js 24
      nodejs

      # Other build deps from bootstrap.sh
      pkgs.python3
      pkgs.libtool
      pkgs.ruby
      pkgs.perl

      # Libraries
      pkgs.openssl
      pkgs.zlib
      pkgs.libxml2
      pkgs.libiconv

      # Dev tools
      pkgs.git
      pkgs.curl
      pkgs.wget
      pkgs.unzip
      pkgs.xz
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
      # Debugging
      pkgs.gdb

      # Chromium runtime deps for Puppeteer tests (bootstrap.sh
      # lines 1397-1483).
      pkgs.libx11
      pkgs.libxcb
      pkgs.libxcomposite
      pkgs.libxcursor
      pkgs.libxdamage
      pkgs.libxext
      pkgs.libxfixes
      pkgs.libxi
      pkgs.libxrandr
      pkgs.libxrender
      pkgs.libxscrnsaver
      pkgs.libxtst
      pkgs.libxkbcommon
      pkgs.mesa
      pkgs.nspr
      pkgs.nss
      pkgs.cups
      pkgs.dbus
      pkgs.expat
      pkgs.fontconfig
      pkgs.freetype
      pkgs.glib
      pkgs.gtk3
      pkgs.pango
      pkgs.cairo
      pkgs.alsa-lib
      pkgs.at-spi2-atk
      pkgs.at-spi2-core
      pkgs.libgbm
      pkgs.liberation_ttf
      pkgs.atk
      pkgs.libdrm
      pkgs.libxshmfence
      pkgs.gdk-pixbuf
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
      # New unified Apple SDK pattern.
      pkgs.apple-sdk
    ]
    ++ extraPackages;
in
(pkgs.mkShell.override { stdenv = pkgs.clangStdenv; }) (
  {
    packages = bunDevPackages;
    hardeningDisable = [ "fortify" ];

    shellHook =
      ''
        export CC="${pkgs.lib.getExe clang}"
        export CXX="${pkgs.lib.getExe' clang "clang++"}"
        export AR="${llvm}/bin/llvm-ar"
        export RANLIB="${llvm}/bin/llvm-ranlib"
        export CMAKE_C_COMPILER="$CC"
        export CMAKE_CXX_COMPILER="$CXX"
        export CMAKE_AR="$AR"
        export CMAKE_RANLIB="$RANLIB"
        export CMAKE_SYSTEM_PROCESSOR="$(uname -m)"
        export TMPDIR="''${TMPDIR:-/tmp}"
      ''
      + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
        export LD="${pkgs.lib.getExe' lld "ld.lld"}"
        export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK:+$NIX_CFLAGS_LINK }-fuse-ld=lld"
        export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath bunDevPackages}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      ''
      + extraShellHook;

    CMAKE_BUILD_TYPE = "Debug";
    ENABLE_CCACHE = "1";
  }
  // extraEnv
)
