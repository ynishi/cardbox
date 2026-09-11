//! The Lua-driven tests: everything here reaches the crate the way a host does, through
//! `preload`, so what is exercised is the module Teal actually gets rather than a Rust
//! function standing in for it.
//!
//! Three files, by what they are about. [`store`] is the mechanism — appends, decisions,
//! blobs, the hatch. [`cards`] is a card's life through the policy module. [`read_models`]
//! is the projection and the reads built on it.

mod cards;
mod read_models;
mod store;

use htl::Htl;

/// A store on a directory of its own, reached through `preload`.
fn opened() -> anyhow::Result<(tempfile::TempDir, Htl)> {
    let dir = tempfile::tempdir()?;
    let h = Htl::new()?;
    crate::preload(&h, dir.path())?;
    Ok((dir, h))
}

fn eval<T: htl::mlua::FromLua>(h: &Htl, src: &str) -> anyhow::Result<T> {
    Ok(h.lua().load(src).eval()?)
}
