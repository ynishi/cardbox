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

local record cards
   -- What `open` is given. `pkg` / `scenario` / `source` / `created_by` are required;
   -- `id` is the caller's own name for the card, and when it is absent one is minted.
   record OpenSpec
      pkg: string
      scenario: string
      source: string
      created_by: string
      parents: {string}
      note: string
      id: string
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

   -- A card as it reads now, folded from its stream. Step 3 builds the same shape out of
   -- projection tables; until then this is the only reader, and it is the definition of
   -- what the events add up to.
   record CardView
      id: string
      pkg: string
      scenario: string
      source: string
      created_by: string
      parents: {string}
      note: string
      state: string
      opened_ms: integer
      closed_ms: integer
      stats: any
      cost: any
      error: string
      samples: Samples
      evals: integer
      checkpoints: {Checkpoint}
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
   for i = 1, #events do
      local e = events[i]
      if e ~= nil and e.kind == "card_closed" then
         return "cannot " .. doing .. " card " .. id .. ": it is closed"
      end
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

   local stream = "card-" .. id
   -- `meta` is scalars only — the store's log indexes it and refuses anything nested — so
   -- the list-valued `parents` and the free-text `note` go in `data`.
   local meta = { pkg = pkg, scenario = scenario, source = source, created_by = created_by }
   local data = { parents = parents, note = spec.note }
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

--- Record one eval result on an open card. The whole object goes in the event: an eval is
--- a summary plus the failures it wants to show, a few kilobytes, and splitting it out
--- would cost a blob read to answer "how did this score".
function cards.record_eval(s: store, id: string, eval: any): store.Recorded, string
   local card, err = required_name(id, "id")
   if card == nil then
      return nil, err
   end
   if type(eval) ~= "table" then
      return nil, "record_eval takes the eval as a table, got a " .. type(eval)
   end
   local rec, aerr = s:append_if("card-" .. card, "open_unclosed", "eval_recorded", nil, eval)
   if aerr ~= nil then
      return nil, aerr
   end
   if rec == nil then
      return nil, not_open(s, card, "record an eval on")
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

--- A card as it reads now, folded from its own stream.
---
--- Step 3 answers this from projection tables; this is the fold those tables have to
--- agree with, and it stays as the thing a rebuild is checked against.
function cards.get(s: store, id: string): cards.CardView, string
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
         end
         if data ~= nil then
            view.note = data.note as string
            local parents = data.parents as {string}
            if parents ~= nil then
               view.parents = parents
            end
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

return cards
