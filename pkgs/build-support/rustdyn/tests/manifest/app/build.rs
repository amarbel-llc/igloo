// The fleet's version-embedding convention (FDR 0009 § 3): a build script
// reads the version and commit from the build environment and hands them to
// the crate as compile-time env. rustdyn sets RUSTDYN_VERSION / RUSTDYN_COMMIT
// for every workspace member's build; `<PNAME>_VERSION` (here MULTI_VERSION,
// from version.env) is the per-consumer name posh/piggy-style build scripts
// already read.
fn main() {
    let version = std::env::var("MULTI_VERSION")
        .or_else(|_| std::env::var("RUSTDYN_VERSION"))
        .unwrap_or_else(|_| "unknown".to_string());
    let commit = std::env::var("RUSTDYN_COMMIT").unwrap_or_else(|_| "unknown".to_string());
    println!("cargo:rustc-env=APP_VERSION={version}");
    println!("cargo:rustc-env=APP_COMMIT={commit}");
    println!("cargo:rerun-if-env-changed=MULTI_VERSION");
    println!("cargo:rerun-if-env-changed=RUSTDYN_VERSION");
    println!("cargo:rerun-if-env-changed=RUSTDYN_COMMIT");
}
