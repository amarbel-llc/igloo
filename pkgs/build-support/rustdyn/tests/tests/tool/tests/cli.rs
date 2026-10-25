// cargo's convention for integration tests of a bin: CARGO_BIN_EXE_<name> is
// the path of the built binary, baked in at compile time.
#[test]
fn cli_prints_five() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_tool"))
        .output()
        .expect("run tool");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "5");
}
