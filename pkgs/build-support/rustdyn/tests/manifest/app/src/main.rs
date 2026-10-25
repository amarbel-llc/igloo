fn main() {
    println!(
        "{} {}+{}",
        greet::greet("greet"),
        env!("APP_VERSION"),
        env!("APP_COMMIT")
    );
}
