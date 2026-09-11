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
hatch, `catch_up` / `rebuild`, `blob_put` / `blob_get`, and the four the removal half needs
(`export` / `import`, `retain_streams`, `blob_gc`).
**Teal is the policy**: `src/cardbox/cards.tl` is a card's life — `open` at the start of a
run, `append_samples` / `record_eval` / `save_checkpoint` while it is open, `close` either
way, and `get` — `src/cardbox/find.tl` is the read half (`list`, `find`, `lineage` and the
query builder behind them), and `src/cardbox/alias.tl` is the names over the top and
`src/cardbox/prune.tl` is the end of a card's life. That is
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
row. `cb_blobs.refs` counts what points at each blob, and is what `store:blob_gc()` reads.

The projection is named `cards_v3`, and the suffix is the migration convention: a shape
change old rows cannot be carried into is a rename, because a projection's name *is* the
primary key of its checkpoint, so a new name starts with no cursor and folds the log from
the beginning. `cards_v1` was this model before the aliases and `cards_v2` before the prune journal.
`Store::open` recognises a
database whose cursor is under a retired name — the retired name has one, the live name has
none — and rebuilds under the new one, which empties the `cb_*` tables first so that the
counters in them are not added to a second time. The retired row itself cannot be removed
(eventsdb 0.5 has no "forget this consumer", and `checkpoints` is reserved against writes),
so it is dragged up to where the live model stands, on every open — and again inside
`retain_streams`, because the log grows between an open and a prune and the row does not.
Left where the old build parked it, it would become the consumer retention refuses to
remove past.
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

## Prune and export

A card is an immutable record, so removing one is the only operation here that can make a
correct read wrong. It happens in the order the event-sourcing literature converged on —
**write the delete-request event first, let the read models purge, and only then remove the
bytes** — and `cards.prune` is that whole sequence:

```
1 select + refuse    cards.find selects; a card with an alias, a card that is somebody's
                     parent, and an open card are skipped into their own buckets
2 store:export()     the WHOLE log, from the end of the confirmed chain, to
                     <root>/export/<utc>-<from>-<through>.jsonl, then confirmed
3 append             cards_pruned on the stream `prune` — the journal
                     the projection folds it and purges every cb_* row of those cards
4 retain_streams     retain(Plan::Streams, Guard::Exported) + reclaim: the bytes go
5 blob_gc            the blobs whose last reference step 3 took away
```

**The export is the whole log and not the streams being pruned**, and that is not a
choice. `Guard::Exported` does not ask whether a stream was exported; it chains the
confirmed **unfiltered** export receipts from position 0 and refuses any plan that would
remove past the chain's end. A filtered export is recorded as not whole and never extends
that chain, so exporting exactly what was about to go would leave the guard exactly where
it was. The cursor for the next export is eventsdb's own `exported_through()` — the chain's
end — so `<root>/export/` ends up an append-only JSONL backup of the log that grows by one
file per call, which is what `cards.import(store, path)` reads back. An import into an empty
store reports `reproduced_coordinates = true`: every event landed on the position it had
where it came from, which is the check that the copy is the same *log* and not merely the
same events.

**Three cards are never pruned**, each because of something outside the card: one that
carries an alias (the name would be left pointing at nothing), one that is somebody's
parent (the lineage edge would dangle), and one that is still open. Only the third can be
overruled, by naming `"open"` in `states` — saying it out loud is the whole of the safety.
A spec must also be bounded by at least one of `pkg` / `pkg_like` / `older_than_ms` / `ids`
and must carry a `reason`, which goes into the journal and outlives the cards. `pkg_like`
is a LIKE pattern and the query carries `ESCAPE '\'`, so a literal that holds `_` or `%`
goes through `cards.like_escape` first: the pkg prefix `_test_` is
`cards.like_escape("_test_") .. "%"`.

**What a pruned card leaves behind** is the journal entry — `cards.prune_log(store)` reads
it newest first, with the ids, the reason and the export file — and nothing else. The
stream `prune` is never itself retained, so it is the pointer event the removed history
points at. Because a pruned card's events are physically gone afterwards, a rebuild replays
the journal over a card that was never recreated and every delete in it is a no-op; that is
why `CardsProjection` may declare `tolerates_truncation`, and why the totals it keeps
(`sample_rows`, `cb_blobs.refs`) come out the same on a replay as they were before it.

**Blobs are reference-counted, not owned.** `cb_blobs.refs` goes up once per
`samples_appended` or `checkpoint_saved` naming the hash and back down once per pruned card
that named it, so a blob two cards share survives the first of them going; `blob_gc`
removes only the rows that reached zero, and deletes the file after the row, never before.

```lua
cards.prune(store, { pkg_like = cards.like_escape("_test_") .. "%",
                     reason = "test debris", dry_run = true })   -- ask first
cards.export(store)                                              -- the backup on its own
cards.import(store, "/path/to/<root>/export/20250911T120000Z-0-42.jsonl")
```

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
