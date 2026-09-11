-- What the command line comes to before any of it reaches a store.
--
-- `htl test` runs the Teal alone, so there is no host here — which is exactly why the two
-- parsers are separated out from the dispatch. Everything below decides its whole answer
-- from its arguments: what a `--key value` line came to, what a `--where` clause means, and
-- what the usage text names.
--
-- The property the refusals are for: an option nobody declared is a mistake, not a
-- positional. A `cardbox open --scenarion arith` that went through would open a card with
-- no scenario and say nothing about why.

local t = require("htl.test")
local cli = require("cardbox.cli")

local function spec(keys: {string:boolean}, flags: {string:boolean}): cli.Spec
   return { keys = keys, flags = flags }
end

local OPEN = spec({ pkg = true, parent = true }, { ["dry-run"] = true, json = true })

t.describe("cli.parse", function()
   t.it("keeps positionals in the order they were given", function()
      local args, err = cli.parse({ "set", "champion", "cot_1" }, OPEN)
      t.expect(err):to_be_nil()
      t.expect(#args.positional):to_equal(3)
      t.expect(args.positional[1]):to_equal("set")
      t.expect(args.positional[2]):to_equal("champion")
      t.expect(args.positional[3]):to_equal("cot_1")
   end)

   t.it("takes a key and its value", function()
      local args = cli.parse({ "--pkg", "cot" }, OPEN)
      t.expect(cli.value(args, "pkg")):to_equal("cot")
      t.expect(#args.positional):to_equal(0)
   end)

   t.it("takes --key=value as the same thing", function()
      local args = cli.parse({ "--pkg=cot" }, OPEN)
      t.expect(cli.value(args, "pkg")):to_equal("cot")
   end)

   t.it("collects a key given more than once, in order", function()
      local args = cli.parse({ "--parent", "a", "--parent", "b" }, OPEN)
      local parents = cli.list(args, "parent")
      t.expect(#parents):to_equal(2)
      t.expect(parents[1]):to_equal("a")
      t.expect(parents[2]):to_equal("b")
      -- and `value` is the last of them, which is what a key meant to be given once needs
      t.expect(cli.value(args, "parent")):to_equal("b")
   end)

   t.it("answers nil for a key that was never given", function()
      local args = cli.parse({ "--pkg", "cot" }, OPEN)
      t.expect(cli.value(args, "parent")):to_be_nil()
      t.expect(cli.list(args, "parent")):to_be_nil()
   end)

   t.it("takes a flag without a value, and leaves the rest alone", function()
      local args = cli.parse({ "--dry-run", "x" }, OPEN)
      t.expect(args.flags["dry-run"]):to_equal(true)
      t.expect(args.positional[1]):to_equal("x")
   end)

   t.it("refuses a value on a flag", function()
      local args, err = cli.parse({ "--dry-run=yes" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("--dry-run")
      t.expect(err):to_contain("takes no value")
   end)

   t.it("refuses an option nobody declared, by name", function()
      local args, err = cli.parse({ "--scenarion", "arith" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("no such option: --scenarion")
   end)

   t.it("refuses a key with nothing after it", function()
      local args, err = cli.parse({ "--pkg" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("--pkg needs a value")
   end)

   t.it("reads a whole number, and refuses one that is not", function()
      local args = cli.parse({ "--pkg", "12" }, OPEN)
      t.expect((cli.integer(args, "pkg"))):to_equal(12)

      local other = cli.parse({ "--pkg", "1.5" }, OPEN)
      local n, err = cli.integer(other, "pkg")
      t.expect(n):to_be_nil()
      t.expect(err):to_contain("whole number")
   end)
end)

t.describe("cli.parse_where", function()
   t.it("reads a number as a number", function()
      local clause, err = cli.parse_where("mean_score > 0.5")
      t.expect(err):to_be_nil()
      t.expect(clause.column):to_equal("mean_score")
      t.expect(clause.op):to_equal(">")
      t.expect(clause.value):to_equal(0.5)
   end)

   t.it("reads an unquoted word as text", function()
      local clause = cli.parse_where("pkg = cot")
      t.expect(clause.column):to_equal("pkg")
      t.expect(clause.op):to_equal("=")
      t.expect(clause.value):to_equal("cot")
   end)

   t.it("reads a quoted value as the text inside it, spaces and all", function()
      local clause = cli.parse_where('note like "my pkg%"')
      t.expect(clause.op):to_equal("like")
      t.expect(clause.value):to_equal("my pkg%")
   end)

   t.it("reads an array as an array", function()
      local clause, err = cli.parse_where('state in ["closed_ok","closed_failed"]')
      t.expect(err):to_be_nil()
      t.expect(clause.op):to_equal("in")
      local values = clause.value as {any}
      t.expect(#values):to_equal(2)
      t.expect(values[1]):to_equal("closed_ok")
      t.expect(values[2]):to_equal("closed_failed")
   end)

   t.it("reads an array of numbers", function()
      local clause = cli.parse_where("n in [3, 5]")
      local values = clause.value as {any}
      t.expect(#values):to_equal(2)
      t.expect(values[1]):to_equal(3)
      t.expect(values[2]):to_equal(5)
   end)

   t.it("reads true and false as booleans", function()
      local clause = cli.parse_where("passed = true")
      t.expect(clause.value):to_equal(true)
   end)

   t.it("refuses a clause that is not three parts", function()
      local clause, err = cli.parse_where("mean_score >")
      t.expect(clause):to_be_nil()
      t.expect(err):to_contain("column op value")
   end)

   t.it("refuses an array that is not closed", function()
      local clause, err = cli.parse_where('state in ["a","b"')
      t.expect(clause):to_be_nil()
      t.expect(err):to_contain("not closed")
   end)

   t.it("refuses an empty array, which would be a query for nothing", function()
      local clause, err = cli.parse_where("state in []")
      t.expect(clause):to_be_nil()
      t.expect(err):to_contain("non-empty")
   end)

   t.it("leaves the column and the operator to find.build_find", function()
      -- Neither is checked here: one whitelist, in one place, named by one refusal.
      local clause, err = cli.parse_where("nonsense ~~ 3")
      t.expect(err):to_be_nil()
      t.expect(clause.column):to_equal("nonsense")
      t.expect(clause.op):to_equal("~~")
   end)
end)

t.describe("cli.usage", function()
   t.it("names every command the dispatch has", function()
      local usage = cli.usage()
      local commands = {
         "open", "samples", "eval", "checkpoint", "close",
         "get", "list", "find", "lineage",
         "alias set", "alias release", "alias get", "alias list", "alias history",
         "promote", "prune", "prune-log", "export", "import",
         "version", "root", "catch-up", "rebuild", "help",
      }
      for i = 1, #commands do
         t.expect(usage):to_contain(commands[i])
      end
   end)

   t.it("says where the output and the refusals go", function()
      local usage = cli.usage()
      t.expect(usage):to_contain("JSON on stdout")
      t.expect(usage):to_contain("CARDBOX_ROOT")
   end)
end)
