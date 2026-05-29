# Allows applying a custom override function to a specific package via
# fetchBunDeps.
#
# API Type: Takes a struct of overrides where attributes have the type:
#   String => Package => Package
{ pkgs, lib, extractPackage }:

{
  overrides ? { },
  ...
}:

let
  preExtractPackage =
    name: pkg:
    pkgs.runCommandLocal "pre-extract-${name}" { } ''
      "${lib.getExe extractPackage}" \
        --package "${pkg}" \
        --out "$out"
    '';

  overridePkg = name: pkg: overrides.${name} (preExtractPackage name pkg);
in
name: pkg: if (overrides ? "${name}") then (overridePkg name pkg) else pkg
