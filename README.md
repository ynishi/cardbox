# cardbox

A card is one run's immutable record — what it came from, what it cost, the samples it
produced, how it scored, the checkpoint it left. `cardbox` keeps them in an append-only
log so that a card exists from the moment a run starts rather than only when one
succeeds, and so that nothing depending on a card can be written without it.

The layering is Lua's own — mechanism apart from policy. **Rust is the mechanism**:
`src/store/` holds one eventsdb SQLite log under `<root>/cards.db`, a content-addressed
blob directory under `<root>/blobs/` and the read models folded out of the log, and exposes
them to Teal as `require("store")` — `append`, `append_if` (folding one of a fixed set of
decisions inside the write), `read_stream`, a read-only SQL hatch, `catch_up` / `rebuild`,
and `blob_put` / `blob_get`.
**Teal is the policy**: `src/cardbox/cards.tl` is a card's life — `open` at the start of a
run, `append_samples` / `record_eval` / `save_checkpoint` while it is open, `close` either
way, and `get` — and `src/cardbox/find.tl` is the read half: `list`, `find`, `lineage` and
the query builder behind them. That is where the naming, the 64 KB inline-or-blob
threshold, the column and operator whitelists and the prune rules live, because changing
those should cost no rebuild. Every function answers `value, err` and validates before it
calls the store. **eventsdb**
is the log underneath, with the per-stream ordering, the global positions and the
retention guard the policy leans on.

## Read models

The log answers "what happened to this card"; it does not answer "which cards in `cot`
scored above 0.5". So `src/store/projection.rs` folds the five card kinds into tables in
the same `cards.db` — `cb_cards`, `cb_samples`, `cb_evals`, `cb_checkpoints`, `cb_lineage`,
`cb_blobs` — through eventsdb's projection runner, which applies a batch and moves its
cursor in **one** transaction. That is what exactly-once means here: a fold that fails
part-way moves neither, so the retry neither double-counts nor skips. The `cb_` prefix
keeps the tables clear of eventsdb's own (`events`, `stream_seq`, `checkpoints`,
`retention`, `exports`), which the transaction handed to a projection refuses to write
anyway.

`cb_cards` carries a close's `stats` and `cost` twice: as the JSON that was written, which
`get` hands back unchanged, and flattened into `mean_score` / `n` / `pass_rate` / `passed` /
`elapsed_ms` / `llm_calls`, which is what a `find` compares without `json_extract` on every
row. `cb_blobs.refs` counts what points at each blob, and is what step 5's GC will read.

The projection is named `cards_v1`, and the suffix is the migration convention: a shape
change old rows cannot be carried into is a rename to `cards_v2`, which starts with its own
cursor and leaves the old model readable until the switch. `store:rebuild()` is the other
route — empty and replay — for when the fold changed and the shape did not.

Reads are **read-your-writes**. `store:query` catches the projection up under the same lock
a write takes, so a `cards.find` a line after a `cards.close` sees the closed card;
`store:catch_up()` is exposed for the cases where the number of events applied is itself
the point. `cards.get` reads these tables, and `cards.fold` adds a card's stream up event
by event — the fold is the definition the tables have to reproduce, and `cargo test` holds
the two against each other.

```sh
htl check .            # type-check + lints
htl test               # tests/*_test.tl via htl.test (Teal only: no Rust host)
htl fmt .              # whitespace formatter
cargo test             # the store, exercised from Lua through preload
CARDBOX_ROOT=/tmp/box cargo run     # the binary: the root, and what is in the log
```

The root is `CARDBOX_ROOT`, else `$HOME/.cardbox`. `src/store.d.tl` is generated from
`#[host_module]` in `src/store/mod.rs`, so the Teal side always sees the current Rust
signatures; `cargo build` writes it, and so does `htl dts` / `htl check`.
