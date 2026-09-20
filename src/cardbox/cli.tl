-- The command line, as policy. Parsing what a person typed, choosing which `cards.*` call
-- they meant, and turning the answer into JSON.
--
-- The whole of it is a thin client: every command below is one call into `cardbox.cards`
-- and nothing else. There is no path through this module that reaches the store directly
-- for anything a card is made of, and no check, default or refusal here that a caller
-- going through `cards.*` from Lua would not also get. That is the point of the shape — a
-- later HTTP or MCP adapter is another client of the same API rather than a second
-- implementation of it — and it is why the interesting parts of this file are the specs and
-- the `--where` parser rather than the dispatch.
--
-- What a `--key value` line comes to is `std.argparse`'s. Each command declares what it
-- accepts — the options by name and shape, the positionals in order — and the host does the
-- walking, the collecting and the refusing. What it has no opinion about is the inside of a
-- `--where` argument, which is a small value syntax rather than an option, so that parser
-- stays here (`cli.parse_where`). It is separated out for the reason `find.build_find` is:
-- it decides the whole of what it decides from its argument and asks nothing of a store, so
-- `htl test` pins it with no host in the room.
--
-- `cli.run` answers `text, err`, like everything else in this project. `src/main.tl` prints
-- the text and turns the refusal into an exit status; nothing here writes to a stream or
-- exits, so the dispatch is testable too (`src/tests/cli.rs`).

local type store = require("store")
local cards = require("cardbox.cards")
local cardbox = require("cardbox")
local type reads = require("cardbox.find")
local list = require("htlx.list")
local argparse = require("std.argparse")
-- `trim` was written here twice over, once for the argument parser and once for the
-- JSON-ish value reader below it, and the reader spelled its prefix and suffix tests as
-- `sub` comparisons. All three are `std.string`'s now: the same patterns, in the host
-- rather than in this file.
local str = require("std.string")

local record cli
end

-- The four shapes an option comes in, named once so that a spec reads as a table of what a
-- command accepts rather than of type strings. `std.argparse` reads `--created-by` and
-- `--created_by` as the same option `created_by`, which is why every name below is spelled
-- with underscores and every name in the usage text with dashes.
local TEXT: argparse.Flag = { type = "string" }
local TEXTS: argparse.Flag = { type = "string", multiple = true }
local WHOLE: argparse.Flag = { type = "integer" }
local FLAG: argparse.Flag = { type = "boolean" }

-- Every command takes `--json`. Output is JSON whether or not it is given — a command's
-- answer is a value, and a shell reading one should not have to ask twice — so this is
-- accepted and means nothing. It is here because a person who types it expects it to work,
-- and because leaving it out would make `--json` an unknown option.
local JSON_FLAG = "json"

local function spec(
   name: string,
   flags: {string:argparse.Flag},
   positionals?: {argparse.Positional}
): argparse.Spec
   flags[JSON_FLAG] = FLAG
   return { name = "cardbox " .. name, flags = flags, positionals = positionals }
end

-- What `std.argparse` puts in front of everything it raises. Taken off again before the
-- message reaches a person: which library read the command line is not something whoever
-- mistyped an option has to know, and `src/main.rs` prints the rest of the sentence after
-- `cardbox: `.
local ARGPARSE = "argparse: "

--- Split a command line into options, their values and positionals, against `s`.
---
--- `--key=value` is the same as `--key value`, `--some-name` and `--some_name` address the
--- same option, and an option declared `multiple` collects its repeats — which is what
--- `--parent`, `--where`, `--id` and `--state` are for. An option the spec does not name is
--- refused by name rather than kept for nobody to read: a typed `--scenarion` that went
--- through as a positional would open a card with the wrong shape and no complaint.
---
--- `std.argparse` raises where this project answers, so the refusal is caught here and
--- handed back as `nil, err` like every other one in this file.
function cli.parse(argv: {string}, s: argparse.Spec): argparse.Result, string
   local ok, answer = pcall(argparse.parse, argv, s)
   if not ok then
      local message = tostring(answer)
      if str.starts_with(message, ARGPARSE) then
         message = message:sub(#ARGPARSE + 1)
      end
      return nil, message
   end
   return answer as argparse.Result
end

--- The last value given for `key`, or nil when it was never given.
---
--- "Last" is what an option declared `multiple` and given twice needs from a caller that
--- wanted one: `--parent a --parent b` is two parents to `cli.list` and `b` to this.
function cli.value(args: argparse.Result, key: string): string
   local v = args.opts[key]
   if v == nil then
      return nil
   end
   if type(v) == "table" then
      local values = v as {string}
      if #values == 0 then
         return nil
      end
      return values[#values]
   end
   return v as string
end

--- Every value given for `key`, in order, or nil when it was never given.
---
--- Nil rather than the empty list `std.argparse` answers an absent `multiple` option with,
--- because "not given" and "given nothing" are different specs downstream: `prune` reads
--- `ids = nil` as "not bounded by ids" and `ids = {}` as a mistake.
function cli.list(args: argparse.Result, key: string): {string}
   local values = args.opts[key] as {string}
   if values == nil or #values == 0 then
      return nil
   end
   return values
end

--- The value given for `key` as a whole number, or nil when it was not given.
---
--- One that is not a whole number never reaches here: the option is declared `integer` and
--- `cli.parse` is where it is refused, by name and with what was typed.
function cli.integer(args: argparse.Result, key: string): integer
   return args.opts[key] as integer
end

--- Whether the flag `key` was given. `--flag` is true and `--no-flag` is false.
function cli.flag(args: argparse.Result, key: string): boolean
   return args.opts[key] == true
end

--- The positional argument named `name`, or nil when it was not given. One the spec
--- declared `required` never reaches here missing: `cli.parse` refuses that by name.
function cli.arg(args: argparse.Result, name: string): string
   return args.args[name] as string
end

-- ------------------------------------------------------------------ --where

-- A quoted value, with its quotes off and its escapes resolved. A backslash makes the next
-- character itself, which is enough to write a value holding a quote and is not a second
-- string syntax.
local function unquote(text: string): string, string
   local parts: {string} = {}
   local i = 2
   local last = #text - 1
   while i <= last do
      local c = text:sub(i, i)
      if c == "\\" then
         local nxt = text:sub(i + 1, i + 1)
         if nxt == "" then
            return nil, "a quoted value ends in a backslash: " .. text
         end
         parts[#parts + 1] = nxt
         i = i + 2
      elseif c == '"' then
         return nil, 'a quoted value holds an unescaped " : ' .. text
      else
         parts[#parts + 1] = c
         i = i + 1
      end
   end
   return table.concat(parts)
end

-- One value as typed. A number is a number, `true` and `false` are booleans, a
-- double-quoted run is the text inside it, and everything else is the text itself — so
-- `pkg = cot` needs no quotes and `pkg = "my pkg"` is how a value with a space is written.
--
-- Deliberately not a JSON parser. The values a clause compares against are scalars: the
-- whitelist of columns they compare against holds numbers and text and nothing else, and a
-- parser that took objects would accept shapes no column can hold. Answers `value, err`,
-- and `false` is a value, so a caller checks `err` rather than the value.
local function scalar(text: string): any, string
   local s = str.trim(text)
   if s == "" then
      return nil, "a clause needs a value after the operator"
   end
   if s == "true" then
      return true
   end
   if s == "false" then
      return false
   end
   local n = tonumber(s)
   if n ~= nil then
      return n
   end
   if str.starts_with(s, '"') then
      if #s < 2 or not str.ends_with(s, '"') then
         return nil, "a quoted value is not closed: " .. s
      end
      return unquote(s)
   end
   return s
end

-- `[a, b, c]` as a list of scalars. A comma inside quotes does not separate, which is the
-- whole reason this is a scan rather than a `gmatch` — and the reason it is not
-- `std.string.split` either, which would cut this one in the wrong place.
local function array(text: string): {any}, string
   local s = str.trim(text)
   if not str.ends_with(s, "]") then
      return nil, "an array value is not closed: " .. s
   end
   local body = str.trim(s:sub(2, #s - 1))
   if body == "" then
      return nil, 'in takes a non-empty array of values, got "[]"'
   end

   local out: {any} = {}
   local start = 1
   local quoted = false
   local i = 1
   while i <= #body do
      local c = body:sub(i, i)
      if quoted and c == "\\" then
         i = i + 1
      elseif c == '"' then
         quoted = not quoted
      elseif c == "," and not quoted then
         local value, err = scalar(body:sub(start, i - 1))
         if err ~= nil then
            return nil, err
         end
         out[#out + 1] = value
         start = i + 1
      end
      i = i + 1
   end
   if quoted then
      return nil, "a quoted value is not closed: " .. s
   end
   local value, err = scalar(body:sub(start))
   if err ~= nil then
      return nil, err
   end
   out[#out + 1] = value
   return out
end

--- One `--where` argument as a clause: `column op value`, the three separated by spaces.
---
--- `mean_score > 0.5` is a number, `pkg = cot` is text, `state in ["closed_ok","open"]` is
--- a list. Which columns and which operators exist is not decided here — `find.build_find`
--- holds both whitelists and names them in its refusal, and a second copy of either in the
--- CLI would be a second thing to keep current. What this decides is only how the three
--- parts are told apart and what the typed value is.
function cli.parse_where(text: string): reads.Clause, string
   if type(text) ~= "string" then
      return nil, "--where takes a clause as text, got a " .. type(text)
   end
   local column, op, rest = text:match("^%s*([^%s]+)%s+([^%s]+)%s+(.+)$")
   if column == nil then
      return nil, '--where takes "column op value", got ' .. string.format("%q", text)
   end

   local raw = str.trim(rest as string)
   local value: any
   local err: string
   if str.starts_with(raw, "[") then
      value, err = array(raw)
   else
      value, err = scalar(raw)
   end
   if err ~= nil then
      return nil, err
   end
   return { column = column as string, op = op as string, value = value }
end

-- ------------------------------------------------------------------ files

-- The two ways bytes get in. `io` is used here and nowhere else in this project: reading
-- what a person named on the command line is the CLI's own job, and a host method for it
-- would be a mechanism every other module could reach for. It stays `io` rather than
-- becoming `std.fs` because this htl does not carry that module — `htl resolve std.fs`
-- answers with nothing on the search path.
-- Always binary. A checkpoint has to be read that way — it is somebody else's format and
-- a byte is a byte — and a JSONL file read the same way is the same bytes, so there is one
-- reader here rather than two that differ on a platform this does not run on.
local function read_file(path: string): string, string
   local f, oerr = io.open(path, "rb")
   if f == nil then
      return nil, "cannot read " .. path .. ": " .. tostring(oerr)
   end
   local text = f:read("a") as string
   f:close()
   if text == nil then
      return nil, "cannot read " .. path
   end
   return text
end

local function read_stdin(): string, string
   local text = io.read("a") as string
   if text == nil then
      return nil, "nothing on stdin"
   end
   return text
end

-- ------------------------------------------------------------------ commands

local type Handler = function(s: store, argv: {string}): string, string

local function encode(s: store, v: any): string, string
   return s:json_encode(v)
end

local OPEN = spec("open", {
   pkg = TEXT,
   scenario = TEXT,
   source = TEXT,
   created_by = TEXT,
   parent = TEXTS,
   note = TEXT,
   id = TEXT,
   params = TEXT,
   model = TEXT,
   trace_id = TEXT,
   work_url = TEXT,
})

local function cmd_open(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, OPEN)
   if args == nil then
      return nil, perr
   end
   -- Who wrote the card, when the caller does not say: this CLI, at the version that is
   -- running. A card's `created_by` is what a reader a year later has to tell two runs of
   -- the same scenario apart, so it is required by `cards.open` and defaulted here.
   local created_by = cli.value(args, "created_by")
   if created_by == nil then
      created_by = "cardbox " .. cardbox.version()
   end
   local params: any
   local text = cli.value(args, "params")
   if text ~= nil then
      local v, jerr = s:json_decode(text)
      if jerr ~= nil then
         return nil, "--params is not JSON: " .. jerr
      end
      params = v
   end
   local card, err = cards.open(s, {
      pkg = cli.value(args, "pkg"),
      scenario = cli.value(args, "scenario"),
      source = cli.value(args, "source"),
      created_by = created_by,
      parents = cli.list(args, "parent"),
      note = cli.value(args, "note"),
      id = cli.value(args, "id"),
      params = params,
      model = cli.value(args, "model"),
      trace_id = cli.value(args, "trace_id"),
      work_url = cli.value(args, "work_url"),
   })
   if card == nil then
      return nil, err
   end
   return encode(s, card)
end

local SAMPLES = spec("samples", { file = TEXT }, { { name = "id", required = true } })

local function cmd_samples(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, SAMPLES)
   if args == nil then
      return nil, perr
   end
   local id = cli.arg(args, "id")

   local text: string
   local rerr: string
   local file = cli.value(args, "file")
   if file ~= nil then
      text, rerr = read_file(file)
   else
      text, rerr = read_stdin()
   end
   if text == nil then
      return nil, rerr
   end

   -- One JSON object per line, which is the shape a run writing samples as it produces
   -- them can append to. Blank lines are skipped; a line that is not JSON is named by its
   -- number, because a file of three hundred rows with one bad one is otherwise a hunt.
   -- `std.string.split` is the cut, so the index a refusal names is the line it is on.
   local rows: {any} = {}
   local lines = str.split(text, "\n")
   for i = 1, #lines do
      local row = str.trim(lines[i])
      if row ~= "" then
         local value, jerr = s:json_decode(row)
         if jerr ~= nil then
            return nil, "line " .. tostring(i) .. " is not JSON: " .. jerr
         end
         rows[#rows + 1] = value
      end
   end
   if #rows == 0 then
      return nil, "no sample rows: one JSON object per line, on stdin or in --file"
   end

   local appended, err = cards.append_samples(s, id, rows)
   if appended == nil then
      return nil, err
   end
   return encode(s, appended)
end

local EVAL = spec("eval", { file = TEXT, source = TEXT }, { { name = "id", required = true } })

local function cmd_eval(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, EVAL)
   if args == nil then
      return nil, perr
   end
   local id = cli.arg(args, "id")
   local file = cli.value(args, "file")
   if file == nil then
      return nil, "eval needs --file: the eval result as one JSON object"
   end
   local text, rerr = read_file(file)
   if text == nil then
      return nil, rerr
   end
   local eval, jerr = s:json_decode(text)
   if jerr ~= nil then
      return nil, file .. " is not JSON: " .. jerr
   end

   local rec, err = cards.record_eval(s, id, eval, cli.value(args, "source"))
   if rec == nil then
      return nil, err
   end
   local meta = rec.meta as {string:any}
   return encode(s, {
      id = id,
      seq = rec.seq,
      kind = rec.kind,
      source = meta.source,
      epoch_ms = rec.epoch_ms,
   })
end

local TAG_SET = spec(
   "tag set",
   {},
   { { name = "id", required = true }, { name = "key", required = true }, { name = "value", required = true } }
)
local TAG_UNSET = spec("tag unset", {}, { { name = "id", required = true }, { name = "key", required = true } })

-- `tag` has a word after it the way `alias` does: two things are done to a label and they
-- take different arguments. Both answer `changed`, which is false when the store had
-- nothing to write — the value was already there, or the key already was not.
local function cmd_tag(s: store, argv: {string}): string, string
   local what = argv[1]
   local rest = list.drop(argv, 1)

   if what == "set" then
      local args, perr = cli.parse(rest, TAG_SET)
      if args == nil then
         return nil, perr
      end
      local id = cli.arg(args, "id")
      local key = cli.arg(args, "key")
      local value = cli.arg(args, "value")
      local rec, err = cards.tag(s, id, key, value)
      if err ~= nil then
         return nil, err
      end
      return encode(s, { id = id, key = key, value = value, changed = rec ~= nil })
   elseif what == "unset" then
      local args, perr = cli.parse(rest, TAG_UNSET)
      if args == nil then
         return nil, perr
      end
      local id = cli.arg(args, "id")
      local key = cli.arg(args, "key")
      local rec, err = cards.untag(s, id, key)
      if err ~= nil then
         return nil, err
      end
      return encode(s, { id = id, key = key, changed = rec ~= nil })
   end

   return nil, "tag takes set or unset, got " .. string.format("%q", tostring(what))
end

local CHECKPOINT = spec(
   "checkpoint",
   { file = TEXT, format = TEXT, note = TEXT },
   { { name = "id", required = true } }
)

local function cmd_checkpoint(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, CHECKPOINT)
   if args == nil then
      return nil, perr
   end
   local id = cli.arg(args, "id")
   local file = cli.value(args, "file")
   if file == nil then
      return nil, "checkpoint needs --file: the checkpoint to save"
   end
   local bytes, rerr = read_file(file)
   if bytes == nil then
      return nil, rerr
   end

   local rec, err = cards.save_checkpoint(s, id, bytes, {
      format = cli.value(args, "format"),
      note = cli.value(args, "note"),
   })
   if rec == nil then
      return nil, err
   end
   local data = rec.data as {string:any}
   return encode(s, {
      id = id,
      seq = rec.seq,
      blob = data.blob,
      size = data.size,
      format = data.format,
   })
end

local CLOSE = spec(
   "close",
   { error = TEXT, stats = TEXT, cost = TEXT, ok = FLAG, failed = FLAG },
   { { name = "id", required = true } }
)

local function cmd_close(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, CLOSE)
   if args == nil then
      return nil, perr
   end
   local id = cli.arg(args, "id")
   if cli.flag(args, "ok") and cli.flag(args, "failed") then
      return nil, "close takes --ok or --failed, not both"
   end

   -- `--ok` is the default, and `cards.close` is what refuses the two ways this can
   -- disagree with itself: an ok close carrying an error, and a failed one without one.
   local outcome: cards.Outcome = { ok = not cli.flag(args, "failed") }
   outcome.error = cli.value(args, "error")

   local stats = cli.value(args, "stats")
   if stats ~= nil then
      local v, jerr = s:json_decode(stats)
      if jerr ~= nil then
         return nil, "--stats is not JSON: " .. jerr
      end
      outcome.stats = v
   end
   local cost = cli.value(args, "cost")
   if cost ~= nil then
      local v, jerr = s:json_decode(cost)
      if jerr ~= nil then
         return nil, "--cost is not JSON: " .. jerr
      end
      outcome.cost = v
   end

   local rec, err = cards.close(s, id, outcome)
   if rec == nil then
      return nil, err
   end
   local state = "closed_failed"
   if outcome.ok then
      state = "closed_ok"
   end
   return encode(s, { id = id, state = state, seq = rec.seq, epoch_ms = rec.epoch_ms })
end

local GET = spec("get", {}, { { name = "id", required = true } })

local function cmd_get(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, GET)
   if args == nil then
      return nil, perr
   end
   local view, err = cards.get(s, cli.arg(args, "id"))
   if view == nil then
      return nil, err
   end
   return encode(s, view)
end

local LIST = spec("list", { pkg = TEXT, state = TEXT, limit = WHOLE, offset = WHOLE })

local function cmd_list(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, LIST)
   if args == nil then
      return nil, perr
   end
   local rows, err = cards.list(s, {
      pkg = cli.value(args, "pkg"),
      state = cli.value(args, "state"),
      limit = cli.integer(args, "limit"),
      offset = cli.integer(args, "offset"),
   })
   if rows == nil then
      return nil, err
   end
   return encode(s, rows)
end

local FIND = spec("find", {
   where = TEXTS,
   order_by = TEXT,
   limit = WHOLE,
   offset = WHOLE,
   asc = FLAG,
})

local function cmd_find(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, FIND)
   if args == nil then
      return nil, perr
   end
   local where = cli.list(args, "where")
   local clauses: {reads.Clause} = {}
   if where ~= nil then
      for i = 1, #where do
         local clause, cerr = cli.parse_where(where[i])
         if clause == nil then
            return nil, cerr
         end
         clauses[i] = clause
      end
   end

   local rows, err = cards.find(s, {
      clauses = clauses,
      order_by = cli.value(args, "order_by"),
      desc = not cli.flag(args, "asc"),
      limit = cli.integer(args, "limit"),
      offset = cli.integer(args, "offset"),
   })
   if rows == nil then
      return nil, err
   end
   return encode(s, rows)
end

local LINEAGE = spec("lineage", { depth = WHOLE }, { { name = "id", required = true } })

local function cmd_lineage(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, LINEAGE)
   if args == nil then
      return nil, perr
   end
   local id = cli.arg(args, "id")
   local tree, err = cards.lineage(s, id, { depth = cli.integer(args, "depth") })
   if tree == nil then
      return nil, err
   end
   return encode(s, tree)
end

local ALIAS_SET = spec(
   "alias set",
   { note = TEXT },
   { { name = "name", required = true }, { name = "id", required = true } }
)
local ALIAS_RELEASE = spec("alias release", { note = TEXT }, { { name = "name", required = true } })
local ALIAS_GET = spec("alias get", {}, { { name = "name", required = true } })
local ALIAS_LIST = spec("alias list", { pkg = TEXT, card = TEXT })
local ALIAS_HISTORY = spec("alias history", {}, { { name = "name", required = true } })

-- `alias` is the one command with a word of its own after it. The five things that can be
-- done to a name are one subject, and five top-level commands would not say so. The word is
-- taken off here rather than declared as a positional, because each of the five accepts
-- something different after it and a spec that covered all five would refuse none of them.
local function cmd_alias(s: store, argv: {string}): string, string
   local what = argv[1]
   local rest = list.drop(argv, 1)

   if what == "set" then
      local args, perr = cli.parse(rest, ALIAS_SET)
      if args == nil then
         return nil, perr
      end
      local name = cli.arg(args, "name")
      local id = cli.arg(args, "id")
      local rec, err = cards.alias(s, name, id, cli.value(args, "note"))
      if err ~= nil then
         return nil, err
      end
      -- `nil, nil` is the store declining because the name already means this card. That
      -- is not a failure and not a write, and `changed` is which of the two happened.
      return encode(s, { alias = name, card_id = id, changed = rec ~= nil })
   elseif what == "release" then
      local args, perr = cli.parse(rest, ALIAS_RELEASE)
      if args == nil then
         return nil, perr
      end
      local name = cli.arg(args, "name")
      local rec, err = cards.alias_release(s, name, cli.value(args, "note"))
      if err ~= nil then
         return nil, err
      end
      return encode(s, { alias = name, released = rec ~= nil })
   elseif what == "get" then
      local args, perr = cli.parse(rest, ALIAS_GET)
      if args == nil then
         return nil, perr
      end
      local view, err = cards.get_by_alias(s, cli.arg(args, "name"))
      if view == nil then
         return nil, err
      end
      return encode(s, view)
   elseif what == "list" then
      local args, perr = cli.parse(rest, ALIAS_LIST)
      if args == nil then
         return nil, perr
      end
      local entries, err = cards.alias_list(s, {
         pkg = cli.value(args, "pkg"),
         card_id = cli.value(args, "card"),
      })
      if entries == nil then
         return nil, err
      end
      return encode(s, entries)
   elseif what == "history" then
      local args, perr = cli.parse(rest, ALIAS_HISTORY)
      if args == nil then
         return nil, perr
      end
      local events, err = cards.alias_history(s, cli.arg(args, "name"))
      if events == nil then
         return nil, err
      end
      return encode(s, events)
   end

   return nil, "alias takes set, release, get, list or history, got "
      .. string.format("%q", tostring(what))
end

local PROMOTE = spec("promote", {
   alias = TEXT,
   pkg = TEXT,
   scenario = TEXT,
   metric = TEXT,
   min_n = WHOLE,
   note = TEXT,
})

local function cmd_promote(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, PROMOTE)
   if args == nil then
      return nil, perr
   end
   local done, err = cards.promote(s, {
      alias = cli.value(args, "alias"),
      pkg = cli.value(args, "pkg"),
      scenario = cli.value(args, "scenario"),
      metric = cli.value(args, "metric"),
      min_n = cli.integer(args, "min_n"),
      note = cli.value(args, "note"),
   })
   if done == nil then
      return nil, err
   end
   return encode(s, done)
end

local PRUNE = spec("prune", {
   reason = TEXT,
   pkg = TEXT,
   pkg_like = TEXT,
   older_than_ms = WHOLE,
   id = TEXTS,
   state = TEXTS,
   dry_run = FLAG,
})

local function cmd_prune(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, PRUNE)
   if args == nil then
      return nil, perr
   end
   -- `--pkg-like` is a LIKE pattern and reaches `cards.prune` as one: `%` and `_` in it
   -- are wildcards, and the query carries `ESCAPE '\'`, so the pkg prefix `_test_` is
   -- written `--pkg-like '\_test\_%'`.
   local report, err = cards.prune(s, {
      reason = cli.value(args, "reason"),
      pkg = cli.value(args, "pkg"),
      pkg_like = cli.value(args, "pkg_like"),
      older_than_ms = cli.integer(args, "older_than_ms"),
      ids = cli.list(args, "id"),
      states = cli.list(args, "state"),
      dry_run = cli.flag(args, "dry_run"),
   })
   if report == nil then
      return nil, err
   end
   return encode(s, report)
end

local PRUNE_LOG = spec("prune-log", { limit = WHOLE })

local function cmd_prune_log(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, PRUNE_LOG)
   if args == nil then
      return nil, perr
   end
   local entries, err = cards.prune_log(s, { limit = cli.integer(args, "limit") })
   if entries == nil then
      return nil, err
   end
   return encode(s, entries)
end

local EXPORT = spec("export", {})

local function cmd_export(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, EXPORT)
   if args == nil then
      return nil, perr
   end
   local report, err = cards.export(s)
   if report == nil then
      return nil, err
   end
   return encode(s, report)
end

local IMPORT = spec("import", {}, { { name = "file", required = true } })

local function cmd_import(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, IMPORT)
   if args == nil then
      return nil, perr
   end
   local report, err = cards.import(s, cli.arg(args, "file"))
   if report == nil then
      return nil, err
   end
   return encode(s, report)
end

local function cmd_version(s: store, _argv: {string}): string, string
   return encode(s, { cardbox = cardbox.version() })
end

local function cmd_root(s: store, _argv: {string}): string, string
   return encode(s, { root = s:root() })
end

local function cmd_catch_up(s: store, _argv: {string}): string, string
   local events, err = s:catch_up()
   if events == nil then
      return nil, err
   end
   return encode(s, { events = events })
end

local function cmd_rebuild(s: store, _argv: {string}): string, string
   local events, err = s:rebuild()
   if events == nil then
      return nil, err
   end
   return encode(s, { events = events })
end

-- ------------------------------------------------------------------ usage

local USAGE = table.concat({
   "cardbox <command> [args] [--key value ...] [--json]",
   "",
   "A card's life:",
   "  open        --pkg P --scenario S --source SRC [--created-by X] [--parent ID ...]",
   "              [--note N] [--id ID] [--params JSON] [--model M] [--trace-id T]",
   "              [--work-url file:///abs/dir | https://...]",
   "  samples     <id> [--file rows.jsonl]    one JSON object per line; stdin without --file",
   "  eval        <id> --file eval.json [--source code|llm_judge|human]",
   "  checkpoint  <id> --file weights.bin --format safetensors [--note N]",
   "  close       <id> [--ok | --failed --error MSG] [--stats JSON] [--cost JSON]",
   "",
   "Said about a card, open or closed:",
   "  tag set <id> <key> <value>              tag unset <id> <key>",
   "  eval        (as above; an eval is the other thing a closed card takes)",
   "",
   "Reading:",
   "  get         <id>",
   "  list        [--pkg P] [--state S] [--limit N] [--offset N]",
   "  find        --where 'col op value' [--where ...] [--order-by col] [--asc]",
   "              [--limit N] [--offset N]",
   "              col is a column, or params.<path>, stats.<path>, tags.<key>",
   "  lineage     <id> [--depth N]",
   "",
   "Names:",
   "  alias set <name> <id> [--note N]        alias release <name> [--note N]",
   "  alias get <name>                        alias history <name>",
   "  alias list [--pkg P] [--card ID]",
   "  promote     --alias A --pkg P [--scenario S] [--metric M] [--min-n N] [--note N]",
   "",
   "Removing, and the backup it leans on:",
   "  prune       --reason R (--pkg P | --pkg-like PAT | --older-than-ms N | --id ID ...)",
   "              [--state S ...] [--dry-run]",
   "  prune-log   [--limit N]",
   "  export                                  import <file>",
   "",
   "The store:",
   "  version     root     catch-up     rebuild     help",
   "",
   "Output is JSON on stdout; a refusal is `cardbox: <message>` on stderr and exit 1.",
   "The store is CARDBOX_ROOT, else $HOME/.cardbox.",
}, "\n")

--- The usage text, which is what `help`, `--help` and no arguments at all answer with.
---
--- Written out rather than assembled from the specs above: `std.argparse.usage` describes
--- one command at a time, and what a person typing `cardbox` with no arguments wants is the
--- shape of all twenty at once, grouped by what they are for.
function cli.usage(): string
   return USAGE
end

local HANDLERS: {string:Handler} = {
   open = cmd_open,
   samples = cmd_samples,
   eval = cmd_eval,
   checkpoint = cmd_checkpoint,
   close = cmd_close,
   tag = cmd_tag,
   get = cmd_get,
   list = cmd_list,
   find = cmd_find,
   lineage = cmd_lineage,
   alias = cmd_alias,
   promote = cmd_promote,
   prune = cmd_prune,
   ["prune-log"] = cmd_prune_log,
   export = cmd_export,
   import = cmd_import,
   version = cmd_version,
   root = cmd_root,
   ["catch-up"] = cmd_catch_up,
   rebuild = cmd_rebuild,
}

--- Run one command line and answer with what belongs on stdout.
---
--- `text, nil` is the answer — JSON for every command that has data, the usage text for
--- `help`. `nil, err` is a refusal, either this module's (a mistyped option, a missing
--- argument) or the API's, passed through word for word: `cards.*` already says what is
--- wrong in a sentence meant for a person, and rewording it here would make two places
--- that have to agree about what a card is.
function cli.run(s: store, argv: {string}): string, string
   local command = argv[1]
   if command == nil or command == "help" or command == "--help" or command == "-h" then
      return cli.usage()
   end

   local handler = HANDLERS[command]
   if handler == nil then
      return nil, "no such command: " .. string.format("%q", command) .. ". Try `cardbox help`"
   end

   return handler(s, list.drop(argv, 1))
end

return cli
