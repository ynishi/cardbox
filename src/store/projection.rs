//! The read models: the five card kinds folded into tables in the same file as the log.
//!
//! # Why the fold is here and not in Teal
//!
//! eventsdb's projection contract is that applying an event and moving the consumer's
//! cursor happen inside **one** transaction — which is only expressible if the fold writes
//! through the transaction the log is being read on. That transaction is a Rust value with
//! a lifetime; there is no way to hand it to Lua and no way to let a Lua error unwind
//! through it. So the fold is mechanism, and it sits beside the append it mirrors.
//!
//! What stays policy is everything above the tables: which of them a query touches, what a
//! card may be filtered on, how a refusal is worded. `src/cardbox/find.tl` is that half,
//! and it reaches these tables through the store's read-only SQL hatch.
//!
//! # The name is the version
//!
//! [`CardsProjection::NAME`] is `cards_v2`, and the suffix is the migration convention
//! rather than decoration: a projection's name **is** the primary key of its checkpoint,
//! so a shape change old rows cannot be carried into is done by renaming the projection.
//! The new name has no checkpoint, so it starts at the beginning of the log and folds all
//! of it, and nothing has to reason about which of the old rows were still right.
//! `rebuild()` on the same name is the other route — empty and replay — which is what a
//! changed fold over unchanged tables wants.
//!
//! `cards_v1` was this model without the two alias kinds and without `cb_aliases` /
//! `cb_alias_log`. [`crate::Store::open`] carries a database written under that name
//! forward; what it does and what it cannot do is documented there.
//!
//! Where this departs from the textbook (Marten's "build the new model beside the old one
//! and switch when it has caught up"): the two versions here share the `cb_*` table names,
//! so the old model does not survive the migration. There is nothing to serve it to. This
//! store is one process that opens the file, folds and answers; a window in which two read
//! models are both live is a thing a service needs and a library embedded in its only
//! reader does not.
//!
//! # The `cb_` prefix
//!
//! Every table here is `cb_`-prefixed because it shares a file with eventsdb's own —
//! `events`, `stream_seq`, `checkpoints`, `retention`, `exports`. Those names are reserved:
//! the transaction handed to `apply` refuses writes to them (and refuses creating anything
//! that would shadow one), so a collision is not a silent overwrite. The prefix is what
//! keeps the refusal from ever being the thing that tells us.

use eventsdb::sqlite::Projection;
use eventsdb::sqlite::rusqlite::{self, Transaction};
use eventsdb::{Error, Result};
use serde_json::Value as Json;

/// The stream prefix a card's events live under: `card-<id>`.
pub const STREAM_PREFIX: &str = "card-";

/// The stream prefix an alias's events live under: `alias-<name>`.
pub const ALIAS_PREFIX: &str = "alias-";

/// The read model over a card's five kinds and an alias's two.
///
/// Stateless apart from the name it answers to: everything it knows is in the tables,
/// which is what makes a rebuild a replay rather than a reconstruction of anything held
/// here.
pub struct CardsProjection {
    name: String,
}

impl Default for CardsProjection {
    fn default() -> Self {
        CardsProjection::new()
    }
}

impl CardsProjection {
    /// The consumer name, and so the identity of the cursor. See the module doc for what
    /// the `_v2` is for.
    pub const NAME: &'static str = "cards_v2";

    /// The projection this build folds under.
    pub fn new() -> CardsProjection {
        CardsProjection {
            name: CardsProjection::NAME.to_string(),
        }
    }

    /// The same fold under some other cursor.
    ///
    /// Only the migration test, and only to write a database whose checkpoint is under a
    /// name this build has retired — which is the one thing about an older store that
    /// `Store::open` has to handle and that nothing else can produce in-process. The
    /// tables it creates are this version's, so what the test reproduces is the *cursor*
    /// of the old build and not its schema; the rest of the old schema is a subset of
    /// this one, so `init` on the way in would have added the difference anyway.
    #[cfg(test)]
    pub fn under(name: &str) -> CardsProjection {
        CardsProjection {
            name: name.to_string(),
        }
    }

    /// The kinds these streams carry. Naming them is not only a filter: it is what lets
    /// the runner read through the `(kind, position)` index instead of walking the whole
    /// log, and it is the reason `apply` may treat an unknown kind as a bug.
    pub const KINDS: [&'static str; 7] = [
        "card_opened",
        "samples_appended",
        "eval_recorded",
        "checkpoint_saved",
        "card_closed",
        "alias_bound",
        "alias_released",
    ];
}

/// The tables, and the indexes the three questions `find` actually asks need: which cards
/// are in this pkg, which are in this state, which are the newest, and who descends from
/// this one.
///
/// `cb_aliases` is the *current* binding, one row per name, and `cb_alias_log` is every
/// binding there has been. The first is a fold that forgets — a rebind overwrites the row,
/// a release deletes it — and the second is the fold that does not, which is what makes
/// "what did this alias point at in March" a question with an answer. Neither is the
/// authority: `alias-<name>` in the log is, and both of these are replayed out of it.
///
/// `cb_cards` carries `stats` and `cost` twice — once as the JSON that was written, once
/// flattened into columns. The JSON is what `get` hands back unchanged, so a card reads the
/// same whatever a run chose to put in there; the columns are what a `WHERE mean_score >
/// 0.5` compares without `json_extract` on every row. A key the writer left out is NULL,
/// and NULL compares false, which is the answer a filter on a card that never recorded a
/// score should give.
const CREATE: &str = "\
CREATE TABLE IF NOT EXISTS cb_cards (
    id               TEXT PRIMARY KEY,
    pkg              TEXT,
    scenario         TEXT,
    source           TEXT,
    created_by       TEXT,
    note             TEXT,
    state            TEXT NOT NULL,
    opened_ms        INTEGER,
    closed_ms        INTEGER,
    opened_position  INTEGER,
    error            TEXT,
    stats_json       TEXT,
    cost_json        TEXT,
    mean_score       REAL,
    n                INTEGER,
    pass_rate        REAL,
    passed           INTEGER,
    elapsed_ms       INTEGER,
    llm_calls        INTEGER,
    sample_batches   INTEGER NOT NULL DEFAULT 0,
    sample_rows      INTEGER NOT NULL DEFAULT 0,
    eval_count       INTEGER NOT NULL DEFAULT 0,
    checkpoint_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS cb_cards_pkg       ON cb_cards (pkg);
CREATE INDEX IF NOT EXISTS cb_cards_state     ON cb_cards (state);
CREATE INDEX IF NOT EXISTS cb_cards_opened_ms ON cb_cards (opened_ms);

CREATE TABLE IF NOT EXISTS cb_samples (
    card_id   TEXT    NOT NULL,
    seq       INTEGER NOT NULL,
    n         INTEGER,
    rows_json TEXT,
    blob      TEXT,
    size      INTEGER,
    epoch_ms  INTEGER,
    PRIMARY KEY (card_id, seq)
);

CREATE TABLE IF NOT EXISTS cb_evals (
    card_id   TEXT    NOT NULL,
    seq       INTEGER NOT NULL,
    data_json TEXT,
    epoch_ms  INTEGER,
    PRIMARY KEY (card_id, seq)
);

CREATE TABLE IF NOT EXISTS cb_checkpoints (
    card_id  TEXT    NOT NULL,
    seq      INTEGER NOT NULL,
    blob     TEXT,
    size     INTEGER,
    format   TEXT,
    note     TEXT,
    epoch_ms INTEGER,
    PRIMARY KEY (card_id, seq)
);

CREATE TABLE IF NOT EXISTS cb_lineage (
    child  TEXT NOT NULL,
    parent TEXT NOT NULL,
    PRIMARY KEY (child, parent)
);
CREATE INDEX IF NOT EXISTS cb_lineage_parent ON cb_lineage (parent);

CREATE TABLE IF NOT EXISTS cb_blobs (
    hash TEXT PRIMARY KEY,
    size INTEGER,
    refs INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS cb_aliases (
    name     TEXT PRIMARY KEY,
    card_id  TEXT NOT NULL,
    pkg      TEXT,
    bound_ms INTEGER,
    note     TEXT
);
CREATE INDEX IF NOT EXISTS cb_aliases_card ON cb_aliases (card_id);

CREATE TABLE IF NOT EXISTS cb_alias_log (
    name     TEXT    NOT NULL,
    seq      INTEGER NOT NULL,
    kind     TEXT    NOT NULL,
    card_id  TEXT,
    epoch_ms INTEGER,
    note     TEXT,
    PRIMARY KEY (name, seq)
);
";

/// What `reset` undoes. Dropping a table takes its indexes with it, so they are not listed.
const DROP: &str = "\
DROP TABLE IF EXISTS cb_cards;
DROP TABLE IF EXISTS cb_samples;
DROP TABLE IF EXISTS cb_evals;
DROP TABLE IF EXISTS cb_checkpoints;
DROP TABLE IF EXISTS cb_lineage;
DROP TABLE IF EXISTS cb_blobs;
DROP TABLE IF EXISTS cb_aliases;
DROP TABLE IF EXISTS cb_alias_log;
";

impl Projection for CardsProjection {
    fn name(&self) -> &str {
        &self.name
    }

    fn kinds(&self) -> Option<Vec<String>> {
        Some(
            CardsProjection::KINDS
                .iter()
                .map(|k| k.to_string())
                .collect(),
        )
    }

    fn init(&mut self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch(CREATE).map_err(storage)
    }

    fn reset(&mut self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch(DROP).map_err(storage)
    }

    /// One event, folded.
    ///
    /// The card's id comes from the **stream name** rather than from `meta`: the stream is
    /// what the store's own decisions fold over, so it is the identity the invariants are
    /// already stated in terms of, and a `meta` that disagreed with it would describe a
    /// card that no `append_if` was ever protecting. An event of one of these kinds on a
    /// stream that is not a card's is a bug in whatever wrote it, and is reported rather
    /// than skipped.
    ///
    /// An unknown kind is likewise an error. `kinds()` is what the runner filters on, so
    /// one arriving here means the filter and this match have drifted apart, and a fold
    /// that quietly ignored it would leave a read model missing rows with nothing saying so.
    fn apply(&mut self, tx: &Transaction<'_>, event: &eventsdb::Recorded) -> Result<()> {
        let kind = event.kind();
        let seq = event.seq() as i64;
        let position = event.position.get() as i64;
        let epoch_ms = num(event.event.get("epoch_ms")).unwrap_or(0);
        let meta = event.event.get("meta");
        let data = event.event.get("data");

        // Two stream shapes, so the kind picks the prefix before anything is stripped: an
        // `alias_bound` is on `alias-<name>` and a `card_opened` on `card-<id>`, and
        // asking either name to yield the other's identity is how a fold would quietly
        // file an alias under a card.
        match kind {
            "card_opened" => opened(
                tx,
                card_id(&event.stream, kind)?,
                epoch_ms,
                position,
                meta,
                data,
            ),
            "samples_appended" => samples(tx, card_id(&event.stream, kind)?, seq, epoch_ms, data),
            "eval_recorded" => eval(tx, card_id(&event.stream, kind)?, seq, epoch_ms, data),
            "checkpoint_saved" => {
                checkpoint(tx, card_id(&event.stream, kind)?, seq, epoch_ms, data)
            }
            "card_closed" => closed(tx, card_id(&event.stream, kind)?, epoch_ms, meta, data),
            "alias_bound" => bound(
                tx,
                alias_name(&event.stream, kind)?,
                seq,
                epoch_ms,
                meta,
                data,
            ),
            "alias_released" => released(
                tx,
                alias_name(&event.stream, kind)?,
                seq,
                epoch_ms,
                meta,
                data,
            ),
            other => Err(Error::storage(format!(
                "the {} projection was handed a {other:?} event, which is not one of the \
                 kinds it asked for ({})",
                self.name,
                CardsProjection::KINDS.join(", ")
            ))),
        }
    }
}

/// `card-<id>` → `<id>`.
fn card_id<'a>(stream: &'a str, kind: &str) -> Result<&'a str> {
    stream.strip_prefix(STREAM_PREFIX).ok_or_else(|| {
        Error::storage(format!(
            "a {kind:?} event is on stream {stream:?}, which is not a card's: \
             a card's stream is {STREAM_PREFIX}<id>"
        ))
    })
}

/// `alias-<name>` → `<name>`.
///
/// The alias's name comes from the stream for the same reason a card's id does: the
/// stream is what the store's decision folds over, so it is the identity the invariant is
/// already stated in terms of. A `meta.name` that disagreed with it would name a
/// reservation nobody was holding.
fn alias_name<'a>(stream: &'a str, kind: &str) -> Result<&'a str> {
    stream.strip_prefix(ALIAS_PREFIX).ok_or_else(|| {
        Error::storage(format!(
            "a {kind:?} event is on stream {stream:?}, which is not an alias's: \
             an alias's stream is {ALIAS_PREFIX}<name>"
        ))
    })
}

/// The row a card starts as.
///
/// `ON CONFLICT DO NOTHING`: a stream carries one `card_opened` because `append_if`'s
/// `unwritten` decision is what `cards.open` writes under, and only a raw `store:append`
/// could produce a second. If one is there anyway, the first open stays the card's opening
/// — the alternative is an error that would refuse every later read of the whole model,
/// including the rebuild that would be the way out of it.
fn opened(
    tx: &Transaction<'_>,
    id: &str,
    epoch_ms: i64,
    position: i64,
    meta: Option<&Json>,
    data: Option<&Json>,
) -> Result<()> {
    tx.execute(
        "INSERT INTO cb_cards (id, pkg, scenario, source, created_by, note, state,
                               opened_ms, opened_position)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7, ?8)
         ON CONFLICT (id) DO NOTHING",
        rusqlite::params![
            id,
            text(meta, "pkg"),
            text(meta, "scenario"),
            text(meta, "source"),
            text(meta, "created_by"),
            text(data, "note"),
            epoch_ms,
            position,
        ],
    )
    .map_err(storage)?;

    // `data.parents` is an array when a run named one and an empty *object* when it named
    // none — Lua cannot tell `{}` from `[]`, and the host resolves that in the one
    // direction that round-trips a cleared record. `as_array` answering `None` for the
    // object is therefore the same answer as an empty list, which is what this wants.
    let parents = data.and_then(|d| d.get("parents")).and_then(Json::as_array);
    for parent in parents.into_iter().flatten() {
        let Some(parent) = parent.as_str() else {
            continue;
        };
        tx.execute(
            "INSERT INTO cb_lineage (child, parent) VALUES (?1, ?2)
             ON CONFLICT (child, parent) DO NOTHING",
            rusqlite::params![id, parent],
        )
        .map_err(storage)?;
    }
    Ok(())
}

fn samples(
    tx: &Transaction<'_>,
    id: &str,
    seq: i64,
    epoch_ms: i64,
    data: Option<&Json>,
) -> Result<()> {
    let n = num(data.and_then(|d| d.get("n")));
    let rows = data
        .and_then(|d| d.get("rows"))
        .map(|rows| rows.to_string());
    let blob = text(data, "blob");
    let size = num(data.and_then(|d| d.get("size")));
    tx.execute(
        "INSERT INTO cb_samples (card_id, seq, n, rows_json, blob, size, epoch_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT (card_id, seq) DO NOTHING",
        rusqlite::params![id, seq, n, rows, blob.as_deref(), size, epoch_ms],
    )
    .map_err(storage)?;
    tx.execute(
        "UPDATE cb_cards SET sample_batches = sample_batches + 1,
                             sample_rows = sample_rows + ?2
         WHERE id = ?1",
        rusqlite::params![id, n.unwrap_or(0)],
    )
    .map_err(storage)?;
    if let Some(hash) = blob {
        reference_blob(tx, &hash, size)?;
    }
    Ok(())
}

fn eval(
    tx: &Transaction<'_>,
    id: &str,
    seq: i64,
    epoch_ms: i64,
    data: Option<&Json>,
) -> Result<()> {
    tx.execute(
        "INSERT INTO cb_evals (card_id, seq, data_json, epoch_ms) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (card_id, seq) DO NOTHING",
        rusqlite::params![id, seq, data.map(Json::to_string), epoch_ms],
    )
    .map_err(storage)?;
    tx.execute(
        "UPDATE cb_cards SET eval_count = eval_count + 1 WHERE id = ?1",
        rusqlite::params![id],
    )
    .map_err(storage)?;
    Ok(())
}

fn checkpoint(
    tx: &Transaction<'_>,
    id: &str,
    seq: i64,
    epoch_ms: i64,
    data: Option<&Json>,
) -> Result<()> {
    let blob = text(data, "blob");
    let size = num(data.and_then(|d| d.get("size")));
    tx.execute(
        "INSERT INTO cb_checkpoints (card_id, seq, blob, size, format, note, epoch_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT (card_id, seq) DO NOTHING",
        rusqlite::params![
            id,
            seq,
            blob.as_deref(),
            size,
            text(data, "format"),
            text(data, "note"),
            epoch_ms,
        ],
    )
    .map_err(storage)?;
    tx.execute(
        "UPDATE cb_cards SET checkpoint_count = checkpoint_count + 1 WHERE id = ?1",
        rusqlite::params![id],
    )
    .map_err(storage)?;
    if let Some(hash) = blob {
        reference_blob(tx, &hash, size)?;
    }
    Ok(())
}

/// How a card ends: the state, the JSON as written, and the handful of numbers flattened
/// out of it so a filter can compare them.
fn closed(
    tx: &Transaction<'_>,
    id: &str,
    epoch_ms: i64,
    meta: Option<&Json>,
    data: Option<&Json>,
) -> Result<()> {
    let state = match text(meta, "outcome").as_deref() {
        Some("ok") => "closed_ok",
        _ => "closed_failed",
    };
    let stats = data.and_then(|d| d.get("stats"));
    let cost = data.and_then(|d| d.get("cost"));
    tx.execute(
        "UPDATE cb_cards SET state = ?2, closed_ms = ?3, error = ?4,
                             stats_json = ?5, cost_json = ?6,
                             mean_score = ?7, n = ?8, pass_rate = ?9, passed = ?10,
                             elapsed_ms = ?11, llm_calls = ?12
         WHERE id = ?1",
        rusqlite::params![
            id,
            state,
            epoch_ms,
            text(data, "error"),
            stats.map(Json::to_string),
            cost.map(Json::to_string),
            real(stats.and_then(|s| s.get("mean_score"))),
            num(stats.and_then(|s| s.get("n"))),
            real(stats.and_then(|s| s.get("pass_rate"))),
            num(stats.and_then(|s| s.get("passed"))),
            num(cost.and_then(|c| c.get("elapsed_ms"))),
            num(cost.and_then(|c| c.get("llm_calls"))),
        ],
    )
    .map_err(storage)?;
    Ok(())
}

/// An alias now points here.
///
/// The current binding is one row that the rebind overwrites, because "what does this
/// name mean" has one answer and a table with two rows for it would need a reader to know
/// which. What the overwrite would lose goes to `cb_alias_log` first, which keeps every
/// one of them.
fn bound(
    tx: &Transaction<'_>,
    name: &str,
    seq: i64,
    epoch_ms: i64,
    meta: Option<&Json>,
    data: Option<&Json>,
) -> Result<()> {
    let card_id = text(meta, "card_id");
    let note = text(data, "note");
    alias_logged(
        tx,
        name,
        seq,
        "alias_bound",
        card_id.as_deref(),
        epoch_ms,
        note.as_deref(),
    )?;
    // An `alias_bound` with no `card_id` is a binding to nothing, which the store cannot
    // write: `bind_alias` reads the card before the append and puts its id in the meta.
    // One arriving here anyway is reported rather than filed as a row pointing nowhere.
    let Some(card_id) = card_id else {
        return Err(Error::storage(format!(
            "an alias_bound on {ALIAS_PREFIX}{name} carries no meta.card_id, \
             so it binds the name to nothing"
        )));
    };
    tx.execute(
        "INSERT INTO cb_aliases (name, card_id, pkg, bound_ms, note) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (name) DO UPDATE SET card_id = excluded.card_id, pkg = excluded.pkg,
                                          bound_ms = excluded.bound_ms, note = excluded.note",
        rusqlite::params![name, card_id, text(meta, "pkg"), epoch_ms, note],
    )
    .map_err(storage)?;
    Ok(())
}

/// The name points at nothing again. The row goes; the history does not.
fn released(
    tx: &Transaction<'_>,
    name: &str,
    seq: i64,
    epoch_ms: i64,
    meta: Option<&Json>,
    data: Option<&Json>,
) -> Result<()> {
    alias_logged(
        tx,
        name,
        seq,
        "alias_released",
        text(meta, "card_id").as_deref(),
        epoch_ms,
        text(data, "note").as_deref(),
    )?;
    tx.execute(
        "DELETE FROM cb_aliases WHERE name = ?1",
        rusqlite::params![name],
    )
    .map_err(storage)?;
    Ok(())
}

/// One line of an alias's history, keyed by the seq it has on its own stream.
fn alias_logged(
    tx: &Transaction<'_>,
    name: &str,
    seq: i64,
    kind: &str,
    card_id: Option<&str>,
    epoch_ms: i64,
    note: Option<&str>,
) -> Result<()> {
    tx.execute(
        "INSERT INTO cb_alias_log (name, seq, kind, card_id, epoch_ms, note)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT (name, seq) DO NOTHING",
        rusqlite::params![name, seq, kind, card_id, epoch_ms, note],
    )
    .map_err(storage)?;
    Ok(())
}

/// One more thing points at these bytes. Step 5's GC is the reader: a blob whose `refs`
/// reach 0 after the events naming it are gone is the only one it may remove.
fn reference_blob(tx: &Transaction<'_>, hash: &str, size: Option<i64>) -> Result<()> {
    tx.execute(
        "INSERT INTO cb_blobs (hash, size, refs) VALUES (?1, ?2, 1)
         ON CONFLICT (hash) DO UPDATE SET refs = refs + 1, size = COALESCE(excluded.size, size)",
        rusqlite::params![hash, size],
    )
    .map_err(storage)?;
    Ok(())
}

fn text(object: Option<&Json>, key: &str) -> Option<String> {
    object
        .and_then(|o| o.get(key))
        .and_then(Json::as_str)
        .map(str::to_string)
}

fn num(value: Option<&Json>) -> Option<i64> {
    value.and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

fn real(value: Option<&Json>) -> Option<f64> {
    value.and_then(Json::as_f64)
}

fn storage(e: rusqlite::Error) -> Error {
    Error::storage(e.to_string())
}
