--- A map and a set that remember insertion order.
---
--- Lua's `pairs` visits a table in no order, so a `{K:V}` cannot say "the first key I was
--- given". `ordered.Map` and `ordered.Set` can: every key or value is kept in the order it
--- was first inserted, `keys` / `values` / `entries` / `pairs` / `iter` all walk that order,
--- and updating a key that is already present keeps its position. This is the place
--- Penlight's `OrderedMap`, Python's `dict`, and JavaScript's `Map` / `Set` hold.
---
--- Both are records with methods, so a value is made by a constructor here and used as
--- `m:set(k, v)`, `s:add(v)`. A constructor with no argument needs its type parameters from
--- the caller: `local m: ordered.Map<string, integer> = ordered.map()`. The `from_*`
--- constructors infer them from their argument.
---
--- Rules every method keeps:
---
--- * An argument that is not what the signature says is a bug in the caller and raises.
---   A method called on something that is not a `Map` / `Set` raises the same way.
--- * `nil` is never a key or a value. `set(k, nil)` and `add(nil)` raise; `delete` is the
---   way to remove an entry. `get` of a missing key returns `nil`, which is therefore
---   always "absent", never "present with nil".
--- * `set` / `add` / `delete` mutate, because the collection exists to be built up, and
---   return `self` (or a boolean) so they can be chained. Every other method that hands
---   back a collection or an array hands back a new one, and the collections a set
---   operation reads (`union`, `intersect`, `difference`) are not changed.
--- * Order is kept in an array of keys, so `delete` is O(n) in the number of entries
---   (the same trade Penlight makes). `set` / `add` / `get` / `has` are one table index.
local record ordered
   --- A map from `K` to `V` that iterates in insertion order.
   record Map<K, V>
      _keys: {K}
      _vals: {K:V}

      set: function(self: Map<K, V>, k: K, v: V): Map<K, V>
      get: function(self: Map<K, V>, k: K): V
      get_or: function(self: Map<K, V>, k: K, default: V): V
      has: function(self: Map<K, V>, k: K): boolean
      delete: function(self: Map<K, V>, k: K): boolean
      keys: function(self: Map<K, V>): {K}
      values: function(self: Map<K, V>): {V}
      entries: function(self: Map<K, V>): {{K, V}}
      pairs: function(self: Map<K, V>): function(): (K, V)
      len: function(self: Map<K, V>): integer
      is_empty: function(self: Map<K, V>): boolean
      copy: function(self: Map<K, V>): Map<K, V>
      each: function(self: Map<K, V>, f: function(V, K))
      sorted: function(self: Map<K, V>, cmp?: function(K, K): boolean): Map<K, V>
      to_table: function(self: Map<K, V>): {K:V}
   end

   --- A set of `T` that iterates in insertion order.
   record Set<T>
      _items: {T}
      _has: {T:boolean}

      add: function(self: Set<T>, v: T): Set<T>
      has: function(self: Set<T>, v: T): boolean
      delete: function(self: Set<T>, v: T): boolean
      values: function(self: Set<T>): {T}
      iter: function(self: Set<T>): function(): T
      len: function(self: Set<T>): integer
      is_empty: function(self: Set<T>): boolean
      copy: function(self: Set<T>): Set<T>
      each: function(self: Set<T>, f: function(T))
      union: function(self: Set<T>, other: Set<T>): Set<T>
      intersect: function(self: Set<T>, other: Set<T>): Set<T>
      difference: function(self: Set<T>, other: Set<T>): Set<T>
      is_subset: function(self: Set<T>, other: Set<T>): boolean
      to_table: function(self: Set<T>): {T:boolean}
   end
end

local OM = ordered.Map
local OS = ordered.Set

-- One metatable per record, made once: `is_map` / `is_set` compare against these, so a
-- table that merely has the same shape is not mistaken for one of ours.
local map_mt: metatable<any> = { __index = OM }
local set_mt: metatable<any> = { __index = OS }

local function check_map(m: any, fname: string)
   if getmetatable(m) ~= map_mt then
      error("htlx.ordered.Map." .. fname .. ": expected an ordered.Map, got " .. type(m), 3)
   end
end

local function check_set(s: any, fname: string, what: string)
   if getmetatable(s) ~= set_mt then
      error("htlx.ordered.Set." .. fname .. ": " .. what .. " must be an ordered.Set, got " .. type(s), 3)
   end
end

local function check_array(t: any, fname: string)
   if type(t) ~= "table" then
      error("htlx.ordered." .. fname .. ": expected an array, got " .. type(t), 3)
   end
end

local function check_table(t: any, fname: string)
   if type(t) ~= "table" then
      error("htlx.ordered." .. fname .. ": expected a table, got " .. type(t), 3)
   end
end

local function check_function(f: any, fname: string, what: string)
   if type(f) ~= "function" then
      error("htlx.ordered." .. fname .. ": " .. what .. " must be a function, got " .. type(f), 3)
   end
end

-- `<` on two values of a type parameter is not something Teal will type, so the default
-- comparator for `sorted` / `from_table` goes through `any`. It is only ever reached with
-- keys of one comparable type, the same condition `tablex.sorted_keys` has.
local function lt(a: any, b: any): boolean
   return (a as number) < (b as number)
end

-- The index of `v` in the order array, or nil. Linear: this is the O(n) in `delete`.
local function index_in<T>(t: {T}, v: T): integer
   for i = 1, #t do
      if t[i] == v then
         return i
      end
   end
   return nil
end

------------------------------------------------------------------------------------------
-- Map
------------------------------------------------------------------------------------------

--- An empty `Map`. Annotate the receiving local so `K` and `V` are known:
--- `local m: ordered.Map<string, integer> = ordered.map()`.
function ordered.map<K, V>(): OM<K, V>
   local self: OM<K, V> = setmetatable({ _keys = {}, _vals = {} }, map_mt as metatable<OM<K, V>>)
   return self
end

--- A `Map` holding each `{ k, v }` pair of `e`, in array order. A key that appears more than
--- once keeps its first position and takes its last value, as `set` would do.
function ordered.from_entries<K, V>(e: {{K, V}}): OM<K, V>
   check_array(e, "from_entries")
   local m: OM<K, V> = ordered.map()
   for i = 1, #e do
      local pair = e[i]
      if type(pair) ~= "table" then
         error("htlx.ordered.from_entries: entry " .. i .. " is not a { key, value } pair, got " .. type(pair), 2)
      end
      m:set(pair[1], pair[2])
   end
   return m
end

--- A `Map` holding every entry of the plain map `t`. `pairs` gives no order to take, so the
--- keys are sorted by `cmp`, or by `<` when no comparator is given, and inserted in that
--- order. `t` is not changed.
function ordered.from_table<K, V>(t: {K:V}, cmp?: function(K, K): boolean): OM<K, V>
   check_table(t, "from_table")
   local ks: {K} = {}
   for k in pairs(t) do
      ks[#ks + 1] = k
   end
   local less = cmp or (lt as function(K, K): boolean)
   table.sort(ks, less)
   local m: OM<K, V> = ordered.map()
   for i = 1, #ks do
      local k = ks[i]
      m:set(k, t[k])
   end
   return m
end

--- Whether `x` is a `Map` made by this module.
function ordered.is_map(x: any): boolean
   return getmetatable(x) == map_mt
end

--- Put `v` under `k` and return `self`. A new key goes to the end of the order; a key already
--- present keeps its position and only its value changes. Raises on a `nil` key or a `nil`
--- value: `delete` is the way to remove an entry.
function OM.set<K, V>(self: OM<K, V>, k: K, v: V): OM<K, V>
   check_map(self, "set")
   if k == nil then
      error("htlx.ordered.Map.set: refusing a nil key", 2)
   end
   if v == nil then
      error("htlx.ordered.Map.set: refusing a nil value (use delete to remove a key)", 2)
   end
   if self._vals[k] == nil then
      self._keys[#self._keys + 1] = k
   end
   self._vals[k] = v
   return self
end

--- The value under `k`, or `nil` when there is none.
function OM.get<K, V>(self: OM<K, V>, k: K): V
   check_map(self, "get")
   return self._vals[k]
end

--- The value under `k`, or `default` when there is none. `self` is not changed.
function OM.get_or<K, V>(self: OM<K, V>, k: K, default: V): V
   check_map(self, "get_or")
   local v = self._vals[k]
   if v == nil then
      return default
   end
   return v
end

--- Whether `k` has a value.
function OM.has<K, V>(self: OM<K, V>, k: K): boolean
   check_map(self, "has")
   return self._vals[k] ~= nil
end

--- Remove `k` and its value. Returns `true` when there was one to remove, `false` when there
--- was not. The keys after it move up one place: O(n) in the number of entries.
function OM.delete<K, V>(self: OM<K, V>, k: K): boolean
   check_map(self, "delete")
   if self._vals[k] == nil then
      return false
   end
   self._vals[k] = nil
   table.remove(self._keys, index_in(self._keys, k))
   return true
end

--- The keys as a new array, in insertion order.
function OM.keys<K, V>(self: OM<K, V>): {K}
   check_map(self, "keys")
   local out: {K} = {}
   for i = 1, #self._keys do
      out[i] = self._keys[i]
   end
   return out
end

--- The values as a new array, in the insertion order of their keys.
function OM.values<K, V>(self: OM<K, V>): {V}
   check_map(self, "values")
   local out: {V} = {}
   for i = 1, #self._keys do
      out[i] = self._vals[self._keys[i]]
   end
   return out
end

--- The entries as a new array of new `{ k, v }` pairs, in insertion order. The shape
--- `from_entries` takes, so `ordered.from_entries(m:entries())` is a copy.
function OM.entries<K, V>(self: OM<K, V>): {{K, V}}
   check_map(self, "entries")
   local out: {{K, V}} = {}
   for i = 1, #self._keys do
      local k = self._keys[i]
      out[i] = { k, self._vals[k] }
   end
   return out
end

--- An iterator over the entries in insertion order: `for k, v in m:pairs() do`.
---
--- The iterator reads the live map. A key set during the loop is visited at the end; a key
--- deleted during the loop shifts the ones after it, so the next entry is skipped. Take
--- `entries()` first when the loop body changes the map.
function OM.pairs<K, V>(self: OM<K, V>): function(): (K, V)
   check_map(self, "pairs")
   local i = 0
   return function(): (K, V)
      i = i + 1
      local k = self._keys[i]
      if k == nil then
         return nil, nil
      end
      return k, self._vals[k]
   end
end

--- How many entries there are.
function OM.len<K, V>(self: OM<K, V>): integer
   check_map(self, "len")
   return #self._keys
end

--- Whether there are no entries at all.
function OM.is_empty<K, V>(self: OM<K, V>): boolean
   check_map(self, "is_empty")
   return #self._keys == 0
end

--- A shallow copy: the same keys and values in the same order, a different `Map`. A change
--- to either afterwards is not seen by the other.
function OM.copy<K, V>(self: OM<K, V>): OM<K, V>
   check_map(self, "copy")
   local out: OM<K, V> = ordered.map()
   for i = 1, #self._keys do
      local k = self._keys[i]
      out:set(k, self._vals[k])
   end
   return out
end

--- Call `f(value, key)` for each entry, in insertion order.
function OM.each<K, V>(self: OM<K, V>, f: function(V, K))
   check_map(self, "each")
   check_function(f, "Map.each", "f")
   for i = 1, #self._keys do
      local k = self._keys[i]
      f(self._vals[k], k)
   end
end

--- A new `Map` with the same entries, ordered by key: by `cmp`, or by `<` when no comparator
--- is given, which wants keys of one comparable type. `self` is not changed.
function OM.sorted<K, V>(self: OM<K, V>, cmp?: function(K, K): boolean): OM<K, V>
   check_map(self, "sorted")
   local ks = self:keys()
   local less = cmp or (lt as function(K, K): boolean)
   table.sort(ks, less)
   local out: OM<K, V> = ordered.map()
   for i = 1, #ks do
      local k = ks[i]
      out:set(k, self._vals[k])
   end
   return out
end

--- The entries as a new plain `{K:V}`. The order is not carried: a plain map has none.
function OM.to_table<K, V>(self: OM<K, V>): {K:V}
   check_map(self, "to_table")
   local out: {K:V} = {}
   for i = 1, #self._keys do
      local k = self._keys[i]
      out[k] = self._vals[k]
   end
   return out
end

------------------------------------------------------------------------------------------
-- Set
------------------------------------------------------------------------------------------

--- An empty `Set`. Annotate the receiving local so `T` is known:
--- `local s: ordered.Set<string> = ordered.set()`.
function ordered.set<T>(): OS<T>
   local self: OS<T> = setmetatable({ _items = {}, _has = {} }, set_mt as metatable<OS<T>>)
   return self
end

--- A `Set` holding each element of `t`, in array order. A value that appears more than once
--- keeps its first position.
function ordered.from<T>(t: {T}): OS<T>
   check_array(t, "from")
   local s: OS<T> = ordered.set()
   for i = 1, #t do
      s:add(t[i])
   end
   return s
end

--- Whether `x` is a `Set` made by this module.
function ordered.is_set(x: any): boolean
   return getmetatable(x) == set_mt
end

--- Put `v` in the set and return `self`. A new value goes to the end of the order; a value
--- already present leaves the set as it was. Raises on `nil`.
function OS.add<T>(self: OS<T>, v: T): OS<T>
   check_set(self, "add", "self")
   if v == nil then
      error("htlx.ordered.Set.add: refusing a nil value", 2)
   end
   if not self._has[v] then
      self._has[v] = true
      self._items[#self._items + 1] = v
   end
   return self
end

--- Whether `v` is in the set.
function OS.has<T>(self: OS<T>, v: T): boolean
   check_set(self, "has", "self")
   return self._has[v] == true
end

--- Remove `v`. Returns `true` when it was there, `false` when it was not. The values after
--- it move up one place: O(n) in the number of values.
function OS.delete<T>(self: OS<T>, v: T): boolean
   check_set(self, "delete", "self")
   if not self._has[v] then
      return false
   end
   self._has[v] = nil
   table.remove(self._items, index_in(self._items, v))
   return true
end

--- The values as a new array, in insertion order.
function OS.values<T>(self: OS<T>): {T}
   check_set(self, "values", "self")
   local out: {T} = {}
   for i = 1, #self._items do
      out[i] = self._items[i]
   end
   return out
end

--- An iterator over the values in insertion order: `for v in s:iter() do`.
---
--- The iterator reads the live set. A value added during the loop is visited at the end; a
--- value deleted during the loop shifts the ones after it, so the next value is skipped.
--- Take `values()` first when the loop body changes the set.
function OS.iter<T>(self: OS<T>): function(): T
   check_set(self, "iter", "self")
   local i = 0
   return function(): T
      i = i + 1
      return self._items[i]
   end
end

--- How many values there are.
function OS.len<T>(self: OS<T>): integer
   check_set(self, "len", "self")
   return #self._items
end

--- Whether there are no values at all.
function OS.is_empty<T>(self: OS<T>): boolean
   check_set(self, "is_empty", "self")
   return #self._items == 0
end

--- A shallow copy: the same values in the same order, a different `Set`. A change to either
--- afterwards is not seen by the other.
function OS.copy<T>(self: OS<T>): OS<T>
   check_set(self, "copy", "self")
   local out: OS<T> = ordered.set()
   for i = 1, #self._items do
      out:add(self._items[i])
   end
   return out
end

--- Call `f(value)` for each value, in insertion order.
function OS.each<T>(self: OS<T>, f: function(T))
   check_set(self, "each", "self")
   check_function(f, "Set.each", "f")
   for i = 1, #self._items do
      f(self._items[i])
   end
end

--- A new `Set` holding every value of `self` in its order, then every value of `other` that
--- `self` did not have, in `other`'s order. Neither set is changed.
function OS.union<T>(self: OS<T>, other: OS<T>): OS<T>
   check_set(self, "union", "self")
   check_set(other, "union", "other")
   local out = self:copy()
   for i = 1, #other._items do
      out:add(other._items[i])
   end
   return out
end

--- A new `Set` holding the values in both `self` and `other`, in `self`'s order. Neither set
--- is changed.
function OS.intersect<T>(self: OS<T>, other: OS<T>): OS<T>
   check_set(self, "intersect", "self")
   check_set(other, "intersect", "other")
   local out: OS<T> = ordered.set()
   for i = 1, #self._items do
      local v = self._items[i]
      if other._has[v] then
         out:add(v)
      end
   end
   return out
end

--- A new `Set` holding the values in `self` that are not in `other`, in `self`'s order.
--- Neither set is changed.
function OS.difference<T>(self: OS<T>, other: OS<T>): OS<T>
   check_set(self, "difference", "self")
   check_set(other, "difference", "other")
   local out: OS<T> = ordered.set()
   for i = 1, #self._items do
      local v = self._items[i]
      if not other._has[v] then
         out:add(v)
      end
   end
   return out
end

--- Whether every value of `self` is in `other`. An empty set is a subset of every set, and
--- a set is a subset of itself.
function OS.is_subset<T>(self: OS<T>, other: OS<T>): boolean
   check_set(self, "is_subset", "self")
   check_set(other, "is_subset", "other")
   for i = 1, #self._items do
      if not other._has[self._items[i]] then
         return false
      end
   end
   return true
end

--- The values as a new plain `{T:boolean}`, each set to `true`: the shape `list.to_set`
--- makes. The order is not carried: a plain map has none.
function OS.to_table<T>(self: OS<T>): {T:boolean}
   check_set(self, "to_table", "self")
   local out: {T:boolean} = {}
   for i = 1, #self._items do
      out[self._items[i]] = true
   end
   return out
end

return ordered
