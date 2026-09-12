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
//
// The one dependency comes from where `htl pkg install` put it: the link htl keeps at the
// dependency's entry, so it is the same file `htl check` and `htl test` read. The path is
// machine-local, like `node_modules/` — a fresh clone runs `htl pkg install` before
// `cargo build`.
const HTLX_LIST: &[u8] = htl::include_tl_bytes!(".htl/modules/entries/htlx/list.tl");
const FIND: &[u8] = htl::include_tl_bytes!("src/cardbox/find.tl");
const ALIAS: &[u8] = htl::include_tl_bytes!("src/cardbox/alias.tl");
const PRUNE: &[u8] = htl::include_tl_bytes!("src/cardbox/prune.tl");
const CARDS: &[u8] = htl::include_tl_bytes!("src/cardbox/cards.tl");
const MODULE: &[u8] = htl::include_tl_bytes!("src/cardbox/init.tl");
const CLI: &[u8] = htl::include_tl_bytes!("src/cardbox/cli.tl");

/// Register what this crate provides on a fresh `Htl`: the Rust `store` module opened on
/// `root`, htl's own native modules as `require("std.*")`, the dependency as
/// `require("htlx.list")`, then the Teal modules as
/// `require("cardbox.find")`, `require("cardbox.alias")`,
/// `require("cardbox.prune")`, `require("cardbox.cards")`, `require("cardbox")` and
/// `require("cardbox.cli")`.
pub fn preload(h: &Htl, root: &Path) -> anyhow::Result<()> {
    Store::open(root)?.htl_preload(h)?;
    // `std.*`: mlua-batteries, which htl assembles under that name. Four of its modules are
    // reached for here — `json` for the array tag, `string` for the text helpers, `argparse`
    // for the command line, `time` for the millisecond clock a prune's cutoff is on — and
    // this one call registers every module the build carries, so a Teal file that requires
    // another needs no change on this side.
    //
    // `json` is also the crate `store::json` converts with, so a table `std.json.array()`
    // tagged on the Teal side is still a list when the store weighs it, which a bare `{}`
    // is not.
    h.install_std()?;
    // Stripped bytecode: small, and with neither line numbers nor a chunk name, so a
    // failure inside these modules reads `?: in function 'cards.open'`. `htl run
    // src/cardbox/init.tl` and `htl test` run the Teal itself and name file and line.
    //
    // Leaves first, because each requires the ones above it as it loads. Lua only consults
    // `package.preload` when the `require` runs, so the order is not what makes this work
    // — it is what keeps the file honest about the dependencies.
    h.preload_bytes("htlx.list", HTLX_LIST)?;
    h.preload_bytes("cardbox.find", FIND)?;
    h.preload_bytes("cardbox.alias", ALIAS)?;
    h.preload_bytes("cardbox.prune", PRUNE)?;
    h.preload_bytes("cardbox.cards", CARDS)?;
    h.preload_bytes("cardbox", MODULE)?;
    // Last, because it is the only one that requires the whole of the module above it. It
    // is registered by `preload` rather than by the binary so that a test, or another
    // crate, reaches the same dispatch the command line does (`src/tests/cli.rs`).
    h.preload_bytes("cardbox.cli", CLI)?;
    Ok(())
}

#[cfg(test)]
mod tests;
