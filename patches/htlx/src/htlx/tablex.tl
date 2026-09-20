--- Functions over maps (`{K:V}`), and the few that are about a table whatever its shape
--- (`deep_copy`, `deep_equals`, `deep_merge`, `freeze`).
---
--- Arrays (`{T}`) are a different type in Teal and have their own module, `htlx.list`;
--- a map and an array cannot share one signature, so nothing here accepts both except the
--- `deep_*` and `freeze` functions, which take any table as `T` and give the same `T` back.
--- A map that remembers the order its keys were put in is `htlx.ordered`.
---
--- Rules every function keeps:
---
--- * An argument that is not what the signature says is a bug in the caller and raises.
---   Nothing returns `nil, err` for that.
--- * Nothing is mutated. Every function that hands back a table hands back a new one
---   (`freeze` hands back a view of the one it was given, which is the point of it).
--- * `keys` and `values` come back as arrays in `pairs` order, which is no order. A caller
---   that needs an order calls `sorted_keys` or `sorted_pairs`, which sort with `<` and so
---   want keys of one comparable type unless given a comparator. A comparator is always
---   the last, optional argument, and is `<` as `table.sort` takes it.
--- * A lookup that finds nothing returns `nil` (`get_or` is the one that does not).
local record tablex
end

local function check_table(t: any, fname: string)
   if type(t) ~= "table" then
      error("htlx.tablex." .. fname .. ": expected a table, got " .. type(t), 3)
   end
end

local function check_function(f: any, fname: string, what: string)
   if type(f) ~= "function" then
      error("htlx.tablex." .. fname .. ": " .. what .. " must be a function, got " .. type(f), 3)
   end
end

--- The keys of `t` as an array, in `pairs` order.
function tablex.keys<K, V>(t: {K:V}): {K}
   check_table(t, "keys")
   local out: {K} = {}
   for k in pairs(t) do
      out[#out + 1] = k
   end
   return out
end

--- The values of `t` as an array, in `pairs` order.
function tablex.values<K, V>(t: {K:V}): {V}
   check_table(t, "values")
   local out: {V} = {}
   for _, v in pairs(t) do
      out[#out + 1] = v
   end
   return out
end

--- The keys of `t` as an array sorted by `cmp`, or by `<` when no comparator is given.
function tablex.sorted_keys<K, V>(t: {K:V}, cmp?: function(K, K): boolean): {K}
   check_table(t, "sorted_keys")
   local out = tablex.keys(t)
   table.sort(out, cmp)
   return out
end

--- An iterator over `t` that visits keys in sorted order, so `for k, v in
--- tablex.sorted_pairs(t) do` is `pairs` with the order pinned down.
---
--- The keys are sorted once when the iterator is made; a key added to `t` during the loop is
--- not visited, and a key removed during the loop is visited with a `nil` value.
function tablex.sorted_pairs<K, V>(t: {K:V}, cmp?: function(K, K): boolean): function(): (K, V)
   check_table(t, "sorted_pairs")
   local keys = tablex.sorted_keys(t, cmp)
   local i = 0
   return function(): (K, V)
      i = i + 1
      local k = keys[i]
      if k == nil then
         return nil, nil
      end
      return k, t[k]
   end
end

--- A new map with the same keys as `t` and `f(value, key)` for each value.
---
--- `f` returning `nil` drops the key from the result, since a `nil` value is no entry in a
--- Lua table; `filter` is the clearer way to say that.
function tablex.map<K, V, R>(t: {K:V}, f: function(V, K): R): {K:R}
   check_table(t, "map")
   check_function(f, "map", "f")
   local out: {K:R} = {}
   for k, v in pairs(t) do
      out[k] = f(v, k)
   end
   return out
end

--- A new map holding the entries of `t` for which `pred(value, key)` is true.
function tablex.filter<K, V>(t: {K:V}, pred: function(V, K): boolean): {K:V}
   check_table(t, "filter")
   check_function(pred, "filter", "pred")
   local out: {K:V} = {}
   for k, v in pairs(t) do
      if pred(v, k) then
         out[k] = v
      end
   end
   return out
end

--- A new map holding every entry of `a` and every entry of `b`; on a key both have, `b`
--- wins. Neither argument is changed.
function tablex.merge<K, V>(a: {K:V}, b: {K:V}): {K:V}
   check_table(a, "merge")
   check_table(b, "merge")
   local out: {K:V} = {}
   for k, v in pairs(a) do
      out[k] = v
   end
   for k, v in pairs(b) do
      out[k] = v
   end
   return out
end

--- A shallow copy of `t`: the same keys, the same values, a different table.
function tablex.copy<K, V>(t: {K:V}): {K:V}
   check_table(t, "copy")
   local out: {K:V} = {}
   for k, v in pairs(t) do
      out[k] = v
   end
   return out
end

--- How many entries `t` has. `#` only counts a sequence; this counts a map.
function tablex.count<K, V>(t: {K:V}): integer
   check_table(t, "count")
   local n = 0
   for _ in pairs(t) do
      n = n + 1
   end
   return n
end

--- Whether `t` has no entries at all.
function tablex.is_empty<K, V>(t: {K:V}): boolean
   check_table(t, "is_empty")
   return next(t) == nil
end

--- Call `f(value, key)` for each entry of `t`, in `pairs` order, for its effect. The same
--- as a `for k, v in pairs(t)` loop, in the form a function can be handed; `sorted_pairs`
--- is the loop with an order.
function tablex.each<K, V>(t: {K:V}, f: function(V, K))
   check_table(t, "each")
   check_function(f, "each", "f")
   for k, v in pairs(t) do
      f(v, k)
   end
end

--- A new map with the same values as `t` under `f(key, value)` for each key. Two keys that
--- `f` maps to the same key keep whichever `pairs` visited last, and a key `f` maps to
--- `nil` raises, since a Lua table cannot hold it.
function tablex.map_keys<K, V, R>(t: {K:V}, f: function(K, V): R): {R:V}
   check_table(t, "map_keys")
   check_function(f, "map_keys", "f")
   local out: {R:V} = {}
   for k, v in pairs(t) do
      local r = f(k, v)
      if r == nil then
         error("htlx.tablex.map_keys: f returned nil for key " .. tostring(k), 2)
      end
      out[r] = v
   end
   return out
end

--- The entries of `t` as an array of `{key, value}` pairs, in `pairs` order.
--- `from_entries` is the inverse; `sorted_pairs` is the same walk with an order.
function tablex.entries<K, V>(t: {K:V}): {{K, V}}
   check_table(t, "entries")
   local out: {{K, V}} = {}
   for k, v in pairs(t) do
      out[#out + 1] = { k, v }
   end
   return out
end

--- A new map from an array of `{key, value}` pairs; a later pair with the same key wins.
--- `entries` is the inverse.
function tablex.from_entries<K, V>(e: {{K, V}}): {K:V}
   check_table(e, "from_entries")
   local out: {K:V} = {}
   for i = 1, #e do
      local p = e[i]
      if type(p) ~= "table" then
         error("htlx.tablex.from_entries: element " .. i .. " is not a pair, got " .. type(p), 2)
      end
      local k = p[1]
      if k == nil then
         error("htlx.tablex.from_entries: pair " .. i .. " has a nil key", 2)
      end
      out[k] = p[2]
   end
   return out
end

--- `t[k]`, or `default` when `t` has no entry for `k`.
function tablex.get_or<K, V>(t: {K:V}, k: K, default: V): V
   check_table(t, "get_or")
   local v = t[k]
   if v == nil then
      return default
   end
   return v
end

--- A new map holding the entries of `t` whose key is in `keys`; a key `t` does not have
--- is left out rather than set to `nil`.
function tablex.pick<K, V>(t: {K:V}, keys: {K}): {K:V}
   check_table(t, "pick")
   check_table(keys, "pick")
   local out: {K:V} = {}
   for i = 1, #keys do
      local k = keys[i]
      local v = t[k]
      if v ~= nil then
         out[k] = v
      end
   end
   return out
end

--- A new map holding the entries of `t` whose key is not in `keys`.
function tablex.omit<K, V>(t: {K:V}, keys: {K}): {K:V}
   check_table(t, "omit")
   check_table(keys, "omit")
   local drop: {K:boolean} = {}
   for i = 1, #keys do
      drop[keys[i]] = true
   end
   local out: {K:V} = {}
   for k, v in pairs(t) do
      if not drop[k] then
         out[k] = v
      end
   end
   return out
end

--- A new map with the keys and values of `t` swapped. Two keys with the same value keep
--- whichever `pairs` visited last.
function tablex.invert<K, V>(t: {K:V}): {V:K}
   check_table(t, "invert")
   local out: {V:K} = {}
   for k, v in pairs(t) do
      out[v] = k
   end
   return out
end

--- Whether `a` and `b` have the same keys with equal (`==`) values. One level only;
--- `deep_equals` compares nested tables by content.
function tablex.equals<K, V>(a: {K:V}, b: {K:V}): boolean
   check_table(a, "equals")
   check_table(b, "equals")
   for k, v in pairs(a) do
      if b[k] ~= v then
         return false
      end
   end
   for k in pairs(b) do
      if a[k] == nil then
         return false
      end
   end
   return true
end

-- ------------------------------------------------------------------ deep

-- The copy so far, keyed by the original, so a table reached twice is copied once and a
-- cycle ends where it began.
local function deep_copy_into(v: any, seen: {table:table}): any
   if type(v) ~= "table" then
      return v
   end
   local src = v as table
   local done = seen[src]
   if done ~= nil then
      return done
   end
   local out: table = {}
   seen[src] = out
   for k, x in pairs(src as {any:any}) do
      (out as {any:any})[deep_copy_into(k, seen)] = deep_copy_into(x, seen)
   end
   local mt = getmetatable(src)
   if mt ~= nil then
      setmetatable(out, mt)
   end
   return out
end

--- A copy of `t` in which every table reachable from it — as a value or as a key — is
--- copied too, so nothing in the result is shared with the original. A table reached
--- twice is copied once, and a cycle stays a cycle. Metatables are kept (shared, not
--- copied), as Penlight's `deepcopy` keeps them. Values that are not tables are the same
--- values.
function tablex.deep_copy<T>(t: T): T
   if type(t) ~= "table" then
      error("htlx.tablex.deep_copy: expected a table, got " .. type(t), 2)
   end
   return deep_copy_into(t, {}) as T
end

local function deep_equals_at(a: any, b: any, seen: {table:{table:boolean}}): boolean
   if a == b then
      return true
   end
   if type(a) ~= "table" or type(b) ~= "table" then
      return false
   end
   local ta = a as {any:any}
   local tb = b as {any:any}
   -- A pair already under comparison is taken as equal: that is what makes two cycles
   -- of the same shape compare equal instead of recursing forever.
   local row = seen[ta as table]
   if row ~= nil and row[tb as table] then
      return true
   end
   if row == nil then
      row = {}
      seen[ta as table] = row
   end
   row[tb as table] = true
   for k, v in pairs(ta) do
      if not deep_equals_at(v, tb[k], seen) then
         return false
      end
   end
   for k in pairs(tb) do
      if ta[k] == nil then
         return false
      end
   end
   return true
end

--- Whether `a` and `b` are equal by content: the same keys at every level, with values
--- that are `==` or are tables that are `deep_equals` in turn. Keys are compared with
--- `==`, so a table used as a key must be the same table on both sides. Metatables are
--- not consulted (no `__eq`), as Penlight's `deepcompare` does not consult them. Two
--- structures with cycles compare by shape rather than recursing forever.
function tablex.deep_equals<T>(a: T, b: T): boolean
   if type(a) ~= "table" or type(b) ~= "table" then
      error("htlx.tablex.deep_equals: expected two tables, got " .. type(a) .. " and " .. type(b), 2)
   end
   return deep_equals_at(a, b, {})
end

local function deep_merge_into(a: any, b: any): any
   if type(a) ~= "table" or type(b) ~= "table" then
      return b
   end
   local out = deep_copy_into(a, {}) as {any:any}
   for k, v in pairs(b as {any:any}) do
      out[k] = deep_merge_into(out[k], v)
   end
   return out
end

--- A new map holding every entry of `a` and every entry of `b`, and where both have a
--- table under the same key, the `deep_merge` of the two; on any other key both have, `b`
--- wins. Nothing in the result is shared with `a` (it is deep-copied first); values taken
--- from `b` are `b`'s own. Arrays are tables too and merge by index, which is rarely what
--- is meant — merge maps of maps with this, not maps of arrays.
function tablex.deep_merge<K, V>(a: {K:V}, b: {K:V}): {K:V}
   check_table(a, "deep_merge")
   check_table(b, "deep_merge")
   return deep_merge_into(a, b) as {K:V}
end

-- ------------------------------------------------------------------ freeze

-- One metatable per frozen table would do, but one for all lets `is_frozen` be a lookup.
local frozen_of: {table:table} = setmetatable({}, { __mode = "k" }) as {table:table}

--- A read-only view of `t`: indexing, `#`, `pairs` and `ipairs` see `t` as it is, and
--- an assignment through the view raises naming the key. `t` itself is not changed and
--- can still be written through its own reference; the view then shows the change. What
--- comes back is a proxy, so it is not `==` to `t`, and `rawset` on it writes the proxy
--- rather than raising. The type is unchanged: Teal has no read-only type, so the promise
--- is in the value, as Luau's `table.freeze` makes it.
function tablex.freeze<T>(t: T): T
   if type(t) ~= "table" then
      error("htlx.tablex.freeze: expected a table, got " .. type(t), 2)
   end
   local src = t as table
   local proxy = setmetatable({}, {
      __index = src,
      __newindex = function(_: table, k: any)
         error("htlx.tablex.freeze: the table is frozen, cannot set " .. tostring(k), 2)
      end,
      __len = function(): integer
         return #(src as {any})
      end,
      __pairs = function(): (function(table, any): (any, any), table, any)
         return next, src, nil
      end,
   })
   frozen_of[proxy] = src
   return proxy as T
end

--- Whether `t` is a view `freeze` made.
function tablex.is_frozen(t: any): boolean
   if type(t) ~= "table" then
      return false
   end
   return frozen_of[t as table] ~= nil
end

return tablex
