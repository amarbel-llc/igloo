# Pin go_1_26 to 1.26.3 — addresses GO-2026-4971 (net.Dial NUL panic) and
# GO-2026-4918 (HTTP/2 infinite loop) ahead of staging-next → master
# promotion. Upstream bump landed in NixOS/nixpkgs staging via PR #517757
# on 2026-05-08; remove this pin once it reaches the master branch this
# flake follows.
final: prev:
{
  go_1_26 = prev.go_1_26.overrideAttrs (_: {
    version = "1.26.3";
    src = final.fetchurl {
      url = "https://go.dev/dl/go1.26.3.src.tar.gz";
      hash = "sha256-HGRoddCqh5kTMYTtV895/yS97+jIggRwYCqdPW2Rkrg=";
    };
  });
}
