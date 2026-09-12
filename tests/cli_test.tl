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
local argparse = require("std.argparse")

-- A stand-in for a real command's spec, carrying one of each shape the commands use: a
-- single-valued key, a repeatable one, a whole number, a flag, and the three positionals
-- `alias set <name> <id>` has after its own word.
--
-- The flag is declared `dry_run` and typed `--dry-run` throughout, because that mapping is
-- what `--created-by`, `--pkg-like` and `--older-than-ms` all lean on.
local OPEN: argparse.Spec = {
   name = "cardbox test",
   flags = {
      pkg = { type = "string" },
      parent = { type = "string", multiple = true },
      limit = { type = "integer" },
      dry_run = { type = "boolean" },
      json = { type = "boolean" },
   },
   positionals = { { name = "what" }, { name = "name" }, { name = "id" } },
}

t.describe("cli.parse", function()
   t.it("gives each positional the name its spec declared, in order", function()
      local args, err = cli.parse({ "set", "champion", "cot_1" }, OPEN)
      t.expect(err):to_be_nil()
      t.expect(cli.arg(args, "what")):to_equal("set")
      t.expect(cli.arg(args, "name")):to_equal("champion")
      t.expect(cli.arg(args, "id")):to_equal("cot_1")
   end)

   t.it("takes a key and its value", function()
      local args = cli.parse({ "--pkg", "cot" }, OPEN)
      t.expect(cli.value(args, "pkg")):to_equal("cot")
      t.expect(cli.arg(args, "what")):to_be_nil()
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
      -- nil rather than the empty list an absent repeatable option collects into, because
      -- "not given" and "given nothing" are different specs downstream
      t.expect(cli.list(args, "parent")):to_be_nil()
   end)

   t.it("takes a flag by its dashed spelling, and leaves the rest alone", function()
      local args = cli.parse({ "--dry-run", "x" }, OPEN)
      t.expect(cli.flag(args, "dry_run")):to_equal(true)
      t.expect(cli.arg(args, "what")):to_equal("x")
   end)

   -- A flag reads a value rather than refusing one, so `--dry-run=false` is how a flag is
   -- turned back off. What is refused is a value that is neither.
   t.it("takes true or false on a flag, and refuses anything else", function()
      local off = cli.parse({ "--dry-run=false" }, OPEN)
      t.expect(cli.flag(off, "dry_run")):to_equal(false)

      local args, err = cli.parse({ "--dry-run=yesplease" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("--dry-run")
      t.expect(err):to_contain("true or false")
   end)

   t.it("refuses an option nobody declared, by name", function()
      local args, err = cli.parse({ "--scenarion", "arith" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("unknown option --scenarion")
   end)

   t.it("refuses a key with nothing after it", function()
      local args, err = cli.parse({ "--pkg" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("--pkg expects a value")
   end)

   -- An argument past the last declared positional is a mistake rather than something
   -- quietly kept: `cardbox get a b` meant one of the two and would have got `a`.
   t.it("refuses an argument the spec has no positional for", function()
      local args, err = cli.parse({ "a", "b", "c", "d" }, OPEN)
      t.expect(args):to_be_nil()
      t.expect(err):to_contain("unexpected argument")
   end)

   t.it("reads a whole number, and refuses one that is not", function()
      local args = cli.parse({ "--limit", "12" }, OPEN)
      t.expect(cli.integer(args, "limit")):to_equal(12)

      -- the refusal is the parse's now, not a second reading of a value already taken
      local other, err = cli.parse({ "--limit", "1.5" }, OPEN)
      t.expect(other):to_be_nil()
      t.expect(err):to_contain("--limit")
      t.expect(err):to_contain("integer")
   end)

   -- The message is the library's, with its own name taken off the front: whoever mistyped
   -- an option is not told which parser read it.
   t.it("names no library in what it refuses with", function()
      local _, err = cli.parse({ "--scenarion", "arith" }, OPEN)
      t.expect(err):to_not_contain("argparse")
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
