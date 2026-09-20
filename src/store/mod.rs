//! The mechanism: one eventsdb log, one blob directory, and the read models built from
//! the first, exposed to Teal as `require("store")`.
//!
//! The host owns the IO, the transaction and the invariant that must hold at the instant a
//! write lands. Which kinds exist, what a card is called, what a card may be filtered on
//! are the Teal side's, where changing them costs no rebuild.

pub mod json;
pub mod projection;
pub mod transfer;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use eventsdb::sqlite::{ProjectionRunner, SqliteEventLog};
use eventsdb::{Committed, EventLog, EventStore, Filter, Position};
use htl::{TealRecord, host_module};
use serde_json::{Map, Value as Json};
use sha2::{Digest, Sha256};

pub use json::Value;
use projection::{ALIAS_PREFIX, CardsProjection, STREAM_PREFIX};

/// Projection names this build has retired, newest last.
///
/// A database written by one of them holds every event; what it does not hold is a cursor
/// this build's projection can use. See [`Store::carry_forward`] for what is done about
/// that, and [`projection`]'s module doc for why the name is the version.
const RETIRED: [&str; 3] = ["cards_v1", "cards_v2", "cards_v3"];

/// A Lua string, in and out, as bytes rather than as `&str`.
///
/// This is `mlua::BString` (`bstr::BString`) and **not** mlua's own `LuaString` alias,
/// which names a string mlua owns and which a `#[host_module]` method cannot construct —
/// building one needs the `&Lua` the generated wrapper keeps to itself. `BString`
/// converts both ways with no `&Lua` and without demanding UTF-8, which a blob (a
/// checkpoint, a compressed page) is not.
///
/// The *name* is the load-bearing part. htl maps a Rust type to a Teal one by the last
/// segment of its path, and `LuaString` is one of the three idents it spells `string`.
/// The value really does become a Lua string, so the generated declaration and the
/// behaviour agree; the alias only keeps `src/store.d.tl` from naming a Rust type Teal
/// has never heard of.
type LuaString = htl::mlua::BString;

/// One event, as Teal reads it: the envelope plus where the store put it.
#[derive(TealRecord, Clone, Debug)]
pub struct Recorded {
    pub stream: String,
    /// Per-stream sequence, from 1.
    pub seq: u64,
    /// Global coordinate. 0 for a backend with no database-wide order; SQLite always has one.
    pub position: u64,
    pub epoch_ms: i64,
    pub kind: String,
    pub meta: Value,
    pub data: Value,
}

/// One blob: the name it is stored under and how big it is.
#[derive(TealRecord, Clone, Debug)]
pub struct Blob {
    /// Lowercase hex of the SHA-256 of the bytes. The file's name, and its identity.
    pub hash: String,
    pub size: u64,
}

/// What one [`Store::export`] wrote.
///
/// `file` is absent when there was nothing new: no file is created, `from` and `through`
/// are both the chain's end, and `events` is 0. An export of nothing is not a file holding
/// nothing.
#[derive(TealRecord, Clone, Debug)]
pub struct ExportReport {
    pub file: Option<String>,
    /// The position the export started after — the end of the confirmed chain.
    pub from: u64,
    /// The position of the last event written, or `from` when none was.
    pub through: u64,
    pub events: u64,
}

/// What one [`Store::import`] read back in.
#[derive(TealRecord, Clone, Debug)]
pub struct ImportReport {
    pub events: u64,
    /// Whether every event landed on the position it carried out of the log it came from.
    /// True for a file imported in order into an empty store, which is what restoring a
    /// backup is; false when it merged into a store that already had history, which
    /// renumbers by design.
    pub reproduced_coordinates: bool,
}

/// What one [`Store::retain_streams`] removed.
#[derive(TealRecord, Clone, Debug)]
pub struct RetainReport {
    /// Events deleted, as eventsdb's retention ledger recorded them.
    pub removed: u64,
    /// How many distinct streams those events were spread over — the streams that actually
    /// held something, which is at most the number asked for.
    pub streams: u64,
}

/// What one [`Store::blob_gc`] deleted.
#[derive(TealRecord, Clone, Debug)]
pub struct BlobGcReport {
    pub deleted: u64,
    /// The sum of the sizes the projection recorded for them, not a measurement of the
    /// filesystem: a blob whose file was already gone still counts the size its row held.
    pub bytes: u64,
}

/// One eventsdb log, one content-addressed blob directory and one read model, under one
/// root.
///
/// Every method is synchronous. eventsdb's API is `async`, so the store owns a
/// current-thread runtime and `block_on`s each call on it: Lua has nothing to suspend
/// into, and a host method that returns a future would be a future nobody polls.
///
/// `command` is the single-writer lock, and it is the reason the decisions below can be
/// trusted. `append_if` makes one stream's fold atomic, but a policy that reads one
/// stream and then writes another — an alias bound only to a card that exists, which is
/// what `bind_alias` is — is two calls, and eventsdb cannot make those one. This process is the
/// only writer of this file, so holding `command` across the pair is what closes that
/// window. Every write method takes it; `query` takes it too, because catching the read
/// model up is itself a write.
pub struct Store {
    log: SqliteEventLog,
    rt: tokio::runtime::Runtime,
    root: PathBuf,
    command: Mutex<()>,
    /// The runner for [`CardsProjection`]. Behind its own lock because every method here
    /// takes `&self` — the host module's methods are called from Lua, which has no way to
    /// hold a `&mut` — while `run_once` needs `&mut` to move the projection into the
    /// transaction and back out.
    cards: Mutex<ProjectionRunner<CardsProjection>>,
}

impl Store {
    /// Open the store under `root`, creating `<root>/` and `<root>/blobs/` if they are
    /// not there. The log is `<root>/cards.db`, and the read model's tables are in it.
    pub fn open(root: &Path) -> anyhow::Result<Store> {
        // `time` as well as `rt`: eventsdb backs off with `tokio::time::sleep` when a
        // write finds the database busy, and a runtime with no timer would panic there
        // rather than wait.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()?;
        std::fs::create_dir_all(root)?;
        std::fs::create_dir_all(root.join("blobs"))?;
        let log = rt.block_on(SqliteEventLog::open(root.join("cards.db")))?;
        let mut cards = log.runner(CardsProjection::new())?;
        // `init` is idempotent and creates the tables. It runs on every open rather than
        // on the first one, because "the file exists" is not "the file has this version's
        // tables in it" — a store opened by an older build has the log and not the model.
        rt.block_on(cards.init())?;
        Store::carry_forward(&rt, &log, &mut cards)?;
        Ok(Store {
            log,
            rt,
            root: root.to_path_buf(),
            command: Mutex::new(()),
            cards: Mutex::new(cards),
        })
    }

    /// Bring a database written under a retired projection name up to this one.
    ///
    /// The mechanism eventsdb gives is the checkpoint, keyed by the projection's name, and
    /// the whole of the migration is which name has one: a retired name with a cursor and
    /// a live name without is a file this build has not folded yet. The `cb_*` tables it
    /// finds there were written by the old fold, so they are emptied and replayed rather
    /// than added to — `rebuild()` does the reset and the rewind in one transaction, and
    /// the counters this model keeps (`sample_rows`, `eval_count`, `cb_blobs.refs`) would
    /// otherwise be counted a second time for every event the old cursor had already seen.
    ///
    /// **What this cannot do is remove the retired row.** `checkpoints` is reserved
    /// against writes and the only cursor API is load and save — eventsdb 0.5 has no
    /// "forget this consumer". So the retired name is dragged up to where the live model
    /// stands instead. That is not cosmetic: retention names the consumer with the lowest
    /// cursor and refuses to remove past it (`Error::ConsumerBehind`), so a row parked at
    /// an old head would become the thing that blocks the prune — on behalf of a
    /// reader that does not exist. It is dragged on every open rather than only on the
    /// migration, because the log grows between opens and that row does not.
    ///
    /// **An open is not enough on its own.** The drag leaves the retired cursor where the
    /// live model stood *then*, and every append after it leaves the row behind again — so
    /// a store opened, written to and pruned in the one process would hit exactly the
    /// `ConsumerBehind` this exists to prevent. [`Store::retain_streams`] runs it again
    /// immediately before the delete, on the same reasoning and for the same row.
    fn carry_forward(
        rt: &tokio::runtime::Runtime,
        log: &SqliteEventLog,
        cards: &mut ProjectionRunner<CardsProjection>,
    ) -> anyhow::Result<()> {
        let live = rt.block_on(log.checkpoint_load(CardsProjection::NAME))?;
        let mut rebuilt = false;
        for retired in RETIRED {
            // A checkpoint is written only once a consumer has passed something, so a
            // cursor still at the beginning means there is no row — and no row means no
            // database was ever folded under that name. Saving one would *create* the
            // consumer this method exists to keep from being a problem.
            let at = rt.block_on(log.checkpoint_load(retired))?;
            if at == Position::BEGINNING {
                continue;
            }
            if live == Position::BEGINNING && !rebuilt {
                rt.block_on(cards.rebuild())?;
                rebuilt = true;
            }
            let now = rt.block_on(cards.position())?;
            if at < now {
                rt.block_on(log.checkpoint_save(retired, now))?;
            }
        }
        Ok(())
    }

    /// The `card_opened` of `card_id`, or nothing if no card was opened under that id.
    ///
    /// One row: the decision that writes a `card_opened` is `unwritten`, so there is at
    /// most one, and the filter reads it through the `(kind, position)` index rather than
    /// through the card's whole stream.
    fn card_opened(&self, card_id: &str) -> anyhow::Result<Option<Recorded>> {
        let stream = format!("{STREAM_PREFIX}{card_id}");
        let filter = Filter::kinds(["card_opened"]).streams([stream.as_str()]);
        let page = self
            .rt
            .block_on(self.log.read_all(Position::BEGINNING, &filter, 1))?;
        Ok(page.into_iter().next().map(recorded_from))
    }

    /// Append `{kind, meta, data}` to `stream` if `rule` says so. The caller holds
    /// `command`.
    fn decided(
        &self,
        stream: &str,
        rule: Rule,
        kind: &str,
        meta: Json,
        data: Json,
    ) -> anyhow::Result<Option<Recorded>> {
        let event = envelope(kind, meta, data);
        let written = event.clone();
        let kinds = rule.kinds();
        let decide: eventsdb::Decision = Box::new(move |seen| rule.allows(seen).then_some(written));
        let mut handle = self.log.stream_handle(stream);
        let committed = self.rt.block_on(handle.append_if(kinds, decide))?;
        Ok(committed.map(|c| recorded_of(stream, &event, c)))
    }

    /// The write lock. Poisoning is ignored on purpose: the guard protects an ordering
    /// between calls, not an invariant held in memory, and a Lua error raised under it
    /// leaves the log exactly as consistent as eventsdb's own transaction left it.
    fn command(&self) -> MutexGuard<'_, ()> {
        self.command.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn runner(&self) -> MutexGuard<'_, ProjectionRunner<CardsProjection>> {
        self.cards.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Fold everything the read model has not seen. The caller already holds `command`;
    /// `Mutex` is not reentrant, so taking it again here would deadlock the process.
    fn caught_up(&self) -> anyhow::Result<u64> {
        let mut runner = self.runner();
        Ok(self.rt.block_on(runner.catch_up())? as u64)
    }

    fn blobs(&self) -> PathBuf {
        self.root.join("blobs")
    }
}

/// Exposed to Teal as `require("store")`. Its declaration is written to `src/store.d.tl`
/// by this macro at build time, and by `htl dts` / `htl check` without building.
///
/// `errors = "return"`: every fallible method comes back Lua-style, `value, err`. An
/// `Option` return then has three answers rather than two, which `append_if` needs —
/// `rec, nil` wrote, `nil, err` failed, and `nil, nil` is the decision declining.
#[host_module(name = "store", dts = "src/store.d.tl", errors = "return", records = [Recorded, Blob, ExportReport, ImportReport, RetainReport, BlobGcReport])]
impl Store {
    /// Append `{kind, meta, data}` to `stream`.
    ///
    /// A null `meta` or `data` is left out of the envelope rather than written as JSON
    /// null: eventsdb's contract is that those two keys are optional and scalars-only /
    /// any-depth respectively, and `null` is neither absent nor a value it wants.
    pub fn append(
        &self,
        stream: &str,
        kind: &str,
        meta: Value,
        data: Value,
    ) -> anyhow::Result<Recorded> {
        let _lock = self.command();
        let event = envelope(kind, meta.0, data.0);
        let mut handle = self.log.stream_handle(stream);
        let committed = self.rt.block_on(handle.append(event.clone()))?;
        Ok(recorded_of(stream, &event, committed))
    }

    /// Append `{kind, meta, data}` only if `decision`, folded over `stream` inside the
    /// write, says so. Returns the event when it wrote and nothing when it declined.
    ///
    /// `decision` names one of a fixed set built here. Teal never passes code: a
    /// decision runs while the log holds its write lock, and a callback into Lua from
    /// there would put an interpreter this host does not control inside eventsdb's
    /// transaction. Teal chooses; Rust decides.
    ///
    /// On the Lua side the three outcomes are `rec, nil` (written), `nil, err` (failed)
    /// and `nil, nil` (declined) — so `if rec == nil and err == nil then` is the test for
    /// a decision that found nothing to do.
    pub fn append_if(
        &self,
        stream: &str,
        decision: &str,
        kind: &str,
        meta: Value,
        data: Value,
    ) -> anyhow::Result<Option<Recorded>> {
        let _lock = self.command();
        self.decided(stream, Rule::parse(decision)?, kind, meta.0, data.0)
    }

    /// Bind `name` to `card_id`, if that card was opened and the name does not already
    /// mean it.
    ///
    /// **Why this is a method and not another decision string.** The invariant — an alias
    /// points only at a card that exists — spans two streams, and `append_if` folds one.
    /// So this is two calls: read `card-<card_id>` for its `card_opened`, then `append_if`
    /// on `alias-<name>`. What makes the pair atomic is `command`, held across both, and
    /// what makes that enough is that this process is the only writer of this file — the
    /// design's reservation stream, and the BP note that a single local writer is a
    /// legitimate answer to a cross-aggregate uniqueness rule rather than a shortcut.
    /// Exposing an alias decision through `append_if` would let Teal make the second call
    /// without the first, which is exactly the dangling alias this step is for.
    ///
    /// `Err` when no card was opened under `card_id`. `Ok(None)` — the decision declining
    /// — when the name already means that card: a rebind to where the alias already points
    /// asks for a state that holds, so it is idempotent and writes nothing. Rebinding to a
    /// *different* card appends another `alias_bound` on the same stream, which is what
    /// keeps the history: nothing is overwritten and nothing has to be released first.
    pub fn bind_alias(
        &self,
        name: &str,
        card_id: &str,
        note: Option<String>,
    ) -> anyhow::Result<Option<Recorded>> {
        let _lock = self.command();
        let Some(opened) = self.card_opened(card_id)? else {
            return Err(anyhow::anyhow!("no card {card_id}"));
        };
        let mut meta = Map::new();
        meta.insert("card_id".to_string(), Json::String(card_id.to_string()));
        // The pkg is the card's own, read off the event that opened it, so `alias_list`
        // can answer "the aliases in this pkg" out of the alias rows alone. Taking it from
        // the caller would let the two disagree about one thing.
        if let Some(pkg) = opened.meta.0.get("pkg").filter(|p| p.is_string()) {
            meta.insert("pkg".to_string(), pkg.clone());
        }
        self.decided(
            &alias_stream(name),
            Rule::AliasNot(card_id.to_string()),
            "alias_bound",
            Json::Object(meta),
            note_data(note),
        )
    }

    /// Release `name`, if it currently means anything. `Ok(None)` when it does not.
    ///
    /// The event carries the card_id it released, so the history reads without a join and
    /// a rebuild can tell "released from A" from "released from B".
    pub fn release_alias(
        &self,
        name: &str,
        note: Option<String>,
    ) -> anyhow::Result<Option<Recorded>> {
        let _lock = self.command();
        let stream = alias_stream(name);
        let data = note_data(note);
        // The card_id comes out of the same fold that decides, not out of a read before
        // it: the fold runs while the log holds the write lock, so the id the event
        // carries is the binding that was there when it was released. The cell is how the
        // finished event gets back here — a `Decision` is `FnOnce` and hands what it built
        // to eventsdb rather than to its caller.
        let captured: Arc<Mutex<Option<Map<String, Json>>>> = Arc::default();
        let sink = Arc::clone(&captured);
        let decide: eventsdb::Decision = Box::new(move |seen| {
            let card_id = bound_to(seen)?;
            let mut meta = Map::new();
            meta.insert("card_id".to_string(), Json::String(card_id));
            let event = envelope("alias_released", Json::Object(meta), data);
            *sink.lock().unwrap_or_else(|e| e.into_inner()) = Some(event.clone());
            Some(event)
        });
        let mut handle = self.log.stream_handle(&stream);
        let committed = self
            .rt
            .block_on(handle.append_if(Rule::AliasBound.kinds(), decide))?;
        let Some(at) = committed else {
            return Ok(None);
        };
        let event = captured
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "an alias_released landed on {stream} that this store did not build"
                )
            })?;
        Ok(Some(recorded_of(&stream, &event, at)))
    }

    /// The whole of `stream` in `seq` order, optionally only `kinds`.
    ///
    /// Paged rather than read at once: `read_all` is one page and a cursor, so this loops
    /// until a page comes back short. Nothing is held between pages.
    pub fn read_stream(
        &self,
        stream: &str,
        kinds: Option<Vec<String>>,
    ) -> anyhow::Result<Vec<Recorded>> {
        const PAGE: usize = 512;
        let filter = match &kinds {
            Some(k) => Filter::kinds(k.iter().map(String::as_str)),
            None => Filter::all(),
        }
        .streams([stream]);
        let mut out = Vec::new();
        let mut from = Position::BEGINNING;
        loop {
            let page = self.rt.block_on(self.log.read_all(from, &filter, PAGE))?;
            let short = page.len() < PAGE;
            for stored in page {
                from = stored.position;
                out.push(recorded_from(stored));
            }
            if short {
                break;
            }
        }
        Ok(out)
    }

    /// The escape hatch: read-only SQL over the log, the read model's tables and anything
    /// else beside them.
    ///
    /// **Read-your-writes.** The projection is caught up first, under the same lock a
    /// write takes, so a Teal `find` that runs a line after a `close` sees the closed
    /// card. Without that the read model would be eventually consistent, which for a
    /// single-process store is a cost with nothing bought by it: the only writer is this
    /// process, so "everything written" is a state this call can reach rather than wait
    /// for. A caught-up projection costs one empty batch read when there is nothing to do.
    ///
    /// `params` binds by position (`?1`, `?2`, …). Rows come back as JSON objects, one
    /// per row, so Teal sees a table per row keyed by column name.
    pub fn query(&self, sql: &str, params: Vec<Value>) -> anyhow::Result<Vec<Value>> {
        let _lock = self.command();
        self.caught_up()?;
        let bound: Vec<Json> = params.into_iter().map(|v| v.0).collect();
        let rows = self.rt.block_on(self.log.query(sql, bound))?;
        Ok(rows.into_iter().map(|r| Value(Json::Object(r))).collect())
    }

    /// Fold everything the read model has not seen yet, and say how many events that was.
    ///
    /// `query` does this on its own, so nothing needs to call it to read correctly. It is
    /// here for the two cases where the number is the point: a batch job that wants the
    /// model warm before it starts timing, and a test that wants to prove a read did not
    /// need it.
    pub fn catch_up(&self) -> anyhow::Result<u64> {
        let _lock = self.command();
        self.caught_up()
    }

    /// Empty the read model and replay the log into it, returning the events applied.
    ///
    /// For a fold that changed without its tables changing shape. When the *shape* changes
    /// incompatibly the move is to rename the projection (`cards_v1` → `cards_v2`), which
    /// gives the new model its own cursor and leaves the old one readable until the switch.
    pub fn rebuild(&self) -> anyhow::Result<u64> {
        let _lock = self.command();
        let mut runner = self.runner();
        Ok(self.rt.block_on(runner.rebuild())? as u64)
    }

    /// Store `bytes` under the hex of their SHA-256 and return the name.
    ///
    /// Content-addressed, so it is idempotent by construction: the same bytes are the
    /// same file, and a second put of them writes nothing. The write goes to a temporary
    /// name in the same directory and is renamed into place, so a reader never sees a
    /// half-written blob under a hash that promises the whole of it.
    pub fn blob_put(&self, bytes: LuaString) -> anyhow::Result<Blob> {
        let _lock = self.command();
        let hash = hex::encode(Sha256::digest(&bytes[..]));
        let size = bytes.len() as u64;
        let path = self.blobs().join(&hash);
        if path.exists() {
            return Ok(Blob { hash, size });
        }
        let tmp = self.blobs().join(format!(".{hash}.{}", std::process::id()));
        std::fs::write(&tmp, &bytes[..])?;
        std::fs::rename(&tmp, &path)?;
        Ok(Blob { hash, size })
    }

    /// The bytes stored under `hash`, or nothing if no blob has that name.
    pub fn blob_get(&self, hash: &str) -> anyhow::Result<Option<LuaString>> {
        let path = self.blobs().join(hash);
        match std::fs::read(&path) {
            Ok(bytes) => Ok(Some(LuaString::from(bytes))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Where the blob named `hash` lives, whether or not it is there yet.
    pub fn blob_path(&self, hash: &str) -> String {
        self.blobs().join(hash).display().to_string()
    }

    /// `v` as JSON text.
    ///
    /// Here because Teal has no JSON of its own, and because the policy side needs to
    /// *weigh* a value before deciding where to put it: a batch of sample rows is inlined
    /// or blobbed on the length of exactly this text. The conversion is the one every
    /// other method on this store uses, so what is measured here is what would be stored.
    pub fn json_encode(&self, v: Value) -> anyhow::Result<String> {
        Ok(serde_json::to_string(&v.0)?)
    }

    /// `text`, parsed. The other direction, for reading back what `blob_put` was handed:
    /// a blob is bytes to this store and JSON only to whoever wrote it.
    /// A short, stable fingerprint of a JSON value: the first 16 hex digits of the SHA-256
    /// of its canonical text, where canonical means every object's keys are in sorted
    /// order and nothing is pretty-printed.
    ///
    /// Here rather than in Teal because Teal has no hash, and canonical because two runs
    /// that were given the same params should print the same whatever order their tables
    /// happened to be walked in. What goes *into* the fingerprint is the policy side's
    /// call — `cards.open` hands it `params` and nothing else — and this only answers what
    /// those bytes are called.
    pub fn digest(&self, v: Value) -> String {
        let canonical = canonical_json(&v.0);
        let hash = Sha256::digest(canonical.as_bytes());
        hex::encode(&hash[..8])
    }

    pub fn json_decode(&self, text: &str) -> anyhow::Result<Value> {
        Ok(Value(serde_json::from_str(text)?))
    }

    /// Write everything the log holds past the end of the confirmed export chain to one
    /// JSON Lines file under `<root>/export/`, and confirm it.
    ///
    /// This is the half of a prune that has to happen first, and the whole log is what it
    /// takes: `Guard::Exported` chains the confirmed **unfiltered** receipts from position
    /// 0 and refuses to remove past the chain's end, so an export of only the streams being
    /// pruned would leave the chain — and therefore the guard — exactly where it was. See
    /// [`transfer`] for the order and the reasoning; what the directory ends up being is an
    /// append-only backup of the log, one file per call, which is what `import` reads.
    ///
    /// Nothing new is not an error and not an empty file: `file` comes back absent and
    /// `events` is 0.
    pub fn export(&self) -> anyhow::Result<ExportReport> {
        let _lock = self.command();
        self.run_export()
    }

    /// Read a JSON Lines file written by [`Store::export`] back into this log, and catch
    /// the read models up.
    ///
    /// `seq` and `position` are this log's to assign; `kind`, `meta`, `data`, `epoch_ms`
    /// and `_schema_version` travel unchanged. `reproduced_coordinates` says whether every
    /// event landed back on the position it carried, which is true for a file imported in
    /// order into an empty store — the check that a restore really is the same log rather
    /// than the same events.
    pub fn import(&self, path: &str) -> anyhow::Result<ImportReport> {
        let _lock = self.command();
        self.run_import(path)
    }

    /// Remove every event of `streams`, if the exports vouch for them and no read model
    /// would be left behind, and give the freed pages back to the filesystem.
    ///
    /// `Guard::Exported`, never `Force`: the one operation here that can make a correct
    /// read wrong is the one operation that asks permission. Both refusals come back as
    /// errors that say what to do — run an export, or catch the named consumer up.
    ///
    /// `removed` counts events and `streams` counts the streams they were spread over,
    /// which is at most the number asked for: a stream with nothing on it is not an error
    /// and is not counted.
    pub fn retain_streams(&self, streams: Vec<String>) -> anyhow::Result<RetainReport> {
        let _lock = self.command();
        self.run_retain(streams)
    }

    /// Delete every blob nothing points at any more, and the row that counted the
    /// pointers.
    ///
    /// `cb_blobs.refs` is the projection's count — one per `samples_appended` or
    /// `checkpoint_saved` naming the hash, one back per card the prune journal removed —
    /// so a blob two cards share survives the first of them going. `cb_blobs` is this
    /// crate's table rather than eventsdb's, which is why the hatch lets the row be
    /// deleted at all.
    pub fn blob_gc(&self) -> anyhow::Result<BlobGcReport> {
        let _lock = self.command();
        self.run_blob_gc()
    }

    /// The directory this store was opened on.
    pub fn root(&self) -> String {
        self.root.display().to_string()
    }
}

// ------------------------------------------------------------------ decisions

/// The fixed set of folds `append_if` will run.
///
/// Each one is a question about a stream that has to be answered at the instant the
/// write lands, and each names the kinds it needs: the fold is shown only those, which is
/// the difference between reading a long stream and reading three events of it.
///
/// The first four are what `append_if` will look up by name. The two alias folds are
/// not: they are reached only through [`Store::bind_alias`] and [`Store::release_alias`],
/// because a bind that skipped the card read those methods do first is the bug the whole
/// step is about. Teal chooses between the methods; it cannot assemble one.
#[derive(Clone)]
enum Rule {
    /// Nothing has been recorded on this stream yet.
    Unwritten,
    /// A `card_opened` is on the stream and no `card_closed` is.
    OpenUnclosed,
    /// No `card_closed` is on the stream. The fold a close itself runs.
    ClosedAbsent,
    /// A `card_opened` is on the stream, whatever came after it. The fold an assessment
    /// and a tag run: those are said *about* a run, not produced by it, so a close does
    /// not end them the way it ends samples and checkpoints.
    Opened,
    /// This alias does not currently mean this card — either it means another one or it
    /// means nothing. The fold a bind runs.
    AliasNot(String),
    /// This alias currently means something. The fold a release runs.
    AliasBound,
}

/// What `alias-<name>` currently means: the card_id of the last `alias_bound` not undone
/// by an `alias_released`, or nothing.
///
/// The fold both alias decisions are, and the one place the current binding is read from
/// the log rather than from the read model. An `alias_bound` with no `meta.card_id` cannot
/// be written by this store (`bind_alias` puts the id there), and reads as unbound here
/// rather than as a binding to nothing; the projection reports the same event as corrupt
/// when it folds it, which is where a reader would want to hear about it.
fn bound_to(seen: &[eventsdb::Current]) -> Option<String> {
    let mut bound = None;
    for event in seen {
        match event.kind() {
            "alias_bound" => {
                bound = event
                    .get("meta")
                    .and_then(|m| m.get("card_id"))
                    .and_then(Json::as_str)
                    .map(str::to_string);
            }
            "alias_released" => bound = None,
            _ => {}
        }
    }
    bound
}

impl Rule {
    const KNOWN: &'static str = r#""unwritten", "open_unclosed", "closed_absent", "opened""#;

    fn parse(name: &str) -> anyhow::Result<Rule> {
        match name {
            "unwritten" => Ok(Rule::Unwritten),
            "open_unclosed" => Ok(Rule::OpenUnclosed),
            "closed_absent" => Ok(Rule::ClosedAbsent),
            "opened" => Ok(Rule::Opened),
            other => Err(anyhow::anyhow!(
                "unknown decision {other:?}; the decisions this store knows are {}",
                Rule::KNOWN
            )),
        }
    }

    /// What the fold is shown. `None` would be the whole stream.
    fn kinds(&self) -> Option<&'static [&'static str]> {
        match self {
            // Unwritten asks whether anything is there, so it cannot name kinds: a
            // stream holding only events of other kinds would read as empty.
            Rule::Unwritten => None,
            Rule::OpenUnclosed => Some(&["card_opened", "card_closed"]),
            Rule::ClosedAbsent => Some(&["card_closed"]),
            Rule::Opened => Some(&["card_opened"]),
            Rule::AliasNot(_) | Rule::AliasBound => Some(&["alias_bound", "alias_released"]),
        }
    }

    fn allows(&self, seen: &[eventsdb::Current]) -> bool {
        match self {
            Rule::Unwritten => seen.is_empty(),
            Rule::OpenUnclosed => {
                seen.iter().any(|e| e.kind() == "card_opened")
                    && !seen.iter().any(|e| e.kind() == "card_closed")
            }
            Rule::ClosedAbsent => !seen.iter().any(|e| e.kind() == "card_closed"),
            Rule::Opened => seen.iter().any(|e| e.kind() == "card_opened"),
            Rule::AliasNot(card_id) => bound_to(seen).as_deref() != Some(card_id.as_str()),
            Rule::AliasBound => bound_to(seen).is_some(),
        }
    }
}

/// `v` as text with every object's keys sorted, so equal values print equal.
///
/// serde_json's `Map` is already a `BTreeMap` unless `preserve_order` is on, and a
/// dependency could turn that on for the whole build without this crate noticing; walking
/// the value here is what keeps the fingerprint independent of that.
fn canonical_json(v: &Json) -> String {
    match v {
        Json::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let fields: Vec<String> = keys
                .into_iter()
                .map(|k| format!("{}:{}", Json::String(k.clone()), canonical_json(&map[k])))
                .collect();
            format!("{{{}}}", fields.join(","))
        }
        Json::Array(items) => {
            let items: Vec<String> = items.iter().map(canonical_json).collect();
            format!("[{}]", items.join(","))
        }
        other => other.to_string(),
    }
}

// ------------------------------------------------------------------ envelopes

/// The stream an alias's events live on.
fn alias_stream(name: &str) -> String {
    format!("{ALIAS_PREFIX}{name}")
}

/// A note, as the `data` of an alias event. Absent when there is none, rather than an
/// object with a null in it.
fn note_data(note: Option<String>) -> Json {
    match note {
        Some(note) => {
            let mut data = Map::new();
            data.insert("note".to_string(), Json::String(note));
            Json::Object(data)
        }
        None => Json::Null,
    }
}

pub(crate) fn envelope(kind: &str, meta: Json, data: Json) -> Map<String, Json> {
    let mut event = Map::new();
    event.insert("kind".to_string(), Json::String(kind.to_string()));
    if !meta.is_null() {
        event.insert("meta".to_string(), meta);
    }
    if !data.is_null() {
        event.insert("data".to_string(), data);
    }
    event
}

/// The event as it was written, plus the coordinates the write returned.
fn recorded_of(stream: &str, event: &Map<String, Json>, at: Committed) -> Recorded {
    Recorded {
        stream: stream.to_string(),
        seq: at.seq,
        position: at.position.map(|p| p.get()).unwrap_or(0),
        epoch_ms: at.epoch_ms as i64,
        kind: field(event, "kind")
            .as_str()
            .unwrap_or_default()
            .to_string(),
        meta: Value(field(event, "meta")),
        data: Value(field(event, "data")),
    }
}

/// An event read back out of the log.
fn recorded_from(stored: eventsdb::Recorded) -> Recorded {
    let position = stored.position.get();
    let stream = stored.stream;
    let event = stored.event.into_inner();
    Recorded {
        stream,
        seq: field(&event, "seq").as_u64().unwrap_or(0),
        position,
        epoch_ms: field(&event, "epoch_ms").as_i64().unwrap_or(0),
        kind: field(&event, "kind")
            .as_str()
            .unwrap_or_default()
            .to_string(),
        meta: Value(field(&event, "meta")),
        data: Value(field(&event, "data")),
    }
}

fn field(event: &Map<String, Json>, key: &str) -> Json {
    event.get(key).cloned().unwrap_or(Json::Null)
}
