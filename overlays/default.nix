# Overlays for this fork.
# - pins/: one file per upstream package override
# - amarbel-packages.nix: new packages not in upstream
# Add new pins as new files — no upstream files need modification.
lib:
let
  pinFiles = lib.filesystem.listFilesRecursive ./pins;
in
map import pinFiles ++ [ (import ./amarbel-packages.nix) ]
