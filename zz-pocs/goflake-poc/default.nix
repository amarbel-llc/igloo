{
  buildGoModule,
  pocLibSrc,
}:

buildGoModule {
  pname = "goflake-poc";
  version = "0.1.0";
  src = ./.;

  # Restrict to the main package so buildGoModule doesn't try to build
  # `./upstream` (which is its own go module) or `.flake-inputs/poc-lib`
  # (the symlinked flake-input source) as subpackages.
  subPackages = [ "." ];

  # No vendor/, no goModules FOD. The replaced module is the ONLY require
  # in go.mod, and we provide its source via the symlink in preBuild. Go
  # then has nothing to download.
  vendorHash = null;

  # buildGoModule auto-appends -mod=vendor to GOFLAGS unless proxyVendor is
  # true (see nixpkgs pkgs/build-support/go/module.nix:232). With
  # vendorHash=null the vendor/ tree doesn't exist, so -mod=vendor fails
  # with "inconsistent vendoring". proxyVendor=true suppresses the flag
  # and lets Go read go.mod directly and follow the replace.
  proxyVendor = true;

  # Phase 2 keeps the symlink-bridge pattern. The consumer's go.mod
  # already carries the require/replace lines (organic flow); we only
  # need to materialize the symlinked source the replace points at.
  preBuild = ''
    mkdir -p .flake-inputs
    ln -sfn ${pocLibSrc} .flake-inputs/poc-lib
  '';

  doCheck = false;
}
