//! The leaf crate of the rustdyn `multi` fixture: a library the `app` member
//! links through a workspace path dependency.

/// Returns the greeting `app` prints.
pub fn greet(name: &str) -> String {
    format!("hello from {name}")
}
