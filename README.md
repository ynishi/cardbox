# cardbox

Teal project managed with [htl](https://github.com/ynishi/htl).

```sh
htl check .            # type-check + lints
htl test               # tests/*_test.tl via htl.test
htl fmt .              # whitespace formatter
htl pkg install        # fetch [deps] from mlua-pkg.toml
cargo run              # the binary: preload, then src/main.tl (type-checked at build)
                       # (src/main.tl requires the Rust `host`, so `htl run` cannot run it)
cargo test             # the library's Rust test: the module loaded through preload
```

Module: `src/cardbox/init.tl` (`require("cardbox")` from `src/` and `tests/`).

`mlua-pkg.toml` `entry = "src/cardbox"` only matters to *consumers* that depend on this
package through mlua-pkg: they get it as `require("cardbox")`. The Rust host is a library:
`src/lib.rs` holds the `#[host_module]`, embeds this module, and registers both in
`preload(&Htl)`. `src/main.rs` is a few lines on top of it — `preload`, then the entry
script. Grow the library, not the binary.

`src/host.d.tl` is generated from `#[host_module]` in `src/lib.rs`: `cargo build` writes it,
and so does `htl dts` / `htl check` without building, so the Teal side always sees the
current Rust signatures.
