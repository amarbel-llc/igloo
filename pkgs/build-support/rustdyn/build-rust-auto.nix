# buildRustAuto — pick rustdyn (per-crate CA, the incremental dev/test loop) or
# rustPlatform.buildRustPackage (one derivation, cold / CI / release) from the
# same arguments; godyn's buildGoAuto for Rust (FDR 0009 § Interface). A pure
# flake cannot read the environment, so `strategy` is an explicit knob:
#   strategy = "native" (alias "dev")  -> rustdyn
#   strategy = "brp"    (alias "ci")   -> buildRustPackage
#   strategy = null                    -> rustdyn on rustdynSystems, buildRustPackage elsewhere
# Both backends stay reachable as passthru.native / passthru.brp, and
# passthru.backend records the choice. The version env, lock, postInstall,
# binaryNames and inputs come from the rustdyn build so the two backends
# cannot drift.
{
  lib,
  stdenv,
  rustPlatform,
  buildRustdynWorkspace,
  rustdynSystems,
  rustdynManifest,
}:
{
  strategy ? null,
  ...
}@rawArgs:
let
  # A cargo.nix manifest is rendered once here, so both backends read the same
  # tree (and `workspaceDir` is already folded into it).
  args = rustdynManifest.withCargoManifest (removeAttrs rawArgs [ "strategy" ]);
  native = buildRustdynWorkspace args;
  workspaceDir = args.workspaceDir or "";
  # The install-step knobs rustdyn applies itself, replayed on cargo's install:
  # keep only the `bins` asked for, then rename.
  keepBins = lib.optional ((args.bins or null) != null) ''
    for b in $out/bin/*; do
      case "$(basename "$b")" in
        ${lib.concatMapStringsSep "|" lib.escapeShellArg args.bins}) ;;
        *) rm -f "$b" ;;
      esac
    done
  '';
  renames = lib.mapAttrsToList (from: to: "mv $out/bin/${from} $out/bin/${to}") (
    args.binaryNames or { }
  );
  brp = rustPlatform.buildRustPackage (
    {
      inherit (args) pname src;
      inherit (native.passthru) version;
      cargoLock = {
        inherit (native.passthru) lockFile;
        outputHashes = args.outputHashes or { };
        allowBuiltinFetchGit = args.allowBuiltinFetchGit or false;
      };
      doCheck = args.tests or false;
      buildInputs = args.buildInputs or [ ];
      nativeBuildInputs = args.nativeBuildInputs or [ ];
      nativeCheckInputs = args.nativeCheckInputs or [ ];
      postInstall = lib.concatStringsSep "\n" (keepBins ++ renames ++ [ (args.postInstall or "") ]);
      env = native.passthru.env // (args.testEnv or { });
      meta = {
        mainProgram = args.pname;
      }
      // (args.meta or { });
    }
    // lib.optionalAttrs (workspaceDir != "") {
      cargoRoot = workspaceDir;
      buildAndTestSubdir = workspaceDir;
    }
  );
  useNative =
    if strategy == null then
      lib.elem stdenv.hostPlatform.system rustdynSystems
    else if
      lib.elem strategy [
        "native"
        "dev"
      ]
    then
      true
    else if
      lib.elem strategy [
        "brp"
        "ci"
      ]
    then
      false
    else
      throw "buildRustAuto: unknown strategy \"${toString strategy}\" (native|dev, brp|ci, or null)";
  chosen = if useNative then native else brp;
in
chosen.overrideAttrs (old: {
  passthru =
    (old.passthru or { })
    # the cargo.nix surface rides along whichever backend was chosen
    // lib.optionalAttrs (native.passthru ? cargoRun) {
      inherit (native.passthru)
        cargoManifest
        cargoResolved
        cargoSrc
        cargoRun
        ingest
        flakeInputs
        ;
    }
    // {
      inherit native brp;
      backend = if useNative then "rustdyn" else "brp";
    };
})
