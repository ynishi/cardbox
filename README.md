# cardbox

A card is one run's immutable record — what it came from, what it cost, the samples it
produced, how it scored, the checkpoint it left. `cardbox` keeps them in an append-only
log so that a card exists from the moment a run starts rather than only when one
succeeds, and so that nothing depending on a card can be written without it.

The layering is Lua's own — mechanism apart from policy. **Rust is the mechanism**:
`src/lib.rs` holds one eventsdb SQLite log under `<root>/cards.db` and a
content-addressed blob directory under `<root>/blobs/`, and exposes them to Teal as
`require("store")` — `append`, `append_if` (folding one of a fixed set of decisions
inside the write), `read_stream`, a read-only SQL hatch, and `blob_put` / `blob_get`.
**Teal is the policy**: `src/cardbox/cards.tl` is a card's life — `open` at the start of a
run, `append_samples` / `record_eval` / `save_checkpoint` while it is open, `close` either
way, and `get`, which folds the stream back into a card — and it is where the naming, the
64 KB inline-or-blob threshold, the find DSL and the prune rules live, because changing
those should cost no rebuild. Every function answers `value, err` and validates before it
calls the store. **eventsdb**
is the log underneath, with the per-stream ordering, the global positions and the
retention guard the policy leans on.

```sh
htl check .            # type-check + lints
htl test               # tests/*_test.tl via htl.test (Teal only: no Rust host)
htl fmt .              # whitespace formatter
cargo test             # the store, exercised from Lua through preload
CARDBOX_ROOT=/tmp/box cargo run     # the binary: the root, and what is in the log
```

The root is `CARDBOX_ROOT`, else `$HOME/.cardbox`. `src/store.d.tl` is generated from
`#[host_module]` in `src/lib.rs`, so the Teal side always sees the current Rust
signatures; `cargo build` writes it, and so does `htl dts` / `htl check`.
