-- The smoke path for the binary: open the store and say what is in it. Step 6 replaces
-- this with the CLI (subcommand dispatch, JSON out).

local cardbox = require("cardbox")
local store = require("store") -- Rust side, see src/lib.rs (types: src/store.d.tl)

print("cardbox " .. cardbox.version())
print("root: " .. store:root())

local rows, err = store:query("SELECT count(*) AS n FROM events", {})
if err ~= nil then
   error(err)
end
local row = rows[1] as {string:any}
print("events: " .. tostring(row.n))
