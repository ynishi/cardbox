-- alc's card/v0 surface, with no store in the room: what a `where` becomes as a query,
-- what it refuses, and what it means over a sample row.

local t = require("htl.test")
local compat = require("cardbox.compat")

local function clauses_of(args: compat.FindArgs): {string}
   local q, err = compat.translate(args)
   assert(err == nil, tostring(err))
   local out: {string} = {}
   for i, c in ipairs(q.clauses) do
      out[i] = c.column .. " " .. c.op .. " " .. tostring(c.value)
   end
   table.sort(out)
   return out
end

t.describe("compat.column_of", function()
   t.it("maps v0's fixed paths onto cardbox columns", function()
      t.expect((compat.column_of("card_id"))):to_equal("id")
      t.expect((compat.column_of("model.id"))):to_equal("model")
      t.expect((compat.column_of("pkg.name"))):to_equal("pkg")
      t.expect((compat.column_of("stats.pass_rate"))):to_equal("pass_rate")
      t.expect((compat.column_of("metadata.trace_id"))):to_equal("trace_id")
      t.expect((compat.column_of("metadata.group"))):to_equal("tags.group")
   end)

   t.it("passes stats, params and tags paths through, and files the rest where the importer did", function()
      t.expect((compat.column_of("stats.ev"))):to_equal("stats.ev")
      t.expect((compat.column_of("params.variant"))):to_equal("params.variant")
      t.expect((compat.column_of("tags.stage"))):to_equal("tags.stage")
      t.expect((compat.column_of("metadata.decision"))):to_equal("stats.metadata.decision")
      t.expect((compat.column_of("optimize.rounds_used"))):to_equal("params.optimize.rounds_used")
      t.expect((compat.column_of("persona"))):to_equal("params.persona")
   end)

   t.it("reads created_at as the run's start, and refuses prior_card_id", function()
      t.expect((compat.column_of("created_at"))):to_equal("started_ms")
      local _, lerr = compat.column_of("metadata.prior_card_id")
      t.expect(lerr):to_contain("lineage")
   end)
end)

t.describe("compat.translate", function()
   t.it("reads nested objects as paths and reserved-operator objects as leaves", function()
      local out = clauses_of({
         pkg = "cot",
         filter = {
            model = { id = "m-a" },
            stats = { pass_rate = { gte = 0.5, lt = 1 } },
            optimize = { rounds = { gt = 1 } },
            params = { variant = "blue" },
         },
      })
      t.expect(out):to_equal({
         "model = m-a",
         "params.optimize.rounds > 1",
         "params.variant = blue",
         "pass_rate < 1",
         "pass_rate >= 0.5",
         "pkg = cot",
      })
   end)

   t.it("reads the key where as the same thing as filter", function()
      local q, err = compat.translate({ ["where"] = { pkg = "cot" } } as compat.FindArgs)
      t.expect(err):to_be_nil()
      local first = q.clauses[1]
      assert(first ~= nil, "one clause")
      t.expect(first.column):to_equal("pkg")
   end)

   t.it("turns contains and starts_with into escaped LIKE patterns", function()
      local q = compat.translate({ filter = { pkg = { contains = "a_b" }, scenario = { starts_with = "x%" } } })
      local by: {string:string} = {}
      for _, c in ipairs(q.clauses) do
         by[c.column] = c.op .. " " .. tostring(c.value)
      end
      t.expect(by.pkg):to_equal("like %a\\_b%")
      t.expect(by.scenario):to_equal("like x\\%%")
   end)

   t.it("takes in, and _and as a list", function()
      local out = clauses_of({ filter = { _and = { { pkg = "a" }, { state = { ["in"] = { "open", "closed_ok" } } } } } })
      t.expect(#out):to_equal(2)
      t.expect(out[1]):to_contain("pkg = a")
      t.expect(out[2]):to_contain("state in")
   end)

   t.it("orders by a dotted path, - for descending, newest first when unsaid", function()
      local q = compat.translate({ order_by = "-stats.pass_rate" })
      t.expect(q.order_by):to_equal("pass_rate")
      t.expect(q.desc):to_equal(true)
      local up = compat.translate({ order_by = "stats.ev" })
      t.expect(up.order_by):to_equal("stats.ev")
      t.expect(up.desc):to_equal(false)
      local one = compat.translate({ order_by = { "-model.id" } })
      t.expect(one.order_by):to_equal("model")
      local none = compat.translate({})
      t.expect(none.order_by):to_be_nil()
   end)

   t.it("refuses what cards.find cannot answer, by name", function()
      local cases: {{string, any}} = {
         { "_or", { _or = { { pkg = "a" }, { pkg = "b" } } } },
         { "_not", { _not = { pkg = "a" } } },
         { "nin", { pkg = { nin = { "a" } } } },
         { "exists", { model = { id = { exists = true } } } },
         { "ISO 8601", { created_at = { gt = "2026" } } },
         { "one key", { pkg = "a" } },
      }
      for i, case in ipairs(cases) do
         local args: compat.FindArgs = { filter = case[2] }
         if i == 6 then
            args.order_by = { "pkg", "scenario" }
         end
         local q, err = compat.translate(args)
         t.expect(q):to_be_nil()
         t.expect(err):to_contain(case[1])
      end
   end)
end)

t.describe("compat.translate, created_at", function()
   t.it("converts an ISO created_at to started_ms, alone, in a leaf and in a list", function()
      local out = clauses_of({ filter = {
         created_at = { gte = "2026-04-11T18:12:36Z", lt = 1790000000000 },
      } })
      t.expect(#out):to_equal(2)
      t.expect(out[1]):to_equal("started_ms < 1790000000000")
      t.expect(out[2]):to_equal("started_ms >= 1775931156000")
      local eq = clauses_of({ filter = { created_at = "1970-01-02T00:00:00.5Z" } })
      t.expect(eq[1]):to_equal("started_ms = 86400500")
      local q, err = compat.translate({ filter = { created_at = { ["in"] = { "1970-01-01T00:00:01Z" } } } })
      t.expect(err):to_be_nil()
      local first = q.clauses[1]
      assert(first ~= nil, "one clause")
      t.expect((first.value as {integer})[1]):to_equal(1000)
   end)

   t.it("orders by created_at as started_ms, and refuses a text match on it", function()
      local q = compat.translate({ order_by = "-created_at" })
      t.expect(q.order_by):to_equal("started_ms")
      t.expect(q.desc):to_equal(true)
      local refused, err = compat.translate({ filter = { created_at = { starts_with = "2026" } } })
      t.expect(refused):to_be_nil()
      t.expect(err):to_contain("number")
   end)
end)

t.describe("compat.matches", function()
   local row = { score = 0.4, variant_id = "v1", meta = { status = "ok", n = 3 }, tags = { "a", "b" } }

   t.it("evaluates the whole DSL over a row", function()
      t.expect((compat.matches(row, { score = { lt = 0.5 } }))):to_equal(true)
      t.expect((compat.matches(row, { score = { gte = 0.5 } }))):to_equal(false)
      t.expect((compat.matches(row, { variant_id = "v1", meta = { status = "ok" } }))):to_equal(true)
      t.expect((compat.matches(row, { meta = { n = { ["in"] = { 1, 3 } } } }))):to_equal(true)
      t.expect((compat.matches(row, { meta = { n = { nin = { 1, 3 } } } }))):to_equal(false)
      t.expect((compat.matches(row, { admission = { exists = true } }))):to_equal(false)
      t.expect((compat.matches(row, { admission = { exists = false } }))):to_equal(true)
      t.expect((compat.matches(row, { variant_id = { starts_with = "v" } }))):to_equal(true)
      t.expect((compat.matches(row, { meta = { status = { contains = "k" } } }))):to_equal(true)
      t.expect((compat.matches(row, { _or = { { score = { gt = 1 } }, { variant_id = "v1" } } }))):to_equal(true)
      t.expect((compat.matches(row, { _not = { variant_id = "v1" } }))):to_equal(false)
      t.expect((compat.matches(row, { _and = { { score = { lt = 1 } }, { score = { gt = 0.5 } } } }))):to_equal(false)
   end)

   t.it("compares only within a type", function()
      t.expect((compat.matches(row, { variant_id = { gt = 1 } }))):to_equal(false)
      t.expect((compat.matches(row, { score = { lt = "z" } }))):to_equal(false)
   end)

   t.it("takes nil as everything and refuses a non-object", function()
      t.expect((compat.matches(row, nil))):to_equal(true)
      local ok, err = compat.matches(row, "score < 1")
      t.expect(ok):to_be_nil()
      t.expect(err):to_contain("object")
   end)
end)
