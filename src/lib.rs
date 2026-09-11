//! The project as a library: the Rust host, the Teal modules embedded beside it, and
//! `preload`, which hands both to an `Htl`. Every entry point — the binary, a test,
//! another crate embedding this one — goes through `preload`.
//!
//! The split this crate is built on: **Rust is mechanism, Teal is policy.** [`store`] owns
//! the IO, the transaction, the invariant that must hold at the instant a write lands, and
//! the exactly-once fold that keeps the read models in step with the log; which kinds
//! exist, what a card is called, what a card may be filtered on and how a refusal is
//! worded are the Teal side's, where changing them costs no rebuild.

pub mod store;

use std::path::Path;

use htl::Htl;

pub use store::json::Value;
pub use store::{Blob, Recorded, Store};

// The Teal modules, type-checked at `cargo build` and embedded as stripped bytecode. Keep
// these after the `#[host_module]` (which is in `store`, compiled first by the `mod store;`
// above) so the declaration exists when the modules are checked. Every module the binary
// reaches has to be here: `preload` is the only searcher an embedded run has, and a
// `require` of a name nobody registered fails at the line that needs it rather than at
// startup.
const FIND: &[u8] = htl::include_tl_bytes!("src/cardbox/find.tl");
const ALIAS: &[u8] = htl::include_tl_bytes!("src/cardbox/alias.tl");
const CARDS: &[u8] = htl::include_tl_bytes!("src/cardbox/cards.tl");
const MODULE: &[u8] = htl::include_tl_bytes!("src/cardbox/init.tl");

/// Register what this crate provides on a fresh `Htl`: the Rust `store` module opened on
/// `root`, then the Teal modules as `require("cardbox.find")`, `require("cardbox.alias")`,
/// `require("cardbox.cards")` and `require("cardbox")`.
pub fn preload(h: &Htl, root: &Path) -> anyhow::Result<()> {
    Store::open(root)?.htl_preload(h)?;
    // Stripped bytecode: small, and with neither line numbers nor a chunk name, so a
    // failure inside these modules reads `?: in function 'cards.open'`. `htl run
    // src/cardbox/init.tl` and `htl test` run the Teal itself and name file and line.
    //
    // Leaves first, because each requires the ones above it as it loads. Lua only consults
    // `package.preload` when the `require` runs, so the order is not what makes this work
    // — it is what keeps the file honest about the dependencies.
    h.preload_bytes("cardbox.find", FIND)?;
    h.preload_bytes("cardbox.alias", ALIAS)?;
    h.preload_bytes("cardbox.cards", CARDS)?;
    h.preload_bytes("cardbox", MODULE)?;
    Ok(())
}

#[cfg(test)]
mod tests;
