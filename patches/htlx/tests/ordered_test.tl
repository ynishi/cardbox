local t = require("htl.test")
local ordered = require("htlx.ordered")

-- The record tables, for calling a method with something that is not an instance as
-- `self` (`m.set(nil, ...)` on an instance is what the `:` hint is about).
local Map = ordered.Map
local Set = ordered.Set

local function map_of(...: string): ordered.Map<string, integer>
   local m: ordered.Map<string, integer> = ordered.map()
   local names = { ... }
   for i = 1, #names do
      m:set(names[i], i)
   end
   return m
end

t.describe("ordered.map / set constructors", function()
   t.it("map starts empty", function()
      local m: ordered.Map<string, integer> = ordered.map()
      t.expect(m:len()):to_equal(0)
      t.expect(m:is_empty()):to_equal(true)
      t.expect(m:keys()):to_equal({})
   end)

   t.it("set starts empty", function()
      local s: ordered.Set<string> = ordered.set()
      t.expect(s:len()):to_equal(0)
      t.expect(s:is_empty()):to_equal(true)
      t.expect(s:values()):to_equal({})
   end)

   t.it("from_entries keeps array order", function()
      local m = ordered.from_entries({ { "c", 3 }, { "a", 1 }, { "b", 2 } })
      t.expect(m:keys()):to_equal({ "c", "a", "b" })
      t.expect(m:values()):to_equal({ 3, 1, 2 })
   end)

   t.it("from_entries takes the last value at the first position for a repeated key", function()
      local m = ordered.from_entries({ { "a", 1 }, { "b", 2 }, { "a", 9 } })
      t.expect(m:keys()):to_equal({ "a", "b" })
      t.expect(m:get("a")):to_equal(9)
   end)

   t.it("from_entries is empty for an empty array", function()
      t.expect(ordered.from_entries({} as {{string, integer}}):len()):to_equal(0)
   end)

   t.it("from_entries raises on a non-table and on a bad entry", function()
      t.expect(function() ordered.from_entries(nil) end):to_error("htlx%.ordered%.from_entries: expected an array, got nil")
      t.expect(function() ordered.from_entries({ 1 as any } as {{string, integer}}) end):to_error("htlx%.ordered%.from_entries: entry 1 is not a")
   end)

   t.it("from_table sorts keys with < by default", function()
      local m = ordered.from_table({ c = 3, a = 1, b = 2 })
      t.expect(m:keys()):to_equal({ "a", "b", "c" })
      t.expect(m:values()):to_equal({ 1, 2, 3 })
   end)

   t.it("from_table sorts keys with the comparator when given", function()
      local m = ordered.from_table({ c = 3, a = 1, b = 2 }, function(x: string, y: string): boolean
         return x > y
      end)
      t.expect(m:keys()):to_equal({ "c", "b", "a" })
   end)

   t.it("from_table is empty for an empty map and leaves the source alone", function()
      local src = { a = 1 }
      local m = ordered.from_table(src)
      m:set("b", 2)
      t.expect(src):to_equal({ a = 1 })
      t.expect(ordered.from_table({} as {string:integer}):len()):to_equal(0)
   end)

   t.it("from_table raises on a non-table", function()
      t.expect(function() ordered.from_table(nil) end):to_error("htlx%.ordered%.from_table: expected a table, got nil")
   end)

   t.it("from keeps array order and the first position of a duplicate", function()
      local s = ordered.from({ "b", "a", "b", "c", "a" })
      t.expect(s:values()):to_equal({ "b", "a", "c" })
      t.expect(s:len()):to_equal(3)
   end)

   t.it("from is empty for an empty array", function()
      t.expect(ordered.from({} as {string}):len()):to_equal(0)
   end)

   t.it("from raises on a non-table", function()
      t.expect(function() ordered.from(nil) end):to_error("htlx%.ordered%.from: expected an array, got nil")
   end)
end)

t.describe("ordered.is_map / is_set", function()
   t.it("tells a Map from a Set from a plain table", function()
      local m: ordered.Map<string, integer> = ordered.map()
      local s: ordered.Set<string> = ordered.set()
      t.expect(ordered.is_map(m)):to_equal(true)
      t.expect(ordered.is_map(s)):to_equal(false)
      t.expect(ordered.is_map({})):to_equal(false)
      t.expect(ordered.is_map(nil)):to_equal(false)
      t.expect(ordered.is_set(s)):to_equal(true)
      t.expect(ordered.is_set(m)):to_equal(false)
      t.expect(ordered.is_set({})):to_equal(false)
      t.expect(ordered.is_set(nil)):to_equal(false)
   end)

   t.it("is false for a table of the same shape", function()
      t.expect(ordered.is_map({ _keys = {}, _vals = {} })):to_equal(false)
      t.expect(ordered.is_set({ _items = {}, _has = {} })):to_equal(false)
   end)
end)

t.describe("Map:set / get / get_or / has", function()
   t.it("keeps insertion order and returns self for chaining", function()
      local m: ordered.Map<string, integer> = ordered.map()
      local back = m:set("z", 1):set("a", 2):set("m", 3)
      t.expect(back == m):to_equal(true)
      t.expect(m:keys()):to_equal({ "z", "a", "m" })
   end)

   t.it("updating an existing key keeps its position", function()
      local m = map_of("a", "b", "c")
      m:set("a", 10)
      t.expect(m:keys()):to_equal({ "a", "b", "c" })
      t.expect(m:values()):to_equal({ 10, 2, 3 })
      t.expect(m:len()):to_equal(3)
   end)

   t.it("get returns the value or nil", function()
      local m = map_of("a")
      t.expect(m:get("a")):to_equal(1)
      t.expect(m:get("z")):to_be_nil()
   end)

   t.it("get_or falls back to the default without inserting", function()
      local m = map_of("a")
      t.expect(m:get_or("a", 0)):to_equal(1)
      t.expect(m:get_or("z", 0)):to_equal(0)
      t.expect(m:has("z")):to_equal(false)
   end)

   t.it("has is true only for a present key", function()
      local m = map_of("a")
      t.expect(m:has("a")):to_equal(true)
      t.expect(m:has("b")):to_equal(false)
      t.expect(m:has(nil)):to_equal(false)
   end)

   t.it("takes non-string keys", function()
      local m: ordered.Map<integer, string> = ordered.map()
      m:set(10, "ten"):set(2, "two")
      t.expect(m:keys()):to_equal({ 10, 2 })
      t.expect(m:get(2)):to_equal("two")
   end)

   t.it("set raises on a nil value", function()
      local m = map_of("a")
      t.expect(function() m:set("a", nil) end):to_error("htlx%.ordered%.Map%.set: refusing a nil value")
      t.expect(m:get("a")):to_equal(1)
   end)

   t.it("set raises on a nil key", function()
      local m = map_of()
      t.expect(function() m:set(nil, 1) end):to_error("htlx%.ordered%.Map%.set: refusing a nil key")
   end)

   t.it("raises when self is not a Map", function()
      t.expect(function() Map.set(nil, "a", 1) end):to_error("htlx%.ordered%.Map%.set: expected an ordered%.Map, got nil")
      t.expect(function() Map.get({} as ordered.Map<string, integer>, "a") end):to_error("htlx%.ordered%.Map%.get: expected an ordered%.Map, got table")
      t.expect(function() Map.get_or(nil, "a", 0) end):to_error("htlx%.ordered%.Map%.get_or: expected an ordered%.Map")
      t.expect(function() Map.has(nil, "a") end):to_error("htlx%.ordered%.Map%.has: expected an ordered%.Map")
   end)
end)

t.describe("Map:delete", function()
   t.it("removes the key and closes the gap in the order", function()
      local m = map_of("a", "b", "c")
      t.expect(m:delete("b")):to_equal(true)
      t.expect(m:keys()):to_equal({ "a", "c" })
      t.expect(m:get("b")):to_be_nil()
      t.expect(m:len()):to_equal(2)
   end)

   t.it("re-setting a deleted key puts it at the end", function()
      local m = map_of("a", "b", "c")
      m:delete("a")
      m:set("a", 9)
      t.expect(m:keys()):to_equal({ "b", "c", "a" })
   end)

   t.it("is false for a missing key and changes nothing", function()
      local m = map_of("a")
      t.expect(m:delete("z")):to_equal(false)
      t.expect(m:keys()):to_equal({ "a" })
   end)

   t.it("is false on an empty map", function()
      t.expect(map_of():delete("a")):to_equal(false)
   end)

   t.it("raises when self is not a Map", function()
      t.expect(function() Map.delete(nil, "a") end):to_error("htlx%.ordered%.Map%.delete: expected an ordered%.Map")
   end)
end)

t.describe("Map:keys / values / entries", function()
   t.it("are new arrays in insertion order", function()
      local m = map_of("b", "a")
      local ks = m:keys()
      ks[1] = "changed"
      t.expect(m:keys()):to_equal({ "b", "a" })
      t.expect(m:values()):to_equal({ 1, 2 })
      t.expect(m:entries()):to_equal({ { "b", 1 }, { "a", 2 } })
   end)

   t.it("are empty for an empty map", function()
      local m = map_of()
      t.expect(m:keys()):to_equal({})
      t.expect(m:values()):to_equal({})
      t.expect(m:entries()):to_equal({})
   end)

   t.it("entries round-trip through from_entries", function()
      local m = map_of("x", "y")
      local back = ordered.from_entries(m:entries())
      t.expect(back:keys()):to_equal({ "x", "y" })
      t.expect(back:values()):to_equal({ 1, 2 })
   end)

   t.it("raise when self is not a Map", function()
      t.expect(function() Map.keys(nil) end):to_error("htlx%.ordered%.Map%.keys: expected an ordered%.Map")
      t.expect(function() Map.values(nil) end):to_error("htlx%.ordered%.Map%.values: expected an ordered%.Map")
      t.expect(function() Map.entries(nil) end):to_error("htlx%.ordered%.Map%.entries: expected an ordered%.Map")
   end)
end)

t.describe("Map:pairs / each", function()
   t.it("pairs visits entries in insertion order", function()
      local seen: {string} = {}
      for k, v in map_of("c", "a", "b"):pairs() do
         seen[#seen + 1] = k .. "=" .. tostring(v)
      end
      t.expect(seen):to_equal({ "c=1", "a=2", "b=3" })
   end)

   t.it("pairs visits nothing for an empty map", function()
      local n = 0
      for _ in map_of():pairs() do
         n = n + 1
      end
      t.expect(n):to_equal(0)
   end)

   t.it("each calls f(value, key) in insertion order", function()
      local seen: {string} = {}
      map_of("b", "a"):each(function(v: integer, k: string)
         seen[#seen + 1] = k .. tostring(v)
      end)
      t.expect(seen):to_equal({ "b1", "a2" })
   end)

   t.it("each raises when f is not a function", function()
      t.expect(function() map_of("a"):each(nil) end):to_error("htlx%.ordered%.Map%.each: f must be a function, got nil")
   end)

   t.it("raise when self is not a Map", function()
      t.expect(function() Map.pairs(nil) end):to_error("htlx%.ordered%.Map%.pairs: expected an ordered%.Map")
      t.expect(function() Map.each(nil, function() end) end):to_error("htlx%.ordered%.Map%.each: expected an ordered%.Map")
   end)
end)

t.describe("Map:len / is_empty", function()
   t.it("count entries, not updates", function()
      local m = map_of("a", "b")
      m:set("a", 5)
      t.expect(m:len()):to_equal(2)
      t.expect(m:is_empty()):to_equal(false)
   end)

   t.it("are 0 / true after every key is deleted", function()
      local m = map_of("a")
      m:delete("a")
      t.expect(m:len()):to_equal(0)
      t.expect(m:is_empty()):to_equal(true)
   end)

   t.it("raise when self is not a Map", function()
      t.expect(function() Map.len(nil) end):to_error("htlx%.ordered%.Map%.len: expected an ordered%.Map")
      t.expect(function() Map.is_empty(nil) end):to_error("htlx%.ordered%.Map%.is_empty: expected an ordered%.Map")
   end)
end)

t.describe("Map:copy", function()
   t.it("keeps order and is independent of the source", function()
      local src = map_of("b", "a")
      local dst = src:copy()
      t.expect(dst == src):to_equal(false)
      t.expect(ordered.is_map(dst)):to_equal(true)
      t.expect(dst:keys()):to_equal({ "b", "a" })
      dst:set("c", 3)
      dst:delete("b")
      src:set("a", 99)
      t.expect(src:keys()):to_equal({ "b", "a" })
      t.expect(dst:keys()):to_equal({ "a", "c" })
      t.expect(dst:get("a")):to_equal(2)
   end)

   t.it("copies an empty map", function()
      t.expect(map_of():copy():is_empty()):to_equal(true)
   end)

   t.it("raises when self is not a Map", function()
      t.expect(function() Map.copy(nil) end):to_error("htlx%.ordered%.Map%.copy: expected an ordered%.Map")
   end)
end)

t.describe("Map:sorted", function()
   t.it("orders by key with < by default and leaves self alone", function()
      local m = map_of("c", "a", "b")
      local s = m:sorted()
      t.expect(s:keys()):to_equal({ "a", "b", "c" })
      t.expect(s:values()):to_equal({ 2, 3, 1 })
      t.expect(m:keys()):to_equal({ "c", "a", "b" })
   end)

   t.it("takes a comparator", function()
      local s = map_of("b", "c", "a"):sorted(function(x: string, y: string): boolean
         return x > y
      end)
      t.expect(s:keys()):to_equal({ "c", "b", "a" })
   end)

   t.it("sorts integer keys", function()
      local m: ordered.Map<integer, string> = ordered.map()
      m:set(3, "c"):set(1, "a"):set(2, "b")
      t.expect(m:sorted():keys()):to_equal({ 1, 2, 3 })
   end)

   t.it("is empty for an empty map", function()
      t.expect(map_of():sorted():len()):to_equal(0)
   end)

   t.it("raises when self is not a Map", function()
      t.expect(function() Map.sorted(nil) end):to_error("htlx%.ordered%.Map%.sorted: expected an ordered%.Map")
   end)
end)

t.describe("Map:to_table", function()
   t.it("is a plain map of the entries, detached from self", function()
      local m = map_of("a", "b")
      local plain = m:to_table()
      t.expect(plain):to_equal({ a = 1, b = 2 })
      t.expect(ordered.is_map(plain)):to_equal(false)
      plain.a = 100
      t.expect(m:get("a")):to_equal(1)
   end)

   t.it("is empty for an empty map", function()
      t.expect(map_of():to_table()):to_equal({})
   end)

   t.it("raises when self is not a Map", function()
      t.expect(function() Map.to_table(nil) end):to_error("htlx%.ordered%.Map%.to_table: expected an ordered%.Map")
   end)
end)

t.describe("Set:add / has", function()
   t.it("keeps insertion order and returns self for chaining", function()
      local s: ordered.Set<string> = ordered.set()
      local back = s:add("z"):add("a"):add("m")
      t.expect(back == s):to_equal(true)
      t.expect(s:values()):to_equal({ "z", "a", "m" })
   end)

   t.it("adding a present value is a no-op that keeps its position", function()
      local s = ordered.from({ "a", "b", "c" })
      s:add("a")
      t.expect(s:values()):to_equal({ "a", "b", "c" })
      t.expect(s:len()):to_equal(3)
   end)

   t.it("has is true only for a present value", function()
      local s = ordered.from({ "a" })
      t.expect(s:has("a")):to_equal(true)
      t.expect(s:has("b")):to_equal(false)
      t.expect(s:has(nil)):to_equal(false)
   end)

   t.it("takes non-string values", function()
      local s = ordered.from({ 3, 1, 3, 2 })
      t.expect(s:values()):to_equal({ 3, 1, 2 })
      t.expect(s:has(2)):to_equal(true)
   end)

   t.it("add raises on nil", function()
      local s: ordered.Set<string> = ordered.set()
      t.expect(function() s:add(nil) end):to_error("htlx%.ordered%.Set%.add: refusing a nil value")
      t.expect(s:len()):to_equal(0)
   end)

   t.it("raise when self is not a Set", function()
      t.expect(function() Set.add(nil, "a") end):to_error("htlx%.ordered%.Set%.add: self must be an ordered%.Set, got nil")
      t.expect(function() Set.has({} as ordered.Set<string>, "a") end):to_error("htlx%.ordered%.Set%.has: self must be an ordered%.Set, got table")
   end)
end)

t.describe("Set:delete", function()
   t.it("removes the value and closes the gap in the order", function()
      local s = ordered.from({ "a", "b", "c" })
      t.expect(s:delete("b")):to_equal(true)
      t.expect(s:values()):to_equal({ "a", "c" })
      t.expect(s:has("b")):to_equal(false)
      t.expect(s:len()):to_equal(2)
   end)

   t.it("re-adding a deleted value puts it at the end", function()
      local s = ordered.from({ "a", "b", "c" })
      s:delete("a")
      s:add("a")
      t.expect(s:values()):to_equal({ "b", "c", "a" })
   end)

   t.it("is false for a missing value and on an empty set", function()
      local s = ordered.from({ "a" })
      t.expect(s:delete("z")):to_equal(false)
      t.expect(s:values()):to_equal({ "a" })
      t.expect(ordered.from({} as {string}):delete("a")):to_equal(false)
   end)

   t.it("raises when self is not a Set", function()
      t.expect(function() Set.delete(nil, "a") end):to_error("htlx%.ordered%.Set%.delete: self must be an ordered%.Set")
   end)
end)

t.describe("Set:values / iter / each", function()
   t.it("values is a new array in insertion order", function()
      local s = ordered.from({ "b", "a" })
      local vs = s:values()
      vs[1] = "changed"
      t.expect(s:values()):to_equal({ "b", "a" })
   end)

   t.it("iter visits values in insertion order", function()
      local seen: {string} = {}
      for v in ordered.from({ "c", "a", "b" }):iter() do
         seen[#seen + 1] = v
      end
      t.expect(seen):to_equal({ "c", "a", "b" })
   end)

   t.it("iter visits nothing for an empty set", function()
      local n = 0
      for _ in ordered.from({} as {string}):iter() do
         n = n + 1
      end
      t.expect(n):to_equal(0)
   end)

   t.it("each calls f(value) in insertion order", function()
      local seen: {string} = {}
      ordered.from({ "b", "a" }):each(function(v: string)
         seen[#seen + 1] = v
      end)
      t.expect(seen):to_equal({ "b", "a" })
   end)

   t.it("each raises when f is not a function", function()
      t.expect(function() ordered.from({ "a" }):each(nil) end):to_error("htlx%.ordered%.Set%.each: f must be a function, got nil")
   end)

   t.it("raise when self is not a Set", function()
      t.expect(function() Set.values(nil) end):to_error("htlx%.ordered%.Set%.values: self must be an ordered%.Set")
      t.expect(function() Set.iter(nil) end):to_error("htlx%.ordered%.Set%.iter: self must be an ordered%.Set")
      t.expect(function() Set.each(nil, function() end) end):to_error("htlx%.ordered%.Set%.each: self must be an ordered%.Set")
   end)
end)

t.describe("Set:len / is_empty", function()
   t.it("count distinct values", function()
      local s = ordered.from({ "a", "a", "b" })
      t.expect(s:len()):to_equal(2)
      t.expect(s:is_empty()):to_equal(false)
   end)

   t.it("are 0 / true after every value is deleted", function()
      local s = ordered.from({ "a" })
      s:delete("a")
      t.expect(s:len()):to_equal(0)
      t.expect(s:is_empty()):to_equal(true)
   end)

   t.it("raise when self is not a Set", function()
      t.expect(function() Set.len(nil) end):to_error("htlx%.ordered%.Set%.len: self must be an ordered%.Set")
      t.expect(function() Set.is_empty(nil) end):to_error("htlx%.ordered%.Set%.is_empty: self must be an ordered%.Set")
   end)
end)

t.describe("Set:copy", function()
   t.it("keeps order and is independent of the source", function()
      local src = ordered.from({ "b", "a" })
      local dst = src:copy()
      t.expect(dst == src):to_equal(false)
      t.expect(ordered.is_set(dst)):to_equal(true)
      t.expect(dst:values()):to_equal({ "b", "a" })
      dst:add("c")
      dst:delete("b")
      t.expect(src:values()):to_equal({ "b", "a" })
      t.expect(dst:values()):to_equal({ "a", "c" })
   end)

   t.it("copies an empty set", function()
      t.expect(ordered.from({} as {string}):copy():is_empty()):to_equal(true)
   end)

   t.it("raises when self is not a Set", function()
      t.expect(function() Set.copy(nil) end):to_error("htlx%.ordered%.Set%.copy: self must be an ordered%.Set")
   end)
end)

t.describe("Set:union", function()
   t.it("is self's order then other's new values, in a new set", function()
      local a = ordered.from({ "c", "a" })
      local b = ordered.from({ "a", "d", "c", "b" })
      local u = a:union(b)
      t.expect(u:values()):to_equal({ "c", "a", "d", "b" })
      t.expect(u == a):to_equal(false)
      t.expect(a:values()):to_equal({ "c", "a" })
      t.expect(b:values()):to_equal({ "a", "d", "c", "b" })
   end)

   t.it("with an empty side is a copy of the other", function()
      local e: ordered.Set<string> = ordered.set()
      local a = ordered.from({ "x", "y" })
      t.expect(a:union(e):values()):to_equal({ "x", "y" })
      t.expect(e:union(a):values()):to_equal({ "x", "y" })
      t.expect(e:union(e):is_empty()):to_equal(true)
   end)

   t.it("raises when a side is not a Set", function()
      local a = ordered.from({ "x" })
      t.expect(function() a:union(nil) end):to_error("htlx%.ordered%.Set%.union: other must be an ordered%.Set, got nil")
      t.expect(function() Set.union(nil, a) end):to_error("htlx%.ordered%.Set%.union: self must be an ordered%.Set, got nil")
   end)
end)

t.describe("Set:intersect", function()
   t.it("keeps self's order, in a new set", function()
      local a = ordered.from({ "d", "b", "a", "c" })
      local b = ordered.from({ "a", "c", "d", "z" })
      t.expect(a:intersect(b):values()):to_equal({ "d", "a", "c" })
      t.expect(b:intersect(a):values()):to_equal({ "a", "c", "d" })
      t.expect(a:values()):to_equal({ "d", "b", "a", "c" })
   end)

   t.it("is empty when nothing is shared or a side is empty", function()
      local e: ordered.Set<string> = ordered.set()
      local a = ordered.from({ "x" })
      t.expect(a:intersect(ordered.from({ "y" })):is_empty()):to_equal(true)
      t.expect(a:intersect(e):is_empty()):to_equal(true)
      t.expect(e:intersect(a):is_empty()):to_equal(true)
   end)

   t.it("raises when other is not a Set", function()
      local a = ordered.from({ "x" })
      t.expect(function() a:intersect(nil) end):to_error("htlx%.ordered%.Set%.intersect: other must be an ordered%.Set, got nil")
   end)
end)

t.describe("Set:difference", function()
   t.it("keeps self's values that other lacks, in self's order", function()
      local a = ordered.from({ "d", "b", "a", "c" })
      local b = ordered.from({ "a", "z" })
      t.expect(a:difference(b):values()):to_equal({ "d", "b", "c" })
      t.expect(b:difference(a):values()):to_equal({ "z" })
      t.expect(a:values()):to_equal({ "d", "b", "a", "c" })
   end)

   t.it("is all of self against an empty set, and empty against itself", function()
      local e: ordered.Set<string> = ordered.set()
      local a = ordered.from({ "x", "y" })
      t.expect(a:difference(e):values()):to_equal({ "x", "y" })
      t.expect(a:difference(a):is_empty()):to_equal(true)
      t.expect(e:difference(a):is_empty()):to_equal(true)
   end)

   t.it("raises when other is not a Set", function()
      local a = ordered.from({ "x" })
      t.expect(function() a:difference(nil) end):to_error("htlx%.ordered%.Set%.difference: other must be an ordered%.Set, got nil")
   end)
end)

t.describe("Set:is_subset", function()
   t.it("is true for a subset, itself, and the empty set", function()
      local e: ordered.Set<string> = ordered.set()
      local a = ordered.from({ "a", "b" })
      local b = ordered.from({ "c", "b", "a" })
      t.expect(a:is_subset(b)):to_equal(true)
      t.expect(a:is_subset(a)):to_equal(true)
      t.expect(e:is_subset(a)):to_equal(true)
      t.expect(e:is_subset(e)):to_equal(true)
   end)

   t.it("is false when a value is missing from other", function()
      local a = ordered.from({ "a", "b" })
      local e: ordered.Set<string> = ordered.set()
      t.expect(ordered.from({ "c", "b", "a" }):is_subset(a)):to_equal(false)
      t.expect(a:is_subset(e)):to_equal(false)
   end)

   t.it("raises when other is not a Set", function()
      local a = ordered.from({ "x" })
      t.expect(function() a:is_subset(nil) end):to_error("htlx%.ordered%.Set%.is_subset: other must be an ordered%.Set, got nil")
   end)
end)

t.describe("Set:to_table", function()
   t.it("is a plain true-map of the values, detached from self", function()
      local s = ordered.from({ "a", "b" })
      local plain = s:to_table()
      t.expect(plain):to_equal({ a = true, b = true })
      t.expect(ordered.is_set(plain)):to_equal(false)
      plain.a = nil
      t.expect(s:has("a")):to_equal(true)
   end)

   t.it("is empty for an empty set", function()
      t.expect(ordered.from({} as {string}):to_table()):to_equal({})
   end)

   t.it("raises when self is not a Set", function()
      t.expect(function() Set.to_table(nil) end):to_error("htlx%.ordered%.Set%.to_table: self must be an ordered%.Set")
   end)
end)
