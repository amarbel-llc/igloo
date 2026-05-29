/**
  Write a plain Bun shebang script to `$out/bin/$name`.

  The script uses `bun` from the Nix store as its interpreter via a
  `#!<bun>/bin/bun` shebang. No bundling or dependency fetching is
  performed — use this for self-contained scripts with no npm imports.

  # Inputs

  `name`
  : Binary name; the file is written to `$out/bin/$name`.

  `text`
  : Script body (without the shebang line).

  # Type

  ```
  writeBunScriptBin :: { name :: String, text :: String } -> Derivation
  ```

  # Examples
  :::{.example}
  ## `writeBunScriptBin` usage example

  ```nix
  writeBunScriptBin {
    name = "hello";
    text = ''
      console.log("hello from bun");
    '';
  }
  ```

  :::
*/
{ pkgs, bun }:

{ name, text }:

pkgs.writeTextFile {
  inherit name;
  text = ''
    #!${bun}/bin/bun
    ${text}
  '';
  executable = true;
  destination = "/bin/${name}";
}
