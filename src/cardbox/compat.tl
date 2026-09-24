-- alc's card/v0 surface, over cardbox. What `alc_card_find` and `alc_card_samples` take —
-- a Prisma-style `where` of nested objects, a dotted `order_by` with `-` for descending, a
-- `pkg` — translated into a `cards.find` query, or evaluated against a sample row; and what
-- they answer with, a v0 summary row, shaped out of a cardbox one.
--
-- This module is the seam an alc built on cardbox stands on, and it is on the Teal side
-- for the reason everything else here is: which v0 path means which cardbox column is a
-- decision, and one that moves as the importer's mapping does. `translate` is pure and
-- `htl test` pins it; `find` and `samples` are the same thing with a store in the room.
--
-- Two limits are stated rather than papered over. `cards.find` is AND-only, so a `where`
-- holding `_or` or `_not` is refused with a sentence saying so, as are `nin` and `exists`,
-- which the SQL builder has no operator for — a row-level `where` on samples has all of
-- them, because that one runs here over decoded rows.
--
-- v0's `created_at` is the run's time, and cardbox's is `started_ms`: an ISO string there,
-- a millisecond count here. A clause on it has its values converted (`cards.utc_ms`) before
-- it becomes a clause, so `{ created_at = { gte = "2026-04-01T00:00:00Z" } }` compares
-- numbers with numbers, and every row carries `created_at` back as the ISO string.

local type store = require("store")
local type reads = require("cardbox.find")
local cards = require("cardbox.cards")
local list = require("htlx.list")
local json = require("std.json")

local record compat
   -- What `alc_card_find` takes. The predicate is the field `filter` here, because Teal
   -- reserves `where` inside a record body (it is the keyword a union variant's predicate
   -- is written with); a table that arrives with the key `where`, which is what alc's own
   -- arguments carry, is read as the same thing.
   record FindArgs
      pkg: string
      filter: any
      order_by: any
      limit: integer
      offset: integer
   end

   -- One row of what it answers with: v0's summary shape, out of cardbox's, plus the
   -- card's current tags — the slot v0's `metadata.group` / `plugin` / `run_status`
   -- landed in, so a caller who filtered on one of those reads the value back on the row.
   record Summary
      card_id: string
      pkg: string
      scenario: string
      model: string
      state: string
      created_at: string
      started_ms: integer
      ended_ms: integer
      opened_ms: integer
      closed_ms: integer
      mean_score: number
      n: integer
      pass_rate: number
      tags: {string:string}
   end

   -- What `alc_card_samples` takes beyond the id. `filter` for the reason above, and the
   -- key `where` is read the same way.
   record RowsOpts
      filter: any
      limit: integer
      offset: integer
   end
end

-- The leaf operators, and what each becomes in a `cards.find` clause. `contains` and
-- `starts_with` are LIKE patterns with the value escaped, so a `_` in it matches itself.
local OPS: {string:string} = {
   eq = "=",
   ne = "!=",
   lt = "<",
   lte = "<=",
   gt = ">",
   gte = ">=",
   ["in"] = "in",
}
local LIKE: {string:boolean} = { contains = true, starts_with = true }
-- Reserved in the DSL, evaluable over a row, and not expressible as a find clause.
local ROW_ONLY: {string:boolean} = { nin = true, exists = true }
local RESERVED: {string:boolean} = {
   eq = true, ne = true, lt = true, lte = true, gt = true, gte = true, ["in"] = true,
   nin = true, exists = true, contains = true, starts_with = true,
}

-- v0 paths that are one cardbox column. Everything under `stats.` / `params.` / `tags.`
-- passes through, `metadata.<x>` is where the importer put the rest of v0's metadata
-- (`stats.metadata.<x>`), and a section a pkg added on its own (`optimize.rounds`) is
-- `params.<section>`, which is where the importer put those too.
local FIXED: {string:string} = {
   id = "id",
   card_id = "id",
   pkg = "pkg",
   ["pkg.name"] = "pkg",
   scenario = "scenario",
   ["scenario.name"] = "scenario",
   model = "model",
   ["model.id"] = "model",
   created_by = "created_by",
   state = "state",
   created_at = "started_ms",
   started_ms = "started_ms",
   ended_ms = "ended_ms",
   opened_ms = "opened_ms",
   closed_ms = "closed_ms",
   mean_score = "mean_score",
   n = "n",
   pass_rate = "pass_rate",
   passed = "passed",
   ["stats.mean_score"] = "mean_score",
   ["stats.n"] = "n",
   ["stats.pass_rate"] = "pass_rate",
   ["stats.passed"] = "passed",
   ["cost.elapsed_ms"] = "elapsed_ms",
   ["cost.llm_calls"] = "llm_calls",
   ["metadata.trace_id"] = "trace_id",
   ["metadata.task_dir"] = "work_url",
   ["metadata.group"] = "tags.group",
   ["metadata.plugin"] = "tags.plugin",
   ["metadata.run_status"] = "tags.run_status",
   fingerprint = "fingerprint",
   trace_id = "trace_id",
   work_url = "work_url",
}

--- The cardbox column a v0 path means.
function compat.column_of(path: string): string, string
   if FIXED[path] ~= nil then
      return FIXED[path]
   end
   if path == "metadata.prior_card_id" then
      return nil, "metadata.prior_card_id is lineage here: ask cards.lineage rather than find"
   end
   local head, rest = path:match("^([%w_]+)%.(.+)$")
   if head == "stats" or head == "params" or head == "tags" then
      return path
   end
   if head == "metadata" then
      return "stats.metadata." .. (rest as string)
   end
   if head ~= nil then
      return "params." .. path
   end
   -- A bare name that is not a column: a top-level v0 key the importer put under params.
   return "params." .. path
end

-- Whether a table is a list: `[1, 2]` rather than `{ gte = 1 }`. An empty table is
-- neither, and reads as an object with nothing in it.
local function is_list(t: {string:any}): boolean
   return (t as {any})[1] ~= nil
end

-- Whether every key of an object is a reserved operator, which is what makes it a leaf.
local function is_leaf(t: {string:any}): boolean
   local any_key = false
   for k, _ in pairs(t) do
      any_key = true
      if RESERVED[k] == nil then
         return false
      end
   end
   return any_key
end

-- The predicate out of an arguments table: `filter`, or `where` when the table came from
-- alc with its own key on it.
local function predicate_of(t: any): any
   if t == nil then
      return nil
   end
   local m = t as {string:any}
   if m.filter ~= nil then
      return m.filter
   end
   return m["where"]
end

-- A value as the column it is compared against holds it. Only `created_at` needs anything:
-- v0 wrote it as an ISO string and `started_ms` is a millisecond count, so a string is
-- converted (and a list of them, for `in`); a number is taken as milliseconds already.
local function value_of(path: string, value: any): any, string
   if path ~= "created_at" then
      return value
   end
   if type(value) == "string" then
      return cards.utc_ms(value as string)
   end
   if type(value) == "table" then
      local out: {any} = {}
      for i, v in ipairs(value as {any}) do
         local converted, err = value_of(path, v)
         if err ~= nil then
            return nil, err
         end
         out[i] = converted
      end
      return out
   end
   return value
end

local function join(prefix: string, key: string): string
   if prefix == "" then
      return key
   end
   return prefix .. "." .. key
end

-- One leaf, as clauses. Every op in it is ANDed with the others, the way Prisma reads
-- `{ gte = 1, lt = 5 }`.
local function leaf_clauses(path: string, leaf: {string:any}, out: {reads.Clause}): string
   local column, cerr = compat.column_of(path)
   if column == nil then
      return cerr
   end
   for op, value in pairs(leaf) do
      if OPS[op] ~= nil then
         local v, verr = value_of(path, value)
         if verr ~= nil then
            return path .. ": " .. verr
         end
         out[#out + 1] = { column = column, op = OPS[op], value = v }
      elseif LIKE[op] and column == "started_ms" then
         return op .. " on " .. path .. " compares text, and the time is a number here: "
            .. "use gte / lt with an ISO timestamp"
      elseif LIKE[op] then
         if type(value) ~= "string" then
            return op .. " on " .. path .. " takes a string, got a " .. type(value)
         end
         local pattern = cards.like_escape(value as string) .. "%"
         if op == "contains" then
            pattern = "%" .. pattern
         end
         out[#out + 1] = { column = column, op = "like", value = pattern }
      elseif ROW_ONLY[op] then
         return op .. " on " .. path .. " has no find operator here: it works on sample rows, "
            .. "not on cards"
      else
         return "unknown operator " .. op .. " on " .. path
      end
   end
   return nil
end

local function walk(node: any, prefix: string, out: {reads.Clause}): string
   if type(node) ~= "table" then
      -- A scalar at a path is equality: `{ pkg = "cot" }`.
      local column, cerr = compat.column_of(prefix)
      if column == nil then
         return cerr
      end
      local v, verr = value_of(prefix, node)
      if verr ~= nil then
         return prefix .. ": " .. verr
      end
      out[#out + 1] = { column = column, op = "=", value = v }
      return nil
   end
   local t = node as {string:any}
   if is_list(t) then
      return "a list at " .. prefix .. " is not a predicate: use { [\"in\"] = { ... } }"
   end
   if prefix ~= "" and is_leaf(t) then
      return leaf_clauses(prefix, t, out)
   end
   for key, value in pairs(t) do
      if key == "_and" then
         if type(value) ~= "table" then
            return "_and takes a list of predicates"
         end
         local parts = value as {any}
         for i = 1, #parts do
            local err = walk(parts[i], prefix, out)
            if err ~= nil then
               return err
            end
         end
      elseif key == "_or" or key == "_not" then
         return key .. " cannot be found by: cards.find is AND-only, so a where holding "
            .. key .. " is refused rather than half-answered"
      elseif RESERVED[key] ~= nil and prefix ~= "" then
         -- An operator beside a section name, `{ stats = { gte = 1, x = 2 } }`: neither a
         -- leaf nor a section, and not something Prisma would take either.
         return "operator " .. key .. " beside a field name under " .. prefix
      else
         local err = walk(value, join(prefix, key), out)
         if err ~= nil then
            return err
         end
      end
   end
   return nil
end

--- The `cards.find` query an `alc_card_find` call means. Pure: answers `query, nil` or
--- `nil, err`, and the query is what `find.build_find` takes.
function compat.translate(args: compat.FindArgs): reads.Query, string
   local a = args or {}
   local clauses: {reads.Clause} = {}
   if a.pkg ~= nil then
      if type(a.pkg) ~= "string" then
         return nil, "pkg takes a string, got a " .. type(a.pkg)
      end
      clauses[#clauses + 1] = { column = "pkg", op = "=", value = a.pkg }
   end
   local predicate = predicate_of(a)
   if predicate ~= nil then
      if type(predicate) ~= "table" then
         return nil, "where takes an object, got a " .. type(predicate)
      end
      local err = walk(predicate, "", clauses)
      if err ~= nil then
         return nil, err
      end
   end

   local q: reads.Query = { clauses = clauses, limit = a.limit, offset = a.offset }
   local order = a.order_by
   if type(order) == "table" then
      local keys = order as {any}
      if #keys > 1 then
         return nil, "order_by takes one key here: cards.find orders by one column and "
            .. "then by position"
      end
      order = keys[1]
   end
   if order ~= nil then
      if type(order) ~= "string" then
         return nil, "order_by takes a dotted path, got a " .. type(order)
      end
      local key = order as string
      local desc = true
      if key:sub(1, 1) == "-" then
         key = key:sub(2)
      else
         desc = false
      end
      local column, cerr = compat.column_of(key)
      if column == nil then
         return nil, cerr
      end
      q.order_by = column
      q.desc = desc
   end
   return q
end

local function summary_of(row: reads.CardSummary): compat.Summary
   local created_at: string
   if row.started_ms ~= nil then
      created_at = cards.utc_iso(row.started_ms)
   end
   return {
      created_at = created_at,
      card_id = row.id,
      pkg = row.pkg,
      scenario = row.scenario,
      model = row.model,
      state = row.state,
      started_ms = row.started_ms,
      ended_ms = row.ended_ms,
      opened_ms = row.opened_ms,
      closed_ms = row.closed_ms,
      mean_score = row.mean_score,
      n = row.n,
      pass_rate = row.pass_rate,
      tags = row.tags,
   }
end

--- `alc_card_find`, over cardbox: the cards the arguments select, as v0 summary rows.
function compat.find(s: store, args: compat.FindArgs): {compat.Summary}, string
   local q, terr = compat.translate(args)
   if q == nil then
      return nil, terr
   end
   local rows, ferr = cards.find(s, q)
   if rows == nil then
      return nil, ferr
   end
   if #rows == 0 then
      return json.array()
   end
   return list.map(rows, summary_of)
end

-- ------------------------------------------------------------------ rows

-- The value at a dotted path inside a row, or nil.
local function at(row: any, path: {string}): any
   local v = row
   for i = 1, #path do
      if type(v) ~= "table" then
         return nil
      end
      v = (v as {string:any})[path[i]]
   end
   return v
end

local function compare(op: string, have: any, want: any): boolean
   if op == "eq" then
      return have == want
   elseif op == "ne" then
      return have ~= want
   elseif op == "exists" then
      return (have ~= nil) == (want == true)
      elseif op == "in" or op == "nin" then
      if type(want) ~= "table" then
         return false
      end
      local found = list.contains(want as {any}, have)
      if op == "in" then
         return found
      end
      return not found
   elseif op == "contains" or op == "starts_with" then
      if type(have) ~= "string" or type(want) ~= "string" then
         return false
      end
      local h = have as string
      local w = want as string
      if op == "contains" then
         return h:find(w, 1, true) ~= nil
      end
      return h:sub(1, #w) == w
   end
   -- The four orderings: only between two numbers or two strings, and false otherwise,
   -- which is what a comparison across types should be in a filter.
   if type(have) ~= type(want) or (type(have) ~= "number" and type(have) ~= "string") then
      return false
   end
   if type(have) == "number" then
      local a = have as number
      local b = want as number
      if op == "lt" then
         return a < b
      elseif op == "lte" then
         return a <= b
      elseif op == "gt" then
         return a > b
      elseif op == "gte" then
         return a >= b
      end
   else
      local a = have as string
      local b = want as string
      if op == "lt" then
         return a < b
      elseif op == "lte" then
         return a <= b
      elseif op == "gt" then
         return a > b
      elseif op == "gte" then
         return a >= b
      end
   end
   return false
end

local function holds(row: any, node: any, path: {string}): boolean, string
   if type(node) ~= "table" then
      return at(row, path) == node
   end
   local t = node as {string:any}
   if is_list(t) then
      return nil, "a list at " .. table.concat(path, ".") .. " is not a predicate"
   end
   if #path > 0 and is_leaf(t) then
      local have = at(row, path)
      for op, want in pairs(t) do
         if not compare(op, have, want) then
            return false
         end
      end
      return true
   end
   for key, value in pairs(t) do
      if key == "_and" or key == "_or" then
         if type(value) ~= "table" then
            return nil, key .. " takes a list of predicates"
         end
         local parts = value as {any}
         local any_true = false
         for i = 1, #parts do
            local ok, err = holds(row, parts[i], path)
            if err ~= nil then
               return nil, err
            end
            if key == "_and" and not ok then
               return false
            end
            if ok then
               any_true = true
            end
         end
         if key == "_or" and not any_true then
            return false
         end
      elseif key == "_not" then
         local ok, err = holds(row, value, path)
         if err ~= nil then
            return nil, err
         end
         if ok then
            return false
         end
      else
         local next_path = list.copy(path)
         next_path[#next_path + 1] = key
         local ok, err = holds(row, value, next_path)
         if err ~= nil then
            return nil, err
         end
         if not ok then
            return false
         end
      end
   end
   return true
end

--- Whether a sample row satisfies a `where`. The whole DSL, `_or` and `exists` included,
--- because this runs over a decoded row and not through the SQL builder.
function compat.matches(row: any, predicate: any): boolean, string
   if predicate == nil then
      return true
   end
   if type(predicate) ~= "table" then
      return nil, "where takes an object, got a " .. type(predicate)
   end
   return holds(row, predicate, {})
end

--- `alc_card_samples`, over cardbox: a card's rows, those a `where` keeps, paged.
---
--- `offset` and `limit` apply to the rows that passed the filter, as they did in v0. The
--- rows are decoded whole — a card's samples are what a run wrote in batches of at most a
--- few thousand — and a card with no samples answers `[]`, as v0 did.
function compat.samples(s: store, id: string, opts: compat.RowsOpts): {any}, string
   local o = opts or {}
   local rows, err = cards.samples(s, id)
   if rows == nil then
      return nil, err
   end
   local kept: {any}
   local predicate = predicate_of(o)
   if predicate ~= nil then
      kept = {}
      for i = 1, #rows do
         local ok, merr = compat.matches(rows[i], predicate)
         if merr ~= nil then
            return nil, merr
         end
         if ok then
            kept[#kept + 1] = rows[i]
         end
      end
   else
      kept = rows
   end
   local from = 1
   if type(o.offset) == "number" and o.offset > 0 then
      from = math.floor(o.offset) + 1
   end
   local to = #kept
   if type(o.limit) == "number" and o.limit >= 0 then
      to = math.min(to, from + math.floor(o.limit) - 1)
   end
   if from > to then
      return json.array()
   end
   return list.slice(kept, from, to)
end

return compat
