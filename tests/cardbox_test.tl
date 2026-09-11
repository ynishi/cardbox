local t = require("htl.test")
local cardbox = require("cardbox")

t.describe("cardbox.greet", function()
   t.it("greets by name", function()
      t.expect(cardbox.greet("teal")):to_equal({ who = "teal", text = "hello, teal" })
   end)
end)
