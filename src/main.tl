-- The entry script: the arguments, one call into the CLI, and what comes back.
--
-- Everything a command means is in `cardbox.cli`; what is here is only the two ends of it.
-- The answer goes to stdout as it came. A refusal is raised rather than printed, because
-- the process has to exit non-zero for it and this script has no way to say so — `exec`
-- discards what a chunk returns — so `src/main.rs` is where the message reaches stderr and
-- where the status is set. `error(.., 0)` keeps the file and the line off the front of it:
-- a refusal is a sentence for whoever typed the command, not a location in this file.
--
-- `os.exit` would be the shorter way and is not taken: it ends the process from inside Lua,
-- so the Rust side never drops the store it opened. Raising hands the same outcome back
-- through the host, which unwinds, closes and then exits.

local cli = require("cardbox.cli")
local store = require("store") -- Rust side, see src/lib.rs (types: src/store.d.tl)

-- What `src/main.rs` looks for to tell a refusal apart from a bug. A refusal is printed
-- alone; anything else keeps its frames, because a stack is useless to the person who
-- mistyped an option and is the whole of the evidence for the person who hit a crash.
local REFUSAL = "cardbox-refusal: "

local argv: {string} = {}
for i = 1, #arg do
   argv[i] = arg[i]
end

local out, err = cli.run(store, argv)
if err ~= nil then
   error(REFUSAL .. err, 0)
end
if out ~= nil and out ~= "" then
   print(out)
end
