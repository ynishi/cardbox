-- What `cardbox.cards` refuses before it touches a store.
--
-- `htl test` runs the Teal alone, so there is no host here and nothing may *call* the
-- store. `local type store = require("store")` is a type-only require — Teal resolves it
-- against src/store.d.tl and generates no `require` for it — and the stub below is an
-- empty table wearing that type. Every test in this file is therefore also an assertion
-- that validation ran first: if one of these calls reached the stub, the run would die on
-- a nil method instead of returning the message the test reads.

local t = require("htl.test")
local type store = require("store")
local cards = require("cardbox.cards")

local stub = {} as store

local function spec(over: cards.OpenSpec): cards.OpenSpec
   return {
      pkg = over.pkg or "cot",
      scenario = over.scenario or "arith",
      source = over.source or "eval",
      created_by = over.created_by or "cardbox 0.1.0",
      parents = over.parents,
      note = over.note,
      id = over.id,
   }
end

t.describe("cards.open", function()
   t.it("refuses a pkg that is not a name", function()
      local card, err = cards.open(stub, spec({ pkg = "cot/v2" }))
      t.expect(card):to_be_nil()
      t.expect(err):to_contain("pkg")
      t.expect(err):to_contain("cot/v2")
   end)

   t.it("names the field it is missing", function()
      local _, no_pkg = cards.open(stub, spec({ pkg = "" }))
      t.expect(no_pkg):to_equal("pkg is required")
      local _, no_scenario = cards.open(stub, spec({ scenario = "" }))
      t.expect(no_scenario):to_equal("scenario is required")
      local _, no_source = cards.open(stub, spec({ source = "" }))
      t.expect(no_source):to_equal("source is required")
      local _, no_created_by = cards.open(stub, spec({ created_by = "" }))
      t.expect(no_created_by):to_equal("created_by is required")
   end)

   t.it("refuses an id of its own that is not a name", function()
      local card, err = cards.open(stub, spec({ id = "card 1" }))
      t.expect(card):to_be_nil()
      t.expect(err):to_contain("id")
   end)

   t.it("refuses a parent that is not a name, saying which one", function()
      local card, err = cards.open(stub, spec({ parents = { "ok_one", "not ok" } }))
      t.expect(card):to_be_nil()
      t.expect(err):to_contain("parents[2]")
   end)
end)

t.describe("cards.mint_id", function()
   t.it("mints an id that is a name", function()
      local id = cards.mint_id("cot", "arith")
      t.expect(id):to_match("^[%w_%-]+$")
   end)

   t.it("leads with the pkg and the scenario and ends with six hex digits", function()
      local id = cards.mint_id("cot", "arith")
      t.expect(id):to_match("^cot_arith_%d%d%d%d%d%d%d%dT%d%d%d%d%d%d_%x%x%x%x%x%x$")
   end)

   t.it("does not repeat itself within one second", function()
      local first = cards.mint_id("cot", "arith")
      local second = cards.mint_id("cot", "arith")
      t.expect(first):to_not_equal(second)
   end)

   t.it("refuses a scenario that is not a name: it becomes part of the id", function()
      local id, err = cards.mint_id("cot", "arith v2")
      t.expect(id):to_be_nil()
      t.expect(err):to_contain("scenario")
   end)
end)

t.describe("cards.close", function()
   t.it("refuses ok = true with an error: the two would disagree", function()
      local rec, err = cards.close(stub, "card_1", { ok = true, error = "boom" })
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("takes no error")
   end)

   t.it("refuses ok = false without one: a failure has to say what it was", function()
      local rec, err = cards.close(stub, "card_1", { ok = false })
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("needs error")
   end)

   t.it("refuses an outcome that says nothing", function()
      local rec, err = cards.close(stub, "card_1", {})
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("outcome.ok")
   end)
end)

t.describe("cards.append_samples", function()
   t.it("refuses an empty batch", function()
      local out, err = cards.append_samples(stub, "card_1", {})
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("at least one row")
   end)

   t.it("refuses a row that is not a table, saying which", function()
      local out, err = cards.append_samples(stub, "card_1", { {}, "nope" })
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("row 2")
   end)

   t.it("refuses an id that could not be a stream name", function()
      local out, err = cards.append_samples(stub, "card 1", { {} })
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("id")
   end)
end)

t.describe("cards.save_checkpoint", function()
   t.it("needs a format", function()
      local rec, err = cards.save_checkpoint(stub, "card_1", "bytes", {})
      t.expect(rec):to_be_nil()
      t.expect(err):to_equal("format is required")
   end)

   t.it("needs the bytes", function()
      local rec, err = cards.save_checkpoint(stub, "card_1", "", { format = "safetensors" })
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("bytes")
   end)
end)
