local t = require("htl.test")
local htlx = require("htlx")

t.describe("require(\"htlx\")", function()
   t.it("is the same tables as the two modules", function()
      t.expect(htlx.tablex == require("htlx.tablex")):to_equal(true)
      t.expect(htlx.list == require("htlx.list")):to_equal(true)
   end)

   t.it("works end to end", function()
      local by_name = { b = 2, a = 1 }
      local names = htlx.tablex.sorted_keys(by_name)
      local set = htlx.list.to_set(names)
      t.expect(names):to_equal({ "a", "b" })
      t.expect(set.a):to_equal(true)
   end)
end)
