-- The command line, as policy. Parsing what a person typed, choosing which `cards.*` call
-- they meant, and turning the answer into JSON.
--
-- The whole of it is a thin client: every command below is one call into `cardbox.cards`
-- and nothing else. There is no path through this module that reaches the store directly
-- for anything a card is made of, and no check, default or refusal here that a caller
-- going through `cards.*` from Lua would not also get. That is the point of the shape — a
-- later HTTP or MCP adapter is another client of the same API rather than a second
-- implementation of it — and it is why the interesting parts of this file are the two
-- parsers rather than the dispatch.
--
-- The parsers are separated out (`cli.parse`, `cli.parse_where`) for the same reason
-- `find.build_find` is: they decide the whole of what they decide from their arguments and
-- ask nothing of a store, so `htl test` pins them with no host in the room.
--
-- `cli.run` answers `text, err`, like everything else in this project. `src/main.tl` prints
-- the text and turns the refusal into an exit status; nothing here writes to a stream or
-- exits, so the dispatch is testable too (`src/tests/cli.rs`).

local type store = require("store")
local cards = require("cardbox.cards")
local cardbox = require("cardbox")
local type reads = require("cardbox.find")

local record cli
   -- What one command line came to. `positional` in the order it was given, `values` the
   -- `--key value` pairs collected per key (a key given twice has two entries, which is
   -- what `--parent` and `--where` are for), `flags` the ones that take no value.
   record Args
      positional: {string}
      values: {string:{string}}
      flags: {string:boolean}
   end

   -- What one command accepts. Both are sets rather than lists so that the parser can say
   -- "no such option" without searching, and an option that is in neither is a mistake
   -- rather than something quietly kept.
   record Spec
      keys: {string:boolean}
      flags: {string:boolean}
   end
end

-- Every command takes `--json`. Output is JSON whether or not it is given — a command's
-- answer is a value, and a shell reading one should not have to ask twice — so this is
-- accepted and means nothing. It is here because a person who types it expects it to work,
-- and because leaving it out would make `--json` a spelling mistake.
local JSON_FLAG = "json"

local function set(names: {string}): {string:boolean}
   local out: {string:boolean} = {}
   for i = 1, #names do
      out[names[i]] = true
   end
   return out
end

local function spec(keys: {string}, flags: {string}): cli.Spec
   local f = set(flags)
   f[JSON_FLAG] = true
   return { keys = set(keys), flags = f }
end

local function trim(s: string): string
   local out = s:gsub("^%s+", "")
   out = out:gsub("%s+$", "")
   return out
end

--- Split a command line into positionals, `--key value` pairs and flags.
---
--- `--key=value` is the same as `--key value`. A key the spec does not name is refused by
--- name rather than kept for nobody to read: a typed `--scenarion` that went through as a
--- positional would open a card with the wrong shape and no complaint.
---
--- Repeats collect. `--parent a --parent b` is two parents and not the second one, which is
--- also what makes `--where`, `--id` and `--state` work.
function cli.parse(argv: {string}, s: cli.Spec): cli.Args, string
   local args: cli.Args = { positional = {}, values = {}, flags = {} }
   local keys = s.keys
   local flags = s.flags

   local i = 1
   while i <= #argv do
      local a = argv[i]
      if a:sub(1, 2) == "--" and #a > 2 then
         local key = a:sub(3)
         local inline: string
         local eq = key:find("=", 1, true)
         if eq ~= nil then
            inline = key:sub(eq + 1)
            key = key:sub(1, eq - 1)
         end

         if flags[key] then
            if inline ~= nil then
               return nil, "--" .. key .. " is a flag and takes no value"
            end
            args.flags[key] = true
         elseif keys[key] then
            local value = inline
            if value == nil then
               i = i + 1
               value = argv[i]
               if value == nil then
                  return nil, "--" .. key .. " needs a value"
               end
            end
            local list = args.values[key]
            if list == nil then
               list = {}
               args.values[key] = list
            end
            list[#list + 1] = value
         else
            return nil, "no such option: --" .. key
         end
      else
         args.positional[#args.positional + 1] = a
      end
      i = i + 1
   end
   return args
end

--- The last value given for `key`, or nil.
function cli.value(args: cli.Args, key: string): string
   local list = args.values[key]
   if list == nil or #list == 0 then
      return nil
   end
   return list[#list]
end

--- Every value given for `key`, in order, or nil when it was never given. Nil rather than
--- an empty list because "not given" and "given nothing" are different specs downstream:
--- `prune` reads `ids = nil` as "not bounded by ids" and `ids = {}` as a mistake.
function cli.list(args: cli.Args, key: string): {string}
   return args.values[key]
end

--- The value given for `key` as a whole number, or nil when it was not given.
function cli.integer(args: cli.Args, key: string): integer, string
   local raw = cli.value(args, key)
   if raw == nil then
      return nil
   end
   local n = tonumber(raw)
   if n == nil or n ~= math.floor(n) then
      return nil, "--" .. key .. " takes a whole number, got " .. string.format("%q", raw)
   end
   return math.floor(n)
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
   local s = trim(text)
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
   if s:sub(1, 1) == '"' then
      if #s < 2 or s:sub(#s) ~= '"' then
         return nil, "a quoted value is not closed: " .. s
      end
      return unquote(s)
   end
   return s
end

-- `[a, b, c]` as a list of scalars. A comma inside quotes does not separate, which is the
-- whole reason this is a scan rather than a `gmatch`.
local function array(text: string): {any}, string
   local s = trim(text)
   if s:sub(#s) ~= "]" then
      return nil, "an array value is not closed: " .. s
   end
   local body = trim(s:sub(2, #s - 1))
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

   local raw = trim(rest as string)
   local value: any
   local err: string
   if raw:sub(1, 1) == "[" then
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
-- would be a mechanism every other module could reach for.
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

local function need(args: cli.Args, at: integer, what: string): string, string
   local v = args.positional[at]
   if v == nil or v == "" then
      return nil, "this command needs " .. what
   end
   return v
end

local OPEN = spec({ "pkg", "scenario", "source", "created-by", "parent", "note", "id" }, {})

local function cmd_open(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, OPEN)
   if args == nil then
      return nil, perr
   end
   -- Who wrote the card, when the caller does not say: this CLI, at the version that is
   -- running. A card's `created_by` is what a reader a year later has to tell two runs of
   -- the same scenario apart, so it is required by `cards.open` and defaulted here.
   local created_by = cli.value(args, "created-by")
   if created_by == nil then
      created_by = "cardbox " .. cardbox.version()
   end
   local card, err = cards.open(s, {
      pkg = cli.value(args, "pkg"),
      scenario = cli.value(args, "scenario"),
      source = cli.value(args, "source"),
      created_by = created_by,
      parents = cli.list(args, "parent"),
      note = cli.value(args, "note"),
      id = cli.value(args, "id"),
   })
   if card == nil then
      return nil, err
   end
   return encode(s, card)
end

local SAMPLES = spec({ "file" }, {})

local function cmd_samples(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, SAMPLES)
   if args == nil then
      return nil, perr
   end
   local id, ierr = need(args, 1, "a card id")
   if id == nil then
      return nil, ierr
   end

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
   local rows: {any} = {}
   local n = 0
   for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      n = n + 1
      local row = trim(line)
      if row ~= "" then
         local value, jerr = s:json_decode(row)
         if jerr ~= nil then
            return nil, "line " .. tostring(n) .. " is not JSON: " .. jerr
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

local EVAL = spec({ "file" }, {})

local function cmd_eval(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, EVAL)
   if args == nil then
      return nil, perr
   end
   local id, ierr = need(args, 1, "a card id")
   if id == nil then
      return nil, ierr
   end
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

   local rec, err = cards.record_eval(s, id, eval)
   if rec == nil then
      return nil, err
   end
   return encode(s, { id = id, seq = rec.seq, kind = rec.kind, epoch_ms = rec.epoch_ms })
end

local CHECKPOINT = spec({ "file", "format", "note" }, {})

local function cmd_checkpoint(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, CHECKPOINT)
   if args == nil then
      return nil, perr
   end
   local id, ierr = need(args, 1, "a card id")
   if id == nil then
      return nil, ierr
   end
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

local CLOSE = spec({ "error", "stats", "cost" }, { "ok", "failed" })

local function cmd_close(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, CLOSE)
   if args == nil then
      return nil, perr
   end
   local id, ierr = need(args, 1, "a card id")
   if id == nil then
      return nil, ierr
   end
   if args.flags["ok"] and args.flags["failed"] then
      return nil, "close takes --ok or --failed, not both"
   end

   -- `--ok` is the default, and `cards.close` is what refuses the two ways this can
   -- disagree with itself: an ok close carrying an error, and a failed one without one.
   local outcome: cards.Outcome = { ok = not args.flags["failed"] }
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

local NOTHING = spec({}, {})

local function cmd_get(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, NOTHING)
   if args == nil then
      return nil, perr
   end
   local id, ierr = need(args, 1, "a card id")
   if id == nil then
      return nil, ierr
   end
   local view, err = cards.get(s, id)
   if view == nil then
      return nil, err
   end
   return encode(s, view)
end

local LIST = spec({ "pkg", "state", "limit", "offset" }, {})

local function cmd_list(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, LIST)
   if args == nil then
      return nil, perr
   end
   local limit, lerr = cli.integer(args, "limit")
   if lerr ~= nil then
      return nil, lerr
   end
   local offset, oerr = cli.integer(args, "offset")
   if oerr ~= nil then
      return nil, oerr
   end
   local rows, err = cards.list(s, {
      pkg = cli.value(args, "pkg"),
      state = cli.value(args, "state"),
      limit = limit,
      offset = offset,
   })
   if rows == nil then
      return nil, err
   end
   return encode(s, rows)
end

local FIND = spec({ "where", "order-by", "limit", "offset" }, { "asc" })

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
   local limit, lerr = cli.integer(args, "limit")
   if lerr ~= nil then
      return nil, lerr
   end
   local offset, oerr = cli.integer(args, "offset")
   if oerr ~= nil then
      return nil, oerr
   end

   local rows, err = cards.find(s, {
      clauses = clauses,
      order_by = cli.value(args, "order-by"),
      desc = not args.flags["asc"],
      limit = limit,
      offset = offset,
   })
   if rows == nil then
      return nil, err
   end
   return encode(s, rows)
end

local LINEAGE = spec({ "depth" }, {})

local function cmd_lineage(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, LINEAGE)
   if args == nil then
      return nil, perr
   end
   local id, ierr = need(args, 1, "a card id")
   if id == nil then
      return nil, ierr
   end
   local depth, derr = cli.integer(args, "depth")
   if derr ~= nil then
      return nil, derr
   end
   local tree, err = cards.lineage(s, id, { depth = depth })
   if tree == nil then
      return nil, err
   end
   return encode(s, tree)
end

local ALIAS_NOTE = spec({ "note" }, {})
local ALIAS_LIST = spec({ "pkg", "card" }, {})

-- `alias` is the one command with a word of its own after it. The five things that can be
-- done to a name are one subject, and five top-level commands would not say so.
local function cmd_alias(s: store, argv: {string}): string, string
   local what = argv[1]
   local rest: {string} = {}
   for i = 2, #argv do
      rest[i - 1] = argv[i]
   end

   if what == "set" then
      local args, perr = cli.parse(rest, ALIAS_NOTE)
      if args == nil then
         return nil, perr
      end
      local name, nerr = need(args, 1, "an alias name")
      if name == nil then
         return nil, nerr
      end
      local id, ierr = need(args, 2, "a card id")
      if id == nil then
         return nil, ierr
      end
      local rec, err = cards.alias(s, name, id, cli.value(args, "note"))
      if err ~= nil then
         return nil, err
      end
      -- `nil, nil` is the store declining because the name already means this card. That
      -- is not a failure and not a write, and `changed` is which of the two happened.
      return encode(s, { alias = name, card_id = id, changed = rec ~= nil })
   elseif what == "release" then
      local args, perr = cli.parse(rest, ALIAS_NOTE)
      if args == nil then
         return nil, perr
      end
      local name, nerr = need(args, 1, "an alias name")
      if name == nil then
         return nil, nerr
      end
      local rec, err = cards.alias_release(s, name, cli.value(args, "note"))
      if err ~= nil then
         return nil, err
      end
      return encode(s, { alias = name, released = rec ~= nil })
   elseif what == "get" then
      local args, perr = cli.parse(rest, NOTHING)
      if args == nil then
         return nil, perr
      end
      local name, nerr = need(args, 1, "an alias name")
      if name == nil then
         return nil, nerr
      end
      local view, err = cards.get_by_alias(s, name)
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
      local args, perr = cli.parse(rest, NOTHING)
      if args == nil then
         return nil, perr
      end
      local name, nerr = need(args, 1, "an alias name")
      if name == nil then
         return nil, nerr
      end
      local events, err = cards.alias_history(s, name)
      if events == nil then
         return nil, err
      end
      return encode(s, events)
   end

   return nil, "alias takes set, release, get, list or history, got "
      .. string.format("%q", tostring(what))
end

local PROMOTE = spec({ "alias", "pkg", "scenario", "metric", "min-n", "note" }, {})

local function cmd_promote(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, PROMOTE)
   if args == nil then
      return nil, perr
   end
   local min_n, merr = cli.integer(args, "min-n")
   if merr ~= nil then
      return nil, merr
   end
   local done, err = cards.promote(s, {
      alias = cli.value(args, "alias"),
      pkg = cli.value(args, "pkg"),
      scenario = cli.value(args, "scenario"),
      metric = cli.value(args, "metric"),
      min_n = min_n,
      note = cli.value(args, "note"),
   })
   if done == nil then
      return nil, err
   end
   return encode(s, done)
end

local PRUNE = spec({ "reason", "pkg", "pkg-like", "older-than-ms", "id", "state" }, { "dry-run" })

local function cmd_prune(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, PRUNE)
   if args == nil then
      return nil, perr
   end
   local older, oerr = cli.integer(args, "older-than-ms")
   if oerr ~= nil then
      return nil, oerr
   end
   -- `--pkg-like` is a LIKE pattern and reaches `cards.prune` as one: `%` and `_` in it
   -- are wildcards, and the query carries `ESCAPE '\'`, so the pkg prefix `_test_` is
   -- written `--pkg-like '\_test\_%'`.
   local report, err = cards.prune(s, {
      reason = cli.value(args, "reason"),
      pkg = cli.value(args, "pkg"),
      pkg_like = cli.value(args, "pkg-like"),
      older_than_ms = older,
      ids = cli.list(args, "id"),
      states = cli.list(args, "state"),
      dry_run = args.flags["dry-run"],
   })
   if report == nil then
      return nil, err
   end
   return encode(s, report)
end

local PRUNE_LOG = spec({ "limit" }, {})

local function cmd_prune_log(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, PRUNE_LOG)
   if args == nil then
      return nil, perr
   end
   local limit, lerr = cli.integer(args, "limit")
   if lerr ~= nil then
      return nil, lerr
   end
   local entries, err = cards.prune_log(s, { limit = limit })
   if entries == nil then
      return nil, err
   end
   return encode(s, entries)
end

local function cmd_export(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, NOTHING)
   if args == nil then
      return nil, perr
   end
   local report, err = cards.export(s)
   if report == nil then
      return nil, err
   end
   return encode(s, report)
end

local function cmd_import(s: store, argv: {string}): string, string
   local args, perr = cli.parse(argv, NOTHING)
   if args == nil then
      return nil, perr
   end
   local path, ferr = need(args, 1, "the path of an export file")
   if path == nil then
      return nil, ferr
   end
   local report, err = cards.import(s, path)
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
   "              [--note N] [--id ID]",
   "  samples     <id> [--file rows.jsonl]    one JSON object per line; stdin without --file",
   "  eval        <id> --file eval.json",
   "  checkpoint  <id> --file weights.bin --format safetensors [--note N]",
   "  close       <id> [--ok | --failed --error MSG] [--stats JSON] [--cost JSON]",
   "",
   "Reading:",
   "  get         <id>",
   "  list        [--pkg P] [--state S] [--limit N] [--offset N]",
   "  find        --where 'col op value' [--where ...] [--order-by col] [--asc]",
   "              [--limit N] [--offset N]",
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
function cli.usage(): string
   return USAGE
end

local HANDLERS: {string:Handler} = {
   open = cmd_open,
   samples = cmd_samples,
   eval = cmd_eval,
   checkpoint = cmd_checkpoint,
   close = cmd_close,
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

   local rest: {string} = {}
   for i = 2, #argv do
      rest[i - 1] = argv[i]
   end
   return handler(s, rest)
end

return cli
