# godyn — the shared Go standard-library derivation.
#
# Port of numtide/go2nix nix/stdlib.nix. One plain input-addressed derivation per
# (go version, goEnv) pair. `go install std` with GODEBUG=installgoroot=all writes
# the compiled stdlib .a files into a writable GOROOT/pkg/<goos>_<goarch>/ tree (Go
# >= 1.20 needs the GODEBUG to restore that behaviour — the default build cache is
# keyed per-build and not directly addressable). We then synthesize $out/importcfg
# mapping each stdlib import path to its .a, which per-package compile derivations
# splice into their own importcfg. Built once and cached normally (no recursive-nix).
{
  lib,
  runCommandCC,
  go,
  # race: the -race instrumented stdlib (`go install -race std`), archived under
  # pkg/<goos>_<goarch>_race, for godyn race builds (igloo#34).
  race ? false,
}:
let
  goEnv = { };
  envSuffix = builtins.substring 0 8 (builtins.hashString "sha256" (builtins.toJSON goEnv));
  archSuffix = lib.optionalString race "_race";
in
runCommandCC "go-stdlib-${go.version}-${envSuffix}${lib.optionalString race "-race"}"
  {
    nativeBuildInputs = [ go ];
    inherit (go) GOOS GOARCH;
    # CGO_ENABLED=1 so the stdlib includes runtime/cgo (+ cgo variants of
    # net/os/user), which cgo consumer packages import. runCommandCC supplies the C
    # compiler. Pure-Go consumers ignore the extra importcfg entries.
    CGO_ENABLED = "1";
    passthru = { inherit go goEnv race; };
  }
  ''
    export HOME=$TMPDIR
    export GOCACHE=$TMPDIR/gocache
    export GOPATH=$TMPDIR/gopath
    export GOFLAGS=-trimpath

    # Writable GOROOT copy so installgoroot=all can write pkg/*.a.
    cp -r "$(go env GOROOT)" goroot
    chmod -R u+w goroot
    export GOROOT="$PWD/goroot"

    echo "building std into GOROOT/pkg ..."
    GODEBUG=installgoroot=all go install -v --trimpath ${lib.optionalString race "-race "}std

    archdir="$GOROOT/pkg/''${GOOS}_''${GOARCH}${archSuffix}"
    if [ ! -d "$archdir" ] || [ -z "$(find "$archdir" -name '*.a' -print -quit)" ]; then
      echo "ERROR: no stdlib .a files found under $archdir" >&2
      echo "(installgoroot=all did not populate GOROOT/pkg — see stdlib.nix note)" >&2
      exit 1
    fi

    mkdir -p "$out/pkg/''${GOOS}_''${GOARCH}${archSuffix}"
    cp -r "$archdir"/. "$out/pkg/''${GOOS}_''${GOARCH}${archSuffix}/"

    # importcfg: one `packagefile <importpath>=<abs .a path>` per archive.
    : > "$out/importcfg"
    ( cd "$out/pkg/''${GOOS}_''${GOARCH}${archSuffix}"
      find . -name '*.a' | sed 's,^\./,,' | sort | while read -r rel; do
        imp="''${rel%.a}"
        echo "packagefile $imp=$out/pkg/''${GOOS}_''${GOARCH}${archSuffix}/$rel"
      done
    ) > "$out/importcfg"

    echo "wrote $(wc -l < "$out/importcfg") importcfg entries"
  ''
