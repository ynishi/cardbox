-- Aliases, as policy: what a name may be spelled with, what "promote" means, and what a
-- reader gets back. The mechanism is two host methods — `store:bind_alias` reads the card
-- and folds the alias stream under one lock, `store:release_alias` folds it — and neither
-- can be talked around from here. What is on this side is everything that is only a
-- decision.
--
-- The model, from the design: an alias is a human name for exactly one card, a card may
-- carry several, and the names are global rather than per pkg — `champion` means one
-- thing in this store. The name's whole life is the stream `alias-<name>`:
-- `alias_bound` / `alias_released` in order, the current binding being the fold of them.
-- A rebind is another `alias_bound` on the same stream, so moving a name keeps every
-- place it has been. That is the MLflow shape (an immutable version, a movable alias, and
-- no stage machine) with the history the registry itself does not keep.
--
-- Every function answers `value, err`, and every one of them validates before the first
-- store call. The two that bind answer a third way: `nil, nil` is the store declining —
-- the name already means that card, or it already means nothing — which is not a failure
-- and not a write.

local type store = require("store")
local reads = require("cardbox.find")

local record aliases
   -- One current binding, as `alias_list` hands it back.
   record Entry
      name: string
      card_id: string
      pkg: string
      bound_ms: integer
      note: string
   end

   -- One line of a name's history. `card_id` is the card bound on an `alias_bound` and
   -- the card *released* on an `alias_released`, so the two read the same way.
   record Event
      seq: integer
      kind: string
      card_id: string
      epoch_ms: integer
      note: string
   end

   record ListOpts
      pkg: string
      card_id: string
   end

   -- What `promote` is told to do: put `alias` on the best closed card in `pkg`.
   -- `metric` and `min_n` are the rule for "best"; `scenario` narrows the field.
   record PromoteSpec
      alias: string
      pkg: string
      scenario: string
      metric: string
      min_n: integer
      note: string
   end

   -- What `promote` did. `changed` is false when the alias already meant this card, which
   -- is the answer a re-run gets: the selection found the same winner and nothing was
   -- written. `previous_card_id` is whatever the name meant when the call started, so on
   -- an unchanged re-run it is the same id as `card_id`, and it is nil only when the name
   -- meant nothing at all.
   record Promotion
      alias: string
      card_id: string
      metric: string
      value: number
      previous_card_id: string
      changed: boolean
   end
end

-- What a name may be spelled with. Wider than a card id — a dot is ordinary in a name
-- like `cot.champion` — and still nothing that would need quoting once it is part of the
-- stream `alias-<name>`.
local NAME = "^[%w_%-%.]+$"
local MAX_NAME = 128

-- A card id, which is the same rule `cards.open` applies when it mints one. Written out
-- again rather than imported: `cardbox.cards` requires this module, so this module cannot
-- require it back, and a shared constant would have to live in a third file that exists
-- only to hold one pattern.
local ID = "^[%w_%-]+$"

-- The columns `promote` will call "best", and the sentence a refusal names them in. Each
-- is a column `find` can order by and a field a `CardSummary` carries, which is what lets
-- the selection be a `cards.find` rather than SQL written here.
local METRICS: {string:boolean} = {
   mean_score = true,
   pass_rate = true,
   passed = true,
   n = true,
}

local METRIC_LIST = "mean_score, pass_rate, passed, n"
local DEFAULT_METRIC = "mean_score"

-- How many candidates a promotion looks at. `find`'s own ceiling is 500; asking for it
-- means the winner is chosen from the whole field of a pkg rather than from a page of it.
local CANDIDATES = 500

local function check_name(name: any): string, string
   if type(name) ~= "string" or name == "" then
      return nil, "alias name is required"
   end
   local s = name as string
   if #s > MAX_NAME then
      return nil, "an alias name is at most " .. tostring(MAX_NAME) .. " characters, got " .. tostring(#s)
   end
   if s:match(NAME) == nil then
      return nil, "an alias name may hold only letters, digits, _ - and ., got " .. string.format("%q", s)
   end
   return s
end

local function check_id(id: any): string, string
   if type(id) ~= "string" or id == "" then
      return nil, "id is required"
   end
   local s = id as string
   if s:match(ID) == nil then
      return nil, "id may hold only letters, digits, _ and -, got " .. string.format("%q", s)
   end
   return s
end

-- The metric of one card, by name. A branch per column rather than an index by string:
-- these four are what `METRICS` promises and a `CardSummary` carries, and spelling them
-- out is what makes the promise checkable by the type checker instead of at run time.
local function metric_of(card: reads.CardSummary, metric: string): number
   if metric == "mean_score" then
      return card.mean_score
   elseif metric == "pass_rate" then
      return card.pass_rate
   elseif metric == "passed" then
      return card.passed
   elseif metric == "n" then
      return card.n
   end
   return nil
end

local function entries(rows: {any}): {aliases.Entry}
   local out: {aliases.Entry} = {}
   for i = 1, #rows do
      local row = rows[i] as {string:any}
      out[i] = {
         name = row.name as string,
         card_id = row.card_id as string,
         pkg = row.pkg as string,
         bound_ms = row.bound_ms as integer,
         note = row.note as string,
      }
   end
   return out
end

--- Point `name` at the card `id`.
---
--- Three answers. `rec, nil` bound it — a new name, or a name moved off another card,
--- which is one `alias_bound` either way and leaves the old binding in the history.
--- `nil, nil` is the store declining because the name already means this card: binding is
--- idempotent, and a caller re-running a promotion should not be writing an event a
--- second. `nil, err` is a name that is not a name, an id that is not an id, or a card
--- that was never opened — the last one is the refusal this whole step exists for, and it
--- comes from the host, which reads the card's stream under the lock it then writes under.
function aliases.alias(s: store, name: string, id: string, note?: string): store.Recorded, string
   local n, nerr = check_name(name)
   if n == nil then
      return nil, nerr
   end
   local card, ierr = check_id(id)
   if card == nil then
      return nil, ierr
   end
   return s:bind_alias(n, card, note)
end

--- Let `name` go. `nil, nil` when it meant nothing to begin with.
---
--- The card it was pointing at is not touched: an alias is a name for a card and a card
--- outlives its names. What the release leaves is a line in the history saying which card
--- the name came off.
function aliases.alias_release(s: store, name: string, note?: string): store.Recorded, string
   local n, nerr = check_name(name)
   if n == nil then
      return nil, nerr
   end
   return s:release_alias(n, note)
end

--- The id of the card a name currently means.
---
--- The whole of `cards.get_by_alias` except the `get`, and it stops here for a reason that
--- is about this file rather than about the reader: a `CardView` is `cardbox.cards`'s
--- shape, and requiring that module from this one would be a cycle — `cards` requires this
--- one to re-export everything below. So the last step is taken there, where `get` already
--- is, and the alias half of it — the name rule, the lookup, the wording of the refusal —
--- is here.
---
--- An unbound name is refused rather than answered with nothing: "no card is called that"
--- and "the card called that is empty" are different answers, and only one is worth
--- acting on.
function aliases.bound_card(s: store, name: string): string, string
   local n, nerr = check_name(name)
   if n == nil then
      return nil, nerr
   end
   local rows, qerr = s:query("SELECT card_id FROM cb_aliases WHERE name = ?", { n })
   if rows == nil then
      return nil, qerr
   end
   if #rows == 0 then
      return nil, "alias " .. n .. " is not bound"
   end
   return (rows[1] as {string:any}).card_id as string
end

--- Every name that currently means something, in name order.
---
--- `pkg` and `card_id` narrow it: the first is the pkg of the card the name was bound to,
--- copied onto the alias row by the host when it bound it, and the second answers "what
--- is this card called".
function aliases.alias_list(s: store, opts?: aliases.ListOpts): {aliases.Entry}, string
   local o = opts or {}
   local sql = "SELECT name, card_id, pkg, bound_ms, note FROM cb_aliases"
   local params: {any} = {}
   local parts: {string} = {}

   if o.pkg ~= nil then
      if type(o.pkg) ~= "string" then
         return nil, "alias_list takes pkg as a string, got a " .. type(o.pkg)
      end
      parts[#parts + 1] = "pkg = ?"
      params[#params + 1] = o.pkg
   end
   if o.card_id ~= nil then
      if type(o.card_id) ~= "string" then
         return nil, "alias_list takes card_id as a string, got a " .. type(o.card_id)
      end
      parts[#parts + 1] = "card_id = ?"
      params[#params + 1] = o.card_id
   end
   if #parts > 0 then
      sql = sql .. " WHERE " .. table.concat(parts, " AND ")
   end
   sql = sql .. " ORDER BY name"

   local rows, err = s:query(sql, params)
   if rows == nil then
      return nil, err
   end
   return entries(rows)
end

--- Everywhere a name has been, oldest first.
---
--- This is what the reservation stream is worth: `cb_aliases` forgets on every rebind and
--- `cb_alias_log` does not, and both are folded out of the same events. A name nobody has
--- ever bound answers with an empty list rather than a refusal — it has no history, which
--- is a fact about it and not a mistake by the caller.
function aliases.alias_history(s: store, name: string): {aliases.Event}, string
   local n, nerr = check_name(name)
   if n == nil then
      return nil, nerr
   end
   local rows, err = s:query(
      "SELECT seq, kind, card_id, epoch_ms, note FROM cb_alias_log WHERE name = ? ORDER BY seq",
      { n }
   )
   if rows == nil then
      return nil, err
   end
   local out: {aliases.Event} = {}
   for i = 1, #rows do
      local row = rows[i] as {string:any}
      out[i] = {
         seq = row.seq as integer,
         kind = row.kind as string,
         card_id = row.card_id as string,
         epoch_ms = row.epoch_ms as integer,
         note = row.note as string,
      }
   end
   return out
end

--- The best of a field, by the rule a promotion uses. Nothing, when the field is empty or
--- nobody in it qualifies.
---
--- Highest metric wins; a tie goes to the card opened last, because two runs that scored
--- identically are most usefully resolved by "the newer one is what the pkg does now".
--- A card whose metric is nil never wins — it did not record that number, and NULL is not
--- a low score — and neither does one under `min_n`, which is how a promotion refuses to
--- crown a lucky three-case run.
---
--- Separated out from `promote` because it is the whole of the policy worth arguing about
--- and it asks nothing of a store: `htl test` pins it with no host in the room.
function aliases.pick_best(candidates: {reads.CardSummary}, metric: string, min_n: integer): reads.CardSummary
   if candidates == nil then
      return nil
   end
   local floor = min_n or 0
   local best: reads.CardSummary = nil

   for i = 1, #candidates do
      local card = candidates[i]
      local value = metric_of(card, metric)
      local n = card.n or 0
      if value ~= nil and n >= floor then
         if best == nil then
            best = card
         else
            local top = metric_of(best, metric)
            if value > top or (value == top and (card.opened_ms or 0) > (best.opened_ms or 0)) then
               best = card
            end
         end
      end
   end
   return best
end

--- Put a name on the best card a pkg has closed successfully.
---
--- The 昇格規則 of the design, and the reason the alias is a name rather than a state on
--- the card: promotion moves a pointer, so nothing about the winner changes and the run
--- that loses it is still exactly what it was. Rolling back is the same call with an id.
---
--- The field is `state = 'closed_ok'` cards of `pkg` (and `scenario`, when given) with at
--- least `min_n` cases, selected through `cards.find` so that the column whitelist is the
--- one every other read uses. `pick_best` is the choice; this is the part around it —
--- validating, reading what the name meant before, binding, and saying what happened.
function aliases.promote(s: store, spec: aliases.PromoteSpec): aliases.Promotion, string
   if spec == nil then
      return nil, "promote needs a spec"
   end
   local name, nerr = check_name(spec.alias)
   if name == nil then
      return nil, nerr
   end
   if type(spec.pkg) ~= "string" or spec.pkg == "" then
      return nil, "promote needs pkg: the cards it chooses between"
   end
   if spec.scenario ~= nil and type(spec.scenario) ~= "string" then
      return nil, "promote takes scenario as a string, got a " .. type(spec.scenario)
   end

   local metric = DEFAULT_METRIC
   if spec.metric ~= nil then
      if type(spec.metric) ~= "string" or METRICS[spec.metric] == nil then
         return nil, 'promote does not rank cards by "'
            .. tostring(spec.metric)
            .. '": the metrics it has are '
            .. METRIC_LIST
      end
      metric = spec.metric
   end

   local min_n = 1
   if spec.min_n ~= nil then
      if type(spec.min_n) ~= "number" then
         return nil, "promote takes min_n as a number, got a " .. type(spec.min_n)
      end
      min_n = math.floor(spec.min_n as number)
      if min_n < 0 then
         return nil, "promote takes min_n as zero or more, got " .. tostring(spec.min_n)
      end
   end

   local clauses: {reads.Clause} = {
      { column = "pkg", op = "=", value = spec.pkg },
      { column = "state", op = "=", value = "closed_ok" },
      { column = "n", op = ">=", value = min_n },
   }
   if spec.scenario ~= nil then
      clauses[#clauses + 1] = { column = "scenario", op = "=", value = spec.scenario }
   end

   local candidates, ferr = reads.find(s, {
      clauses = clauses,
      order_by = metric,
      limit = CANDIDATES,
   })
   if candidates == nil then
      return nil, ferr
   end

   local best = aliases.pick_best(candidates, metric, min_n)
   if best == nil then
      local field = spec.pkg
      if spec.scenario ~= nil then
         field = field .. " / " .. spec.scenario
      end
      return nil, "no closed_ok card in " .. field .. " has a " .. metric
         .. " with n >= " .. tostring(min_n)
   end

   -- What the name meant before this call. Read rather than inferred from the bind's
   -- answer: a decline says "it already means this card" and says nothing about a name
   -- that is moving off another one.
   local previous: string
   local rows, qerr = s:query("SELECT card_id FROM cb_aliases WHERE name = ?", { name })
   if rows == nil then
      return nil, qerr
   end
   if #rows > 0 then
      previous = (rows[1] as {string:any}).card_id as string
   end

   local rec, berr = s:bind_alias(name, best.id, spec.note)
   if berr ~= nil then
      return nil, berr
   end

   return {
      alias = name,
      card_id = best.id,
      metric = metric,
      value = metric_of(best, metric),
      previous_card_id = previous,
      changed = rec ~= nil,
   }
end

return aliases
