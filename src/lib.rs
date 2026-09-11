//! The project as a library: the Rust host, the Teal module embedded beside it, and
//! `preload`, which hands both to an `Htl`. Everything that grows lives here — a second
//! `#[host_module]`, a Rust test, an `extern "C"` layer — and every entry point (the
//! binary, a test, another crate embedding this one) goes through `preload`.
//!
//! The split this crate is built on: **Rust is mechanism, Teal is policy.** The host
//! below owns the IO, the transaction and the invariant that must hold at the instant a
//! write lands; which kinds exist, what a card is called, when one may be pruned are the
//! Teal side's, where changing them costs no rebuild.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use eventsdb::sqlite::SqliteEventLog;
use eventsdb::{Committed, EventLog, EventStore, Filter, Position};
use htl::{Htl, TealRecord, host_module};
use serde_json::{Map, Value as Json};
use sha2::{Digest, Sha256};

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

/// JSON as it crosses to Teal: a plain Lua value, declared `any`.
///
/// A newtype rather than `serde_json::Value` itself, because mlua has no conversion for
/// that type and a host cannot write one for a foreign type it does not own. The name is
/// load-bearing in one place only — htl's syntactic mapping spells the ident `Value` as
/// `any`, which is the escape hatch this is meant to be.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Value(pub Json);

impl From<Json> for Value {
    fn from(j: Json) -> Self {
        Value(j)
    }
}

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

/// One eventsdb log and one content-addressed blob directory, under one root.
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
/// window. Every write method takes it; a read does not.
pub struct Store {
    log: SqliteEventLog,
    rt: tokio::runtime::Runtime,
    root: PathBuf,
    command: Mutex<()>,
}

impl Store {
    /// Open the store under `root`, creating `<root>/` and `<root>/blobs/` if they are
    /// not there. The log is `<root>/cards.db`.
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
        Ok(Store {
            log,
            rt,
            root: root.to_path_buf(),
            command: Mutex::new(()),
        })
    }

    /// The write lock. Poisoning is ignored on purpose: the guard protects an ordering
    /// between calls, not an invariant held in memory, and a Lua error raised under it
    /// leaves the log exactly as consistent as eventsdb's own transaction left it.
    fn command(&self) -> MutexGuard<'_, ()> {
        self.command.lock().unwrap_or_else(|e| e.into_inner())
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

    /// The escape hatch: read-only SQL over the log and any table beside it.
    ///
    /// `params` binds by position (`?1`, `?2`, …). Rows come back as JSON objects, one
    /// per row, so Teal sees a table per row keyed by column name.
    pub fn query(&self, sql: &str, params: Vec<Value>) -> anyhow::Result<Vec<Value>> {
        let bound: Vec<Json> = params.into_iter().map(|v| v.0).collect();
        let rows = self.rt.block_on(self.log.query(sql, bound))?;
        Ok(rows.into_iter().map(|r| Value(Json::Object(r))).collect())
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

// ------------------------------------------------------------- JSON <-> Lua

/// How deep a table may nest before this refuses it. A cycle would otherwise recurse
/// until the stack goes, and a JSON document has no cycles to lose.
const MAX_DEPTH: usize = 64;

impl htl::mlua::FromLua for Value {
    fn from_lua(value: htl::mlua::Value, lua: &htl::mlua::Lua) -> htl::mlua::Result<Self> {
        from_lua(value, lua, 0).map(Value)
    }
}

impl htl::mlua::IntoLua for Value {
    fn into_lua(self, lua: &htl::mlua::Lua) -> htl::mlua::Result<htl::mlua::Value> {
        into_lua(self.0, lua)
    }
}

fn from_lua(
    value: htl::mlua::Value,
    lua: &htl::mlua::Lua,
    depth: usize,
) -> htl::mlua::Result<Json> {
    use htl::mlua::Value as Lua;
    if depth > MAX_DEPTH {
        return Err(htl::mlua::Error::external(format!(
            "a table nested more than {MAX_DEPTH} deep has no JSON value (a cycle?)"
        )));
    }
    Ok(match value {
        Lua::Nil => Json::Null,
        Lua::Boolean(b) => Json::Bool(b),
        Lua::Integer(i) => Json::from(i),
        Lua::Number(n) => serde_json::Number::from_f64(n)
            .map(Json::Number)
            .ok_or_else(|| {
                htl::mlua::Error::external(format!(
                    "{n} is not a finite number and has no JSON value"
                ))
            })?,
        Lua::String(s) => Json::String(lua_str(&s)?),
        Lua::Table(t) => table_to_json(t, lua, depth)?,
        other => {
            return Err(htl::mlua::Error::external(format!(
                "a {} has no JSON value",
                other.type_name()
            )));
        }
    })
}

/// A table with a sequence part is a JSON array; anything else is an object, the empty
/// table included. Lua cannot tell `{}` from `[]` and something has to be chosen: an
/// object is the one that round-trips a record with every field cleared.
fn table_to_json(
    t: htl::mlua::Table,
    lua: &htl::mlua::Lua,
    depth: usize,
) -> htl::mlua::Result<Json> {
    let n = t.raw_len();
    if n > 0 {
        let mut items = Vec::with_capacity(n);
        for i in 1..=n {
            items.push(from_lua(t.raw_get(i)?, lua, depth + 1)?);
        }
        return Ok(Json::Array(items));
    }
    let mut object = Map::new();
    for pair in t.pairs::<htl::mlua::Value, htl::mlua::Value>() {
        let (key, value) = pair?;
        let key = match key {
            htl::mlua::Value::String(s) => lua_str(&s)?,
            htl::mlua::Value::Integer(i) => i.to_string(),
            other => {
                return Err(htl::mlua::Error::external(format!(
                    "a {} is not a JSON object key",
                    other.type_name()
                )));
            }
        };
        object.insert(key, from_lua(value, lua, depth + 1)?);
    }
    Ok(Json::Object(object))
}

/// A Lua string as text, refusing rather than mangling what is not UTF-8: JSON holds
/// text and `blob_put` holds bytes, and quietly replacing a byte would blur the two.
fn lua_str(s: &htl::mlua::LuaString) -> htl::mlua::Result<String> {
    let bytes = s.as_bytes();
    std::str::from_utf8(&bytes)
        .map(str::to_string)
        .map_err(|_| {
            htl::mlua::Error::external(
                "a Lua string that is not UTF-8 has no JSON value; put it in a blob",
            )
        })
}

fn into_lua(value: Json, lua: &htl::mlua::Lua) -> htl::mlua::Result<htl::mlua::Value> {
    use htl::mlua::Value as Lua;
    Ok(match value {
        Json::Null => Lua::Nil,
        Json::Bool(b) => Lua::Boolean(b),
        Json::Number(n) => match n.as_i64() {
            Some(i) => Lua::Integer(i),
            None => Lua::Number(n.as_f64().unwrap_or(f64::NAN)),
        },
        Json::String(s) => Lua::String(lua.create_string(&s)?),
        Json::Array(items) => {
            let t = lua.create_table()?;
            for (i, item) in items.into_iter().enumerate() {
                t.raw_set(i + 1, into_lua(item, lua)?)?;
            }
            Lua::Table(t)
        }
        Json::Object(fields) => {
            let t = lua.create_table()?;
            for (key, item) in fields {
                t.raw_set(key, into_lua(item, lua)?)?;
            }
            Lua::Table(t)
        }
    })
}

// ------------------------------------------------------------------- preload

// The Teal module, type-checked at `cargo build` and embedded as stripped bytecode. Keep
// this after `#[host_module]` (same file, source order) so the declaration exists when the
// module is checked.
const MODULE: &[u8] = htl::include_tl_bytes!("src/cardbox/init.tl");

/// Register what this crate provides on a fresh `Htl`: the Rust `store` module opened on
/// `root`, then the Teal module as `require("cardbox")`.
pub fn preload(h: &Htl, root: &Path) -> anyhow::Result<()> {
    Store::open(root)?.htl_preload(h)?;
    // Stripped bytecode: small, and with neither line numbers nor a chunk name, so a
    // failure inside this module reads `?: in function 'cardbox.version'`. `htl run
    // src/cardbox/init.tl` and `htl test` run the Teal itself and name file and line.
    h.preload_bytes("cardbox", MODULE)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::preload;
    use htl::Htl;
    use sha2::Digest;

    /// A store on a directory of its own, reached the way a host reaches it: through
    /// `preload`, so every test below runs against the module Teal actually gets.
    fn opened() -> anyhow::Result<(tempfile::TempDir, Htl)> {
        let dir = tempfile::tempdir()?;
        let h = Htl::new()?;
        preload(&h, dir.path())?;
        Ok((dir, h))
    }

    fn eval<T: htl::mlua::FromLua>(h: &Htl, src: &str) -> anyhow::Result<T> {
        Ok(h.lua().load(src).eval()?)
    }

    #[test]
    fn an_append_comes_back_out_of_the_stream_it_went_into() -> anyhow::Result<()> {
        let (_dir, h) = opened()?;
        let seq: i64 = eval(
            &h,
            r#"
            local store = require('store')
            local rec, err = store:append('card-1', 'card_opened', { pkg = 'cot' }, { n = 3 })
            assert(err == nil, tostring(err))
            assert(rec.seq == 1, 'the first append is seq 1')
            local all, err2 = store:read_stream('card-1')
            assert(err2 == nil, tostring(err2))
            assert(#all == 1, 'one event')
            assert(all[1].kind == 'card_opened', all[1].kind)
            assert(all[1].meta.pkg == 'cot', 'meta round-trips')
            assert(all[1].data.n == 3, 'data round-trips')
            assert(all[1].stream == 'card-1')
            return all[1].seq
            "#,
        )?;
        assert_eq!(seq, 1);
        Ok(())
    }

    /// The fold step 2 is built on: a dependent event may be written while the card is
    /// open, and not before it opened or after it closed.
    #[test]
    fn open_unclosed_declines_before_the_open_and_after_the_close() -> anyhow::Result<()> {
        let (_dir, h) = opened()?;
        let kinds: Vec<String> = eval(
            &h,
            r#"
            local store = require('store')
            local s = 'card-2'

            local rec, err = store:append_if(s, 'open_unclosed', 'samples_appended', nil, { n = 1 })
            assert(rec == nil and err == nil, 'an empty stream is not open')

            store:append(s, 'card_opened', nil, nil)
            local rec2, err2 = store:append_if(s, 'open_unclosed', 'samples_appended', nil, { n = 2 })
            assert(err2 == nil, tostring(err2))
            assert(rec2 ~= nil, 'an opened card takes a dependent event')

            store:append(s, 'card_closed', nil, { outcome = 'ok' })
            local rec3, err3 = store:append_if(s, 'open_unclosed', 'samples_appended', nil, { n = 3 })
            assert(rec3 == nil and err3 == nil, 'a closed card takes nothing more')

            local all = store:read_stream(s)
            local out = {}
            for i = 1, #all do out[i] = all[i].kind end
            return out
            "#,
        )?;
        assert_eq!(kinds, ["card_opened", "samples_appended", "card_closed"]);
        Ok(())
    }

    #[test]
    fn unwritten_accepts_once() -> anyhow::Result<()> {
        let (_dir, h) = opened()?;
        let count: i64 = eval(
            &h,
            r#"
            local store = require('store')
            local first, err = store:append_if('card-3', 'unwritten', 'card_opened', nil, nil)
            assert(err == nil, tostring(err))
            assert(first ~= nil and first.seq == 1, 'the first one writes')
            local second, err2 = store:append_if('card-3', 'unwritten', 'card_opened', nil, nil)
            assert(second == nil and err2 == nil, 'the second one declines')
            return #store:read_stream('card-3')
            "#,
        )?;
        assert_eq!(count, 1);
        Ok(())
    }

    /// `closed_absent` is what a close runs: the second close finds the first and stops.
    #[test]
    fn closed_absent_lets_a_card_close_once() -> anyhow::Result<()> {
        let (_dir, h) = opened()?;
        let count: i64 = eval(
            &h,
            r#"
            local store = require('store')
            store:append('card-4', 'card_opened', nil, nil)
            local first = store:append_if('card-4', 'closed_absent', 'card_closed', nil, { outcome = 'ok' })
            assert(first ~= nil, 'the first close writes')
            local second, err = store:append_if('card-4', 'closed_absent', 'card_closed', nil, { outcome = 'failed' })
            assert(second == nil and err == nil, 'the second close declines')
            return #store:read_stream('card-4', { 'card_closed' })
            "#,
        )?;
        assert_eq!(count, 1);
        Ok(())
    }

    #[test]
    fn a_blob_is_its_own_name_and_writing_it_twice_writes_one_file() -> anyhow::Result<()> {
        let (dir, h) = opened()?;
        let hash: String = eval(
            &h,
            r#"
            local store = require('store')
            local b, err = store:blob_put('the bytes')
            assert(err == nil, tostring(err))
            assert(b.size == 9, b.size)
            local again = store:blob_put('the bytes')
            assert(again.hash == b.hash, 'the same bytes are the same blob')
            local back, err2 = store:blob_get(b.hash)
            assert(err2 == nil, tostring(err2))
            assert(back == 'the bytes', tostring(back))
            local missing, err3 = store:blob_get('0000')
            assert(missing == nil and err3 == nil, 'an unknown hash is nothing, not an error')
            return b.hash
            "#,
        )?;
        // The name is the content and nothing else, and the file is under `blobs/`.
        let expected = hex::encode(sha2::Sha256::digest(b"the bytes"));
        assert_eq!(hash, expected);
        assert!(dir.path().join("blobs").join(&hash).is_file());
        // The atomic write leaves nothing behind: `blobs/` holds the one file.
        let left: Vec<_> = std::fs::read_dir(dir.path().join("blobs"))?
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(left.len(), 1, "{left:?}");
        Ok(())
    }

    #[test]
    fn the_hatch_sees_what_was_appended() -> anyhow::Result<()> {
        let (_dir, h) = opened()?;
        let kinds: Vec<String> = eval(
            &h,
            r#"
            local store = require('store')
            store:append('card-5', 'card_opened', nil, nil)
            store:append('card-5', 'card_closed', nil, nil)
            local rows, err = store:query('SELECT stream, kind FROM events ORDER BY position', {})
            assert(err == nil, tostring(err))
            local out = {}
            for i = 1, #rows do
               local row = rows[i]
               assert(row.stream == 'card-5', row.stream)
               out[i] = row.kind
            end
            return out
            "#,
        )?;
        assert_eq!(kinds, ["card_opened", "card_closed"]);
        Ok(())
    }

    #[test]
    fn an_unknown_decision_says_which_ones_exist() -> anyhow::Result<()> {
        let (_dir, h) = opened()?;
        let err: String = eval(
            &h,
            r#"
            local store = require('store')
            local rec, err = store:append_if('card-6', 'whenever', 'card_opened', nil, nil)
            assert(rec == nil, 'nothing is written')
            return err
            "#,
        )?;
        assert!(err.contains("whenever"), "{err}");
        assert!(err.contains("unwritten"), "{err}");
        assert!(err.contains("open_unclosed"), "{err}");
        assert!(err.contains("closed_absent"), "{err}");
        Ok(())
    }

    #[test]
    fn the_root_is_the_directory_the_store_was_opened_on() -> anyhow::Result<()> {
        let (dir, h) = opened()?;
        let root: String = eval(&h, "return require('store'):root()")?;
        assert_eq!(root, dir.path().display().to_string());
        Ok(())
    }
}
