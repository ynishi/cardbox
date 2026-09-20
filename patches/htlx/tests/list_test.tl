local t = require("htl.test")
local list = require("htlx.list")

t.describe("list.push / pop", function()
   t.it("pushes to the end and returns the same array", function()
      local xs = { 1, 2 }
      local back = list.push(xs, 3)
      t.expect(xs):to_equal({ 1, 2, 3 })
      t.expect(back == xs):to_equal(true)
   end)

   t.it("refuses nil", function()
      t.expect(function() list.push({ 1 }, nil) end):to_error("htlx%.list%.push: refusing to push nil")
   end)

   t.it("pops from the end", function()
      local xs = { 1, 2, 3 }
      t.expect(list.pop(xs)):to_equal(3)
      t.expect(xs):to_equal({ 1, 2 })
   end)

   t.it("pops nil from an empty array", function()
      t.expect(list.pop({} as {integer})):to_be_nil()
   end)

   t.it("raises on a non-table", function()
      t.expect(function() list.push(nil, 1) end):to_error("htlx%.list%.push: expected an array, got nil")
   end)
end)

t.describe("list.concat", function()
   t.it("joins two arrays into a new one", function()
      local a = { 1, 2 }
      local b = { 3 }
      t.expect(list.concat(a, b)):to_equal({ 1, 2, 3 })
      t.expect(a):to_equal({ 1, 2 })
      t.expect(b):to_equal({ 3 })
   end)

   t.it("handles empty sides", function()
      t.expect(list.concat({} as {integer}, { 1 })):to_equal({ 1 })
      t.expect(list.concat({ 1 }, {} as {integer})):to_equal({ 1 })
   end)
end)

t.describe("list.index_of / contains", function()
   t.it("finds the first match", function()
      t.expect(list.index_of({ "a", "b", "a" }, "a")):to_equal(1)
      t.expect(list.index_of({ "a", "b", "a" }, "b")):to_equal(2)
   end)

   t.it("is nil / false when absent", function()
      t.expect(list.index_of({ "a" }, "z")):to_be_nil()
      t.expect(list.contains({ "a" }, "z")):to_equal(false)
      t.expect(list.contains({ "a" }, "a")):to_equal(true)
   end)
end)

t.describe("list.map", function()
   t.it("maps in order with the index", function()
      local out = list.map({ "a", "b" }, function(v: string, i: integer): string
         return v .. tostring(i)
      end)
      t.expect(out):to_equal({ "a1", "b2" })
   end)

   t.it("raises when f returns nil", function()
      t.expect(function()
         list.map({ 1, 2 }, function(v: integer): integer
            if v == 2 then return nil end
            return v
         end)
      end):to_error("htlx%.list%.map: f returned nil at index 2")
   end)

   t.it("raises when f is not a function", function()
      t.expect(function() list.map({ 1 }, nil) end):to_error("htlx%.list%.map: f must be a function, got nil")
   end)
end)

t.describe("list.filter / filter_map", function()
   t.it("keeps accepted elements in order", function()
      local out = list.filter({ 1, 2, 3, 4 }, function(v: integer): boolean
         return v % 2 == 0
      end)
      t.expect(out):to_equal({ 2, 4 })
   end)

   t.it("passes the index", function()
      local out = list.filter({ "a", "b", "c" }, function(_: string, i: integer): boolean
         return i ~= 2
      end)
      t.expect(out):to_equal({ "a", "c" })
   end)

   t.it("filter_map drops nil and packs the rest", function()
      local out = list.filter_map({ 1, 2, 3, 4 }, function(v: integer): string
         if v % 2 == 0 then return "e" .. tostring(v) end
         return nil
      end)
      t.expect(out):to_equal({ "e2", "e4" })
   end)
end)

t.describe("list.to_set", function()
   t.it("makes every element a true key", function()
      t.expect(list.to_set({ "a", "b" })):to_equal({ a = true, b = true })
   end)

   t.it("is empty for an empty array", function()
      t.expect(list.to_set({} as {string})):to_equal({})
   end)
end)

t.describe("list.copy / reverse / sorted", function()
   t.it("copies to a different table", function()
      local src = { 1, 2 }
      local dst = list.copy(src)
      t.expect(dst):to_equal(src)
      t.expect(dst == src):to_equal(false)
   end)

   t.it("reverses into a new array", function()
      local src = { 1, 2, 3 }
      t.expect(list.reverse(src)):to_equal({ 3, 2, 1 })
      t.expect(src):to_equal({ 1, 2, 3 })
   end)

   t.it("sorts into a new array", function()
      local src = { 3, 1, 2 }
      t.expect(list.sorted(src)):to_equal({ 1, 2, 3 })
      t.expect(src):to_equal({ 3, 1, 2 })
   end)

   t.it("sorts with a comparator", function()
      local out = list.sorted({ 3, 1, 2 }, function(a: integer, b: integer): boolean
         return a > b
      end)
      t.expect(out):to_equal({ 3, 2, 1 })
   end)
end)

t.describe("list.flat_map / each", function()
   t.it("concatenates what f returns", function()
      local out = list.flat_map({ 1, 2 }, function(n: integer): {integer}
         return { n, n * 10 }
      end)
      t.expect(out):to_equal({ 1, 10, 2, 20 })
   end)

   t.it("drops an element whose f returns an empty array", function()
      local out = list.flat_map({ 1, 2, 3 }, function(n: integer): {integer}
         if n == 2 then return {} end
         return { n }
      end)
      t.expect(out):to_equal({ 1, 3 })
   end)

   t.it("raises when f does not return an array", function()
      t.expect(function()
         list.flat_map({ 1 }, function(_: integer): {integer} return nil end)
      end):to_error("htlx%.list%.flat_map: f must return an array")
   end)

   t.it("each visits in order with the index", function()
      local seen: {string} = {}
      list.each({ "a", "b" }, function(v: string, i: integer)
         seen[#seen + 1] = i .. v
      end)
      t.expect(seen):to_equal({ "1a", "2b" })
   end)
end)

t.describe("list.fold / any / all", function()
   t.it("folds from the left with the index", function()
      local out = list.fold({ "a", "b" }, "", function(acc: string, v: string, i: integer): string
         return acc .. v .. i
      end)
      t.expect(out):to_equal("a1b2")
   end)

   t.it("fold of an empty array is init", function()
      t.expect(list.fold({} as {integer}, 7, function(a: integer, n: integer): integer return a + n end)):to_equal(7)
   end)

   t.it("any is false on empty, true when one matches", function()
      local even = function(n: integer): boolean return n % 2 == 0 end
      t.expect(list.any({} as {integer}, even)):to_equal(false)
      t.expect(list.any({ 1, 3 }, even)):to_equal(false)
      t.expect(list.any({ 1, 2 }, even)):to_equal(true)
   end)

   t.it("all is true on empty, false when one fails", function()
      local even = function(n: integer): boolean return n % 2 == 0 end
      t.expect(list.all({} as {integer}, even)):to_equal(true)
      t.expect(list.all({ 2, 4 }, even)):to_equal(true)
      t.expect(list.all({ 2, 3 }, even)):to_equal(false)
   end)

   t.it("raises when pred is not a function", function()
      t.expect(function() list.any({ 1 }, nil) end):to_error("htlx%.list%.any: pred must be a function")
   end)
end)

t.describe("list.find / find_index / last_index_of / enumerate", function()
   t.it("finds the first match and its index", function()
      local big = function(n: integer): boolean return n > 1 end
      t.expect(list.find({ 1, 2, 3 }, big)):to_equal(2)
      t.expect(list.find_index({ 1, 2, 3 }, big)):to_equal(2)
   end)

   t.it("is nil when nothing matches", function()
      local never = function(_: integer): boolean return false end
      t.expect(list.find({ 1 }, never)):to_be_nil()
      t.expect(list.find_index({ 1 }, never)):to_be_nil()
   end)

   t.it("last_index_of finds the last match", function()
      t.expect(list.last_index_of({ "a", "b", "a" }, "a")):to_equal(3)
      t.expect(list.last_index_of({ "a" }, "z")):to_be_nil()
   end)

   t.it("enumerate is ipairs", function()
      local seen: {string} = {}
      for i, v in list.enumerate({ "x", "y" }) do
         seen[#seen + 1] = i .. v
      end
      t.expect(seen):to_equal({ "1x", "2y" })
   end)
end)

t.describe("list.take / drop / take_while / drop_while / slice / chunk", function()
   t.it("take and drop split at n", function()
      t.expect(list.take({ 1, 2, 3 }, 2)):to_equal({ 1, 2 })
      t.expect(list.drop({ 1, 2, 3 }, 2)):to_equal({ 3 })
   end)

   t.it("take and drop past the end", function()
      t.expect(list.take({ 1 }, 5)):to_equal({ 1 })
      t.expect(list.drop({ 1 }, 5)):to_equal({})
      t.expect(list.take({ 1 }, 0)):to_equal({})
      t.expect(list.drop({ 1 }, 0)):to_equal({ 1 })
   end)

   t.it("take and drop refuse a negative n", function()
      t.expect(function() list.take({ 1 }, -1) end):to_error("htlx%.list%.take: n must not be negative")
      t.expect(function() list.drop({ 1 }, -1) end):to_error("htlx%.list%.drop: n must not be negative")
   end)

   t.it("take_while and drop_while split at the first false", function()
      local small = function(n: integer): boolean return n < 3 end
      t.expect(list.take_while({ 1, 2, 3, 1 }, small)):to_equal({ 1, 2 })
      t.expect(list.drop_while({ 1, 2, 3, 1 }, small)):to_equal({ 3, 1 })
   end)

   t.it("slice counts like string.sub", function()
      local xs = { 1, 2, 3, 4, 5 }
      t.expect(list.slice(xs, 2, 4)):to_equal({ 2, 3, 4 })
      t.expect(list.slice(xs, 4)):to_equal({ 4, 5 })
      t.expect(list.slice(xs, -2)):to_equal({ 4, 5 })
      t.expect(list.slice(xs, 2, -2)):to_equal({ 2, 3, 4 })
      t.expect(list.slice(xs, 4, 2)):to_equal({})
      t.expect(list.slice(xs, 9)):to_equal({})
   end)

   t.it("chunk cuts into n-sized pieces with a short tail", function()
      t.expect(list.chunk({ 1, 2, 3, 4, 5 }, 2)):to_equal({ { 1, 2 }, { 3, 4 }, { 5 } })
      t.expect(list.chunk({} as {integer}, 2)):to_equal({})
   end)

   t.it("chunk refuses n below 1", function()
      t.expect(function() list.chunk({ 1 }, 0) end):to_error("htlx%.list%.chunk: n must be at least 1")
   end)
end)

t.describe("list.sorted_by / min / max / min_by / max_by", function()
   t.it("sorted_by sorts by the key and leaves the input alone", function()
      local src = { "ccc", "a", "bb" }
      local out = list.sorted_by(src, function(s: string): integer return #s end)
      t.expect(out):to_equal({ "a", "bb", "ccc" })
      t.expect(src):to_equal({ "ccc", "a", "bb" })
   end)

   t.it("sorted_by takes a comparator on the keys", function()
      local out = list.sorted_by({ "ccc", "a", "bb" }, function(s: string): integer return #s end, function(a: integer, b: integer): boolean
         return a > b
      end)
      t.expect(out):to_equal({ "ccc", "bb", "a" })
   end)

   t.it("min and max by < and by a comparator", function()
      t.expect(list.min({ 3, 1, 2 })):to_equal(1)
      t.expect(list.max({ 3, 1, 2 })):to_equal(3)
      t.expect(list.min({ 3, 1, 2 }, function(a: integer, b: integer): boolean return a > b end)):to_equal(3)
   end)

   t.it("min and max are nil on empty", function()
      t.expect(list.min({} as {integer})):to_be_nil()
      t.expect(list.max({} as {integer})):to_be_nil()
   end)

   t.it("min_by and max_by pick by the key, first of equals", function()
      local len = function(s: string): integer return #s end
      t.expect(list.min_by({ "ccc", "a", "bb", "z" }, len)):to_equal("a")
      t.expect(list.max_by({ "ccc", "a", "bb", "ddd" }, len)):to_equal("ccc")
      t.expect(list.min_by({} as {string}, len)):to_be_nil()
   end)

   t.it("raises when key is not a function", function()
      t.expect(function() list.sorted_by({ 1 }, nil) end):to_error("htlx%.list%.sorted_by: key must be a function")
   end)
end)

t.describe("list.sum / sum_of / binary_search", function()
   t.it("sums numbers, zero on empty", function()
      t.expect(list.sum({ 1, 2, 3.5 })):to_equal(6.5)
      t.expect(list.sum({})):to_equal(0)
   end)

   t.it("sum_of sums the key", function()
      t.expect(list.sum_of({ "a", "bb" }, function(s: string): number return #s end)):to_equal(3)
   end)

   t.it("binary_search finds in a sorted array and is nil otherwise", function()
      t.expect(list.binary_search({ 1, 3, 5, 7 }, 5)):to_equal(3)
      t.expect(list.binary_search({ 1, 3, 5, 7 }, 1)):to_equal(1)
      t.expect(list.binary_search({ 1, 3, 5, 7 }, 4)):to_be_nil()
      t.expect(list.binary_search({} as {integer}, 4)):to_be_nil()
   end)

   t.it("binary_search takes the comparator the array was sorted with", function()
      local desc = function(a: integer, b: integer): boolean return a > b end
      t.expect(list.binary_search({ 7, 5, 3, 1 }, 3, desc)):to_equal(3)
   end)
end)

t.describe("list.flatten / zip / unzip / range / join / fill", function()
   t.it("flatten one level", function()
      t.expect(list.flatten({ { 1, 2 }, {}, { 3 } })):to_equal({ 1, 2, 3 })
      t.expect(list.flatten({} as {{integer}})):to_equal({})
   end)

   t.it("flatten raises on a non-array element", function()
      t.expect(function() list.flatten({ { 1 }, nil, { 2 } } as {{integer}}) end):to_error("htlx%.list%.flatten: element")
   end)

   t.it("zip pairs up to the shorter, unzip undoes it", function()
      local z = list.zip({ "a", "b", "c" }, { 1, 2 })
      t.expect(z):to_equal({ { "a", 1 }, { "b", 2 } })
      local a, b = list.unzip(z)
      t.expect(a):to_equal({ "a", "b" })
      t.expect(b):to_equal({ 1, 2 })
   end)

   t.it("range counts up, down, and by step", function()
      t.expect(list.range(1, 4)):to_equal({ 1, 2, 3, 4 })
      t.expect(list.range(3, 1, -1)):to_equal({ 3, 2, 1 })
      t.expect(list.range(1, 6, 2)):to_equal({ 1, 3, 5 })
      t.expect(list.range(4, 1)):to_equal({})
   end)

   t.it("range refuses a zero step", function()
      t.expect(function() list.range(1, 2, 0) end):to_error("htlx%.list%.range: step must not be zero")
   end)

   t.it("join uses tostring, or f, with the separator", function()
      t.expect(list.join({ 1, true, "x" } as {any}, ", ")):to_equal("1, true, x")
      t.expect(list.join({ "a", "b" })):to_equal("ab")
      t.expect(list.join({ 1, 2 }, "-", function(n: integer): string return "n" .. n end)):to_equal("n1-n2")
      t.expect(list.join({} as {integer}, ",")):to_equal("")
   end)

   t.it("fill repeats v n times and refuses nil", function()
      t.expect(list.fill(3, "x")):to_equal({ "x", "x", "x" })
      t.expect(list.fill(0, "x")):to_equal({})
      t.expect(function() list.fill(2, nil) end):to_error("htlx%.list%.fill: refusing to fill with nil")
   end)
end)

t.describe("list.partition / group_by / uniq / uniq_by", function()
   t.it("partition splits by the predicate in order", function()
      local yes, no = list.partition({ 1, 2, 3, 4 }, function(n: integer): boolean return n % 2 == 0 end)
      t.expect(yes):to_equal({ 2, 4 })
      t.expect(no):to_equal({ 1, 3 })
   end)

   t.it("group_by groups by the key in order", function()
      local g = list.group_by({ "aa", "b", "cc", "d" }, function(s: string): integer return #s end)
      t.expect(g):to_equal({ [1] = { "b", "d" }, [2] = { "aa", "cc" } })
   end)

   t.it("group_by raises on a nil key", function()
      t.expect(function()
         list.group_by({ 1 }, function(_: integer): string return nil end)
      end):to_error("htlx%.list%.group_by: key returned nil")
   end)

   t.it("uniq drops every repeat, not only adjacent ones", function()
      t.expect(list.uniq({ 1, 2, 1, 3, 2 })):to_equal({ 1, 2, 3 })
      t.expect(list.uniq({} as {integer})):to_equal({})
   end)

   t.it("uniq_by keeps the first with each key", function()
      local out = list.uniq_by({ "aa", "b", "cc", "d" }, function(s: string): integer return #s end)
      t.expect(out):to_equal({ "aa", "b" })
   end)
end)

t.describe("list.union / intersect / difference", function()
   t.it("union keeps the left order then the new ones", function()
      t.expect(list.union({ 1, 2, 2 }, { 3, 2, 4 })):to_equal({ 1, 2, 3, 4 })
   end)

   t.it("intersect keeps what both have, in the left order, once", function()
      t.expect(list.intersect({ 3, 1, 2, 1 }, { 1, 3 })):to_equal({ 3, 1 })
      t.expect(list.intersect({ 1 }, {} as {integer})):to_equal({})
   end)

   t.it("difference keeps what only the left has", function()
      t.expect(list.difference({ 1, 2, 3, 1 }, { 2 })):to_equal({ 1, 3 })
   end)
end)

t.describe("list.shuffle / sample", function()
   t.it("shuffle permutes in place with the given rng", function()
      local xs = { 1, 2, 3, 4 }
      local back = list.shuffle(xs, function(n: integer): integer return n end)
      t.expect(back == xs):to_equal(true)
      t.expect(list.sorted(xs)):to_equal({ 1, 2, 3, 4 })
      -- rng(n) = n swaps each element with itself: the order is kept, which is a
      -- permutation like any other and the one this rng pins down.
      t.expect(xs):to_equal({ 1, 2, 3, 4 })
   end)

   t.it("shuffle with rng(n) = 1 rotates", function()
      local xs = { 1, 2, 3 }
      list.shuffle(xs, function(_: integer): integer return 1 end)
      t.expect(xs):to_equal({ 2, 3, 1 })
   end)

   t.it("sample picks by the rng and is nil on empty", function()
      t.expect(list.sample({ "a", "b", "c" }, function(_: integer): integer return 2 end)):to_equal("b")
      t.expect(list.sample({} as {string})):to_be_nil()
   end)

   t.it("sample without an rng returns an element", function()
      local xs = { "a", "b" }
      t.expect(list.contains(xs, list.sample(xs))):to_equal(true)
   end)
end)

t.describe("list.equals / is_empty / len", function()
   t.it("equals compares length and elements", function()
      t.expect(list.equals({ 1, 2 }, { 1, 2 })):to_equal(true)
      t.expect(list.equals({ 1, 2 }, { 1, 3 })):to_equal(false)
      t.expect(list.equals({ 1 }, { 1, 2 })):to_equal(false)
      t.expect(list.equals({} as {integer}, {} as {integer})):to_equal(true)
   end)

   t.it("equals is one level", function()
      t.expect(list.equals({ { 1 } }, { { 1 } })):to_equal(false)
   end)

   t.it("is_empty and len", function()
      t.expect(list.is_empty({} as {integer})):to_equal(true)
      t.expect(list.is_empty({ 1 })):to_equal(false)
      t.expect(list.len({ 1, 2 })):to_equal(2)
   end)
end)
