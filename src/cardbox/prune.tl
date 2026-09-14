-- Pruning, as policy: which cards may go, which may never go, and in what order the going
-- happens. The mechanism is four host methods — `store:export`, `store:retain_streams`,
-- `store:blob_gc` and the plain `store:append` that writes the journal — and not one of
-- them decides anything about a card. What is on this side is every decision that is only
-- a decision: the selection, the three refusals, the wording of them, and the order.
--
-- The order is the point, and it is the one the BP survey converged on: **write the
-- delete-request event first, let the read models purge, and only then remove the bytes.**
--
--   1 select, through `cards.find`, and drop what may not go
--   2 `store:export()` — the whole log, because `Guard::Exported` chains only unfiltered
--     receipts (see `src/store/transfer.rs`); the file is the backup the removal leans on
--   3 append `cards_pruned` to the stream `prune` — the journal, which is never itself
--     retained, so it outlives what it describes and says where the export went
--   4 `store:retain_streams` — the bytes, under the guard the export just satisfied
--   5 `store:blob_gc` — the blobs whose last reference the journal event took away
--
-- Reversing 3 and 4 would leave the read models holding rows for cards whose events are
-- gone, with nothing left in the log to tell the projection to let go of them.
--
-- **Three cards are never pruned**, and each refusal is about something outside the card:
-- one that carries an alias (a name would be left pointing at nothing), one that is
-- somebody's parent (a lineage edge would dangle), and one that is still open (a run in
-- flight is not debris). The third is the only one a caller may overrule, by naming
-- `"open"` in `states` — saying it out loud is the whole of the safety.
--
-- Every function answers `value, err`. `plan_prune` is the selection on its own, a pure
-- function over summaries, so `htl test` argues about the rule with no store in the room.

local type store = require("store")
local reads = require("cardbox.find")
local list = require("htlx.list")
-- For `millis()` alone. The `older_than_ms` cutoff is on a millisecond column and
-- `os.time()` is whole seconds, so the arithmetic that bridged them was a clock this can
-- now ask for directly.
local time = require("std.time")

local record prune
   -- What `prune` is told to remove. At least one of `pkg` / `pkg_like` /
   -- `older_than_ms` / `ids` is required: a spec that bounds nothing selects the whole
   -- store, and that is not a thing this answers.
   --
   -- `pkg_like` is a SQL LIKE **pattern**, so `%` and `_` in it are wildcards. A literal
   -- that holds either goes through `prune.like_escape` first — the pkg `_test_` is
   -- `like_escape("_test_") .. "%"`, which is `\_test\_%` — and the query carries
   -- `ESCAPE '\'` so that the escape means something.
   record PruneSpec
      pkg: string
      pkg_like: string
      older_than_ms: integer
      states: {string}
      ids: {string}
      reason: string
      dry_run: boolean
   end

   -- The selection, split four ways. Every candidate lands in exactly one of these, and
   -- the first refusal that applies is the one it is filed under: a card that is both
   -- aliased and a parent is reported as aliased, because that is the first thing a
   -- reader has to undo.
   record PrunePlan
      selected: {string}
      skipped_aliased: {string}
      skipped_parent: {string}
      skipped_open: {string}
   end

   -- The plan, plus what came of it. `pruned` is empty on a dry run and on a plan that
   -- selected nothing; `export_file` is absent when the log was already exported through
   -- its end, which is not an error — the guard was satisfied before the call.
   record PruneReport
      selected: {string}
      skipped_aliased: {string}
      skipped_parent: {string}
      skipped_open: {string}
      pruned: {string}
      export_file: string
      events_removed: integer
      blobs_deleted: integer
      dry_run: boolean
   end

   -- One line of the journal, as `prune_log` reads it back.
   record PruneEntry
      seq: integer
      epoch_ms: integer
      count: integer
      cards: {string}
      reason: string
      export_file: string
   end

   record LogOpts
      limit: integer
   end
end

-- The journal's stream and kind. The stream is one name and not a prefix: it is the log
-- of every removal there has been, and `src/store/projection.rs` folds it by that name.
local JOURNAL = "prune"
local PRUNED = "cards_pruned"

-- How many cards one page of the selection reads. `find` clamps a limit at 500, so this
-- is its ceiling and the selection pages until a page comes back short — a prune of six
-- hundred `_test_` cards should not quietly become a prune of five hundred.
local PAGE = 500

-- How many journal entries `prune_log` answers with when it does not say.
local DEFAULT_LOG_LIMIT = 50

-- The ways a spec may be bounded, in the sentence the refusal names them in.
local BOUNDS = "pkg, pkg_like, older_than_ms or ids"

local function string_list(v: any, field: string): {string}, string
   if type(v) ~= "table" then
      return nil, "prune takes " .. field .. " as an array of strings, got a " .. type(v)
   end
   local values = v as {string}
   if #values == 0 then
      return nil, "prune takes " .. field .. " as a non-empty array of strings"
   end
   -- The first element that is not a name, by index, because the refusal names it.
   local bad = list.find_index(values, function(v2: string): boolean
      return type(v2) ~= "string" or v2 == ""
   end)
   if bad ~= nil then
      return nil, "prune takes " .. field .. " as an array of strings: "
         .. field .. "[" .. tostring(bad) .. "] is a " .. type(values[bad])
   end
   return values
end

-- Everything about a spec that can be decided without looking at a card. Run before the
-- first store call by `prune.prune` and again at the top of `prune.plan_prune`, so a
-- refusal reads the same whether or not a store was ever opened.
local function check(spec: prune.PruneSpec): boolean, string
   if spec == nil then
      return false, "prune needs a spec"
   end
   if type(spec.reason) ~= "string" or spec.reason == "" then
      return false, "prune needs reason: what these cards are being removed for. "
         .. "It goes in the journal event, which outlives the cards"
   end

   local bounded = false
   if spec.pkg ~= nil then
      if type(spec.pkg) ~= "string" or spec.pkg == "" then
         return false, "prune takes pkg as a string, got a " .. type(spec.pkg)
      end
      bounded = true
   end
   if spec.pkg_like ~= nil then
      if type(spec.pkg_like) ~= "string" or spec.pkg_like == "" then
         return false, "prune takes pkg_like as a string, got a " .. type(spec.pkg_like)
      end
      bounded = true
   end
   if spec.older_than_ms ~= nil then
      if type(spec.older_than_ms) ~= "number" or (spec.older_than_ms as number) <= 0 then
         return false, "prune takes older_than_ms as a positive number of milliseconds, got "
            .. tostring(spec.older_than_ms)
      end
      bounded = true
   end
   if spec.ids ~= nil then
      local _, err = string_list(spec.ids, "ids")
      if err ~= nil then
         return false, err
      end
      bounded = true
   end
   if spec.states ~= nil then
      local _, err = string_list(spec.states, "states")
      if err ~= nil then
         return false, err
      end
   end
   if spec.dry_run ~= nil and type(spec.dry_run) ~= "boolean" then
      return false, "prune takes dry_run as a boolean, got a " .. type(spec.dry_run)
   end

   if not bounded then
      return false, "prune refuses a spec that selects every card: bound it with "
         .. BOUNDS
   end
   return true
end

--- A literal, as a LIKE pattern that matches itself.
---
--- `\`, `%` and `_` are the three characters LIKE reads as something other than
--- themselves, and each comes back preceded by a backslash. The query this feeds carries
--- `ESCAPE '\'`, which is what makes the backslash mean "the next one is a character" —
--- without it SQLite's LIKE has no escape at all and `\_` would match a backslash followed
--- by anything.
---
--- It escapes the whole string, so a *pattern* is built by escaping the literal parts and
--- adding the wildcards after: `prune.like_escape("_test_") .. "%"` is `\_test\_%`, which
--- is every pkg whose name starts with the four characters `_test_`.
function prune.like_escape(s: string): string
   if type(s) ~= "string" then
      return nil
   end
   local escaped = s:gsub("[\\%%_]", "\\%0")
   return escaped
end

--- Which of `candidates` may go, and which may not and why.
---
--- Pure: `aliased` and `parents` are the two facts about the world outside a card that the
--- refusals turn on, passed in as sets rather than read here, so this is the rule and
--- nothing else. `prune.prune` is what asks the store for them.
---
--- An open card is skipped unless `spec.states` names `"open"`. That is not a filter —
--- the states are already in the query — it is a confirmation: a spec that asks for open
--- cards by name has said what it is doing, and a spec that did not is protected from
--- removing a run that is still writing.
function prune.plan_prune(
   candidates: {reads.CardSummary},
   aliased: {string:boolean},
   parents: {string:boolean},
   spec: prune.PruneSpec
): prune.PrunePlan, string
   local ok, err = check(spec)
   if not ok then
      return nil, err
   end

   local open_allowed = spec.states ~= nil and list.contains(spec.states, "open")

   local plan: prune.PrunePlan = {
      selected = {},
      skipped_aliased = {},
      skipped_parent = {},
      skipped_open = {},
   }
   local named = aliased or {}
   local ancestors = parents or {}

   for i = 1, #(candidates or {}) do
      local card = candidates[i]
      if card ~= nil and card.id ~= nil then
         if named[card.id] then
            plan.skipped_aliased[#plan.skipped_aliased + 1] = card.id
         elseif ancestors[card.id] then
            plan.skipped_parent[#plan.skipped_parent + 1] = card.id
         elseif card.state == "open" and not open_allowed then
            plan.skipped_open[#plan.skipped_open + 1] = card.id
         else
            plan.selected[#plan.selected + 1] = card.id
         end
      end
   end
   return plan
end

-- The cards a spec selects, every page of them. `find` clamps at 500 and this pages past
-- that, because a selection that stopped at the ceiling would prune a prefix of what the
-- caller asked for and report it as the whole.
local function candidates(s: store, spec: prune.PruneSpec): {reads.CardSummary}, string
   local clauses: {reads.Clause} = {}
   if spec.ids ~= nil then
      clauses[#clauses + 1] = { column = "id", op = "in", value = spec.ids }
   end
   if spec.pkg ~= nil then
      clauses[#clauses + 1] = { column = "pkg", op = "=", value = spec.pkg }
   end
   if spec.pkg_like ~= nil then
      clauses[#clauses + 1] = { column = "pkg", op = "like", value = spec.pkg_like }
   end
   if spec.older_than_ms ~= nil then
      -- `std.time.millis()` is the clock `opened_ms` is on. A cutoff computed here rather
      -- than in SQL is what keeps the whole selection one `find` with bound parameters.
      local cutoff = time.millis() - math.floor(spec.older_than_ms as number)
      clauses[#clauses + 1] = { column = "opened_ms", op = "<", value = cutoff }
   end
   if spec.states ~= nil then
      clauses[#clauses + 1] = { column = "state", op = "in", value = spec.states }
   end

   local out: {reads.CardSummary} = {}
   local offset = 0
   while true do
      local page, err = reads.find(s, {
         clauses = clauses,
         order_by = "opened_ms",
         desc = false,
         limit = PAGE,
         offset = offset,
      })
      if page == nil then
         return nil, err
      end
      out = list.concat(out, page)
      if #page < PAGE then
         return out
      end
      offset = offset + PAGE
   end
end

-- Every card an alias currently points at, and every card that is somebody's parent. Both
-- whole tables: `cb_aliases` holds one row per live name and `cb_lineage` one per edge, and
-- a store where either is large enough for this to matter is a store where the prune
-- itself is the larger cost.
--
-- Each comes back as the column mapped out of the rows and then `to_set`: both columns are
-- NOT NULL, so the map never meets the nil it would refuse, and the set is what
-- `plan_prune` indexes rather than searches.
local function outside_facts(s: store): {string:boolean}, {string:boolean}, string
   local rows, err = s:query("SELECT DISTINCT card_id FROM cb_aliases", {})
   if rows == nil then
      return nil, nil, err
   end
   local named = list.to_set(list.map(rows, function(r: any): string
      return (r as {string:any}).card_id as string
   end))

   local edges, eerr = s:query("SELECT DISTINCT parent FROM cb_lineage", {})
   if edges == nil then
      return nil, nil, eerr
   end
   local ancestors = list.to_set(list.map(edges, function(r: any): string
      return (r as {string:any}).parent as string
   end))
   return named, ancestors
end

--- Remove the cards a spec selects, having first written down that they are going.
---
--- The five steps are in the module comment above and in that order; the interesting
--- thing about the code is how little of it there is, because each step is one host call
--- that either did its whole job or answered with why it could not.
---
--- Nothing is written when the selection is empty or `dry_run` is set: no export, no
--- journal event, no retain. A dry run is a question about the policy, and asking it
--- should not extend the export chain.
function prune.prune(s: store, spec: prune.PruneSpec): prune.PruneReport, string
   local ok, cerr = check(spec)
   if not ok then
      return nil, cerr
   end

   local field, ferr = candidates(s, spec)
   if field == nil then
      return nil, ferr
   end
   local named, ancestors, oerr = outside_facts(s)
   if named == nil then
      return nil, oerr
   end
   local plan, perr = prune.plan_prune(field, named, ancestors, spec)
   if plan == nil then
      return nil, perr
   end

   local report: prune.PruneReport = {
      selected = plan.selected,
      skipped_aliased = plan.skipped_aliased,
      skipped_parent = plan.skipped_parent,
      skipped_open = plan.skipped_open,
      pruned = {},
      events_removed = 0,
      blobs_deleted = 0,
      dry_run = spec.dry_run == true,
   }
   if #plan.selected == 0 or report.dry_run then
      return report
   end

   -- The whole log, not these streams: see `src/store/transfer.rs` for why a filtered
   -- export cannot satisfy the guard that is about to be asked.
   local exported, xerr = s:export()
   if exported == nil then
      return nil, xerr
   end
   report.export_file = exported.file

   -- The journal event, before anything is removed. The projection folds it — purging
   -- every `cb_*` row of these cards and giving back their blob references — so by the
   -- time the retain runs the read models have already let go.
   local _, aerr = s:append(JOURNAL, PRUNED, { count = #plan.selected }, {
      cards = plan.selected,
      reason = spec.reason,
      export_file = exported.file,
      at = os.date("!%Y%m%dT%H%M%SZ"),
   })
   if aerr ~= nil then
      return nil, aerr
   end

   local streams = list.map(plan.selected, function(id: string): string
      return "card-" .. id
   end)
   local removed, rerr = s:retain_streams(streams)
   if removed == nil then
      return nil, rerr
   end
   report.events_removed = removed.removed

   local collected, gerr = s:blob_gc()
   if collected == nil then
      return nil, gerr
   end
   report.blobs_deleted = collected.deleted

   report.pruned = plan.selected
   return report
end

--- Write everything the log holds past the last confirmed export to `<root>/export/`.
---
--- `cards.prune` calls this on its own, so nothing has to. It is here for the other
--- reason to want it: `<root>/export/` is an append-only JSONL backup of the log, one file
--- per call, and `cards.import` reads one back.
function prune.export(s: store): store.ExportReport, string
   return s:export()
end

--- Read one of those files back into this store.
---
--- `reproduced_coordinates` in the answer is the check worth making: true means every
--- event landed on the position it had in the log it came from, which is what restoring
--- into an empty store gives and what merging into a store with history does not.
function prune.import(s: store, path: string): store.ImportReport, string
   if type(path) ~= "string" or path == "" then
      return nil, "import needs the path of an export file"
   end
   return s:import(path)
end

--- The journal, newest first.
---
--- This is what a pruned card leaves behind, and it is the only thing that does: the
--- events are gone, the rows are gone, and this says what went, when, why, and which
--- export file holds it. The stream `prune` is never retained, so the list only grows.
function prune.prune_log(s: store, opts?: prune.LogOpts): {prune.PruneEntry}, string
   local limit = DEFAULT_LOG_LIMIT
   if opts ~= nil and opts.limit ~= nil then
      if type(opts.limit) ~= "number" then
         return nil, "prune_log takes limit as a number, got a " .. type(opts.limit)
      end
      limit = math.floor(opts.limit as number)
      if limit < 1 then
         limit = 1
      end
   end

   local events, err = s:read_stream(JOURNAL, { PRUNED })
   if events == nil then
      return nil, err
   end

   -- Newest first and no more than `limit` of them: the stream is read from its end, which
   -- is `reverse` and then `take`, and each event is one entry.
   return list.map(list.take(list.reverse(events), limit), function(e: store.Recorded): prune.PruneEntry
      local meta = e.meta as {string:any}
      local data = e.data as {string:any}
      local cards: {string} = {}
      local reason: string = nil
      local export_file: string = nil
      if data ~= nil then
         if data.cards ~= nil then
            cards = data.cards as {string}
         end
         reason = data.reason as string
         export_file = data.export_file as string
      end
      local count = #cards
      if meta ~= nil and meta.count ~= nil then
         count = meta.count as integer
      end
      return {
         seq = e.seq,
         epoch_ms = e.epoch_ms,
         count = count,
         cards = cards,
         reason = reason,
         export_file = export_file,
      }
   end)
end

return prune
