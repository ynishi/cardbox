-- The read half of the policy: what a card may be looked up by, and what a refusal says.
--
-- The tables under this are the `cb_*` read models that `src/store/projection.rs` folds
-- out of the log, exactly once, in the same transaction that moves its cursor. This module
-- never writes them and never sees them move: it asks the store's read-only SQL hatch,
-- which catches the projection up before it runs the query, so a read a line after a write
-- sees the write.
--
-- Why the query is structured rather than a string. `find` takes `{ clauses = { { column,
-- op, value } } }` and turns it into SQL with `?` placeholders and a parallel params array
-- — the value never reaches the SQL text. A string DSL (`pkg = "cot" and mean_score >
-- 0.5`) is a nicer thing to type and can be built on top of this later; it cannot be built
-- *under* it, because a parser that got a quote wrong would be a parser that wrote SQL out
-- of a caller's string. The column and the operator are the only parts that reach the
-- text, and both come from a whitelist below.
--
-- Every function answers `value, err`. A caller's mistake is `nil, "..."` and never an
-- `error()`, and `build_find` is separated out from `find` so that the SQL it writes can be
-- pinned by `htl test` with no store in the room.

local type store = require("store")

local record find
   -- What a card looks like in a list. The ten columns a reader scans before deciding
   -- which card to open — not the card, which is `cards.get`.
   --
   -- All four of the flattened close numbers are here, `passed` included, because they
   -- are also what a promotion ranks by: `cards.promote` chooses its winner out of a list
   -- of these, so a metric a summary did not carry would be a metric nothing could be
   -- ranked by (`cardbox.alias`, `METRICS`).
   record CardSummary
      id: string
      pkg: string
      scenario: string
      state: string
      opened_ms: integer
      closed_ms: integer
      mean_score: number
      n: integer
      pass_rate: number
      passed: integer
   end

   record ListOpts
      pkg: string
      state: string
      limit: integer
      offset: integer
   end

   -- One comparison: a whitelisted column, a whitelisted operator, and a value that only
   -- ever travels as a bound parameter.
   record Clause
      column: string
      op: string
      value: any
   end

   -- The field is `clauses` and not `where` because Teal reserves `where` inside a record
   -- body — it is the keyword that gives a union variant its predicate — and a field
   -- spelled that way is a syntax error rather than a field.
   record Query
      clauses: {Clause}
      order_by: string
      desc: boolean
      limit: integer
      offset: integer
   end

   record LineageNode
      id: string
      depth: integer
   end

   record Lineage
      id: string
      parents: {string}
      children: {string}
      ancestors: {LineageNode}
      descendants: {LineageNode}
   end

   record LineageOpts
      depth: integer
   end
end

-- The columns a caller may filter and order by, and the sentence a refusal names them in.
-- Everything here is a real column of `cb_cards`: the flattened `stats` and `cost` numbers
-- are in it because that is what they were flattened for, and `stats_json` / `cost_json`
-- are not, because comparing text that happens to hold JSON is the thing the flattening
-- replaced.
local COLUMNS: {string:boolean} = {
   id = true,
   pkg = true,
   scenario = true,
   source = true,
   created_by = true,
   state = true,
   opened_ms = true,
   closed_ms = true,
   mean_score = true,
   n = true,
   pass_rate = true,
   passed = true,
   elapsed_ms = true,
   llm_calls = true,
   sample_rows = true,
   eval_count = true,
   checkpoint_count = true,
}

local COLUMN_LIST = "id, pkg, scenario, source, created_by, state, opened_ms, closed_ms, "
   .. "mean_score, n, pass_rate, passed, elapsed_ms, llm_calls, sample_rows, eval_count, "
   .. "checkpoint_count"

-- The operators, mapped to what they are spelled as in SQL. `in` is the one that is not a
-- binary comparison: it takes an array and expands to as many placeholders as it has
-- elements.
local OPS: {string:string} = {
   ["="] = "=",
   ["!="] = "!=",
   ["<"] = "<",
   ["<="] = "<=",
   [">"] = ">",
   [">="] = ">=",
   ["like"] = "LIKE",
   ["in"] = "IN",
}

-- What an operator needs after its placeholder. Only `like` has one, and it is the
-- difference between a pattern that can quote a wildcard and one that cannot: SQLite's
-- LIKE has **no** escape character unless the statement names one, so `\_` in a pattern
-- would otherwise match a backslash followed by anything at all. With this, a caller can
-- pass a literal through `cards.like_escape` and have it match itself — which is what a
-- prune of the pkg `_test_` needs, `_` being a wildcard.
--
-- Every pattern that holds no backslash behaves exactly as it did without the clause, so
-- this is not a change to what an existing query means.
local OP_SUFFIX: {string:string} = {
   ["like"] = " ESCAPE '\\'",
}

local OP_LIST = '=, !=, <, <=, >, >=, like, in'

-- How many rows a query answers with when it does not say, and the most it will answer
-- with when it asks for more. The ceiling is not a guess about memory: it is what keeps a
-- caller that meant `limit = 50` and typed `5000` from pulling a whole store through the
-- JSON conversion before noticing.
local DEFAULT_LIMIT = 50
local MAX_LIMIT = 500

-- How far `lineage` walks by default, and the most it will walk. A card's ancestry is a
-- few generations of "this run started from that one"; ten is far past where a reader is
-- still reading a tree rather than a crowd.
local DEFAULT_DEPTH = 3
local MAX_DEPTH = 10

local SUMMARY = "SELECT id, pkg, scenario, state, opened_ms, closed_ms, mean_score, n, "
   .. "pass_rate, passed FROM cb_cards"

-- The tiebreaker every ordering ends with. `opened_ms` is a millisecond clock and two
-- cards opened in the same millisecond would otherwise come back in whatever order SQLite
-- felt like; `opened_position` is the log's own global coordinate, which is unique and
-- monotonic, so appending it makes every order total.
local TIEBREAK = "opened_position DESC"

local function clamp(v: any, fallback: integer, low: integer, high: integer): integer
   if type(v) ~= "number" then
      return fallback
   end
   local n = math.floor(v as number)
   if n < low then
      return low
   end
   if n > high then
      return high
   end
   return n
end

local function row_summary(row: {string:any}): find.CardSummary
   return {
      id = row.id as string,
      pkg = row.pkg as string,
      scenario = row.scenario as string,
      state = row.state as string,
      opened_ms = row.opened_ms as integer,
      closed_ms = row.closed_ms as integer,
      mean_score = row.mean_score as number,
      n = row.n as integer,
      pass_rate = row.pass_rate as number,
      passed = row.passed as integer,
   }
end

local function summaries(rows: {any}): {find.CardSummary}
   local out: {find.CardSummary} = {}
   for i = 1, #rows do
      out[i] = row_summary(rows[i] as {string:any})
   end
   return out
end

-- `LIMIT` and `OFFSET` are written into the text rather than bound, and that is not an
-- exception to "a value never reaches the SQL". They are not values: `clamp` has already
-- turned whatever arrived into an integer inside a known range, and `%d` can emit nothing
-- else. Keeping them out of the params array is also what lets a test read the array and
-- see exactly the clause values it passed.
local function page(limit: any, offset: any): string
   return string.format(
      " LIMIT %d OFFSET %d",
      clamp(limit, DEFAULT_LIMIT, 1, MAX_LIMIT),
      clamp(offset, 0, 0, math.maxinteger)
   )
end

--- The SQL a `Query` becomes: the text, the parameters to bind into it, and a refusal.
---
--- Public so that `htl test` can pin it without a store — the SQL this writes is the whole
--- of what `find` does that is worth arguing about, and a test that had to open a store to
--- see it would be testing the store too.
---
--- Answers `sql, params` or `nil, nil, err`.
function find.build_find(q: find.Query): string, {any}, string
   if q == nil then
      return nil, nil, "find needs a query"
   end

   local sql = SUMMARY
   local params: {any} = {}
   local clauses = q.clauses

   if clauses ~= nil and #clauses > 0 then
      local parts: {string} = {}
      for i = 1, #clauses do
         local clause = clauses[i]
         local at = "clause " .. tostring(i)
         if clause == nil or type(clause.column) ~= "string" then
            return nil, nil, at .. " needs a column"
         end
         if COLUMNS[clause.column] == nil then
            return nil, nil, at .. ' names no column a card can be found by: "'
               .. clause.column
               .. '" is not one of '
               .. COLUMN_LIST
         end
         if type(clause.op) ~= "string" then
            return nil, nil, at .. " needs an op"
         end
         local op = OPS[clause.op]
         if op == nil then
            return nil, nil, at .. ' asks for an op this find does not have: "'
               .. clause.op
               .. '" is not one of '
               .. OP_LIST
         end

         -- `in` takes an array, and a non-empty one: `IN ()` is not SQL, and a caller who
         -- meant "match nothing" has said something they did not mean.
         if clause.op == "in" then
            local values = clause.value as {any}
            if type(clause.value) ~= "table" or values == nil or #values == 0 then
               return nil, nil, at .. ' uses "in", which takes a non-empty array of values, got a '
                  .. type(clause.value)
            end
            local marks: {string} = {}
            for j = 1, #values do
               marks[j] = "?"
               params[#params + 1] = values[j]
            end
            parts[#parts + 1] = clause.column .. " IN (" .. table.concat(marks, ", ") .. ")"
         else
            parts[#parts + 1] = clause.column .. " " .. op .. " ?" .. (OP_SUFFIX[clause.op] or "")
            params[#params + 1] = clause.value
         end
      end
      sql = sql .. " WHERE " .. table.concat(parts, " AND ")
   end

   local order = "opened_ms"
   if q.order_by ~= nil then
      if type(q.order_by) ~= "string" or COLUMNS[q.order_by] == nil then
         return nil, nil, 'order_by names no column a card can be ordered by: "'
            .. tostring(q.order_by)
            .. '" is not one of '
            .. COLUMN_LIST
      end
      order = q.order_by
   end
   -- Descending unless the caller says otherwise: the newest card, the highest score and
   -- the longest run are what a reader asking for one of these is usually after.
   local direction = "DESC"
   if q.desc == false then
      direction = "ASC"
   end
   sql = sql .. " ORDER BY " .. order .. " " .. direction .. ", " .. TIEBREAK
   sql = sql .. page(q.limit, q.offset)

   return sql, params
end

--- The cards a `Query` selects, newest first unless it orders otherwise.
function find.find(s: store, q: find.Query): {find.CardSummary}, string
   local sql, params, err = find.build_find(q)
   if sql == nil then
      return nil, err
   end
   local rows, qerr = s:query(sql, params)
   if rows == nil then
      return nil, qerr
   end
   return summaries(rows)
end

--- The cards, newest first, optionally narrowed to one pkg or one state.
---
--- `find` with two clauses would answer the same thing; this is here because "the last
--- fifty" is the question a reader opens with, and it should not need a query object.
function find.list(s: store, opts: find.ListOpts): {find.CardSummary}, string
   local o = opts or {}
   local sql = SUMMARY
   local params: {any} = {}
   local parts: {string} = {}

   if o.pkg ~= nil then
      if type(o.pkg) ~= "string" then
         return nil, "list takes pkg as a string, got a " .. type(o.pkg)
      end
      parts[#parts + 1] = "pkg = ?"
      params[#params + 1] = o.pkg
   end
   if o.state ~= nil then
      if type(o.state) ~= "string" then
         return nil, "list takes state as a string, got a " .. type(o.state)
      end
      parts[#parts + 1] = "state = ?"
      params[#params + 1] = o.state
   end
   if #parts > 0 then
      sql = sql .. " WHERE " .. table.concat(parts, " AND ")
   end
   sql = sql .. " ORDER BY opened_ms DESC, " .. TIEBREAK .. page(o.limit, o.offset)

   local rows, err = s:query(sql, params)
   if rows == nil then
      return nil, err
   end
   return summaries(rows)
end

-- One step of the walk, in whichever direction. `cb_lineage` is `(child, parent)`, so
-- going up reads the parents of a child and going down reads the children of a parent.
local UP = "SELECT parent AS other FROM cb_lineage WHERE child = ?"
local DOWN = "SELECT child AS other FROM cb_lineage WHERE parent = ?"

-- Breadth-first, so a node's `depth` is the shortest way to it and not the first way found.
--
-- `seen` starts holding the card itself. That is the whole of the cycle safety: a parent
-- chain that loops back is an ordinary table of rows to SQLite, and without the visited set
-- this would walk it until `depth` ran out and report the card as its own ancestor on the
-- way. Nothing stops such a chain being written — `open` takes the parent ids on trust,
-- because a parent may legitimately be a card that does not exist here yet — so the reader
-- is where it has to be handled.
local function walk(s: store, start: string, sql: string, depth: integer): {find.LineageNode}, string
   local seen: {string:boolean} = { [start] = true }
   local out: {find.LineageNode} = {}
   local frontier: {string} = { start }

   for d = 1, depth do
      local next_frontier: {string} = {}
      for i = 1, #frontier do
         local rows, err = s:query(sql, { frontier[i] })
         if rows == nil then
            return nil, err
         end
         for j = 1, #rows do
            local row = rows[j] as {string:any}
            local other = row.other as string
            if other ~= nil and not seen[other] then
               seen[other] = true
               out[#out + 1] = { id = other, depth = d }
               next_frontier[#next_frontier + 1] = other
            end
         end
      end
      if #next_frontier == 0 then
         return out
      end
      frontier = next_frontier
   end
   return out
end

local function neighbours(s: store, sql: string, id: string): {string}, string
   local rows, err = s:query(sql, { id })
   if rows == nil then
      return nil, err
   end
   local out: {string} = {}
   for i = 1, #rows do
      local row = rows[i] as {string:any}
      out[i] = row.other as string
   end
   return out
end

--- Where a card came from and what came from it.
---
--- `parents` and `children` are the one step either way; `ancestors` and `descendants` are
--- the walk, each node carrying how many steps away it is. An id no card is under is
--- refused rather than answered with four empty lists, because "nothing descends from it"
--- and "there is no such card" are different answers and only one of them is worth acting
--- on.
function find.lineage(s: store, id: string, opts: find.LineageOpts): find.Lineage, string
   if type(id) ~= "string" or id == "" then
      return nil, "id is required"
   end
   local depth = clamp((opts or {}).depth, DEFAULT_DEPTH, 1, MAX_DEPTH)

   local rows, err = s:query("SELECT id FROM cb_cards WHERE id = ?", { id })
   if rows == nil then
      return nil, err
   end
   if #rows == 0 then
      return nil, "no card " .. id
   end

   local parents, perr = neighbours(s, UP, id)
   if parents == nil then
      return nil, perr
   end
   local children, cerr = neighbours(s, DOWN, id)
   if children == nil then
      return nil, cerr
   end
   local ancestors, aerr = walk(s, id, UP, depth)
   if ancestors == nil then
      return nil, aerr
   end
   local descendants, derr = walk(s, id, DOWN, depth)
   if descendants == nil then
      return nil, derr
   end

   return {
      id = id,
      parents = parents,
      children = children,
      ancestors = ancestors,
      descendants = descendants,
   }
end

return find
