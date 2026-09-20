--- Functions over arrays (`{T}`).
---
--- Maps (`{K:V}`) are a different type in Teal and have their own module, `htlx.tablex`;
--- a lazy form of most of what is here is `htlx.seq`, and an array that is also a set with
--- an order is `htlx.ordered`.
---
--- Rules every function keeps:
---
--- * An argument that is not what the signature says is a bug in the caller and raises.
---   Nothing returns `nil, err` for that.
--- * No function puts `nil` into an array. `{T}` is a Lua sequence and `#` stops at the
---   first hole, so a `nil` in the middle would silently shorten every later loop. `push`
---   refuses a `nil` value and `map` refuses an `f` that returns one; `filter` and
---   `filter_map` are the way to drop elements.
--- * `push`, `pop` and `shuffle` change the array they are given, because that is what a
---   stack and an in-place shuffle are for. Everything else hands back a new array and
---   leaves its arguments alone. Insertion and removal at a position, and sorting in place,
---   are `table.insert`, `table.remove` and `table.sort`, which Lua already has; there is
---   no second spelling of them here.
--- * A function that looks something up returns it, or `nil` when there is none (`find`,
---   `min`, `pop`, ...). Teal cannot write `T | nil`, so the doc says it where it applies.
--- * `_by` takes a key function, as in Kotlin, Deno and lodash. A comparator is always the
---   last, optional argument, and is `<` — `function(a, b): boolean`, true when `a` sorts
---   first — as `table.sort` takes it. Without one, `<` is used, and elements that `<`
---   cannot compare raise at run time, as `table.sort` would.
local record list
end

local function check_array(t: any, fname: string)
   if type(t) ~= "table" then
      error("htlx.list." .. fname .. ": expected an array, got " .. type(t), 3)
   end
end

local function check_function(f: any, fname: string, what: string)
   if type(f) ~= "function" then
      error("htlx.list." .. fname .. ": " .. what .. " must be a function, got " .. type(f), 3)
   end
end

local function check_integer(n: any, fname: string, what: string)
   if math.type(n) ~= "integer" then
      error("htlx.list." .. fname .. ": " .. what .. " must be an integer, got " .. tostring(n), 3)
   end
end

-- The default order: `<` on whatever the elements are. Teal cannot write `<` on a type
-- variable, so it is written on `any` once and cast to the comparator type at each use.
local function lt(a: any, b: any): boolean
   return (a as number) < (b as number)
end

-- ------------------------------------------------------------------ stack

--- Append `v` to the end of `t` and return `t`. Raises on a `nil` value.
function list.push<T>(t: {T}, v: T): {T}
   check_array(t, "push")
   if v == nil then
      error("htlx.list.push: refusing to push nil (it would put a hole in the array)", 2)
   end
   t[#t + 1] = v
   return t
end

--- Remove the last element of `t` and return it, or `nil` when `t` is empty.
function list.pop<T>(t: {T}): T
   check_array(t, "pop")
   local n = #t
   if n == 0 then
      return nil
   end
   local v = t[n]
   t[n] = nil
   return v
end

--- A shallow copy of `t`: the same elements in the same order, a different table.
function list.copy<T>(t: {T}): {T}
   check_array(t, "copy")
   local out: {T} = {}
   for i = 1, #t do
      out[i] = t[i]
   end
   return out
end

-- ------------------------------------------------------------------ walking

--- A new array holding `f(element, index)` for each element of `t`, in order.
---
--- `f` returning `nil` raises: it would leave a hole (see the module note). Use `filter`
--- first, or `filter_map`, to drop elements.
function list.map<T, R>(t: {T}, f: function(T, integer): R): {R}
   check_array(t, "map")
   check_function(f, "map", "f")
   local out: {R} = {}
   for i = 1, #t do
      local r = f(t[i], i)
      if r == nil then
         error("htlx.list.map: f returned nil at index " .. i .. " (it would put a hole in the array)", 2)
      end
      out[i] = r
   end
   return out
end

--- A new array holding the elements of `t` for which `pred(element, index)` is true,
--- in their original order.
function list.filter<T>(t: {T}, pred: function(T, integer): boolean): {T}
   check_array(t, "filter")
   check_function(pred, "filter", "pred")
   local out: {T} = {}
   for i = 1, #t do
      local v = t[i]
      if pred(v, i) then
         out[#out + 1] = v
      end
   end
   return out
end

--- `map` and `filter` in one pass: a new array holding `f(element, index)` for each element
--- of `t`, skipping the elements for which `f` returned `nil`.
function list.filter_map<T, R>(t: {T}, f: function(T, integer): R): {R}
   check_array(t, "filter_map")
   check_function(f, "filter_map", "f")
   local out: {R} = {}
   for i = 1, #t do
      local r = f(t[i], i)
      if r ~= nil then
         out[#out + 1] = r
      end
   end
   return out
end

--- A new array holding, in order, every element of every array `f(element, index)` returns.
--- `f` returning an empty array drops the element; that is how `flat_map` filters.
function list.flat_map<T, R>(t: {T}, f: function(T, integer): {R}): {R}
   check_array(t, "flat_map")
   check_function(f, "flat_map", "f")
   local out: {R} = {}
   for i = 1, #t do
      local r = f(t[i], i)
      if type(r) ~= "table" then
         error("htlx.list.flat_map: f must return an array, got " .. type(r) .. " at index " .. i, 2)
      end
      for j = 1, #r do
         out[#out + 1] = r[j]
      end
   end
   return out
end

--- Call `f(element, index)` for each element of `t`, in order, for its effect. The same as
--- a `for i, v in ipairs(t)` loop, in the form a function can be handed.
function list.each<T>(t: {T}, f: function(T, integer))
   check_array(t, "each")
   check_function(f, "each", "f")
   for i = 1, #t do
      f(t[i], i)
   end
end

--- Fold `t` from the left: `f(f(f(init, t[1]), t[2]), t[3])`, and so on. The result of an
--- empty array is `init`.
function list.fold<T, A>(t: {T}, init: A, f: function(A, T, integer): A): A
   check_array(t, "fold")
   check_function(f, "fold", "f")
   local acc = init
   for i = 1, #t do
      acc = f(acc, t[i], i)
   end
   return acc
end

--- Whether `pred(element, index)` is true for at least one element. False for an empty
--- array, and stops at the first true.
function list.any<T>(t: {T}, pred: function(T, integer): boolean): boolean
   check_array(t, "any")
   check_function(pred, "any", "pred")
   for i = 1, #t do
      if pred(t[i], i) then
         return true
      end
   end
   return false
end

--- Whether `pred(element, index)` is true for every element. True for an empty array, and
--- stops at the first false.
function list.all<T>(t: {T}, pred: function(T, integer): boolean): boolean
   check_array(t, "all")
   check_function(pred, "all", "pred")
   for i = 1, #t do
      if not pred(t[i], i) then
         return false
      end
   end
   return true
end

--- The first element for which `pred(element, index)` is true, or `nil` when there is none.
--- `find_index` is the same search returning where it was.
function list.find<T>(t: {T}, pred: function(T, integer): boolean): T
   check_array(t, "find")
   check_function(pred, "find", "pred")
   for i = 1, #t do
      if pred(t[i], i) then
         return t[i]
      end
   end
   return nil
end

--- The index of the first element for which `pred(element, index)` is true, or `nil` when
--- there is none.
function list.find_index<T>(t: {T}, pred: function(T, integer): boolean): integer
   check_array(t, "find_index")
   check_function(pred, "find_index", "pred")
   for i = 1, #t do
      if pred(t[i], i) then
         return i
      end
   end
   return nil
end

--- The index of the first element of `t` equal (`==`) to `v`, or `nil` when there is none.
function list.index_of<T>(t: {T}, v: T): integer
   check_array(t, "index_of")
   for i = 1, #t do
      if t[i] == v then
         return i
      end
   end
   return nil
end

--- The index of the last element of `t` equal (`==`) to `v`, or `nil` when there is none.
function list.last_index_of<T>(t: {T}, v: T): integer
   check_array(t, "last_index_of")
   for i = #t, 1, -1 do
      if t[i] == v then
         return i
      end
   end
   return nil
end

--- Whether some element of `t` is equal (`==`) to `v`.
function list.contains<T>(t: {T}, v: T): boolean
   return list.index_of(t, v) ~= nil
end

--- An iterator over `(index, element)`, 1-based, in order: `for i, v in list.enumerate(t)`.
--- It is `ipairs` under another name, here so that the same spelling works on the
--- iterators `htlx.seq` makes.
function list.enumerate<T>(t: {T}): function(): (integer, T)
   check_array(t, "enumerate")
   local i = 0
   return function(): (integer, T)
      i = i + 1
      local v = t[i]
      if v == nil then
         return nil, nil
      end
      return i, v
   end
end

-- ------------------------------------------------------------------ cutting

--- A new array of the first `n` elements of `t`, or all of them when there are fewer.
--- `n` below zero raises.
function list.take<T>(t: {T}, n: integer): {T}
   check_array(t, "take")
   check_integer(n, "take", "n")
   if n < 0 then
      error("htlx.list.take: n must not be negative, got " .. n, 2)
   end
   local out: {T} = {}
   for i = 1, math.min(n, #t) do
      out[i] = t[i]
   end
   return out
end

--- A new array of the elements of `t` after the first `n`, or an empty one when there are
--- no more. `n` below zero raises.
function list.drop<T>(t: {T}, n: integer): {T}
   check_array(t, "drop")
   check_integer(n, "drop", "n")
   if n < 0 then
      error("htlx.list.drop: n must not be negative, got " .. n, 2)
   end
   local out: {T} = {}
   for i = n + 1, #t do
      out[#out + 1] = t[i]
   end
   return out
end

--- A new array of the leading elements of `t` for which `pred(element, index)` is true,
--- stopping at the first one for which it is not.
function list.take_while<T>(t: {T}, pred: function(T, integer): boolean): {T}
   check_array(t, "take_while")
   check_function(pred, "take_while", "pred")
   local out: {T} = {}
   for i = 1, #t do
      if not pred(t[i], i) then
         break
      end
      out[i] = t[i]
   end
   return out
end

--- A new array of the elements of `t` from the first one for which `pred(element, index)`
--- is false, onwards.
function list.drop_while<T>(t: {T}, pred: function(T, integer): boolean): {T}
   check_array(t, "drop_while")
   check_function(pred, "drop_while", "pred")
   local out: {T} = {}
   local dropping = true
   for i = 1, #t do
      if dropping and not pred(t[i], i) then
         dropping = false
      end
      if not dropping then
         out[#out + 1] = t[i]
      end
   end
   return out
end

--- A new array of the elements of `t` from index `from` to index `to`, both included, as
--- `string.sub` counts: a negative index counts from the end (`-1` is the last), `to`
--- defaults to the end, and a range that is empty or lies outside `t` gives an empty array.
function list.slice<T>(t: {T}, from: integer, to?: integer): {T}
   check_array(t, "slice")
   check_integer(from, "slice", "from")
   local n = #t
   local last = to
   if last == nil then
      last = n
   else
      check_integer(last, "slice", "to")
   end
   if from < 0 then
      from = n + from + 1
   end
   if last < 0 then
      last = n + last + 1
   end
   if from < 1 then
      from = 1
   end
   if last > n then
      last = n
   end
   local out: {T} = {}
   for i = from, last do
      out[#out + 1] = t[i]
   end
   return out
end

--- `t` cut into arrays of `n` elements each, in order; the last one is shorter when `#t`
--- is not a multiple of `n`. An empty array gives no chunks. `n` below one raises.
function list.chunk<T>(t: {T}, n: integer): {{T}}
   check_array(t, "chunk")
   check_integer(n, "chunk", "n")
   if n < 1 then
      error("htlx.list.chunk: n must be at least 1, got " .. n, 2)
   end
   local out: {{T}} = {}
   for i = 1, #t, n do
      local c: {T} = {}
      for j = i, math.min(i + n - 1, #t) do
         c[#c + 1] = t[j]
      end
      out[#out + 1] = c
   end
   return out
end

-- ------------------------------------------------------------------ ordering

--- A new array sorted by `cmp`, or by `<` when no comparator is given. `t` is not changed;
--- `table.sort` is the in-place one.
function list.sorted<T>(t: {T}, cmp?: function(T, T): boolean): {T}
   check_array(t, "sorted")
   local out = list.copy(t)
   table.sort(out, cmp)
   return out
end

--- A new array sorted by `key(element)`: by `cmp` on the keys, or by `<` on them when no
--- comparator is given. Each key is computed once. `table.sort` is not stable, so neither
--- is this: elements with equal keys come out in no particular order.
function list.sorted_by<T, K>(t: {T}, key: (function(T): K), cmp?: function(K, K): boolean): {T}
   check_array(t, "sorted_by")
   check_function(key, "sorted_by", "key")
   local less = cmp or (lt as function(K, K): boolean)
   -- Decorate, sort, undecorate: the key of each element beside it, so `key` runs n
   -- times rather than once per comparison.
   local pairs_: {{K, T}} = {}
   for i = 1, #t do
      pairs_[i] = { key(t[i]), t[i] }
   end
   table.sort(pairs_, function(a: {K, T}, b: {K, T}): boolean
      return less(a[1], b[1])
   end)
   local out: {T} = {}
   for i = 1, #pairs_ do
      local p = pairs_[i]
      out[i] = p[2]
   end
   return out
end

--- A new array holding the elements of `t` in reverse order.
function list.reverse<T>(t: {T}): {T}
   check_array(t, "reverse")
   local out: {T} = {}
   local n = #t
   for i = 1, n do
      out[i] = t[n - i + 1]
   end
   return out
end

--- The smallest element by `cmp`, or by `<` when no comparator is given; the first of
--- several equal ones. `nil` for an empty array.
function list.min<T>(t: {T}, cmp?: function(T, T): boolean): T
   check_array(t, "min")
   local less = cmp or (lt as function(T, T): boolean)
   local best: T = nil
   for i = 1, #t do
      if best == nil or less(t[i], best) then
         best = t[i]
      end
   end
   return best
end

--- The largest element by `cmp`, or by `<` when no comparator is given; the first of
--- several equal ones. `nil` for an empty array.
function list.max<T>(t: {T}, cmp?: function(T, T): boolean): T
   check_array(t, "max")
   local less = cmp or (lt as function(T, T): boolean)
   local best: T = nil
   for i = 1, #t do
      if best == nil or less(best, t[i]) then
         best = t[i]
      end
   end
   return best
end

--- The element whose `key(element)` is smallest by `cmp`, or by `<` when no comparator is
--- given; the first of several equal ones. `nil` for an empty array.
function list.min_by<T, K>(t: {T}, key: (function(T): K), cmp?: function(K, K): boolean): T
   check_array(t, "min_by")
   check_function(key, "min_by", "key")
   local less = cmp or (lt as function(K, K): boolean)
   local best: T = nil
   local best_key: K = nil
   for i = 1, #t do
      local k = key(t[i])
      if best == nil or less(k, best_key) then
         best, best_key = t[i], k
      end
   end
   return best
end

--- The element whose `key(element)` is largest by `cmp`, or by `<` when no comparator is
--- given; the first of several equal ones. `nil` for an empty array.
function list.max_by<T, K>(t: {T}, key: (function(T): K), cmp?: function(K, K): boolean): T
   check_array(t, "max_by")
   check_function(key, "max_by", "key")
   local less = cmp or (lt as function(K, K): boolean)
   local best: T = nil
   local best_key: K = nil
   for i = 1, #t do
      local k = key(t[i])
      if best == nil or less(best_key, k) then
         best, best_key = t[i], k
      end
   end
   return best
end

--- The sum of the numbers in `t`; `0` for an empty array. Numbers only: Teal cannot write
--- `+` on a type variable, so `sum_of` is the form for anything else.
function list.sum(t: {number}): number
   check_array(t, "sum")
   local s: number = 0
   for i = 1, #t do
      s = s + t[i]
   end
   return s
end

--- The sum of `key(element)` over `t`; `0` for an empty array.
function list.sum_of<T>(t: {T}, key: function(T): number): number
   check_array(t, "sum_of")
   check_function(key, "sum_of", "key")
   local s: number = 0
   for i = 1, #t do
      s = s + key(t[i])
   end
   return s
end

--- The index of `v` in `t`, which must be sorted by `cmp` (or by `<`), by binary search;
--- `nil` when it is not there. Which index comes back when `v` is there more than once is
--- not specified. On an unsorted array the answer is meaningless, and nothing checks.
function list.binary_search<T>(t: {T}, v: T, cmp?: function(T, T): boolean): integer
   check_array(t, "binary_search")
   local less = cmp or (lt as function(T, T): boolean)
   local lo, hi = 1, #t
   while lo <= hi do
      local mid = (lo + hi) // 2
      local m = t[mid]
      if less(m, v) then
         lo = mid + 1
      elseif less(v, m) then
         hi = mid - 1
      else
         return mid
      end
   end
   return nil
end

-- ------------------------------------------------------------------ combining

--- A new array holding the elements of `a` followed by the elements of `b`.
function list.concat<T>(a: {T}, b: {T}): {T}
   check_array(a, "concat")
   check_array(b, "concat")
   local out: {T} = {}
   for i = 1, #a do
      out[i] = a[i]
   end
   local n = #a
   for i = 1, #b do
      out[n + i] = b[i]
   end
   return out
end

--- A new array of every element of every array in `t`, in order — one level only:
--- `{ {1, 2}, {3} }` becomes `{1, 2, 3}`, and an element that is itself an array of arrays
--- stays one.
function list.flatten<T>(t: {{T}}): {T}
   check_array(t, "flatten")
   local out: {T} = {}
   for i = 1, #t do
      local inner = t[i]
      if type(inner) ~= "table" then
         error("htlx.list.flatten: element " .. i .. " is not an array, got " .. type(inner), 2)
      end
      for j = 1, #inner do
         out[#out + 1] = inner[j]
      end
   end
   return out
end

--- The elements of `a` and `b` side by side: `{ {a[1], b[1]}, {a[2], b[2]}, ... }`, as long
--- as the shorter of the two. `unzip` is the inverse.
function list.zip<A, B>(a: {A}, b: {B}): {{A, B}}
   check_array(a, "zip")
   check_array(b, "zip")
   local out: {{A, B}} = {}
   for i = 1, math.min(#a, #b) do
      out[i] = { a[i], b[i] }
   end
   return out
end

--- Two arrays out of an array of pairs: the firsts and the seconds. `zip` is the inverse.
function list.unzip<A, B>(t: {{A, B}}): {A}, {B}
   check_array(t, "unzip")
   local firsts: {A} = {}
   local seconds: {B} = {}
   for i = 1, #t do
      local p = t[i]
      if type(p) ~= "table" then
         error("htlx.list.unzip: element " .. i .. " is not a pair, got " .. type(p), 2)
      end
      firsts[i] = p[1]
      seconds[i] = p[2]
   end
   return firsts, seconds
end

--- The integers from `from` to `to`, both included, `step` apart (default 1; negative to
--- count down). Empty when `to` is on the wrong side of `from`. A `step` of zero raises.
function list.range(from: integer, to: integer, step?: integer): {integer}
   check_integer(from, "range", "from")
   check_integer(to, "range", "to")
   local by = step or 1
   check_integer(by, "range", "step")
   if by == 0 then
      error("htlx.list.range: step must not be zero", 2)
   end
   local out: {integer} = {}
   for i = from, to, by do
      out[#out + 1] = i
   end
   return out
end

--- The elements of `t` as one string, `sep` (default `""`) between them: each one through
--- `f` when given, and through `tostring` otherwise. `table.concat` is the same for an
--- array that is already strings or numbers; this is for one that is not.
function list.join<T>(t: {T}, sep?: string, f?: function(T): string): string
   check_array(t, "join")
   local parts: {string} = {}
   for i = 1, #t do
      local s: string
      if f then
         s = f(t[i])
         if type(s) ~= "string" then
            error("htlx.list.join: f must return a string, got " .. type(s) .. " at index " .. i, 2)
         end
      else
         s = tostring(t[i])
      end
      parts[i] = s
   end
   return table.concat(parts, sep or "")
end

--- A new array of `n` copies of `v`. `n` below zero raises; `nil` for `v` raises (see the
--- module note).
function list.fill<T>(n: integer, v: T): {T}
   check_integer(n, "fill", "n")
   if n < 0 then
      error("htlx.list.fill: n must not be negative, got " .. n, 2)
   end
   if v == nil then
      error("htlx.list.fill: refusing to fill with nil (it would be an empty array)", 2)
   end
   local out: {T} = {}
   for i = 1, n do
      out[i] = v
   end
   return out
end

-- ------------------------------------------------------------------ splitting

--- Two new arrays: the elements for which `pred(element, index)` is true, and the ones for
--- which it is not, each in the original order.
function list.partition<T>(t: {T}, pred: function(T, integer): boolean): {T}, {T}
   check_array(t, "partition")
   check_function(pred, "partition", "pred")
   local yes: {T} = {}
   local no: {T} = {}
   for i = 1, #t do
      local v = t[i]
      if pred(v, i) then
         yes[#yes + 1] = v
      else
         no[#no + 1] = v
      end
   end
   return yes, no
end

--- The elements of `t` grouped by `key(element)`: a map from each key to the array of the
--- elements that have it, each array in the original order. A key of `nil` raises, since a
--- Lua table cannot hold it.
function list.group_by<T, K>(t: {T}, key: function(T): K): {K:{T}}
   check_array(t, "group_by")
   check_function(key, "group_by", "key")
   local out: {K:{T}} = {}
   for i = 1, #t do
      local k = key(t[i])
      if k == nil then
         error("htlx.list.group_by: key returned nil at index " .. i, 2)
      end
      local g = out[k]
      if g == nil then
         g = {}
         out[k] = g
      end
      g[#g + 1] = t[i]
   end
   return out
end

--- A new array of the elements of `t` with every repeat (`==`) after the first dropped,
--- in the original order. Every repeat, not only adjacent ones: this is lodash's `uniq`
--- and Kotlin's `distinct`, not Rust's `dedup`.
function list.uniq<T>(t: {T}): {T}
   check_array(t, "uniq")
   local seen: {T:boolean} = {}
   local out: {T} = {}
   for i = 1, #t do
      local v = t[i]
      if not seen[v] then
         seen[v] = true
         out[#out + 1] = v
      end
   end
   return out
end

--- `uniq` by `key(element)`: the first element with each key is kept, in the original
--- order. A key of `nil` raises.
function list.uniq_by<T, K>(t: {T}, key: function(T): K): {T}
   check_array(t, "uniq_by")
   check_function(key, "uniq_by", "key")
   local seen: {K:boolean} = {}
   local out: {T} = {}
   for i = 1, #t do
      local k = key(t[i])
      if k == nil then
         error("htlx.list.uniq_by: key returned nil at index " .. i, 2)
      end
      if not seen[k] then
         seen[k] = true
         out[#out + 1] = t[i]
      end
   end
   return out
end

-- ------------------------------------------------------------------ sets

--- The elements of `t` as the keys of a new map, each set to `true`, so membership is one
--- index instead of a scan. `{ "a", "b" }` becomes `{ a = true, b = true }`. `htlx.ordered`
--- has the set that also remembers its order.
function list.to_set<T>(t: {T}): {T:boolean}
   check_array(t, "to_set")
   local out: {T:boolean} = {}
   for i = 1, #t do
      out[t[i]] = true
   end
   return out
end

--- The elements of `a` followed by the elements of `b` that are not in `a`, each once, in
--- that order.
function list.union<T>(a: {T}, b: {T}): {T}
   check_array(a, "union")
   check_array(b, "union")
   return list.uniq(list.concat(a, b))
end

--- The elements of `a` that are also in `b`, each once, in `a`'s order.
function list.intersect<T>(a: {T}, b: {T}): {T}
   check_array(a, "intersect")
   check_array(b, "intersect")
   local in_b = list.to_set(b)
   local out: {T} = {}
   local seen: {T:boolean} = {}
   for i = 1, #a do
      local v = a[i]
      if in_b[v] and not seen[v] then
         seen[v] = true
         out[#out + 1] = v
      end
   end
   return out
end

--- The elements of `a` that are not in `b`, each once, in `a`'s order.
function list.difference<T>(a: {T}, b: {T}): {T}
   check_array(a, "difference")
   check_array(b, "difference")
   local in_b = list.to_set(b)
   local out: {T} = {}
   local seen: {T:boolean} = {}
   for i = 1, #a do
      local v = a[i]
      if not in_b[v] and not seen[v] then
         seen[v] = true
         out[#out + 1] = v
      end
   end
   return out
end

-- ------------------------------------------------------------------ random

--- Shuffle `t` in place (Fisher–Yates) and return it. `rng(n)` must return an integer in
--- `[1, n]`; the default is `math.random`, so pass one for a repeatable order — `htl.test`'s
--- `rng()` has that shape.
function list.shuffle<T>(t: {T}, rng?: function(integer): integer): {T}
   check_array(t, "shuffle")
   local random = rng or (math.random as function(integer): integer)
   for i = #t, 2, -1 do
      local j = random(i)
      t[i], t[j] = t[j], t[i]
   end
   return t
end

--- One element of `t` chosen at random, or `nil` for an empty array. `rng` as in `shuffle`.
function list.sample<T>(t: {T}, rng?: function(integer): integer): T
   check_array(t, "sample")
   local n = #t
   if n == 0 then
      return nil
   end
   local random = rng or (math.random as function(integer): integer)
   return t[random(n)]
end

-- ------------------------------------------------------------------ asking

--- Whether `a` and `b` have the same length and equal (`==`) elements at every index. One
--- level only; `htlx.tablex.deep_equals` compares nested tables by content.
function list.equals<T>(a: {T}, b: {T}): boolean
   check_array(a, "equals")
   check_array(b, "equals")
   if #a ~= #b then
      return false
   end
   for i = 1, #a do
      if a[i] ~= b[i] then
         return false
      end
   end
   return true
end

--- Whether `t` has no elements. `#t == 0` under a name.
function list.is_empty<T>(t: {T}): boolean
   check_array(t, "is_empty")
   return #t == 0
end

--- How many elements `t` has. `#t` under a name, here so that the same spelling works
--- across the modules.
function list.len<T>(t: {T}): integer
   check_array(t, "len")
   return #t
end

return list
