// An integration test harness (tests/integration.rs): links the lib as an
// external crate and reads a fixture file relative to the package root, which
// cargo provides as the test's cwd and CARGO_MANIFEST_DIR at run time.
use std::path::PathBuf;

#[test]
fn integration_adds() {
    assert_eq!(calc::add(40, 2), 42);
}

#[test]
fn reads_fixture_relative_to_manifest_dir() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR set at run time");
    let data = std::fs::read_to_string(PathBuf::from(dir).join("tests/data.txt")).unwrap();
    assert_eq!(data.trim(), "forty-two");
    // cwd is the package root too.
    assert!(std::path::Path::new("tests/data.txt").exists());
}
