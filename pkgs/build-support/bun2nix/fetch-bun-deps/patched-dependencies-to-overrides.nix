# Helper function that converts a patchedDependencies attribute set
# into a valid overrides set for use with fetchBunDeps.
#
# Example:
#   let
#     src = ./.;
#     packageJsonPath = ./package.json;
#     packageJsonContents = lib.importJSON packageJsonPath;
#     patchedDependencies = lib.mapAttrs (_: path: "${src}/${path}") (
#       packageJsonContents.patchedDependencies or { }
#     );
#     patchOverrides = patchedDependenciesToOverrides {
#       inherit patchedDependencies;
#     };
#   in
#   fetchBunDeps {
#     bunNix = ./bun.nix;
#     overrides = patchOverrides;
#   }
{ pkgs, lib }:

{
  patchedDependencies ? { },
}:

lib.mapAttrs (
  name: patchFile: pkg:
  pkgs.runCommandLocal "patched-${name}" { nativeBuildInputs = [ pkgs.patch ]; } ''
    mkdir $out
    cp -r ${pkg}/. $out

    echo "Applying patch for ${name}..."
    patch -p1 -d $out < ${patchFile}
  ''
) patchedDependencies
