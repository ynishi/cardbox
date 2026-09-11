//! The mechanism: one eventsdb log, one blob directory, and the read models built from
//! the first, exposed to Teal as `require("store")`.
//!
//! The host owns the IO, the transaction and the invariant that must hold at the instant a
//! write lands. Which kinds exist, what a card is called, what a card may be filtered on
//! are the Teal side's, where changing them costs no rebuild.

pub mod json;
pub mod projection;

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use eventsdb::sqlite::{ProjectionRunner, SqliteEventLog};
use eventsdb::{Committed, EventLog, EventStore, Filter, Position};
use htl::{TealRecord, host_module};
use serde_json::{Map, Value as Json};
use sha2::{Digest, Sha256};

pub use json::Value;
use projection::CardsProjection;

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

/// One eventsdb log, one content-addressed blob directory and one read model, under one
/// root.
///
/// Every method is synchronous. eventsdb's API is `async`, so the store owns a
/// current-thread runtime and `block_on`s each call on it: Lua has nothing to suspend
/// into, and a host method that returns a future would be a future nobody polls.
///
/// `command` is the single-writer lock, and it is the reason the decisions below can be
/// trusted. `append_if` makes one stream's fold atomic, but a policy that reads one
/// stream and then writes another — an alias bound only to a card that exists, the case
/// step 4 is for — is two calls, and eventsdb cannot make those one. This process is the
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
        let mut cards = log.runner(CardsProjection)?;
        // `init` is idempotent and creates the tables. It runs on every open rather than
        // on the first one, because "the file exists" is not "the file has this version's
        // tables in it" — a store opened by an older build has the log and not the model.
        rt.block_on(cards.init())?;
        Ok(Store {
            log,
            rt,
            root: root.to_path_buf(),
            command: Mutex::new(()),
            cards: Mutex::new(cards),
        })
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
#[host_module(name = "store", dts = "src/store.d.tl", errors = "return", records = [Recorded, Blob])]
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
        let rule = Rule::parse(decision)?;
        let event = envelope(kind, meta.0, data.0);
        let written = event.clone();
        let decide: eventsdb::Decision = Box::new(move |seen| rule.allows(seen).then_some(written));
        let mut handle = self.log.stream_handle(stream);
        let committed = self.rt.block_on(handle.append_if(rule.kinds(), decide))?;
        Ok(committed.map(|c| recorded_of(stream, &event, c)))
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
    pub fn json_decode(&self, text: &str) -> anyhow::Result<Value> {
        Ok(Value(serde_json::from_str(text)?))
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
#[derive(Clone, Copy)]
enum Rule {
    /// Nothing has been recorded on this stream yet.
    Unwritten,
    /// A `card_opened` is on the stream and no `card_closed` is.
    OpenUnclosed,
    /// No `card_closed` is on the stream. The fold a close itself runs.
    ClosedAbsent,
}

impl Rule {
    const KNOWN: &'static str = r#""unwritten", "open_unclosed", "closed_absent""#;

    fn parse(name: &str) -> anyhow::Result<Rule> {
        match name {
            "unwritten" => Ok(Rule::Unwritten),
            "open_unclosed" => Ok(Rule::OpenUnclosed),
            "closed_absent" => Ok(Rule::ClosedAbsent),
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
        }
    }
}

// ------------------------------------------------------------------ envelopes

fn envelope(kind: &str, meta: Json, data: Json) -> Map<String, Json> {
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
