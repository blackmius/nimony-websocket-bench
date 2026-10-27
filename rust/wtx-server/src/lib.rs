//! Shared bits of the two wtx servers: the environment knobs that the nimony
//! and Bun servers also read, so one `scripts/bench.sh` line can start any of
//! them.

use std::{env, str::FromStr};

/// `PORT`, as the other servers in this benchmark read it.
#[must_use]
pub fn env_u16(key: &str, fallback: u16) -> u16 {
    env::var(key)
        .ok()
        .and_then(|value| u16::from_str(&value).ok())
        .unwrap_or(fallback)
}

/// `CLIENTS_COUNT` and friends.
#[must_use]
pub fn env_usize(key: &str, fallback: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|value| usize::from_str(&value).ok())
        .unwrap_or(fallback)
}

/// The `?name=` the chat client puts on the handshake, from a request path.
///
/// The nimony server answers `"anon"` when there is none and so does Bun; the
/// name is only a prefix on every published line, but it is part of the
/// payload the benchmark moves, so it is taken from the same place.
#[must_use]
pub fn name_from_path(path: &str) -> String {
    match path.split_once("name=") {
        Some((_, name)) => name.split('&').next().unwrap_or(name).to_string(),
        None => String::from("anon"),
    }
}
