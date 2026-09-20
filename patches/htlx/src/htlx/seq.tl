--- Lazy sequences: iterators that hand out one element per call and `nil` when done.
---
--- An iterator here is a plain `function(): T`. The entry functions (`of`, `keys`,
--- `values`, `entries`, `range`, `iterate`) make one from a table or a rule; the transforms
--- (`map`, `filter`, `take`, `zip`, ...) wrap one in another without pulling anything yet;
--- the exits (`collect`, `fold`, `find`, `each`, ...) pull until the end. Nothing runs until
--- an exit runs, so `take` can cut an endless `iterate` and a `map` over a million rows
--- costs one element at a time.
---
--- `htlx.list` and `htlx.tablex` are the eager side over the same tables; this module is
--- for a pipeline of several steps, or for a source that has no end.
---
--- Rules every function keeps:
---
--- * An argument that is not what the signature says is a bug in the caller and raises.
---   Nothing returns `nil, err` for that. An iterator argument is checked to be a function;
---   what it yields is not checked.
--- * `nil` ends a sequence, so no sequence carries a `nil` element (the same rule as
---   `htlx.list`). `false` is an ordinary element. `map` refuses an `f` that returns `nil`;
---   `filter` and `filter_map` are the way to drop elements.
--- * Two-valued things travel as one value. `entries` and `zip` yield a `{K, V}` / `{A, B}`
---   tuple; `enumerate` is the one exception, made for `for i, v in`.
--- * An iterator is consumed by whoever pulls from it. A transform takes ownership of the
---   iterator it is given: pull from the result, not from the source. Tables passed to the
---   entry functions are never changed.
local record seq
end

local function check_iter(it: any, fname: string, what: string)
   if type(it) ~= "function" then
      error("htlx.seq." .. fname .. ": " .. what .. " must be an iterator (a function), got " .. type(it), 3)
   end
end

local function check_function(f: any, fname: string, what: string)
   if type(f) ~= "function" then
      error("htlx.seq." .. fname .. ": " .. what .. " must be a function, got " .. type(f), 3)
   end
end

local function check_table(t: any, fname: string)
   if type(t) ~= "table" then
      error("htlx.seq." .. fname .. ": expected a table, got " .. type(t), 3)
   end
end

local function check_integer(n: any, fname: string, what: string)
   if math.type(n) ~= "integer" then
      error("htlx.seq." .. fname .. ": " .. what .. " must be an integer, got " .. (math.type(n) or type(n)), 3)
   end
end

local function check_count(n: any, fname: string)
   check_integer(n, fname, "n")
   if (n as integer) < 0 then
      error("htlx.seq." .. fname .. ": n must be at least 0, got " .. tostring(n), 3)
   end
end

--- An iterator over the elements of `t` in index order, `1` to `#t`.
function seq.of<T>(t: {T}): function(): T
   check_table(t, "of")
   local i = 0
   return function(): T
      i = i + 1
      return t[i]
   end
end

--- An iterator over the keys of `t`, in `pairs` order.
function seq.keys<K, V>(t: {K:V}): function(): K
   check_table(t, "keys")
   local k: K = nil
   return function(): K
      k = next(t, k)
      return k
   end
end

--- An iterator over the values of `t`, in `pairs` order.
function seq.values<K, V>(t: {K:V}): function(): V
   check_table(t, "values")
   local k: K = nil
   local v: V
   return function(): V
      k, v = next(t, k)
      return v
   end
end

--- An iterator over the entries of `t` as `{key, value}` tuples, in `pairs` order.
--- `to_map` turns them back into a map.
function seq.entries<K, V>(t: {K:V}): function(): {K, V}
   check_table(t, "entries")
   local k: K = nil
   local v: V
   return function(): {K, V}
      k, v = next(t, k)
      if k == nil then
         return nil
      end
      local e: {K, V} = { k, v }
      return e
   end
end

--- An iterator over the integers from `from` to `to` inclusive, stepping by `step` (default
--- `1`). A negative `step` counts down; a `step` of `0` raises. The sequence is empty when
--- the step never reaches `to` from `from`, as `for i = from, to, step` is.
function seq.range(from: integer, to: integer, step?: integer): function(): integer
   check_integer(from, "range", "from")
   check_integer(to, "range", "to")
   if step == nil then
      step = 1
   else
      check_integer(step, "range", "step")
   end
   if step == 0 then
      error("htlx.seq.range: step must not be 0", 2)
   end
   local i = from
   return function(): integer
      local v = i
      if (step > 0 and v > to) or (step < 0 and v < to) then
         return nil
      end
      i = i + step
      return v
   end
end

--- An endless iterator: `init`, `f(init)`, `f(f(init))`, ... Cut it with `take` or
--- `take_while`; `collect`, `count` and the other exits never return on it. The one way it
--- stops on its own is `f` returning `nil`, which is the end mark of every sequence.
function seq.iterate<T>(init: T, f: function(T): T): function(): T
   check_function(f, "iterate", "f")
   local cur = init
   local started = false
   return function(): T
      if not started then
         started = true
      elseif cur ~= nil then
         cur = f(cur)
      end
      return cur
   end
end

--- An iterator yielding `f(element)` for each element of `it`, in order.
---
--- `f` returning `nil` raises when that element is pulled: `nil` would end the sequence
--- early and silently. Use `filter` first, or `filter_map`, to drop elements.
function seq.map<T, R>(it: function(): T, f: function(T): R): function(): R
   check_iter(it, "map", "it")
   check_function(f, "map", "f")
   return function(): R
      local v = it()
      if v == nil then
         return nil
      end
      local r = f(v)
      if r == nil then
         error("htlx.seq.map: f returned nil (it would end the sequence early)", 2)
      end
      return r
   end
end

--- An iterator over the elements of `it` for which `pred(element)` is true, in order.
function seq.filter<T>(it: function(): T, pred: function(T): boolean): function(): T
   check_iter(it, "filter", "it")
   check_function(pred, "filter", "pred")
   return function(): T
      while true do
         local v = it()
         if v == nil then
            return nil
         end
         if pred(v) then
            return v
         end
      end
   end
end

--- `map` and `filter` in one pass: an iterator yielding `f(element)` for each element of
--- `it`, skipping the elements for which `f` returned `nil`.
function seq.filter_map<T, R>(it: function(): T, f: function(T): R): function(): R
   check_iter(it, "filter_map", "it")
   check_function(f, "filter_map", "f")
   return function(): R
      while true do
         local v = it()
         if v == nil then
            return nil
         end
         local r = f(v)
         if r ~= nil then
            return r
         end
      end
   end
end

--- An iterator over the elements of each array `f(element)` returns, one array after the
--- other, in order. An empty array contributes nothing. `f` returning something that is not
--- a table raises when that element is pulled.
function seq.flat_map<T, R>(it: function(): T, f: function(T): {R}): function(): R
   check_iter(it, "flat_map", "it")
   check_function(f, "flat_map", "f")
   local inner: {R} = nil
   local j = 0
   return function(): R
      while true do
         if inner ~= nil then
            j = j + 1
            local r = inner[j]
            if r ~= nil then
               return r
            end
            inner = nil
         end
         local v = it()
         if v == nil then
            return nil
         end
         local arr = f(v)
         if type(arr) ~= "table" then
            error("htlx.seq.flat_map: f must return an array, got " .. type(arr), 2)
         end
         inner = arr
         j = 0
      end
   end
end

--- An iterator over the first `n` elements of `it`, or all of them when there are fewer.
--- Nothing past the `n`th is pulled from `it`, so this is the way to cut `iterate`.
function seq.take<T>(it: function(): T, n: integer): function(): T
   check_iter(it, "take", "it")
   check_count(n, "take")
   local i = 0
   local done = false
   return function(): T
      if done or i >= n then
         return nil
      end
      i = i + 1
      local v = it()
      if v == nil then
         done = true
      end
      return v
   end
end

--- An iterator over the elements of `it` after the first `n`. The `n` skipped elements are
--- pulled on the first call, not when `drop` is called.
function seq.drop<T>(it: function(): T, n: integer): function(): T
   check_iter(it, "drop", "it")
   check_count(n, "drop")
   local skipped = false
   return function(): T
      if not skipped then
         skipped = true
         for _ = 1, n do
            if it() == nil then
               return nil
            end
         end
      end
      return it()
   end
end

--- An iterator over the leading elements of `it` for which `pred(element)` is true. It ends
--- at the first element `pred` rejects; that element is pulled and dropped, and nothing
--- after it is pulled.
function seq.take_while<T>(it: function(): T, pred: function(T): boolean): function(): T
   check_iter(it, "take_while", "it")
   check_function(pred, "take_while", "pred")
   local done = false
   return function(): T
      if done then
         return nil
      end
      local v = it()
      if v == nil or not pred(v) then
         done = true
         return nil
      end
      return v
   end
end

--- An iterator over the elements of `it` from the first one `pred(element)` rejects, that
--- one included, to the end. `pred` is not asked about anything after it.
function seq.drop_while<T>(it: function(): T, pred: function(T): boolean): function(): T
   check_iter(it, "drop_while", "it")
   check_function(pred, "drop_while", "pred")
   local dropping = true
   return function(): T
      if dropping then
         dropping = false
         while true do
            local v = it()
            if v == nil or not pred(v) then
               return v
            end
         end
      end
      return it()
   end
end

--- An iterator over `{a_element, b_element}` tuples, pairing `a` and `b` element by element.
--- It ends when either side ends; the other side is left where it was, one element past
--- when it was `a` that had more.
function seq.zip<A, B>(a: function(): A, b: function(): B): function(): {A, B}
   check_iter(a, "zip", "a")
   check_iter(b, "zip", "b")
   local done = false
   return function(): {A, B}
      if done then
         return nil
      end
      local x = a()
      if x == nil then
         done = true
         return nil
      end
      local y = b()
      if y == nil then
         done = true
         return nil
      end
      local e: {A, B} = { x, y }
      return e
   end
end

--- An iterator yielding two values, the 1-based position and the element, so that
--- `for i, v in seq.enumerate(it) do` reads like `ipairs`. This is the one iterator here
--- that yields two values; wrap it in nothing, only loop over it.
function seq.enumerate<T>(it: function(): T): function(): (integer, T)
   check_iter(it, "enumerate", "it")
   local i = 0
   return function(): (integer, T)
      local v = it()
      if v == nil then
         return nil, nil
      end
      i = i + 1
      return i, v
   end
end

--- An iterator over every element of the first iterator, then every element of the second,
--- and so on. No iterator is pulled before the one ahead of it has ended. With no arguments
--- the sequence is empty.
function seq.chain<T>(...: function(): T): function(): T
   local its: {function(): T} = { ... }
   for i = 1, select("#", ...) do
      if type(its[i]) ~= "function" then
         error("htlx.seq.chain: argument " .. i .. " must be an iterator (a function), got " .. type(its[i]), 2)
      end
   end
   local k = 1
   return function(): T
      while true do
         local cur = its[k]
         if cur == nil then
            return nil
         end
         local v = cur()
         if v ~= nil then
            return v
         end
         k = k + 1
      end
   end
end

--- Every element of `it`, in order, as a new array. Consumes `it`.
function seq.collect<T>(it: function(): T): {T}
   check_iter(it, "collect", "it")
   local out: {T} = {}
   for v in it do
      out[#out + 1] = v
   end
   return out
end

--- `f(f(f(init, e1), e2), e3)`... over the elements of `it`, in order; `init` when `it` is
--- empty. Consumes `it`.
function seq.fold<T, A>(it: function(): T, init: A, f: function(A, T): A): A
   check_iter(it, "fold", "it")
   check_function(f, "fold", "f")
   local acc = init
   for v in it do
      acc = f(acc, v)
   end
   return acc
end

--- Whether `pred(element)` is true for some element of `it`. Stops pulling at the first one
--- that is; `false` for an empty sequence.
function seq.any<T>(it: function(): T, pred: function(T): boolean): boolean
   check_iter(it, "any", "it")
   check_function(pred, "any", "pred")
   for v in it do
      if pred(v) then
         return true
      end
   end
   return false
end

--- Whether `pred(element)` is true for every element of `it`. Stops pulling at the first one
--- that is not; `true` for an empty sequence.
function seq.all<T>(it: function(): T, pred: function(T): boolean): boolean
   check_iter(it, "all", "it")
   check_function(pred, "all", "pred")
   for v in it do
      if not pred(v) then
         return false
      end
   end
   return true
end

--- The first element of `it` for which `pred(element)` is true, or `nil` when there is none.
--- Stops pulling at the match, so `it` can be pulled again for what follows it.
function seq.find<T>(it: function(): T, pred: function(T): boolean): T
   check_iter(it, "find", "it")
   check_function(pred, "find", "pred")
   for v in it do
      if pred(v) then
         return v
      end
   end
   return nil
end

--- Call `f(element)` for each element of `it`, in order, for the side effect. Consumes `it`.
function seq.each<T>(it: function(): T, f: function(T))
   check_iter(it, "each", "it")
   check_function(f, "each", "f")
   for v in it do
      f(v)
   end
end

--- A new map from an iterator of `{key, value}` tuples, the inverse of `entries`. A later
--- tuple with the same key wins. A tuple whose key is `nil` raises, since it cannot be an
--- entry; a tuple whose value is `nil` is no entry either and so adds nothing. A yielded
--- element that is not a table raises. Consumes `it`.
function seq.to_map<K, V>(it: function(): {K, V}): {K:V}
   check_iter(it, "to_map", "it")
   local out: {K:V} = {}
   local i = 0
   for e in it do
      i = i + 1
      if type(e) ~= "table" then
         error("htlx.seq.to_map: element " .. i .. " must be a {key, value} tuple, got " .. type(e), 2)
      end
      local k = e[1]
      if k == nil then
         error("htlx.seq.to_map: element " .. i .. " has a nil key", 2)
      end
      out[k] = e[2]
   end
   return out
end

--- How many elements `it` yields before it ends. Consumes `it`.
function seq.count<T>(it: function(): T): integer
   check_iter(it, "count", "it")
   local n = 0
   for _ in it do
      n = n + 1
   end
   return n
end

return seq
