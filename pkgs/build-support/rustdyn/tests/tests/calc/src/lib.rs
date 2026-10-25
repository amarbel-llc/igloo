//! The lib member of the rustdyn `tests` fixture: a unit test in the lib
//! harness, an integration test under tests/ that reads a data file through
//! the runtime CARGO_MANIFEST_DIR the run derivation sets.

/// Adds two numbers.
pub fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(2, 3), 5);
    }
}
