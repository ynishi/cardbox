-- What the alias half refuses, and how it picks a winner, before any of it reaches a
-- store.
--
-- `htl test` runs the Teal alone, so there is no host here: the stub below is an empty
-- table wearing the store's type, and every refusal in this file is therefore also an
-- assertion that validation ran first — a call that reached the stub would die on a nil
-- method instead of returning the message the test reads.
--
-- `pick_best` needs no store at all. It is the whole of the promotion rule that is worth
-- arguing about — highest metric, ties to the newest, nothing under `min_n`, nothing that
-- never recorded the number — and it is a pure function over the summaries `cards.find`
-- answers with so that it can be read here rather than through a database.

local t = require("htl.test")
local type store = require("store")
local cards = require("cardbox.cards")
local type find = require("cardbox.find")

local stub = {} as store

local function card(id: string, over: find.CardSummary): find.CardSummary
   return {
      id = id,
      pkg = over.pkg or "cot",
      scenario = over.scenario or "arith",
      state = "closed_ok",
      started_ms = over.started_ms,
      opened_ms = over.opened_ms or 1000,
      closed_ms = over.closed_ms,
      mean_score = over.mean_score,
      n = over.n or 10,
      pass_rate = over.pass_rate,
      passed = over.passed,
   }
end

t.describe("cards.alias", function()
   t.it("takes a name of letters, digits, _ - and .", function()
      -- The store here is the stub, so a call that gets past validation dies on a nil
      -- `bind_alias` rather than returning anything. That failure is the assertion: the
      -- name was accepted, and the only thing left to reach was the host.
      t.expect(pcall(function()
         cards.alias(stub, "cot.champion", "cot_arith_1")
      end)):to_be_falsy()
   end)

   t.it("refuses a name with a space, showing it", function()
      local rec, err = cards.alias(stub, "the champion", "cot_arith_1")
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("alias name")
      t.expect(err):to_contain("the champion")
   end)

   t.it("refuses a name with a slash: it becomes part of a stream name", function()
      local rec, err = cards.alias(stub, "cot/champion", "cot_arith_1")
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("letters, digits")
   end)

   t.it("refuses an empty name", function()
      local rec, err = cards.alias(stub, "", "cot_arith_1")
      t.expect(rec):to_be_nil()
      t.expect(err):to_equal("alias name is required")
   end)

   t.it("refuses a name past 128 characters, saying how long it was", function()
      local long = string.rep("a", 129)
      local rec, err = cards.alias(stub, long, "cot_arith_1")
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("128")
      t.expect(err):to_contain("129")
   end)

   t.it("takes a name of exactly 128", function()
      t.expect(pcall(function()
         cards.alias(stub, string.rep("a", 128), "cot_arith_1")
      end)):to_be_falsy()
   end)

   t.it("refuses an id that could not be a card's stream", function()
      local rec, err = cards.alias(stub, "champion", "cot arith 1")
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("id")
   end)
end)

t.describe("cards.alias_release", function()
   t.it("refuses a name that is not a name, without asking the store", function()
      local rec, err = cards.alias_release(stub, "not a name")
      t.expect(rec):to_be_nil()
      t.expect(err):to_contain("alias name")
   end)
end)

t.describe("cards.promote", function()
   t.it("names the metrics it has when asked for one it does not", function()
      local out, err = cards.promote(stub, { alias = "champion", pkg = "cot", metric = "vibes" })
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("vibes")
      t.expect(err):to_contain("mean_score, pass_rate, passed, n")
   end)

   t.it("needs a pkg: it is the field it chooses between", function()
      local out, err = cards.promote(stub, { alias = "champion", pkg = "" })
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("pkg")
   end)

   t.it("refuses an alias that is not a name", function()
      local out, err = cards.promote(stub, { alias = "the champion", pkg = "cot" })
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("alias name")
   end)

   t.it("refuses a negative min_n", function()
      local out, err = cards.promote(stub, { alias = "champion", pkg = "cot", min_n = -1 })
      t.expect(out):to_be_nil()
      t.expect(err):to_contain("min_n")
   end)
end)

t.describe("cards.pick_best", function()
   t.it("takes the highest metric", function()
      local best = cards.pick_best({
         card("low", { mean_score = 0.2 }),
         card("high", { mean_score = 0.9 }),
         card("mid", { mean_score = 0.6 }),
      }, "mean_score", 1)
      t.expect(best.id):to_equal("high")
   end)

   t.it("gives a tie to the card opened last", function()
      local best = cards.pick_best({
         card("older", { mean_score = 0.8, opened_ms = 1000 }),
         card("newer", { mean_score = 0.8, opened_ms = 2000 }),
         card("oldest", { mean_score = 0.8, opened_ms = 500 }),
      }, "mean_score", 1)
      t.expect(best.id):to_equal("newer")
   end)

   t.it("gives a tie to the run that started last, not the card written last", function()
      local best = cards.pick_best({
         card("imported", { mean_score = 0.8, started_ms = 100, opened_ms = 9000 }),
         card("recent", { mean_score = 0.8, started_ms = 5000, opened_ms = 5000 }),
      }, "mean_score", 1)
      t.expect(best.id):to_equal("recent")
   end)

   t.it("passes over a card under min_n, however well it scored", function()
      local best = cards.pick_best({
         card("lucky", { mean_score = 1.0, n = 3 }),
         card("steady", { mean_score = 0.7, n = 40 }),
      }, "mean_score", 10)
      t.expect(best.id):to_equal("steady")
   end)

   t.it("counts a card that never recorded the metric as no answer, not as a low one", function()
      local best = cards.pick_best({
         card("silent", {}),
         card("scored", { mean_score = 0.1 }),
      }, "mean_score", 1)
      t.expect(best.id):to_equal("scored")
   end)

   t.it("answers with nothing when nobody qualifies", function()
      t.expect(cards.pick_best({}, "mean_score", 1)):to_be_nil()
      t.expect(cards.pick_best({ card("thin", { mean_score = 1.0, n = 2 }) }, "mean_score", 10))
      :to_be_nil()
      t.expect(cards.pick_best({ card("silent", {}) }, "mean_score", 1)):to_be_nil()
   end)

   t.it("ranks by whichever metric it was given", function()
      local wide = card("wide", { mean_score = 0.5, n = 100, passed = 60, pass_rate = 0.6 })
      local sharp = card("sharp", { mean_score = 0.9, n = 10, passed = 9, pass_rate = 0.9 })
      t.expect(cards.pick_best({ wide, sharp }, "mean_score", 1).id):to_equal("sharp")
      t.expect(cards.pick_best({ wide, sharp }, "passed", 1).id):to_equal("wide")
      t.expect(cards.pick_best({ wide, sharp }, "pass_rate", 1).id):to_equal("sharp")
      t.expect(cards.pick_best({ wide, sharp }, "n", 1).id):to_equal("wide")
   end)
end)
