//! The project as a library: the Rust host, the Teal module embedded beside it, and
//! `preload`, which hands both to an `Htl`. Everything that grows lives here — a second
//! `#[host_module]`, a Rust test, an `extern "C"` layer, a window loop — and every entry
//! point (the binary, a test, another crate embedding this one) goes through `preload`.

use htl::{Htl, TealRecord, host_module};

/// Crosses the Rust <-> Teal boundary as a plain table (`host.Point` on the Teal side).
#[derive(TealRecord, Clone)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

pub struct Host;

/// Exposed to Teal as `require("host")`. Its declaration is written to `src/host.d.tl`
/// by this macro at build time, and by `htl dts` / `htl check` without building.
#[host_module(name = "host", dts = "src/host.d.tl", records = [Point])]
impl Host {
    pub fn greet(&self, who: &str) -> String {
        format!("hello from Rust, {who}")
    }

    pub fn scale(&self, p: Point, k: f64) -> Point {
        Point { x: p.x * k, y: p.y * k }
    }
}

// The Teal module, type-checked at `cargo build` and embedded as stripped bytecode. Keep
// this after `#[host_module]` (same file, source order) so the declaration exists when the
// module is checked.
const MODULE: &[u8] = htl::include_tl_bytes!("src/cardbox/init.tl");

/// Register what this crate provides on a fresh `Htl`: the Rust `host` module, then the
/// Teal module as `require("cardbox")`.
pub fn preload(h: &Htl) -> anyhow::Result<()> {
    Host.htl_preload(h)?;
    // Stripped bytecode: small, and with neither line numbers nor a chunk name, so a
    // failure inside this module reads `?: in function 'cardbox.greet'`. `htl run
    // src/cardbox/init.tl` and `htl test` run the Teal itself and name file and line.
    h.preload_bytes("cardbox", MODULE)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::preload;
    use htl::Htl;

    /// The Teal side, exercised the way a host does it: through `preload`, so the test
    /// fails if the module stops loading or `greet` changes shape.
    #[test]
    fn greet_comes_back_through_preload() -> anyhow::Result<()> {
        let h = Htl::new()?;
        preload(&h)?;
        let g: htl::mlua::Table = h
            .lua()
            .load("return require('cardbox').greet('rust')")
            .eval()?;
        assert_eq!(g.get::<String>("text")?, "hello, rust");
        Ok(())
    }
}
