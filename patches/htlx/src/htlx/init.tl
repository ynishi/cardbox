--- `require("htlx")`: the four modules under one name, for a file that wants them together.
--- `require("htlx.list")` and the rest return the same tables.
local list = require("htlx.list")
local tablex = require("htlx.tablex")
local seq = require("htlx.seq")
local ordered = require("htlx.ordered")

local record htlx
   list: list
   tablex: tablex
   seq: seq
   ordered: ordered
end

htlx.list = list
htlx.tablex = tablex
htlx.seq = seq
htlx.ordered = ordered

return htlx
