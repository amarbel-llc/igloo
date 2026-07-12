# Pin container (apple/container) to 1.0.0 — the pinned nixpkgs rev still
# ships 0.12.3. The nixpkgs package fetches the Apple-signed installer pkg
# (a fetchurl FOD, keeping Apple's codesign + virtualization entitlements
# intact) and extracts it with xar/bsdtar; its src URL is templated on
# version and 1.0.0 keeps the same asset naming, so bumping version+hash
# is sufficient. aarch64-darwin only. Remove this pin once nixpkgs-master
# carries >= 1.0.0.
final: prev: {
  container = prev.container.overrideAttrs (_: {
    version = "1.0.0";
    src = final.fetchurl {
      url = "https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg";
      hash = "sha256-E/RfJtqUw1Sty+/h6PdjHn8SbpPF1N1qWlOKpmtPR50=";
    };
  });
}
