local t = require("htl.test")
local seq = require("htlx.seq")

t.describe("seq.of", function()
   t.it("yields the elements in order and nil at the end", function()
      local it = seq.of({ "a", "b" })
      t.expect(it()):to_equal("a")
      t.expect(it()):to_equal("b")
      t.expect(it()):to_be_nil()
      t.expect(it()):to_be_nil()
   end)

   t.it("lets false through as an element", function()
      t.expect(seq.collect(seq.of({ false, true, false }))):to_equal({ false, true, false })
   end)

   t.it("is empty for an empty array", function()
      t.expect(seq.of({} as {integer})()):to_be_nil()
   end)

   t.it("raises on a non-table", function()
      t.expect(function() seq.of(nil) end):to_error("htlx%.seq%.of: expected a table, got nil")
   end)
end)

t.describe("seq.keys / values / entries", function()
   t.it("keys yields every key once", function()
      local ks = seq.collect(seq.keys({ a = 1, b = 2, c = 3 }))
      table.sort(ks)
      t.expect(ks):to_equal({ "a", "b", "c" })
   end)

   t.it("values yields every value once", function()
      local vs = seq.collect(seq.values({ a = 1, b = 2, c = 3 }))
      table.sort(vs)
      t.expect(vs):to_equal({ 1, 2, 3 })
   end)

   t.it("entries yields {key, value} tuples", function()
      local es = seq.collect(seq.entries({ a = 1, b = 2 }))
      table.sort(es, function(x: {string, integer}, y: {string, integer}): boolean
         return x[1] < y[1]
      end)
      t.expect(es):to_equal({ { "a", 1 }, { "b", 2 } })
   end)

   t.it("are empty for an empty map", function()
      t.expect(seq.keys({} as {string:integer})()):to_be_nil()
      t.expect(seq.values({} as {string:integer})()):to_be_nil()
      t.expect(seq.entries({} as {string:integer})()):to_be_nil()
   end)

   t.it("raise on a non-table", function()
      t.expect(function() seq.keys(nil) end):to_error("htlx%.seq%.keys: expected a table, got nil")
      t.expect(function() seq.values(nil) end):to_error("htlx%.seq%.values: expected a table, got nil")
      t.expect(function() seq.entries(nil) end):to_error("htlx%.seq%.entries: expected a table, got nil")
   end)
end)

t.describe("seq.range", function()
   t.it("counts up inclusively with step 1", function()
      t.expect(seq.collect(seq.range(1, 4))):to_equal({ 1, 2, 3, 4 })
   end)

   t.it("takes a positive step and stops before overshooting", function()
      t.expect(seq.collect(seq.range(1, 10, 4))):to_equal({ 1, 5, 9 })
   end)

   t.it("counts down with a negative step", function()
      t.expect(seq.collect(seq.range(3, 1, -1))):to_equal({ 3, 2, 1 })
   end)

   t.it("is empty when the step never reaches to", function()
      t.expect(seq.collect(seq.range(5, 1))):to_equal({})
      t.expect(seq.collect(seq.range(1, 5, -1))):to_equal({})
   end)

   t.it("raises on step 0", function()
      t.expect(function() seq.range(1, 5, 0) end):to_error("htlx%.seq%.range: step must not be 0")
   end)

   t.it("raises on a non-integer bound", function()
      t.expect(function() seq.range(1.5 as integer, 5) end):to_error("htlx%.seq%.range: from must be an integer, got float")
      t.expect(function() seq.range(1, nil) end):to_error("htlx%.seq%.range: to must be an integer, got nil")
   end)
end)

t.describe("seq.iterate", function()
   t.it("is endless until take cuts it", function()
      local pow = seq.iterate(1, function(x: integer): integer return x * 2 end)
      t.expect(seq.collect(seq.take(pow, 5))):to_equal({ 1, 2, 4, 8, 16 })
   end)

   t.it("starts with init and keeps going", function()
      local it = seq.iterate("a", function(s: string): string return s .. "a" end)
      t.expect(it()):to_equal("a")
      t.expect(it()):to_equal("aa")
      t.expect(it()):to_equal("aaa")
   end)

   t.it("ends when f returns nil", function()
      local it = seq.iterate(3, function(x: integer): integer
         if x == 1 then return nil end
         return x - 1
      end)
      t.expect(seq.collect(it)):to_equal({ 3, 2, 1 })
      t.expect(it()):to_be_nil()
   end)

   t.it("raises when f is not a function", function()
      t.expect(function() seq.iterate(1, nil) end):to_error("htlx%.seq%.iterate: f must be a function, got nil")
   end)
end)

t.describe("seq.map", function()
   t.it("maps each element in order", function()
      local out = seq.collect(seq.map(seq.of({ 1, 2, 3 }), function(v: integer): string
         return "n" .. tostring(v)
      end))
      t.expect(out):to_equal({ "n1", "n2", "n3" })
   end)

   t.it("is lazy: nothing runs until pulled", function()
      local calls = 0
      local it = seq.map(seq.of({ 1, 2 }), function(v: integer): integer
         calls = calls + 1
         return v
      end)
      t.expect(calls):to_equal(0)
      it()
      t.expect(calls):to_equal(1)
   end)

   t.it("is empty over an empty sequence", function()
      t.expect(seq.collect(seq.map(seq.of({} as {integer}), function(v: integer): integer return v end))):to_equal({})
   end)

   t.it("raises when f returns nil", function()
      local it = seq.map(seq.of({ 1, 2 }), function(v: integer): integer
         if v == 2 then return nil end
         return v
      end)
      t.expect(it()):to_equal(1)
      t.expect(function() it() end):to_error("htlx%.seq%.map: f returned nil")
   end)

   t.it("raises when it is not an iterator", function()
      t.expect(function() seq.map(nil, function(v: integer): integer return v end) end):to_error("htlx%.seq%.map: it must be an iterator %(a function%), got nil")
   end)

   t.it("raises when f is not a function", function()
      t.expect(function() seq.map(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.map: f must be a function, got nil")
   end)
end)

t.describe("seq.filter / filter_map", function()
   t.it("filter keeps accepted elements in order", function()
      local out = seq.collect(seq.filter(seq.range(1, 6), function(v: integer): boolean
         return v % 2 == 0
      end))
      t.expect(out):to_equal({ 2, 4, 6 })
   end)

   t.it("filter is empty when nothing is accepted", function()
      t.expect(seq.collect(seq.filter(seq.range(1, 3), function(): boolean return false end))):to_equal({})
   end)

   t.it("filter raises when pred is not a function", function()
      t.expect(function() seq.filter(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.filter: pred must be a function, got nil")
   end)

   t.it("filter_map drops nil and keeps the rest", function()
      local out = seq.collect(seq.filter_map(seq.range(1, 4), function(v: integer): string
         if v % 2 == 0 then return "e" .. tostring(v) end
         return nil
      end))
      t.expect(out):to_equal({ "e2", "e4" })
   end)

   t.it("filter_map is empty when f returns nil everywhere", function()
      t.expect(seq.collect(seq.filter_map(seq.range(1, 3), function(): string return nil end))):to_equal({})
   end)

   t.it("filter_map raises when it is not an iterator", function()
      local not_an_iter = { 1 } as any
      t.expect(function() seq.filter_map(not_an_iter as (function(): integer), function(v: integer): integer return v end) end):to_error("htlx%.seq%.filter_map: it must be an iterator %(a function%), got table")
   end)
end)

t.describe("seq.flat_map", function()
   t.it("flattens the arrays in order", function()
      local out = seq.collect(seq.flat_map(seq.of({ 1, 2, 3 }), function(v: integer): {integer}
         return { v, v * 10 }
      end))
      t.expect(out):to_equal({ 1, 10, 2, 20, 3, 30 })
   end)

   t.it("skips empty arrays", function()
      local out = seq.collect(seq.flat_map(seq.of({ 1, 2, 3 }), function(v: integer): {integer}
         if v == 2 then return {} end
         return { v }
      end))
      t.expect(out):to_equal({ 1, 3 })
   end)

   t.it("is empty over an empty sequence", function()
      t.expect(seq.collect(seq.flat_map(seq.of({} as {integer}), function(v: integer): {integer} return { v } end))):to_equal({})
   end)

   t.it("raises when f does not return a table", function()
      local it = seq.flat_map(seq.of({ 1 }), function(v: integer): {integer} return v as any as {integer} end)
      t.expect(function() it() end):to_error("htlx%.seq%.flat_map: f must return an array, got number")
   end)
end)

t.describe("seq.take / drop", function()
   t.it("take yields the first n and pulls nothing more", function()
      local pulled = 0
      local src = function(): integer
         pulled = pulled + 1
         return pulled
      end
      t.expect(seq.collect(seq.take(src, 3))):to_equal({ 1, 2, 3 })
      t.expect(pulled):to_equal(3)
   end)

   t.it("take yields everything when n is larger", function()
      t.expect(seq.collect(seq.take(seq.of({ 1, 2 }), 5))):to_equal({ 1, 2 })
   end)

   t.it("take 0 is empty", function()
      t.expect(seq.take(seq.of({ 1, 2 }), 0)()):to_be_nil()
   end)

   t.it("take raises on a negative or non-integer n", function()
      t.expect(function() seq.take(seq.of({ 1 }), -1) end):to_error("htlx%.seq%.take: n must be at least 0, got %-1")
      t.expect(function() seq.take(seq.of({ 1 }), 1.5 as integer) end):to_error("htlx%.seq%.take: n must be an integer, got float")
   end)

   t.it("drop skips the first n", function()
      t.expect(seq.collect(seq.drop(seq.range(1, 5), 2))):to_equal({ 3, 4, 5 })
   end)

   t.it("drop is empty when n covers the sequence", function()
      t.expect(seq.collect(seq.drop(seq.range(1, 2), 2))):to_equal({})
      t.expect(seq.collect(seq.drop(seq.range(1, 2), 9))):to_equal({})
   end)

   t.it("drop raises when it is not an iterator", function()
      t.expect(function() seq.drop(nil, 1) end):to_error("htlx%.seq%.drop: it must be an iterator %(a function%), got nil")
   end)
end)

t.describe("seq.take_while / drop_while", function()
   t.it("take_while stops at the first rejected element", function()
      local out = seq.collect(seq.take_while(seq.of({ 1, 2, 5, 1 }), function(v: integer): boolean
         return v < 3
      end))
      t.expect(out):to_equal({ 1, 2 })
   end)

   t.it("take_while cuts an endless sequence", function()
      local nat = seq.iterate(1, function(x: integer): integer return x + 1 end)
      t.expect(seq.collect(seq.take_while(nat, function(v: integer): boolean return v <= 4 end))):to_equal({ 1, 2, 3, 4 })
   end)

   t.it("take_while is empty when the first element is rejected", function()
      t.expect(seq.collect(seq.take_while(seq.of({ 5, 1 }), function(v: integer): boolean return v < 3 end))):to_equal({})
   end)

   t.it("drop_while keeps from the first rejected element on", function()
      local out = seq.collect(seq.drop_while(seq.of({ 1, 2, 5, 1 }), function(v: integer): boolean
         return v < 3
      end))
      t.expect(out):to_equal({ 5, 1 })
   end)

   t.it("drop_while is empty when everything is accepted", function()
      t.expect(seq.collect(seq.drop_while(seq.of({ 1, 2 }), function(): boolean return true end))):to_equal({})
   end)

   t.it("raise when pred is not a function", function()
      t.expect(function() seq.take_while(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.take_while: pred must be a function, got nil")
      t.expect(function() seq.drop_while(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.drop_while: pred must be a function, got nil")
   end)
end)

t.describe("seq.zip", function()
   t.it("pairs element by element", function()
      t.expect(seq.collect(seq.zip(seq.of({ 1, 2 }), seq.of({ "a", "b" })))):to_equal({ { 1, "a" }, { 2, "b" } })
   end)

   t.it("ends with the shorter side, either way round", function()
      t.expect(seq.collect(seq.zip(seq.of({ 1, 2, 3 }), seq.of({ "a" })))):to_equal({ { 1, "a" } })
      t.expect(seq.collect(seq.zip(seq.of({ 1 }), seq.of({ "a", "b", "c" })))):to_equal({ { 1, "a" } })
   end)

   t.it("cuts an endless side", function()
      local nat = seq.iterate(1, function(x: integer): integer return x + 1 end)
      t.expect(seq.collect(seq.zip(nat, seq.of({ "a", "b" })))):to_equal({ { 1, "a" }, { 2, "b" } })
   end)

   t.it("is empty when a side is empty", function()
      t.expect(seq.zip(seq.of({} as {integer}), seq.of({ "a" }))()):to_be_nil()
   end)

   t.it("raises when a side is not an iterator", function()
      t.expect(function() seq.zip(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.zip: b must be an iterator %(a function%), got nil")
   end)
end)

t.describe("seq.enumerate", function()
   t.it("yields 1-based positions in a for loop", function()
      local seen: {string} = {}
      for i, v in seq.enumerate(seq.of({ "a", "b" })) do
         seen[#seen + 1] = tostring(i) .. v
      end
      t.expect(seen):to_equal({ "1a", "2b" })
   end)

   t.it("yields nothing for an empty sequence", function()
      local n = 0
      for _ in seq.enumerate(seq.of({} as {string})) do
         n = n + 1
      end
      t.expect(n):to_equal(0)
   end)

   t.it("raises when it is not an iterator", function()
      t.expect(function() seq.enumerate(nil) end):to_error("htlx%.seq%.enumerate: it must be an iterator %(a function%), got nil")
   end)
end)

t.describe("seq.chain", function()
   t.it("runs the iterators one after the other", function()
      t.expect(seq.collect(seq.chain(seq.of({ 1 }), seq.of({} as {integer}), seq.of({ 2, 3 })))):to_equal({ 1, 2, 3 })
   end)

   t.it("does not pull a later iterator before the earlier one ends", function()
      local pulled = false
      local late = function(): integer
         pulled = true
         return nil
      end
      local it = seq.chain(seq.of({ 1, 2 }), late)
      t.expect(it()):to_equal(1)
      t.expect(pulled):to_equal(false)
      t.expect(seq.collect(it)):to_equal({ 2 })
      t.expect(pulled):to_equal(true)
   end)

   t.it("is empty with no arguments", function()
      t.expect(seq.chain()()):to_be_nil()
   end)

   t.it("raises when an argument is not an iterator", function()
      t.expect(function() seq.chain(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.chain: argument 2 must be an iterator %(a function%), got nil")
   end)
end)

t.describe("seq.collect / count", function()
   t.it("collect drains into a new array", function()
      t.expect(seq.collect(seq.range(1, 3))):to_equal({ 1, 2, 3 })
   end)

   t.it("collect leaves the source array alone", function()
      local src = { 1, 2 }
      local out = seq.collect(seq.of(src))
      t.expect(out):to_equal(src)
      t.expect(out == src):to_equal(false)
   end)

   t.it("count counts elements", function()
      t.expect(seq.count(seq.range(1, 10))):to_equal(10)
      t.expect(seq.count(seq.of({} as {integer}))):to_equal(0)
   end)

   t.it("raise when it is not an iterator", function()
      t.expect(function() seq.collect(nil) end):to_error("htlx%.seq%.collect: it must be an iterator %(a function%), got nil")
      t.expect(function() seq.count(nil) end):to_error("htlx%.seq%.count: it must be an iterator %(a function%), got nil")
   end)
end)

t.describe("seq.fold", function()
   t.it("folds left with the accumulator first", function()
      local out = seq.fold(seq.of({ "a", "b", "c" }), "", function(acc: string, v: string): string
         return acc .. v
      end)
      t.expect(out):to_equal("abc")
   end)

   t.it("returns init for an empty sequence", function()
      t.expect(seq.fold(seq.of({} as {integer}), 7, function(acc: integer, v: integer): integer return acc + v end)):to_equal(7)
   end)

   t.it("raises when f is not a function", function()
      t.expect(function() seq.fold(seq.of({ 1 }), 0, nil) end):to_error("htlx%.seq%.fold: f must be a function, got nil")
   end)
end)

t.describe("seq.any / all / find", function()
   t.it("any stops at the first hit", function()
      local it = seq.of({ 1, 2, 3 })
      t.expect(seq.any(it, function(v: integer): boolean return v == 2 end)):to_equal(true)
      t.expect(it()):to_equal(3)
   end)

   t.it("any is false when nothing matches or the sequence is empty", function()
      t.expect(seq.any(seq.of({ 1, 3 }), function(v: integer): boolean return v == 2 end)):to_equal(false)
      t.expect(seq.any(seq.of({} as {integer}), function(): boolean return true end)):to_equal(false)
   end)

   t.it("all stops at the first miss", function()
      local it = seq.of({ 2, 3, 4 })
      t.expect(seq.all(it, function(v: integer): boolean return v % 2 == 0 end)):to_equal(false)
      t.expect(it()):to_equal(4)
   end)

   t.it("all is true when everything matches or the sequence is empty", function()
      t.expect(seq.all(seq.of({ 2, 4 }), function(v: integer): boolean return v % 2 == 0 end)):to_equal(true)
      t.expect(seq.all(seq.of({} as {integer}), function(): boolean return false end)):to_equal(true)
   end)

   t.it("find returns the first match and leaves the rest", function()
      local it = seq.of({ 1, 2, 3 })
      t.expect(seq.find(it, function(v: integer): boolean return v > 1 end)):to_equal(2)
      t.expect(it()):to_equal(3)
   end)

   t.it("find is nil when nothing matches", function()
      t.expect(seq.find(seq.of({ 1, 2 }), function(v: integer): boolean return v > 5 end)):to_be_nil()
   end)

   t.it("find searches an endless sequence", function()
      local nat = seq.iterate(1, function(x: integer): integer return x + 1 end)
      t.expect(seq.find(nat, function(v: integer): boolean return v * v > 50 end)):to_equal(8)
   end)

   t.it("raise when pred is not a function", function()
      t.expect(function() seq.any(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.any: pred must be a function, got nil")
      t.expect(function() seq.all(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.all: pred must be a function, got nil")
      t.expect(function() seq.find(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.find: pred must be a function, got nil")
   end)
end)

t.describe("seq.each", function()
   t.it("calls f on every element in order", function()
      local seen: {integer} = {}
      seq.each(seq.range(1, 3), function(v: integer)
         seen[#seen + 1] = v
      end)
      t.expect(seen):to_equal({ 1, 2, 3 })
   end)

   t.it("calls nothing on an empty sequence", function()
      local n = 0
      seq.each(seq.of({} as {integer}), function() n = n + 1 end)
      t.expect(n):to_equal(0)
   end)

   t.it("raises when f is not a function", function()
      t.expect(function() seq.each(seq.of({ 1 }), nil) end):to_error("htlx%.seq%.each: f must be a function, got nil")
   end)
end)

t.describe("seq.to_map", function()
   t.it("builds a map from {key, value} tuples", function()
      t.expect(seq.to_map(seq.of({ { "a", 1 }, { "b", 2 } }))):to_equal({ a = 1, b = 2 })
   end)

   t.it("is the inverse of entries", function()
      local src = { x = 1, y = 2, z = 3 }
      t.expect(seq.to_map(seq.entries(src))):to_equal(src)
   end)

   t.it("lets a later key win", function()
      t.expect(seq.to_map(seq.of({ { "a", 1 }, { "a", 2 } }))):to_equal({ a = 2 })
   end)

   t.it("is empty for an empty sequence", function()
      t.expect(seq.to_map(seq.of({} as {{string, integer}}))):to_equal({})
   end)

   t.it("raises on a nil key or a non-table element", function()
      t.expect(function() seq.to_map(seq.of({ { nil, 1 } as {string, integer} })) end):to_error("htlx%.seq%.to_map: element 1 has a nil key")
      t.expect(function() seq.to_map(seq.of({ 1 } as any as {{string, integer}})) end):to_error("htlx%.seq%.to_map: element 1 must be a {key, value} tuple, got number")
   end)
end)

t.describe("pipelines", function()
   t.it("compose across entry, transforms and exit", function()
      local total = seq.fold(
         seq.take(
            seq.filter(seq.iterate(1, function(x: integer): integer return x + 1 end), function(v: integer): boolean
         return v % 3 == 0
            end),
            4
         ),
         0,
         function(acc: integer, v: integer): integer return acc + v end
      )
      t.expect(total):to_equal(3 + 6 + 9 + 12)
   end)

   t.it("carry entries through map into to_map", function()
      local out = seq.to_map(seq.map(seq.entries({ a = 1, b = 2 }), function(e: {string, integer}): {string, integer}
         local r: {string, integer} = { e[1] .. "!", e[2] * 10 }
         return r
      end))
      t.expect(out):to_equal({ ["a!"] = 10, ["b!"] = 20 })
   end)
end)
