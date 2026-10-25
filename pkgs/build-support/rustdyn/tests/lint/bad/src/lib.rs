//! Compiles clean under rustc, fails clippy's default (style) lints:
//! clippy::bool_comparison and clippy::needless_bool. rustc alone says
//! nothing, so a finding here proves clippy-driver ran.

pub fn is_true(x: bool) -> bool {
    if x == true {
        true
    } else {
        false
    }
}
