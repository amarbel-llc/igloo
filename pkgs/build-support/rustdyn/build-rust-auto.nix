# buildRustAuto — pick rustdyn (per-crate CA, the incremental dev/test loop) or
# rustPlatform.buildRustPackage (one derivation, cold / CI / release) from the
# same arguments; godyn's buildGoAuto for Rust (FDR 0009 § Interface). A pure
# flake cannot read the environment, so `strategy` is an explicit knob:
#   strategy = "native"  -> rustdyn
#   strategy = "brp"     -> buildRustPackage
#   strategy = null      -> rustdyn on rustdynSystems, buildRustPackage elsewhere
# Both backends stay reachable as passthru.native / passthru.brp, and
# passthru.backend records the choice.
{
  lib,
  stdenv,
  rustPlatform,
  buildRustdynWorkspace,
  rustdynSystems,
}:
{
  strategy ? null,
  ...
}@args:
let
  rustdynArgs = removeAttrs args [ "strategy" ];
  native = buildRustdynWorkspace rustdynArgs;
  workspaceDir = args.workspaceDir or "";
  pnameUpper = lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] args.pname);
  binaryNames = args.binaryNames or { };
  brp = rustPlatform.buildRustPackage (
    {
      inherit (args) pname src;
      version = native.passthru.version;
      cargoLock = {
        lockFile =
          if (args.cargoLock or null) != null then
            args.cargoLock
          else if workspaceDir == "" then
            "${args.src}/Cargo.lock"
          else
            "${args.src}/${workspaceDir}/Cargo.lock";
        outputHashes = args.outputHashes or { };
        allowBuiltinFetchGit = args.allowBuiltinFetchGit or false;
      };
      doCheck = args.tests or false;
      buildInputs = args.buildInputs or [ ];
      nativeBuildInputs = args.nativeBuildInputs or [ ];
      nativeCheckInputs = args.nativeCheckInputs or [ ];
      postInstall =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (from: to: "mv $out/bin/${from} $out/bin/${to}") binaryNames
        )
        + "\n"
        + (args.postInstall or "");
      env = {
        RUSTDYN_VERSION = native.passthru.version;
        RUSTDYN_COMMIT = native.passthru.commit;
        "${pnameUpper}_VERSION" = native.passthru.version;
        "${pnameUpper}_COMMIT" = native.passthru.commit;
      }
      // (args.memberEnv or { })
      // (args.testEnv or { });
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
    if strategy != null then
      strategy == "native"
    else
      lib.elem stdenv.hostPlatform.system rustdynSystems;
  chosen = if useNative then native else brp;
in
chosen.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit native brp;
    backend = if useNative then "rustdyn" else "brp";
  };
})
