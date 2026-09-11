-- What `cards.prune` decides before any of it reaches a store.
--
-- `htl test` runs the Teal alone, so there is no host here: `plan_prune` takes the two
-- facts about the world outside a card — which cards carry an alias, which cards are
-- somebody's parent — as plain sets, precisely so that the rule can be argued about
-- without opening a log. Everything below is therefore also an assertion that the rule is
-- total: it decides every candidate from the three inputs and asks nothing.
--
-- The property the refusals are for: **a prune never removes something another thing is
-- still pointing at, and never removes everything by accident.** The first is the three
-- skip buckets; the second is the refusal of a spec that bounds nothing.

local t = require("htl.test")
local cards = require("cardbox.cards")
local type find = require("cardbox.find")
local type prune = require("cardbox.prune")

local function card(id: string, state?: string): find.CardSummary
   return { id = id, pkg = "cot", scenario = "arith", state = state or "closed_ok" }
end

local function ids(list: {string}): string
   return table.concat(list, ",")
end

-- The smallest spec that is bounded and has a reason, which is what every bucket test
-- wants: the refusals it is about are per card, not per spec.
local function spec(over: prune.PruneSpec): prune.PruneSpec
   local out: prune.PruneSpec = { pkg = "cot", reason = "test debris" }
   if over ~= nil then
      out.pkg = over.pkg or out.pkg
      out.pkg_like = over.pkg_like
      out.older_than_ms = over.older_than_ms
      out.states = over.states
      out.ids = over.ids
      out.reason = over.reason or out.reason
      out.dry_run = over.dry_run
   end
   return out
end

t.describe("cards.plan_prune", function()
   t.it("selects a closed card nothing points at", function()
      local plan, err = cards.plan_prune({ card("a"), card("b") }, {}, {}, spec(nil))
      t.expect(err):to_be_nil()
      t.expect(ids(plan.selected)):to_equal("a,b")
      t.expect(#plan.skipped_aliased):to_equal(0)
      t.expect(#plan.skipped_parent):to_equal(0)
      t.expect(#plan.skipped_open):to_equal(0)
   end)

   t.it("skips a card that carries an alias", function()
      local plan = cards.plan_prune({ card("a"), card("b") }, { b = true }, {}, spec(nil))
      t.expect(ids(plan.selected)):to_equal("a")
      t.expect(ids(plan.skipped_aliased)):to_equal("b")
   end)

   t.it("skips a card that is somebody's parent", function()
      local plan = cards.plan_prune({ card("a"), card("b") }, {}, { a = true }, spec(nil))
      t.expect(ids(plan.selected)):to_equal("b")
      t.expect(ids(plan.skipped_parent)):to_equal("a")
   end)

   t.it("skips an open card unless the spec names the state", function()
      local plan = cards.plan_prune({ card("a", "open"), card("b") }, {}, {}, spec(nil))
      t.expect(ids(plan.selected)):to_equal("b")
      t.expect(ids(plan.skipped_open)):to_equal("a")
   end)

   t.it("takes an open card when states names it", function()
      local allowed = spec({ states = { "open", "closed_failed" } })
      local plan = cards.plan_prune({ card("a", "open"), card("b") }, {}, {}, allowed)
      t.expect(ids(plan.selected)):to_equal("a,b")
      t.expect(#plan.skipped_open):to_equal(0)
   end)

   -- A card can fail more than one refusal, and the report has to file it once. The
   -- alias is first because it is the first thing a reader would have to undo.
   t.it("files a card that is both aliased and a parent under the alias", function()
      local plan = cards.plan_prune({ card("a") }, { a = true }, { a = true }, spec(nil))
      t.expect(#plan.selected):to_equal(0)
      t.expect(ids(plan.skipped_aliased)):to_equal("a")
      t.expect(#plan.skipped_parent):to_equal(0)
   end)
end)

t.describe("cards.plan_prune refusals", function()
   t.it("refuses a spec that bounds nothing, naming the four ways to bound one", function()
      local plan, err = cards.plan_prune({ card("a") }, {}, {}, { reason = "spring cleaning" })
      t.expect(plan):to_be_nil()
      t.expect(err):to_contain("every card")
      t.expect(err):to_contain("pkg")
      t.expect(err):to_contain("pkg_like")
      t.expect(err):to_contain("older_than_ms")
      t.expect(err):to_contain("ids")
   end)

   t.it("refuses a spec with no reason: the journal outlives the cards", function()
      local plan, err = cards.plan_prune({ card("a") }, {}, {}, { pkg = "cot" })
      t.expect(plan):to_be_nil()
      t.expect(err):to_contain("reason")

      local blank, berr = cards.plan_prune({ card("a") }, {}, {}, { pkg = "cot", reason = "" })
      t.expect(blank):to_be_nil()
      t.expect(berr):to_contain("reason")
   end)

   t.it("refuses ids and states that are not arrays of strings", function()
      local _, ierr = cards.plan_prune({}, {}, {}, { ids = {}, reason = "why" })
      t.expect(ierr):to_contain("ids")

      local _, serr = cards.plan_prune({}, {}, {}, { pkg = "cot", states = {}, reason = "why" })
      t.expect(serr):to_contain("states")
   end)

   t.it("refuses an older_than_ms that is not a positive number", function()
      local _, err = cards.plan_prune({}, {}, {}, { older_than_ms = 0, reason = "why" })
      t.expect(err):to_contain("older_than_ms")
   end)
end)

t.describe("cards.like_escape", function()
   -- `_` and `%` are LIKE wildcards and `\` is the escape the query names, so all three
   -- come back quoted. The pattern a caller wants is the escaped literal plus the
   -- wildcards they meant: `_test_` is a pkg prefix, `%` is "and anything after it".
   t.it("quotes the three characters LIKE does not read literally", function()
      t.expect(cards.like_escape("_test_")):to_equal("\\_test\\_")
      t.expect(cards.like_escape("_test_") .. "%"):to_equal("\\_test\\_%")
      t.expect(cards.like_escape("100%")):to_equal("100\\%")
      t.expect(cards.like_escape("a\\b")):to_equal("a\\\\b")
   end)

   t.it("leaves a string with none of them alone", function()
      t.expect(cards.like_escape("cot")):to_equal("cot")
   end)

   -- Escaping the whole of a pattern is the other reading, and it is the wrong one: it
   -- would turn "every pkg starting with _test_" into "the pkg literally called _test_%".
   t.it("escapes every wildcard, including one the caller meant as a wildcard", function()
      t.expect(cards.like_escape("_test_%")):to_equal("\\_test\\_\\%")
   end)
end)
