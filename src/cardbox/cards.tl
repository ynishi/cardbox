-- A card's life, as policy. What a card may be called, what has to be present before one
-- is opened, when a batch of samples is small enough to live inside the event and when it
-- becomes a blob, what "closed" means and what closing with a failure still leaves behind.
--
-- None of this is what makes the invariants hold — `store:append_if` folds the stream
-- inside the write and is the thing that cannot be talked around. What lives here is
-- every decision that is only a decision: the naming, the shapes, the thresholds, the
-- wording of a refusal. Changing one of those costs no rebuild, which is the whole reason
-- they are on this side of the line.
--
-- Every function answers `value, err`. A caller's mistake is `nil, "..."` and never an
-- `error()`: a wrong argument is an answer, not a crash. Validation runs before the first
-- store call in every one of them, so a refusal reads the same whether or not a store is
-- there to be called — which is also what lets the Teal-only tests check it.

local type store = require("store")
local reads = require("cardbox.find")
local aliases = require("cardbox.alias")
local pruning = require("cardbox.prune")
local list = require("htlx.list")
-- For `array()` alone: a card with no samples answers a list, and an untagged empty table
-- would reach a JSON reader as `{}`.
local json = require("std.json")

local record cards
   -- The read half: declared here, defined in `cardbox.find`. A caller holds one module —
   -- a card is opened, written, closed, read and searched through `cards` — and the split
   -- is only about where the source lives, because the query builder, the whitelists and
   -- the lineage walk are a file's worth of policy on their own.
   build_find: function(q: reads.Query): string, {any}, string
   find: function(s: store, q: reads.Query): {reads.CardSummary}, string
   list: function(s: store, opts: reads.ListOpts): {reads.CardSummary}, string
   lineage: function(s: store, id: string, opts: reads.LineageOpts): reads.Lineage, string

   -- The alias half, the same way: declared here, defined in `cardbox.alias`. A name for
   -- a card, the history of every name it has had, and the promotion rule that moves one.
   -- `get_by_alias` is the exception — it is written below rather than there, because it
   -- ends in `cards.get` and a `cardbox.alias` that required this module back would be a
   -- cycle. What it does before the `get` is `aliases.bound_card`.
   alias: function(s: store, name: string, id: string, note?: string): store.Recorded, string
   alias_release: function(s: store, name: string, note?: string): store.Recorded, string
   get_by_alias: function(s: store, name: string): CardView, string
   alias_list: function(s: store, opts?: aliases.ListOpts): {aliases.Entry}, string
   alias_history: function(s: store, name: string): {aliases.Event}, string
   promote: function(s: store, spec: aliases.PromoteSpec): aliases.Promotion, string
   pick_best: function(candidates: {reads.CardSummary}, metric: string, min_n: integer): reads.CardSummary

   -- The prune half, the same way: declared here, defined in `cardbox.prune`. What may be
   -- removed, in what order it is removed, and the export the removal leans on. `prune`
   -- is the whole sequence; `plan_prune` and `like_escape` are the two pieces of it that
   -- decide something without a store, and `prune_log` is what a removal leaves behind.
   prune: function(s: store, spec: pruning.PruneSpec): pruning.PruneReport, string
   plan_prune: function(candidates: {reads.CardSummary}, aliased: {string:boolean}, parents: {string:boolean}, spec: pruning.PruneSpec): pruning.PrunePlan, string
   like_escape: function(s: string): string
   export: function(s: store): store.ExportReport, string
   import: function(s: store, path: string): store.ImportReport, string
   prune_log: function(s: store, opts?: pruning.LogOpts): {pruning.PruneEntry}, string

   -- What `open` is given. `pkg` / `scenario` / `source` / `created_by` are required;
   -- `id` is the caller's own name for the card, and when it is absent one is minted.
   --
   -- The rest is what a run knows about itself before it starts, and all of it is
   -- immutable from the open on. `params` is the run's input — the knobs that were set,
   -- as one table of whatever shape the pkg keeps them in — and its fingerprint is minted
   -- from it so that two runs given the same knobs can be told to be. `model`, `trace_id`
   -- and `work_url` are the run's identity: which model answered, which trace it is a
   -- part of, where it worked. They are scalars because they are what a reader asks *by*.
   --
   -- `work_url` is a URL and not a path: `file:///Users/me/tasks/x`, `https://…`, `s3://…`.
   -- A bare path is refused rather than given a `file://`, because the paths that arrive
   -- bare are the relative ones (`tasks/x`), and only the writer knows what
   -- they are relative to. Making the writer say so is what the scheme is for.
   record OpenSpec
      pkg: string
      scenario: string
      source: string
      created_by: string
      parents: {string}
      note: string
      id: string
      params: any
      model: string
      trace_id: string
      work_url: string
   end

   -- What `open` hands back: enough to write the rest of the card without reading it.
   record Card
      id: string
      stream: string
      pkg: string
      scenario: string
      source: string
      created_by: string
      state: string
      fingerprint: string
   end

   -- What `append_samples` hands back. `blob` and `size` are set only when the batch was
   -- too big to inline, so their absence is how a caller sees which way it went.
   record Appended
      n: integer
      seq: integer
      blob: string
      size: integer
   end

   record CheckpointInfo
      format: string
      note: string
   end

   -- How a run ended. `error` is required when `ok` is false and refused when it is true:
   -- the two fields say one thing, and a card that disagrees with itself is worse than no
   -- card at all.
   record Outcome
      ok: boolean
      stats: any
      cost: any
      error: string
   end

   record Samples
      batches: integer
      rows: integer
   end

   record Checkpoint
      blob: string
      size: integer
      format: string
   end

   -- A card as it reads now. Two things produce this shape and have to agree: `cards.get`,
   -- which reads the `cb_*` projection tables, and `cards.fold`, which adds the stream up
   -- itself. The fold is the definition — the projection is only the same answer, kept
   -- ready — and `cargo test` is where the two are held against each other.
   --
   -- `aliases` is the one field the fold cannot answer. A name lives on its own stream,
   -- so a card's events do not know what it is called; `cards.fold` leaves the list empty
   -- and `cards.get` reads `cb_aliases`, which is what the projection is for.
   record CardView
      id: string
      pkg: string
      scenario: string
      source: string
      created_by: string
      parents: {string}
      note: string
      model: string
      trace_id: string
      work_url: string
      fingerprint: string
      params: any
      state: string
      opened_ms: integer
      closed_ms: integer
      stats: any
      cost: any
      error: string
      samples: Samples
      evals: integer
      checkpoints: {Checkpoint}
      tags: {string:string}
      aliases: {string}
   end
end

-- 64 KB, as JSON text. SQLite's own measurement of where a blob stops being cheaper
-- inside the database than in a file beside it lands near 100 KB, and this sits under it
-- with room to spare. It is a policy default and not a measurement of this store: nothing
-- here has been benchmarked, and the number is meant to move when something is.
local INLINE_LIMIT = 64 * 1024

-- What a pkg, a scenario and an id may be spelled with. An id becomes a stream name and
-- part of a minted id, so it may hold nothing that would need quoting or escaping
-- downstream — no spaces, no dots, no separators.
local NAME = "^[%w_%-]+$"

-- What a tag's key may be spelled with: a dotted namespace, the way OpenTelemetry spells
-- attribute keys (`review.verdict`, `data.split`), and nothing that would need quoting
-- in a `--where`. A value is any string; the empty one is refused because "set to
-- nothing" and "unset" would otherwise be two spellings of one thing.
local TAG_KEY = "^[%w_%-]+%.?[%w_%-%.]*$"

-- Who an assessment came from. The three MLflow's assessments distinguish, because the
-- question a reader asks is exactly "was this the run scoring itself, a judge, or a
-- person": `code` is the run's own evaluator, `llm_judge` a model asked afterwards,
-- `human` somebody who looked.
local SOURCES: {string:boolean} = { code = true, llm_judge = true, human = true }
local SOURCE_LIST = "code, llm_judge, human"

-- The front of a URL, RFC 3986 §3.1: a letter, then letters, digits, `+`, `-` and `.`,
-- then the colon. That is the whole of the check — what follows the scheme is the
-- scheme's business — and it is exactly the check a bare path fails.
local URL_SCHEME = "^[A-Za-z][A-Za-z0-9+%-%.]*:"

-- One seed per module load. `os.time()` alone repeats for every card minted within the
-- same second, which is exactly the window two cards of one run share; `os.clock()` is
-- the process's own CPU time and separates them.
math.randomseed(os.time(), math.floor(os.clock() * 1000000))

local function required_string(v: any, field: string): string, string
   if type(v) ~= "string" then
      return nil, field .. " is required"
   end
   local s = v as string
   if s == "" then
      return nil, field .. " is required"
   end
   return s
end

-- A string that may be absent. Present and not a string is the mistake this refuses;
-- present and empty is treated as absent, because a CLI hands `--model ''` through as
-- a string and nobody meant a model called nothing.
local function optional_string(v: any, field: string): string, string
   if v == nil or v == "" then
      return nil
   end
   if type(v) ~= "string" then
      return nil, field .. " must be a string, got a " .. type(v)
   end
   return v as string
end

local function required_name(v: any, field: string): string, string
   local s, err = required_string(v, field)
   if s == nil then
      return nil, err
   end
   if s:match(NAME) == nil then
      return nil, field .. " may hold only letters, digits, _ and -, got " .. string.format("%q", s)
   end
   return s
end

-- Why `append_if` declined a dependent event. The decision only says no; the two reasons
-- it says no for are different mistakes, so this reads the stream to tell them apart.
local function not_open(s: store, id: string, doing: string): string
   local events, err = s:read_stream("card-" .. id, { "card_opened", "card_closed" })
   if events == nil then
      return err
   end
   local closed = list.any(events, function(e: store.Recorded): boolean
      return e ~= nil and e.kind == "card_closed"
   end)
   if closed then
      return "cannot " .. doing .. " card " .. id .. ": it is closed"
   end
   return "cannot " .. doing .. " card " .. id .. ": no card was opened under that id"
end

--- The id a card gets when the caller brings none: `<pkg>_<scenario>_<UTC>_<6 hex>`.
---
--- The timestamp says when and reads in order; the six hex digits are what keep two runs
--- of the same scenario in the same second apart. Nothing here asks the store whether the
--- id is free — `open` writes with the `unwritten` decision, which is the only check that
--- can be trusted, and a collision comes back as a refusal rather than as a silent
--- overwrite.
function cards.mint_id(pkg: string, scenario: string): string, string
   local p, perr = required_name(pkg, "pkg")
   if p == nil then
      return nil, perr
   end
   local sc, serr = required_name(scenario, "scenario")
   if sc == nil then
      return nil, serr
   end
   local stamp = os.date("!%Y%m%dT%H%M%S")
   return string.format("%s_%s_%s_%06x", p, sc, stamp, math.random(0, 0xffffff))
end

--- Open a card: the first event of its stream, written at the start of a run rather than
--- at the end of a successful one. Everything else about the card is written against this
--- event's presence, so a run that dies leaves a card that says it was open.
---
--- `unwritten` is the decision, so opening the same id twice is refused rather than
--- appended: a card is opened once and is immutable from there.
function cards.open(s: store, spec: cards.OpenSpec): cards.Card, string
   if spec == nil then
      return nil, "open needs a spec"
   end
   local pkg, perr = required_name(spec.pkg, "pkg")
   if pkg == nil then
      return nil, perr
   end
   local scenario, scerr = required_name(spec.scenario, "scenario")
   if scenario == nil then
      return nil, scerr
   end
   local source, soerr = required_string(spec.source, "source")
   if source == nil then
      return nil, soerr
   end
   local created_by, cerr = required_string(spec.created_by, "created_by")
   if created_by == nil then
      return nil, cerr
   end

   local parents: {string} = {}
   if spec.parents ~= nil then
      for i = 1, #spec.parents do
         local parent, pererr = required_name(spec.parents[i], "parents[" .. tostring(i) .. "]")
         if parent == nil then
            return nil, pererr
         end
         parents[i] = parent
      end
   end

   local id: string
   if spec.id ~= nil then
      local given, ierr = required_name(spec.id, "id")
      if given == nil then
         return nil, ierr
      end
      id = given
   else
      local minted, merr = cards.mint_id(pkg, scenario)
      if minted == nil then
         return nil, merr
      end
      id = minted
   end

   local model, merr = optional_string(spec.model, "model")
   if merr ~= nil then
      return nil, merr
   end
   local trace_id, terr = optional_string(spec.trace_id, "trace_id")
   if terr ~= nil then
      return nil, terr
   end
   local work_url, derr = optional_string(spec.work_url, "work_url")
   if derr ~= nil then
      return nil, derr
   end
   if work_url ~= nil and work_url:match(URL_SCHEME) == nil then
      return nil, "work_url is a URL with a scheme (file:///abs/dir, https://..., s3://...), got "
         .. string.format("%q", work_url)
   end
   local fingerprint: string
   if spec.params ~= nil then
      if type(spec.params) ~= "table" then
         return nil, "open takes params as a table, got a " .. type(spec.params)
      end
      -- The fingerprint is of the params and of nothing else: not the pkg, not the
      -- scenario, not the model. It answers "were these two runs given the same knobs",
      -- and a reader who wants "the same knobs *and* the same model" has both columns.
      fingerprint = s:digest(spec.params)
   end

   local stream = "card-" .. id
   -- `meta` is scalars only — the store's log indexes it and refuses anything nested — so
   -- the list-valued `parents`, the free-text `note` and the `params` table go in `data`.
   local meta = {
      pkg = pkg,
      scenario = scenario,
      source = source,
      created_by = created_by,
      model = model,
      trace_id = trace_id,
      work_url = work_url,
      fingerprint = fingerprint,
   }
   local data = { parents = parents, note = spec.note, params = spec.params }
   local rec, aerr = s:append_if(stream, "unwritten", "card_opened", meta, data)
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, "card " .. id .. " is already there: a card is opened once"
   end

   return {
      id = id,
      stream = stream,
      pkg = pkg,
      scenario = scenario,
      source = source,
      created_by = created_by,
      state = "open",
      fingerprint = fingerprint,
   }
end

--- Append one batch of sample rows to an open card.
---
--- The rows are encoded once to measure them, and a batch whose JSON is at most
--- `INLINE_LIMIT` bytes is carried in the event; a bigger one becomes a blob and the event
--- keeps the hash, the size and the row count. Either way the count is in the event, so
--- `get` can total the rows of a card without opening a single blob.
function cards.append_samples(s: store, id: string, rows: {any}): cards.Appended, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if type(rows) ~= "table" or #rows == 0 then
      return nil, "append_samples needs at least one row"
   end
   for i = 1, #rows do
      if type(rows[i]) ~= "table" then
         return nil, "append_samples takes rows as tables: row " .. tostring(i) .. " is a " .. type(rows[i])
      end
   end

   local text, jerr = s:json_encode(rows)
   if text == nil then
      return nil, jerr
   end

   -- A blob written below and then refused by the decision after it is an unreferenced
   -- file, not a corrupted one: it is named by its own bytes, so nothing points at it and
   -- re-running the batch reuses it. Step 5's refcount is what reclaims it.
   local data: {string:any}
   local blob: store.Blob
   if #text <= INLINE_LIMIT then
      data = { n = #rows, rows = rows }
   else
      local put, berr = s:blob_put(text)
      if put == nil then
         return nil, berr
      end
      blob = put
      data = { n = #rows, blob = put.hash, size = put.size }
   end

   local rec, aerr = s:append_if("card-" .. card, "open_unclosed", "samples_appended", nil, data)
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, not_open(s, card, "append samples to")
   end

   local out: cards.Appended = { n = #rows, seq = rec.seq }
   if blob ~= nil then
      out.blob = blob.hash
      out.size = blob.size
   end
   return out
end

--- Every sample row of a card, in the order the batches were appended.
---
--- The read that `append_samples` is the write of: an inline batch is decoded out of the
--- event's `rows`, a batch that went to a blob is fetched and decoded, and the two are
--- one list. A card with no samples answers an empty list; an id no card is under is
--- refused, because "nothing was written" and "there is no such card" are different
--- answers and a reader acting on the first should not be given the second.
function cards.samples(s: store, id: string): {any}, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   local batches, qerr = s:query(
      "SELECT rows_json, blob FROM cb_samples WHERE card_id = ? ORDER BY seq",
      { card }
   )
   if batches == nil then
      return nil, qerr
   end
   if #batches == 0 then
      local present, perr = s:query("SELECT 1 AS one FROM cb_cards WHERE id = ?", { card })
      if present == nil then
         return nil, perr
      end
      if #present == 0 then
         return nil, "no card " .. card
      end
      return json.array()
   end

   local out: {any} = {}
   for i = 1, #batches do
      local batch = batches[i] as {string:any}
      local text: string
      if batch.rows_json ~= nil then
         text = batch.rows_json as string
      elseif batch.blob ~= nil then
         local bytes, berr = s:blob_get(batch.blob as string)
         if berr ~= nil then
            return nil, berr
         end
         if bytes == nil then
            return nil, "card " .. card .. " names a samples blob that is not in the store: "
               .. (batch.blob as string)
         end
         text = bytes
      end
      if text ~= nil then
         local rows, jerr = s:json_decode(text)
         if rows == nil then
            return nil, jerr
         end
         local decoded = rows as {any}
         for j = 1, #decoded do
            out[#out + 1] = decoded[j]
         end
      end
   end
   if #out == 0 then
      return json.array()
   end
   return out
end

--- Record one eval result on an open card. The whole object goes in the event: an eval is
--- a summary plus the failures it wants to show, a few kilobytes, and splitting it out
--- would cost a blob read to answer "how did this score".
function cards.record_eval(s: store, id: string, eval: any, source?: string): store.Recorded, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if type(eval) ~= "table" then
      return nil, "record_eval takes the eval as a table, got a " .. type(eval)
   end
   -- The run's own evaluator unless the caller says otherwise: an eval recorded while a
   -- card is being written is, nearly always, the run scoring itself.
   local who = source or "code"
   if type(who) ~= "string" or SOURCES[who] == nil then
      return nil, "record_eval takes source as one of " .. SOURCE_LIST .. ", got "
         .. string.format("%q", tostring(source))
   end
   -- `opened` and not `open_unclosed`: an assessment is said *about* a run, by a judge
   -- or a person who may come along long after it closed, and a close ends what the run
   -- produces rather than what can be said of it. This is the one write a closed card
   -- takes besides a tag.
   local rec, aerr = s:append_if("card-" .. card, "opened", "eval_recorded", { source = who }, eval)
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, "cannot record an eval on card " .. card .. ": no card was opened under that id"
   end
   return rec
end

--- Put a label on a card, or move one. `nil, nil` when the card already carries exactly
--- this value, so a schedule that re-tags what it already tagged writes nothing.
---
--- A tag is the mutable slot. Everything else on a card is written once — the open, the
--- close, each sample batch — and a tag is the one thing meant to be changed afterwards:
--- `stage=prod` moves to the next card, `review.verdict` is overturned. What moved is on
--- the stream, in order; what is current is in `cb_tags`.
function cards.tag(s: store, id: string, key: string, value: string): store.Recorded, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if type(key) ~= "string" or key:match(TAG_KEY) == nil then
      return nil, "a tag key is a dotted name, letters, digits, _ and -, got "
         .. string.format("%q", tostring(key))
   end
   if type(value) ~= "string" or value == "" then
      return nil, "a tag value is a non-empty string, got " .. string.format("%q", tostring(value))
   end
   -- Read before write, and not under the store's lock: the worst a race here does is
   -- write a `tag_set` that repeats the value already there, which the fold overwrites
   -- with itself. The invariant a tag has — the card exists — is the decision's.
   local rows, qerr = s:query("SELECT value FROM cb_tags WHERE card_id = ? AND key = ?", { card, key })
   if rows == nil then
      return nil, qerr
   end
   if #rows == 1 and (rows[1] as {string:any}).value == value then
      return nil, nil
   end
   local rec, aerr = s:append_if("card-" .. card, "opened", "tag_set", { key = key, value = value }, nil)
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, "cannot tag card " .. card .. ": no card was opened under that id"
   end
   return rec
end

--- Take a label off a card. `nil, nil` when it carried no such key.
function cards.untag(s: store, id: string, key: string): store.Recorded, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if type(key) ~= "string" or key:match(TAG_KEY) == nil then
      return nil, "a tag key is a dotted name, letters, digits, _ and -, got "
         .. string.format("%q", tostring(key))
   end
   local rows, qerr = s:query("SELECT value FROM cb_tags WHERE card_id = ? AND key = ?", { card, key })
   if rows == nil then
      return nil, qerr
   end
   if #rows == 0 then
      -- Nothing to take off — but "no such tag" on a card that exists and "no such card"
      -- are different answers, and only the first is `nil, nil`.
      local present, perr = s:query("SELECT 1 AS one FROM cb_cards WHERE id = ?", { card })
      if present == nil then
         return nil, perr
      end
      if #present == 0 then
         return nil, "cannot untag card " .. card .. ": no card was opened under that id"
      end
      return nil, nil
   end
   local rec, aerr = s:append_if("card-" .. card, "opened", "tag_unset", { key = key }, nil)
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, "cannot untag card " .. card .. ": no card was opened under that id"
   end
   return rec
end

--- Save a checkpoint on an open card. Always a blob, whatever it weighs: a checkpoint is
--- opaque bytes in somebody else's format, and a log row is not where those belong.
function cards.save_checkpoint(s: store, id: string, bytes: string, info: cards.CheckpointInfo): store.Recorded, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if type(bytes) ~= "string" or bytes == "" then
      return nil, "save_checkpoint needs the checkpoint bytes"
   end
   if info == nil then
      return nil, "save_checkpoint needs an info"
   end
   local format, ferr = required_string(info.format, "format")
   if format == nil then
      return nil, ferr
   end

   local put, berr = s:blob_put(bytes)
   if put == nil then
      return nil, berr
   end
   local rec, aerr = s:append_if("card-" .. card, "open_unclosed", "checkpoint_saved", nil, {
      blob = put.hash,
      size = put.size,
      format = format,
      note = info.note,
   })
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, not_open(s, card, "save a checkpoint on")
   end
   return rec
end

--- Close a card, either way. A failed run closes too — that is the point of opening at the
--- start: the record of the failure is the card, and `ok = false` with the reason is what
--- keeps it from looking like a run that never happened.
function cards.close(s: store, id: string, outcome: cards.Outcome): store.Recorded, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if outcome == nil then
      return nil, "close needs an outcome"
   end
   if type(outcome.ok) ~= "boolean" then
      return nil, "close needs outcome.ok, true or false"
   end
   if outcome.ok then
      if outcome.error ~= nil then
         return nil, "close with ok = true takes no error: a card that carries one is closed with ok = false"
      end
   else
      if type(outcome.error) ~= "string" or outcome.error == "" then
         return nil, "close with ok = false needs error: what went wrong"
      end
   end
   if outcome.stats ~= nil and type(outcome.stats) ~= "table" then
      return nil, "close takes stats as a table"
   end
   if outcome.cost ~= nil and type(outcome.cost) ~= "table" then
      return nil, "close takes cost as a table"
   end

   local label = "failed"
   if outcome.ok then
      label = "ok"
   end
   local meta = { outcome = label }
   local data = { stats = outcome.stats, cost = outcome.cost, error = outcome.error }
   local rec, aerr = s:append_if("card-" .. card, "open_unclosed", "card_closed", meta, data)
   if aerr ~= nil then
      return nil, aerr
   end
   -- `open_unclosed` declines for two reasons and a close cares which: closing twice is a
   -- caller repeating itself, closing nothing is a caller with the wrong id.
   if rec == nil then
      local events, rerr = s:read_stream("card-" .. card, { "card_opened", "card_closed" })
      if events == nil then
         return nil, rerr
      end
      if #events == 0 then
         return nil, "cannot close card " .. card .. ": no card was opened under that id"
      end
      return nil, "card " .. card .. " is already closed"
   end
   return rec
end

--- A card as it reads now, folded from its own stream, event by event.
---
--- This is the definition of what a card's events add up to. `cards.get` answers the same
--- shape out of the read models, which is faster and is what everything should call; this
--- stays because a read model is only ever as right as the fold it claims to reproduce,
--- and something has to be the claim. `cargo test` holds the two against each other.
function cards.fold(s: store, id: string): cards.CardView, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   local events, rerr = s:read_stream("card-" .. card)
   if events == nil then
      return nil, rerr
   end

   local view: cards.CardView = {
      id = card,
      parents = {},
      state = "open",
      samples = { batches = 0, rows = 0 },
      evals = 0,
      checkpoints = {},
      tags = {},
      -- Empty, and not because this card has no names: a name is bound on `alias-<name>`
      -- and this reads `card-<id>`. Asking the fold for it would mean reading every alias
      -- stream in the store, which is the question the projection already answered.
      aliases = {},
   }
   local opened = false

   for i = 1, #events do
      local e = events[i]
      local meta = e.meta as {string:any}
      local data = e.data as {string:any}
      if e.kind == "card_opened" then
         opened = true
         view.opened_ms = e.epoch_ms
         if meta ~= nil then
            view.pkg = meta.pkg as string
            view.scenario = meta.scenario as string
            view.source = meta.source as string
            view.created_by = meta.created_by as string
            view.model = meta.model as string
            view.trace_id = meta.trace_id as string
            view.work_url = meta.work_url as string
            view.fingerprint = meta.fingerprint as string
         end
         if data ~= nil then
            view.note = data.note as string
            view.params = data.params
            local parents = data.parents as {string}
            if parents ~= nil then
               view.parents = parents
            end
         end
      elseif e.kind == "tag_set" then
         if meta ~= nil then
            view.tags[meta.key as string] = meta.value as string
         end
      elseif e.kind == "tag_unset" then
         if meta ~= nil then
            view.tags[meta.key as string] = nil
         end
      elseif e.kind == "samples_appended" then
         view.samples.batches = view.samples.batches + 1
         if data ~= nil and data.n ~= nil then
            view.samples.rows = view.samples.rows + (data.n as integer)
         end
      elseif e.kind == "eval_recorded" then
         view.evals = view.evals + 1
      elseif e.kind == "checkpoint_saved" then
         if data ~= nil then
            view.checkpoints[#view.checkpoints + 1] = {
               blob = data.blob as string,
               size = data.size as integer,
               format = data.format as string,
            }
         end
      elseif e.kind == "card_closed" then
         view.closed_ms = e.epoch_ms
         view.state = "closed_failed"
         if meta ~= nil and (meta.outcome as string) == "ok" then
            view.state = "closed_ok"
         end
         if data ~= nil then
            view.stats = data.stats
            view.cost = data.cost
            view.error = data.error as string
         end
      end
   end

   -- A stream with events but no `card_opened` is not a card. Nothing this module writes
   -- can produce one, and reading it as a card would be reading somebody else's stream.
   if not opened then
      return nil, "no card " .. card
   end
   return view
end

--- A card as it reads now, out of the read models.
---
--- The same `CardView` as `cards.fold` and four small queries instead of the card's whole
--- stream: `cb_cards` carries the scalars and the counts, `cb_lineage` the parents,
--- `cb_checkpoints` the checkpoints. Nothing here folds anything — the fold happened once,
--- in the projection, inside the transaction that moved its cursor.
---
--- `stats` and `cost` come back out of the JSON the close wrote rather than out of the
--- flattened columns, so a run that put something of its own in `stats` gets it back. The
--- columns are for `find` to compare against.
---
--- The refusals in the *write* paths (`append_samples` on a closed card, and the rest) go
--- on reading the stream, not `cb_cards.state`. A refusal is about what the log said at
--- the instant the write was declined, and the read model is a copy of the log — correct,
--- caught up before every query, and still a copy. The write path should not be the place
--- that finds out the copy is wrong.
function cards.get(s: store, id: string): cards.CardView, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end

   local rows, qerr = s:query(
      "SELECT id, pkg, scenario, source, created_by, note, state, opened_ms, closed_ms, "
         .. "model, trace_id, work_url, fingerprint, params_json, "
         .. "error, stats_json, cost_json, sample_batches, sample_rows, eval_count "
         .. "FROM cb_cards WHERE id = ?",
      { card }
   )
   if rows == nil then
      return nil, qerr
   end
   if #rows == 0 then
      return nil, "no card " .. card
   end
   local row = rows[1] as {string:any}

   local view: cards.CardView = {
      id = card,
      pkg = row.pkg as string,
      scenario = row.scenario as string,
      source = row.source as string,
      created_by = row.created_by as string,
      note = row.note as string,
      model = row.model as string,
      trace_id = row.trace_id as string,
      work_url = row.work_url as string,
      fingerprint = row.fingerprint as string,
      state = row.state as string,
      opened_ms = row.opened_ms as integer,
      closed_ms = row.closed_ms as integer,
      error = row.error as string,
      parents = {},
      samples = {
         batches = row.sample_batches as integer,
         rows = row.sample_rows as integer,
      },
      evals = row.eval_count as integer,
      checkpoints = {},
      tags = {},
      aliases = {},
   }

   if row.params_json ~= nil then
      local params, perr = s:json_decode(row.params_json as string)
      if params == nil then
         return nil, perr
      end
      view.params = params
   end
   if row.stats_json ~= nil then
      local stats, serr = s:json_decode(row.stats_json as string)
      if stats == nil then
         return nil, serr
      end
      view.stats = stats
   end
   if row.cost_json ~= nil then
      local cost, cerr = s:json_decode(row.cost_json as string)
      if cost == nil then
         return nil, cerr
      end
      view.cost = cost
   end

   local parents, perr = s:query("SELECT parent FROM cb_lineage WHERE child = ? ORDER BY parent", { card })
   if parents == nil then
      return nil, perr
   end
   view.parents = list.map(parents, function(r: any): string
      return (r as {string:any}).parent as string
   end)

   local named, aerr = s:query("SELECT name FROM cb_aliases WHERE card_id = ? ORDER BY name", { card })
   if named == nil then
      return nil, aerr
   end
   view.aliases = list.map(named, function(r: any): string
      return (r as {string:any}).name as string
   end)

   local tagged, terr = s:query("SELECT key, value FROM cb_tags WHERE card_id = ? ORDER BY key", { card })
   if tagged == nil then
      return nil, terr
   end
   for i = 1, #tagged do
      local tag = tagged[i] as {string:any}
      view.tags[tag.key as string] = tag.value as string
   end

   local saved, kerr = s:query(
      "SELECT blob, size, format FROM cb_checkpoints WHERE card_id = ? ORDER BY seq",
      { card }
   )
   if saved == nil then
      return nil, kerr
   end
   view.checkpoints = list.map(saved, function(r: any): cards.Checkpoint
      local cp = r as {string:any}
      return {
         blob = cp.blob as string,
         size = cp.size as integer,
         format = cp.format as string,
      }
   end)

   return view
end

--- The card a name means, in full.
---
--- `aliases.bound_card` resolves the name — that is where the name rule and the refusal
--- for an unbound one live — and the rest is `cards.get`, so what comes back is the same
--- `CardView` every other read answers with, aliases and all.
function cards.get_by_alias(s: store, name: string): cards.CardView, string
   local id, err = aliases.bound_card(s, name)
   if id == nil then
      return nil, err
   end
   return cards.get(s, id)
end

-- The read half, as `cards.*`. See the record at the top of this file for why it is
-- declared here and written in `cardbox.find`.
cards.build_find = reads.build_find
cards.find = reads.find
cards.list = reads.list
cards.lineage = reads.lineage

cards.prune = pruning.prune
cards.plan_prune = pruning.plan_prune
cards.like_escape = pruning.like_escape
cards.export = pruning.export
cards.import = pruning.import
cards.prune_log = pruning.prune_log

cards.alias = aliases.alias
cards.alias_release = aliases.alias_release
cards.alias_list = aliases.alias_list
cards.alias_history = aliases.alias_history
cards.promote = aliases.promote
cards.pick_best = aliases.pick_best

return cards
