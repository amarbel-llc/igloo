# M2+ — the recursive-nix / dynamic-derivations wrapper.
#
# Port of numtide/go2nix nix/dynamic/default.nix, trimmed for the POC. A
# text-mode CA derivation runs `godyn-resolver` at build time; its $out IS the
# final link `.drv` file, and `builtins.outputOf` resolves that to the binary
# at eval time. The resolver registers per-package CA derivations via
# `nix derivation add` over the in-sandbox daemon socket (needs recursive-nix +
# the trust/system-features set by `just enable-recursive-nix`).
{
  lib,
  stdenv,
  runCommandCC,
  go,
  bash,
  coreutils,
  cacert,
  cc,
  nix,
}:

# Guard rails: dynamic-derivations gates builtins.outputOf; assert it is on.
assert lib.assertMsg (builtins ? outputOf)
  "godyn-poc: builtins.outputOf missing — enable dynamic-derivations (run `just enable-recursive-nix`).";
assert lib.assertMsg (lib.versionAtLeast (lib.versions.majorMinor nix.version) "2.34")
  "godyn-poc: nix ${nix.version} < 2.34; dynamic-derivations needs the v4 derivation format.";

{
  src,
  pname,
  stdlib,
  lockfile ? null,
  # bridges: attrset of go-module-path -> go-pkgs store path. Each becomes a
  # `--bridge mod=path` flag, sourcing that module from a flake-input go-pkgs
  # output via a synthesized `replace` instead of a module-proxy FOD (RFC 0001).
  bridges ? { },
  # tags: comma-separated build tags threaded to `go list` for file selection.
  tags ? "",
  system ? stdenv.hostPlatform.system,
  goVersion ? "go1.26",
}:
let
  resolver =
    runCommandCC "godyn-resolver"
      {
        nativeBuildInputs = [ go ];
      }
      ''
        export HOME=$TMPDIR GOCACHE=$TMPDIR/c GOFLAGS=-trimpath GOPROXY=off
        export GO111MODULE=on CGO_ENABLED=0
        cp -r ${./resolver} src && chmod -R +w src && cd src
        mkdir -p $out/bin
        go build -o $out/bin/godyn-resolver .
      '';

  wrapper = stdenv.mkDerivation {
    name = "${pname}-dynamic.drv";

    # text-mode CA: $out is a single file (the link .drv).
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";

    # The resolver talks to the daemon (nix derivation add / build / store add)
    # from inside the sandbox.
    requiredSystemFeatures = [ "recursive-nix" ];

    dontUnpack = true;
    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      export NIX_CONFIG="extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix"
      ${resolver}/bin/godyn-resolver \
        --src ${src} \
        --stdlib ${stdlib} \
        --go ${go} \
        --bash ${bash} \
        --coreutils ${coreutils} \
        --cc ${cc} \
        --cacert ${cacert} \
        --nix ${nix}/bin/nix \
        --pname ${pname} \
        --go-version ${goVersion} \
        --system ${system} \
        ${lib.optionalString (tags != "") "--tags ${tags} "}${lib.concatStrings (lib.mapAttrsToList (m: p: "--bridge ${m}=${p} ") bridges)}${lib.optionalString (lockfile != null) "--lockfile ${lockfile} "}--out $out
      runHook postBuild
    '';
  };
in
{
  inherit wrapper resolver;
  # The eval-time resolution: build the wrapper (-> link .drv), then build that.
  target = builtins.outputOf wrapper.outPath "out";
}
