# types/

Hand-written `.d.tl` declarations for modules the host provides at run time and
that ship no declaration of their own (a Rust crate re-exported to Lua, a runtime
SDK): `xlib.d.tl` here makes `require("xlib")` typed in `htl check`, `htl test` and
`include_tl!`. Consulted after the project root and `src/`, before `[check] paths`;
a `.tl` source anywhere on the path beats a declaration, so nothing here can shadow
an implementation, and a second declaration of the same module is reported
(`duplicate-declaration`) rather than silently losing to one of them.

Files htl writes here are the ones the project *publishes*: the module a
`---@contract` type is declared in, for the authors of the modules that contract
holds. Declarations generated from this crate's own Rust (`#[host_module]`) are
written next to the scripts, not here. Both are committed.

So is `<crate>/`, when there is one: a dependency that names its declarations in
`[package.metadata.htl] dts` has them copied there by `htl dts` (and by check / run
/ test). Edit the crate, not the copy — the next run writes it again.
