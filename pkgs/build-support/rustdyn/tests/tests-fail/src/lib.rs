//! A single-crate workspace (the package is the workspace root) whose one
//! test fails: the run derivation must fail the build.

pub fn one() -> i64 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn fails_on_purpose() {
        assert_eq!(super::one(), 2);
    }
}
