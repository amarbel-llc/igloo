// The bin member: its own unit test (the bin's harness) and an integration
// test under tests/ that execs the real binary through CARGO_BIN_EXE_tool.
fn answer() -> i64 {
    calc::add(2, 3)
}

fn main() {
    println!("{}", answer());
}

#[cfg(test)]
mod tests {
    #[test]
    fn bin_unit() {
        assert_eq!(super::answer(), 5);
    }
}
