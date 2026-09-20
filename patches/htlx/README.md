# htl-x

The collections library for Teal projects built with [htl](https://github.com/ynishi/htl):
what Penlight's `tablex` / `List` / `seq` / `OrderedMap`, Lua's `table`, lodash, Kotlin's
`kotlin.collections`, Go's `slices` / `maps` and Deno's `@std/collections` have in common,
written once, typed, for the two table shapes Teal has.

Pure Teal, no host. Four modules:

| module | over | what |
|---|---|---|
| `htlx.list` | arrays `{T}` | walk, cut, order, combine, split, set operations, random, ask |
| `htlx.tablex` | maps `{K:V}`, and any table for `deep_*` / `freeze` | keys and entries, pick and merge, deep copy / equals / merge, read-only views |
| `htlx.seq` | iterators `function(): T` | the lazy side: a pipeline over an array, a map or an endless rule, pulled one element at a time |
| `htlx.ordered` | `Map<K, V>` and `Set<T>` records | maps and sets that remember the order things were put in, which `pairs` does not |

`require("htlx")` gives all four as `htlx.list`, `htlx.tablex`, `htlx.seq` and `htlx.ordered`.

## Using it

In your project's `mlua-pkg.toml`:

```toml
[deps]
htlx = { git = "https://github.com/ynishi/htl-x", tag = "v0.1.0" }
```

then

```sh
htl pkg install
```

and in any `.tl`:

```lua
local list = require("htlx.list")
local tablex = require("htlx.tablex")
local seq = require("htlx.seq")
local ordered = require("htlx.ordered")

for name, count in tablex.sorted_pairs(counts) do   -- pairs, in key order
   print(name, count)
end

local wanted = list.to_set({ "json", "quiet" })      -- { json = true, quiet = true }
local ids = list.map(rows, function(row: Row): string return row.id end)
local by_kind = list.group_by(rows, function(row: Row): string return row.kind end)
local oldest = list.min_by(rows, function(row: Row): integer return row.born end)

local firsts = seq.collect(seq.take(seq.map(seq.iterate(1, function(n: integer): integer
   return n * 2
end), tostring), 5))                                 -- { "1", "2", "4", "8", "16" }

local m: ordered.Map<string, integer> = ordered.map()
m:set("b", 2); m:set("a", 1)
for k, v in m:pairs() do print(k, v) end             -- b 2, then a 1
```

The `[deps]` key is the require root, so it has to be `htlx`. Needs an htl that applies
a dependency's `entry` — `main` after ynishi/htl#204, or the release after 0.4.0; on
0.4.0 itself every `require("htlx.*")` is `module not found`.

## The functions

`htlx.list` — arrays `{T}`:

| | |
|---|---|
| walk | `map` `filter` `filter_map` `flat_map` `each` `fold` `any` `all` `find` `find_index` `index_of` `last_index_of` `contains` `enumerate` |
| cut | `take` `drop` `take_while` `drop_while` `slice` `chunk` |
| order | `sorted` `sorted_by` `reverse` `min` `max` `min_by` `max_by` `sum` `sum_of` `binary_search` |
| combine | `concat` `flatten` `zip` `unzip` `range` `join` `fill` |
| split | `partition` `group_by` `uniq` `uniq_by` |
| sets | `to_set` `union` `intersect` `difference` |
| random | `shuffle` `sample` |
| ask | `equals` `is_empty` `len` `copy` |
| stack | `push` `pop` |

`htlx.tablex` — maps `{K:V}`:

| | |
|---|---|
| walk | `keys` `values` `sorted_keys` `sorted_pairs` `each` `entries` `from_entries` |
| shape | `map` `map_keys` `filter` `merge` `pick` `omit` `invert` |
| ask | `get_or` `count` `is_empty` `equals` `copy` |
| any table | `deep_copy` `deep_equals` `deep_merge` `freeze` `is_frozen` |

`htlx.seq` — iterators `function(): T`:

| | |
|---|---|
| in | `of` `keys` `values` `entries` `range` `iterate` |
| through | `map` `filter` `filter_map` `flat_map` `take` `drop` `take_while` `drop_while` `zip` `enumerate` `chain` |
| out | `collect` `fold` `any` `all` `find` `each` `to_map` `count` |

`htlx.ordered` — `Map<K, V>` and `Set<T>`:

| | |
|---|---|
| make | `map` `from_entries` `from_table` `set` `from` `is_map` `is_set` |
| `Map` | `set` `get` `get_or` `has` `delete` `keys` `values` `entries` `pairs` `len` `is_empty` `copy` `each` `sorted` `to_table` |
| `Set` | `add` `has` `delete` `values` `iter` `len` `is_empty` `copy` `each` `union` `intersect` `difference` `is_subset` `to_table` |

Each function's doc comment, above it in the source, is the contract.

## Rules

Every function in every module keeps these:

- **Argument bugs raise.** A non-table where a table is due, or a non-function for `f`,
  is an `error` naming the function, not a `nil, err` return. Those are for the caller's
  code, not the caller's data.
- **`nil` never goes into an array, and ends a sequence.** `{T}` is a Lua sequence; a hole
  stops `#` and every loop after it. `list.push(t, nil)` raises, `list.map` raises when `f`
  returns `nil`, and `filter` / `filter_map` are the way to drop elements. In `seq`, `nil`
  is the end; `false` is an element.
- **Nothing is mutated** except what exists to mutate: `list.push` / `pop` / `shuffle`, and
  the `set` / `add` / `delete` methods of `ordered`. Every other function returns a new
  table (`freeze` returns a view). Insertion and removal at a position, and sorting in
  place, are `table.insert` / `table.remove` / `table.sort`, which Lua already has.
- **A lookup that finds nothing returns `nil`** (`find`, `min`, `pop`, `get`, ...). Teal
  cannot write `T | nil`; the doc comment says it where it applies. `get_or` is the one
  that does not.
- **`_by` takes a key function** (`sorted_by`, `min_by`, `group_by`, `uniq_by`), as in
  Kotlin, Deno and lodash. **A comparator is always the last, optional argument** and is
  `<` as `table.sort` takes it: `function(a, b): boolean`, true when `a` sorts first. With
  none, `<` is used, and elements it cannot compare raise at run time.
- **Arrays come back as arrays.** `keys`, `values`, `map`, `filter` return `{T}`; the
  iterators are `sorted_pairs`, `enumerate`, `ordered`'s `pairs` / `iter`, and everything
  in `seq`.
- **A map and an array never share a signature.** They are different types in Teal, so
  `tablex.map` and `list.map` are two functions and neither accepts the other's argument.
  `deep_copy`, `deep_equals`, `deep_merge` and `freeze` take any table as `T` and give the
  same `T` back.

Two things Teal makes you spell:

- A function type followed by more parameters needs parentheses —
  `key: (function(T): K), cmp?: ...` — or the return list swallows what follows.
- `ordered.map()` and `ordered.set()` need the type on the variable —
  `local m: ordered.Map<string, integer> = ordered.map()` — since nothing else fixes `K`
  and `V`. `from_entries` / `from` / `from_table` infer it.

## What is not here

- string helpers, argparse, pretty-printing, JSON, IO, regex: those are on the Rust side
  ([mlua-batteries](https://github.com/ynishi/mlua-batteries), `std.*`). This package is
  the Teal side: tables only.
- in-place insert / remove / sort / clear: `table.*` has them.

## Developing

```sh
htl check .            # type-check + lints (strict)
htl test               # tests/*_test.tl via htl.test
htl fmt .              # whitespace formatter
```

Sources are under `src/htlx/`; `mlua-pkg.toml` `entry = "src/htlx"` is what makes a
consumer's `require("htlx.list")` land on `src/htlx/list.tl`.

## License

MIT or Apache-2.0, at your option — the same as htl. See `LICENSE-MIT` and
`LICENSE-APACHE`.
