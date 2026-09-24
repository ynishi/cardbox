-- `htl test` runs the Teal alone: there is no Rust host here, so nothing in this file
-- may `require("store")`. The store's own tests are `cargo test` in src/lib.rs, which
-- reaches the module the way a host does — through `preload`.

local t = require("htl.test")
local cardbox = require("cardbox")

t.describe("cardbox", function()
   t.it("says which version it is", function()
      t.expect(cardbox.version()):to_equal("0.1.3")
   end)
end)
