# cardbox

A card is one run's immutable record — what it came from, what it cost, the samples it
produced, how it scored, the checkpoint it left. `cardbox` keeps them in an append-only
log so that a card exists from the moment a run starts rather than only when one
succeeds, and so that nothing depending on a card can be written without it.

The layering is Lua's own — mechanism apart from policy. **Rust is the mechanism**:
`src/store/` holds one eventsdb SQLite log under `<root>/cards.db`, a content-addressed
blob directory under `<root>/blobs/` and the read models folded out of the log, and exposes
them to Teal as `require("store")` — `append`, `append_if` (folding one of a fixed set of
decisions inside the write), `bind_alias` / `release_alias`, `read_stream`, a read-only SQL
hatch, `catch_up` / `rebuild`, and `blob_put` / `blob_get`.
**Teal is the policy**: `src/cardbox/cards.tl` is a card's life — `open` at the start of a
run, `append_samples` / `record_eval` / `save_checkpoint` while it is open, `close` either
way, and `get` — `src/cardbox/find.tl` is the read half (`list`, `find`, `lineage` and the
query builder behind them), and `src/cardbox/alias.tl` is the names over the top. That is
where the naming, the 64 KB inline-or-blob
threshold, the column and operator whitelists and the prune rules live, because changing
those should cost no rebuild. Every function answers `value, err` and validates before it
calls the store. **eventsdb**
is the log underneath, with the per-stream ordering, the global positions and the
retention guard the policy leans on.

## Read models

The log answers "what happened to this card"; it does not answer "which cards in `cot`
scored above 0.5". So `src/store/projection.rs` folds the seven kinds into tables in
the same `cards.db` — `cb_cards`, `cb_samples`, `cb_evals`, `cb_checkpoints`, `cb_lineage`,
`cb_blobs`, `cb_aliases`, `cb_alias_log` — through eventsdb's projection runner, which applies a batch and moves its
cursor in **one** transaction. That is what exactly-once means here: a fold that fails
part-way moves neither, so the retry neither double-counts nor skips. The `cb_` prefix
keeps the tables clear of eventsdb's own (`events`, `stream_seq`, `checkpoints`,
`retention`, `exports`), which the transaction handed to a projection refuses to write
anyway.

`cb_cards` carries a close's `stats` and `cost` twice: as the JSON that was written, which
`get` hands back unchanged, and flattened into `mean_score` / `n` / `pass_rate` / `passed` /
`elapsed_ms` / `llm_calls`, which is what a `find` compares without `json_extract` on every
row. `cb_blobs.refs` counts what points at each blob, and is what step 5's GC will read.

The projection is named `cards_v2`, and the suffix is the migration convention: a shape
change old rows cannot be carried into is a rename, because a projection's name *is* the
primary key of its checkpoint, so a new name starts with no cursor and folds the log from
the beginning. `cards_v1` was this model before the aliases. `Store::open` recognises a
database whose cursor is under a retired name — the retired name has one, the live name has
none — and rebuilds under the new one, which empties the `cb_*` tables first so that the
counters in them are not added to a second time. The retired row itself cannot be removed
(eventsdb 0.5 has no "forget this consumer", and `checkpoints` is reserved against writes),
so it is dragged up to where the live model stands, on every open: left where the old build
parked it, it would become the consumer retention refuses to remove past.
`store:rebuild()` is the other route — empty and replay — for when the fold changed and the
shape did not.

Reads are **read-your-writes**. `store:query` catches the projection up under the same lock
a write takes, so a `cards.find` a line after a `cards.close` sees the closed card;
`store:catch_up()` is exposed for the cases where the number of events applied is itself
the point. `cards.get` reads these tables, and `cards.fold` adds a card's stream up event
by event — the fold is the definition the tables have to reproduce, and `cargo test` holds
the two against each other.

## Aliases

A card is immutable and its id is minted once, so what moves is the *name*. An alias is a
human name (`champion`, `cot.baseline`) for exactly one card id; a card may carry several;
the names are global. That is the shape model registries converged on — MLflow deprecated
its staging states in favour of aliases — with the history they do not keep: a name lives
on its own stream `alias-<name>`, `alias_bound` / `alias_released` in order, and the
current binding is the fold of the two. A rebind appends another `alias_bound` to the same
stream, so `cards.alias_history` says everywhere a name has been while `cb_aliases` holds
only where it is now.

**Binding is a host method rather than a decision Teal names.** Every other invariant here
is one stream's fold, which `store:append_if` runs inside the write. "An alias may point
only at a card that was opened" is not: it reads `card-<id>` and writes `alias-<name>`, and
eventsdb cannot make two streams one write. So `store:bind_alias` does both under the
store's command lock — the reservation pattern, with a single-process writer standing in
for the conditional append that would be needed across processes — and no generic alias
decision is exposed on `append_if` for Teal to reach for instead. A name cannot be made to
dangle, because the only route to writing one reads the card first.

`cards.alias` / `cards.alias_release` answer three ways: the event, an error, or
`nil, nil` when the store declined because the name already means that card (or already
means nothing). Binding is therefore idempotent, which is what lets `cards.promote` run on
a schedule: it selects among the `closed_ok` cards of a pkg — through `cards.find`, so the
column whitelist is the one every read uses — takes the highest `mean_score` (or
`pass_rate` / `passed` / `n`) among those with at least `min_n` cases, ties going to the
newest, and binds the alias to it. A re-run that finds the same winner reports
`changed = false` and writes nothing. `cards.pick_best` is that choice on its own, a pure
function over summaries, which is how `htl test` argues about the rule with no store in the
room. The rest of the reads are `cards.get_by_alias`, `cards.alias_list` and
`cards.alias_history`, and `cards.get` now lists a card's names.

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
