local cardbox = require("cardbox")
local host = require("host") -- Rust side, see src/lib.rs (types: src/host.d.tl)

local g = cardbox.greet(arg and arg[1] or "teal")
print(g.text)

print(host:greet(g.who))
local p: host.Point = host:scale({ x = 1, y = 2 }, 3)
print("scaled:", p.x, p.y)
