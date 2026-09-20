local t = require("htl.test")
local tablex = require("htlx.tablex")

t.describe("tablex.keys / values", function()
   t.it("returns every key once", function()
      local ks = tablex.keys({ a = 1, b = 2, c = 3 })
      table.sort(ks)
      t.expect(ks):to_equal({ "a", "b", "c" })
   end)

   t.it("returns every value once", function()
      local vs = tablex.values({ a = 1, b = 2, c = 3 })
      table.sort(vs)
      t.expect(vs):to_equal({ 1, 2, 3 })
   end)

   t.it("is empty for an empty map", function()
      t.expect(tablex.keys({} as {string:integer})):to_equal({})
      t.expect(tablex.values({} as {string:integer})):to_equal({})
   end)

   t.it("raises on a non-table", function()
      t.expect(function() tablex.keys(nil) end):to_error("htlx%.tablex%.keys: expected a table, got nil")
   end)
end)

t.describe("tablex.sorted_keys", function()
   t.it("sorts with < by default", function()
      t.expect(tablex.sorted_keys({ c = 1, a = 2, b = 3 })):to_equal({ "a", "b", "c" })
   end)

   t.it("sorts with the comparator when given", function()
      local ks = tablex.sorted_keys({ c = 1, a = 2, b = 3 }, function(x: string, y: string): boolean
         return x > y
      end)
      t.expect(ks):to_equal({ "c", "b", "a" })
   end)
end)

t.describe("tablex.sorted_pairs", function()
   t.it("visits entries in key order", function()
      local seen: {string} = {}
      for k, v in tablex.sorted_pairs({ c = 3, a = 1, b = 2 }) do
         seen[#seen + 1] = k .. "=" .. tostring(v)
      end
      t.expect(seen):to_equal({ "a=1", "b=2", "c=3" })
   end)

   t.it("visits nothing for an empty map", function()
      local n = 0
      for _ in tablex.sorted_pairs({} as {string:integer}) do
         n = n + 1
      end
      t.expect(n):to_equal(0)
   end)

   t.it("takes a comparator", function()
      local seen: {integer} = {}
      for k in tablex.sorted_pairs({ [1] = "x", [3] = "y", [2] = "z" }, function(a: integer, b: integer): boolean
         return a > b
      end) do
         seen[#seen + 1] = k
      end
      t.expect(seen):to_equal({ 3, 2, 1 })
   end)
end)

t.describe("tablex.map", function()
   t.it("maps values and keeps keys", function()
      local out = tablex.map({ a = 1, b = 2 }, function(v: integer, k: string): string
         return k .. tostring(v * 10)
      end)
      t.expect(out):to_equal({ a = "a10", b = "b20" })
   end)

   t.it("leaves the input alone", function()
      local input = { a = 1 }
      tablex.map(input, function(v: integer): integer return v + 1 end)
      t.expect(input):to_equal({ a = 1 })
   end)

   t.it("raises when f is not a function", function()
      t.expect(function() tablex.map({ a = 1 }, nil) end):to_error("htlx%.tablex%.map: f must be a function, got nil")
   end)
end)

t.describe("tablex.filter", function()
   t.it("keeps the entries the predicate accepts", function()
      local out = tablex.filter({ a = 1, b = 2, c = 3 }, function(v: integer): boolean
         return v % 2 == 1
      end)
      t.expect(out):to_equal({ a = 1, c = 3 })
   end)

   t.it("passes the key as the second argument", function()
      local out = tablex.filter({ a = 1, b = 2 }, function(_: integer, k: string): boolean
         return k == "b"
      end)
      t.expect(out):to_equal({ b = 2 })
   end)
end)

t.describe("tablex.merge", function()
   t.it("takes both sides and lets the second win", function()
      t.expect(tablex.merge({ a = 1, b = 2 }, { b = 20, c = 3 })):to_equal({ a = 1, b = 20, c = 3 })
   end)

   t.it("changes neither argument", function()
      local a = { a = 1 }
      local b = { b = 2 }
      tablex.merge(a, b)
      t.expect(a):to_equal({ a = 1 })
      t.expect(b):to_equal({ b = 2 })
   end)
end)

t.describe("tablex.copy / count / is_empty", function()
   t.it("copies to a different table with the same entries", function()
      local src = { a = 1, b = 2 }
      local dst = tablex.copy(src)
      t.expect(dst):to_equal(src)
      t.expect(dst == src):to_equal(false)
   end)

   t.it("counts map entries, which # does not", function()
      t.expect(tablex.count({ a = 1, b = 2, c = 3 })):to_equal(3)
      t.expect(tablex.count({} as {string:integer})):to_equal(0)
   end)

   t.it("knows an empty map from a full one", function()
      t.expect(tablex.is_empty({} as {string:integer})):to_equal(true)
      t.expect(tablex.is_empty({ a = 1 })):to_equal(false)
   end)
end)

t.describe("tablex.each / map_keys / entries / from_entries", function()
   t.it("each visits every entry with value then key", function()
      local seen: {string} = {}
      tablex.each({ a = 1, b = 2 }, function(v: integer, k: string)
         seen[#seen + 1] = k .. v
      end)
      table.sort(seen)
      t.expect(seen):to_equal({ "a1", "b2" })
   end)

   t.it("map_keys renames keys and keeps values", function()
      local out = tablex.map_keys({ a = 1, b = 2 }, function(k: string, v: integer): string
         return k .. v
      end)
      t.expect(out):to_equal({ a1 = 1, b2 = 2 })
   end)

   t.it("map_keys raises on a nil key", function()
      t.expect(function()
         tablex.map_keys({ a = 1 }, function(_: string): string return nil end)
      end):to_error("htlx%.tablex%.map_keys: f returned nil")
   end)

   t.it("entries and from_entries round-trip", function()
      local src = { a = 1, b = 2 }
      local e = tablex.entries(src)
      t.expect(#e):to_equal(2)
      t.expect(tablex.from_entries(e)):to_equal(src)
      t.expect(tablex.entries({} as {string:integer})):to_equal({})
   end)

   t.it("from_entries lets a later pair win and refuses a nil key", function()
      t.expect(tablex.from_entries({ { "a", 1 }, { "a", 2 } })):to_equal({ a = 2 })
      t.expect(function() tablex.from_entries({ { nil, 1 } } as {{string, integer}}) end):to_error("htlx%.tablex%.from_entries: pair 1 has a nil key")
   end)
end)

t.describe("tablex.get_or / pick / omit / invert / equals", function()
   t.it("get_or falls back only when the key is absent", function()
      t.expect(tablex.get_or({ a = 1 }, "a", 9)):to_equal(1)
      t.expect(tablex.get_or({ a = 1 }, "z", 9)):to_equal(9)
      t.expect(tablex.get_or({ a = false }, "a", true)):to_equal(false)
   end)

   t.it("pick keeps the named keys that exist", function()
      t.expect(tablex.pick({ a = 1, b = 2, c = 3 }, { "a", "c", "z" })):to_equal({ a = 1, c = 3 })
      t.expect(tablex.pick({ a = 1 }, {})):to_equal({})
   end)

   t.it("omit drops the named keys", function()
      t.expect(tablex.omit({ a = 1, b = 2, c = 3 }, { "b" })):to_equal({ a = 1, c = 3 })
      t.expect(tablex.omit({ a = 1 }, {})):to_equal({ a = 1 })
   end)

   t.it("invert swaps keys and values", function()
      t.expect(tablex.invert({ a = 1, b = 2 })):to_equal({ [1] = "a", [2] = "b" })
   end)

   t.it("equals is one level, both ways", function()
      t.expect(tablex.equals({ a = 1 }, { a = 1 })):to_equal(true)
      t.expect(tablex.equals({ a = 1 }, { a = 2 })):to_equal(false)
      t.expect(tablex.equals({ a = 1 }, { a = 1, b = 2 })):to_equal(false)
      t.expect(tablex.equals({ a = 1, b = 2 }, { a = 1 })):to_equal(false)
      t.expect(tablex.equals({ a = { 1 } }, { a = { 1 } })):to_equal(false)
      t.expect(tablex.equals({} as {string:integer}, {} as {string:integer})):to_equal(true)
   end)
end)

t.describe("tablex.deep_copy", function()
   t.it("copies nested tables so nothing is shared", function()
      local src = { a = { b = { 1, 2 } }, c = 3 }
      local dst = tablex.deep_copy(src)
      t.expect(dst):to_equal(src)
      t.expect(dst == src):to_equal(false)
      t.expect(dst.a == src.a):to_equal(false)
      t.expect(dst.a.b == src.a.b):to_equal(false)
      dst.a.b[1] = 9
      t.expect(src.a.b[1]):to_equal(1)
   end)

   t.it("copies a table used as a key", function()
      local k = { 1 }
      local src: {{integer}:string} = { [k] = "v" }
      local dst = tablex.deep_copy(src)
      local keys = tablex.keys(dst)
      t.expect(#keys):to_equal(1)
      t.expect(keys[1] == k):to_equal(false)
      t.expect(keys[1]):to_equal({ 1 })
      t.expect(dst[keys[1]]):to_equal("v")
   end)

   t.it("keeps a shared table shared once and a cycle a cycle", function()
      local shared = { 1 }
      local src: {string:any} = { x = shared, y = shared }
      src.self = src
      local dst = tablex.deep_copy(src)
      t.expect(dst.x == dst.y):to_equal(true)
      t.expect(dst.x == shared):to_equal(false)
      t.expect(dst.self == dst):to_equal(true)
   end)

   t.it("keeps the metatable", function()
      local mt = { __index = { hello = "there" } }
      local src = setmetatable({} as {string:string}, mt)
      local dst = tablex.deep_copy(src)
      t.expect(getmetatable(dst) == mt):to_equal(true)
   end)

   t.it("raises on a non-table", function()
      t.expect(function() tablex.deep_copy(3 as {string:integer}) end):to_error("htlx%.tablex%.deep_copy: expected a table, got number")
   end)
end)

t.describe("tablex.deep_equals / deep_merge", function()
   t.it("deep_equals compares by content at every level", function()
      t.expect(tablex.deep_equals({ a = { b = { 1, 2 } } }, { a = { b = { 1, 2 } } })):to_equal(true)
      t.expect(tablex.deep_equals({ a = { b = { 1, 2 } } }, { a = { b = { 1, 3 } } })):to_equal(false)
      t.expect(tablex.deep_equals({ a = { b = 1 } }, { a = { b = 1, c = 2 } })):to_equal(false)
      t.expect(tablex.deep_equals({ a = { b = 1, c = 2 } }, { a = { b = 1 } })):to_equal(false)
   end)

   t.it("deep_equals ends on cycles of the same shape", function()
      local a: {string:any} = {}
      a.self = a
      local b: {string:any} = {}
      b.self = b
      t.expect(tablex.deep_equals(a, b)):to_equal(true)
   end)

   t.it("deep_equals raises on a non-table", function()
      t.expect(function() tablex.deep_equals({} as {string:integer}, 1 as {string:integer}) end):to_error("htlx%.tablex%.deep_equals: expected two tables")
   end)

   t.it("deep_merge merges nested maps and lets b win on leaves", function()
      local a: {string:any} = { x = { p = 1, q = 2 }, y = 1 }
      local b: {string:any} = { x = { q = 20, r = 30 }, z = 3 }
      local out = tablex.deep_merge(a, b)
      t.expect(out):to_equal({ x = { p = 1, q = 20, r = 30 }, y = 1, z = 3 })
      t.expect(a):to_equal({ x = { p = 1, q = 2 }, y = 1 })
      t.expect((out.x as {string:any}) == (a.x as {string:any})):to_equal(false)
   end)

   t.it("deep_merge replaces a table with a non-table and back", function()
      t.expect(tablex.deep_merge({ x = { 1 } } as {string:any}, { x = 2 } as {string:any})):to_equal({ x = 2 })
      t.expect(tablex.deep_merge({ x = 2 } as {string:any}, { x = { 1 } } as {string:any})):to_equal({ x = { 1 } })
   end)
end)

t.describe("tablex.freeze / is_frozen", function()
   t.it("reads through and refuses writes", function()
      local src: {string:integer} = { a = 1 }
      local f = tablex.freeze(src)
      t.expect(f.a):to_equal(1)
      t.expect(function() f.b = 2 end):to_error("htlx%.tablex%.freeze: the table is frozen, cannot set b")
      t.expect(src.b):to_be_nil()
   end)

   t.it("shows a change made through the original", function()
      local src: {string:integer} = { a = 1 }
      local f = tablex.freeze(src)
      src.a = 5
      t.expect(f.a):to_equal(5)
   end)

   t.it("supports #, ipairs and pairs", function()
      local arr = tablex.freeze({ "x", "y" })
      t.expect(#arr):to_equal(2)
      local seen: {string} = {}
      for _, v in ipairs(arr) do
         seen[#seen + 1] = v
      end
      t.expect(seen):to_equal({ "x", "y" })
      local m = tablex.freeze({ a = 1 } as {string:integer})
      local n = 0
      for k, v in pairs(m) do
         n = n + 1
         t.expect(k):to_equal("a")
         t.expect(v):to_equal(1)
      end
      t.expect(n):to_equal(1)
      t.expect(tablex.count(m)):to_equal(1)
   end)

   t.it("is_frozen tells a view from a plain table", function()
      local src: {string:integer} = { a = 1 }
      t.expect(tablex.is_frozen(tablex.freeze(src))):to_equal(true)
      t.expect(tablex.is_frozen(src)):to_equal(false)
      t.expect(tablex.is_frozen(nil)):to_equal(false)
   end)

   t.it("raises on a non-table", function()
      t.expect(function() tablex.freeze("x" as {string:integer}) end):to_error("htlx%.tablex%.freeze: expected a table, got string")
   end)
end)
