# Copy of nixpkgs's bun package containing an extra binary `node` which
# aliases to the `bun` binary output of the original package.
{ pkgs, lib, bun }:

{
  useFakeNode ? true,
  ...
}:
if useFakeNode then
  pkgs.stdenvNoCC.mkDerivation {
    name = "bun-with-fake-node";

    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
      cp -r "${bun}/." "$out"
      chmod u+w "$out/bin"

      for node_binary in "node" "npm" "npx"; do
        ln -s "$out/bin/bun" "$out/bin/$node_binary"
      done
    '';
  }
else
  pkgs.symlinkJoin {
    name = "bun-with-real-node";
    paths = [
      bun
      pkgs.nodejs
    ];
  }
