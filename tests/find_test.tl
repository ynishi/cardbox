-- What `cards.find` turns a query into, before any of it reaches a store.
--
-- `htl test` runs the Teal alone, so there is no host here: `build_find` is separated out
-- from `find` precisely so that the SQL and the parameters can be read without one. Every
-- test below is therefore also an assertion that the builder is total — it decides the
-- whole statement from the query object and asks nothing.
--
-- The property the refusals are for: a value never reaches the SQL text. Only a
-- whitelisted column name and a whitelisted operator do, and everything a caller supplies
-- comes back in the params array beside the `?` that will bind it.

local t = require("htl.test")
local cards = require("cardbox.cards")
local type find = require("cardbox.find")

local function clause(column: string, op: string, value: any): find.Clause
   return { column = column, op = op, value = value }
end

t.describe("cards.build_find", function()
   t.it("turns one clause into one placeholder and one parameter", function()
      local sql, params, err = cards.build_find({ clauses = { clause("pkg", "=", "cot") } })
      t.expect(err):to_be_nil()
      t.expect(sql):to_equal(
         "SELECT id, pkg, scenario, model, state, opened_ms, closed_ms, mean_score, n, pass_rate, "
            .. "passed, (SELECT json_group_object(key, value) FROM cb_tags WHERE card_id = cb_cards.id) "
            .. "AS tags_json FROM cb_cards WHERE pkg = ? "
            .. "ORDER BY opened_ms DESC, opened_position DESC LIMIT 50 OFFSET 0"
      )
      t.expect(#params):to_equal(1)
      t.expect(params[1]):to_equal("cot")
   end)

   t.it("joins two clauses with AND, in the order they were given", function()
      local sql, params = cards.build_find({
         clauses = { clause("pkg", "=", "cot"), clause("mean_score", ">", 0.5) },
      })
      t.expect(sql):to_contain("WHERE pkg = ? AND mean_score > ?")
      t.expect(#params):to_equal(2)
      t.expect(params[1]):to_equal("cot")
      t.expect(params[2]):to_equal(0.5)
   end)

   t.it("expands in to one placeholder per element", function()
      local sql, params = cards.build_find({
         clauses = { clause("state", "in", { "closed_ok", "closed_failed" }) },
      })
      t.expect(sql):to_contain("state IN (?, ?)")
      t.expect(#params):to_equal(2)
      t.expect(params[1]):to_equal("closed_ok")
      t.expect(params[2]):to_equal("closed_failed")
   end)

   t.it("refuses in with something that is not an array", function()
      local sql, params, err = cards.build_find({
         clauses = { clause("state", "in", "closed_ok") },
      })
      t.expect(sql):to_be_nil()
      t.expect(params):to_be_nil()
      t.expect(err):to_contain("in")
      t.expect(err):to_contain("array")
   end)

   t.it("refuses an empty in: IN () is not a query anyone meant", function()
      local sql, _, err = cards.build_find({ clauses = { clause("state", "in", {}) } })
      t.expect(sql):to_be_nil()
      t.expect(err):to_contain("array")
   end)

   t.it("refuses a column that is not one a card can be found by, naming both", function()
      local sql, params, err = cards.build_find({
         clauses = { clause("stats_json", "=", "{}") },
      })
      t.expect(sql):to_be_nil()
      t.expect(params):to_be_nil()
      t.expect(err):to_contain("stats_json")
      t.expect(err):to_contain("mean_score")
      t.expect(err):to_contain("clause 1")
   end)

   t.it("refuses an op it does not have, naming the ones it does", function()
      local sql, _, err = cards.build_find({ clauses = { clause("pkg", "=~", "cot") } })
      t.expect(sql):to_be_nil()
      t.expect(err):to_contain("=~")
      t.expect(err):to_contain("like")
   end)

   t.it("takes the ops it does have", function()
      for _, op in ipairs({ "=", "!=", "<", "<=", ">", ">=", "like" }) do
         local sql, _, err = cards.build_find({ clauses = { clause("pkg", op, "cot") } })
         t.expect(err):to_be_nil()
         t.expect(sql):to_contain("WHERE pkg " .. (op == "like" and "LIKE" or op) .. " ?")
      end
   end)

   t.it("orders by a whitelisted column and refuses any other", function()
      local sql = cards.build_find({ order_by = "mean_score" })
      t.expect(sql):to_contain("ORDER BY mean_score DESC, opened_position DESC")

      local up = cards.build_find({ order_by = "mean_score", desc = false })
      t.expect(up):to_contain("ORDER BY mean_score ASC")

      local refused, _, err = cards.build_find({ order_by = "opened_ms; DROP TABLE cb_cards" })
      t.expect(refused):to_be_nil()
      t.expect(err):to_contain("order_by")
      t.expect(err):to_contain("DROP TABLE")
   end)

   t.it("reaches into params and stats by a dotted path, and refuses one that could close the quote", function()
      local sql, params = cards.build_find({
         clauses = { clause("params.model.temperature", ">", 0.5), clause("stats.ev", ">=", 5) },
         order_by = "stats.ev",
      })
      t.expect(sql):to_contain("WHERE json_extract(params_json, '$.model.temperature') > ?")
      t.expect(sql):to_contain("AND json_extract(stats_json, '$.ev') >= ?")
      t.expect(sql):to_contain("ORDER BY json_extract(stats_json, '$.ev') DESC")
      t.expect(#params):to_equal(2)

      for _, bad in ipairs({ "params.a'b", "params..a", "params.a.", "stats.", "params.a b" }) do
         local refused, _, err = cards.build_find({ clauses = { clause(bad, "=", 1) } })
         t.expect(refused):to_be_nil()
         t.expect(err):to_contain("path")
      end
   end)

   t.it("carries every row's tags as one JSON object, built in the same statement", function()
      -- The tags are a correlated subquery in the SELECT list and not a second query, so
      -- the row and its tags are the same instant of the store; and the subquery takes no
      -- parameter, so a query with no clauses still binds nothing.
      local sql, params = cards.build_find({})
      t.expect(sql):to_contain(
         "passed, (SELECT json_group_object(key, value) FROM cb_tags WHERE card_id = cb_cards.id) AS tags_json"
      )
      t.expect(#params):to_equal(0)
   end)

   t.it("reads a tag by key, with the key bound before the value", function()
      local sql, params = cards.build_find({
         clauses = { clause("pkg", "=", "cot"), clause("tags.stage", "=", "prod") },
         order_by = "tags.review.verdict",
      })
      t.expect(sql):to_contain("AND (SELECT value FROM cb_tags WHERE card_id = cb_cards.id AND key = ?) = ?")
      t.expect(sql):to_contain("ORDER BY (SELECT value FROM cb_tags WHERE card_id = cb_cards.id AND key = ?) DESC")
      t.expect(params[1] as string):to_equal("cot")
      t.expect(params[2] as string):to_equal("stage")
      t.expect(params[3] as string):to_equal("prod")
      t.expect(params[4] as string):to_equal("review.verdict")

      local refused, _, err = cards.build_find({ clauses = { clause("tags.a b", "=", 1) } })
      t.expect(refused):to_be_nil()
      t.expect(err):to_contain("tag key")

      local unknown, _, uerr = cards.build_find({ clauses = { clause("cost.x", "=", 1) } })
      t.expect(unknown):to_be_nil()
      t.expect(uerr):to_contain("params.<path>")
   end)

   t.it("clamps the limit at 500 and floors it at 1", function()
      t.expect((cards.build_find({ limit = 10000 }))):to_contain("LIMIT 500")
      t.expect((cards.build_find({ limit = 0 }))):to_contain("LIMIT 1")
      t.expect((cards.build_find({ limit = 20, offset = 40 }))):to_contain("LIMIT 20 OFFSET 40")
   end)

   t.it("takes no clauses at all: the whole store, newest first", function()
      local sql, params, err = cards.build_find({})
      t.expect(err):to_be_nil()
      t.expect(#params):to_equal(0)
      t.expect(sql):to_contain("FROM cb_cards ORDER BY opened_ms DESC")
   end)
end)
