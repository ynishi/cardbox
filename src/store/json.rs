//! The one value that crosses between Lua and the store, and the two conversions that
//! carry it.
//!
//! Everything the host hands Teal or takes back — an event's `meta` and `data`, a row out
//! of the SQL hatch, a parameter bound into one — is JSON on this side and a plain table
//! on that one. Keeping the conversion in one place is what keeps "what was measured is
//! what was stored" true: `json_encode` weighs a batch of rows with exactly the code that
//! would write it.
//!
//! That code is now mlua-batteries', the crate behind `std.json` on the Teal side. It was
//! written here first because nothing else had it; sharing it buys the one thing a
//! hand-written pair could not have: an empty list stays a list. Lua cannot tell `{}` from
//! `[]`, and the convention that settles it — a `__jsontype = "array"` metatable, which
//! `std.json.array()` sets and `dkjson` reads — only works when both ends agree on it.
//! Both ends are this crate now, so `cardbox list` on an empty store prints `[]`.

use htl::mlua;
use mlua_batteries::json::{DEFAULT_MAX_DEPTH, json_to_lua, lua_to_json};
use serde_json::Value as Json;

/// JSON as it crosses to Teal: a plain Lua value, declared `any`.
///
/// A newtype rather than `serde_json::Value` itself, because mlua has no conversion for
/// that type and a host cannot write one for a foreign type it does not own. The name is
/// load-bearing in one place only — htl's syntactic mapping spells the ident `Value` as
/// `any`, which is the escape hatch this is meant to be.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Value(pub Json);

impl From<Json> for Value {
    fn from(j: Json) -> Self {
        Value(j)
    }
}

impl mlua::FromLua for Value {
    fn from_lua(value: mlua::Value, _lua: &mlua::Lua) -> mlua::Result<Self> {
        lua_to_json(&value, DEFAULT_MAX_DEPTH).map(Value)
    }
}

impl mlua::IntoLua for Value {
    fn into_lua(self, lua: &mlua::Lua) -> mlua::Result<mlua::Value> {
        json_to_lua(lua, &self.0, DEFAULT_MAX_DEPTH)
    }
}
