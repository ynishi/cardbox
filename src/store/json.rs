//! The one value that crosses between Lua and the store, and the two conversions that
//! carry it.
//!
//! Everything the host hands Teal or takes back — an event's `meta` and `data`, a row out
//! of the SQL hatch, a parameter bound into one — is JSON on this side and a plain table
//! on that one. Keeping the conversion in one place is what keeps "what was measured is
//! what was stored" true: `json_encode` weighs a batch of rows with exactly the code that
//! would write it.

use htl::mlua;
use serde_json::{Map, Value as Json};

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

/// How deep a table may nest before this refuses it. A cycle would otherwise recurse
/// until the stack goes, and a JSON document has no cycles to lose.
const MAX_DEPTH: usize = 64;

impl mlua::FromLua for Value {
    fn from_lua(value: mlua::Value, lua: &mlua::Lua) -> mlua::Result<Self> {
        from_lua(value, lua, 0).map(Value)
    }
}

impl mlua::IntoLua for Value {
    fn into_lua(self, lua: &mlua::Lua) -> mlua::Result<mlua::Value> {
        into_lua(self.0, lua)
    }
}

fn from_lua(value: mlua::Value, lua: &mlua::Lua, depth: usize) -> mlua::Result<Json> {
    use mlua::Value as Lua;
    if depth > MAX_DEPTH {
        return Err(mlua::Error::external(format!(
            "a table nested more than {MAX_DEPTH} deep has no JSON value (a cycle?)"
        )));
    }
    Ok(match value {
        Lua::Nil => Json::Null,
        Lua::Boolean(b) => Json::Bool(b),
        Lua::Integer(i) => Json::from(i),
        Lua::Number(n) => serde_json::Number::from_f64(n)
            .map(Json::Number)
            .ok_or_else(|| {
                mlua::Error::external(format!("{n} is not a finite number and has no JSON value"))
            })?,
        Lua::String(s) => Json::String(lua_str(&s)?),
        Lua::Table(t) => table_to_json(t, lua, depth)?,
        other => {
            return Err(mlua::Error::external(format!(
                "a {} has no JSON value",
                other.type_name()
            )));
        }
    })
}

/// A table with a sequence part is a JSON array; anything else is an object, the empty
/// table included. Lua cannot tell `{}` from `[]` and something has to be chosen: an
/// object is the one that round-trips a record with every field cleared.
fn table_to_json(t: mlua::Table, lua: &mlua::Lua, depth: usize) -> mlua::Result<Json> {
    let n = t.raw_len();
    if n > 0 {
        let mut items = Vec::with_capacity(n);
        for i in 1..=n {
            items.push(from_lua(t.raw_get(i)?, lua, depth + 1)?);
        }
        return Ok(Json::Array(items));
    }
    let mut object = Map::new();
    for pair in t.pairs::<mlua::Value, mlua::Value>() {
        let (key, value) = pair?;
        let key = match key {
            mlua::Value::String(s) => lua_str(&s)?,
            mlua::Value::Integer(i) => i.to_string(),
            other => {
                return Err(mlua::Error::external(format!(
                    "a {} is not a JSON object key",
                    other.type_name()
                )));
            }
        };
        object.insert(key, from_lua(value, lua, depth + 1)?);
    }
    Ok(Json::Object(object))
}

/// A Lua string as text, refusing rather than mangling what is not UTF-8: JSON holds
/// text and `blob_put` holds bytes, and quietly replacing a byte would blur the two.
fn lua_str(s: &mlua::LuaString) -> mlua::Result<String> {
    let bytes = s.as_bytes();
    std::str::from_utf8(&bytes)
        .map(str::to_string)
        .map_err(|_| {
            mlua::Error::external(
                "a Lua string that is not UTF-8 has no JSON value; put it in a blob",
            )
        })
}

fn into_lua(value: Json, lua: &mlua::Lua) -> mlua::Result<mlua::Value> {
    use mlua::Value as Lua;
    Ok(match value {
        Json::Null => Lua::Nil,
        Json::Bool(b) => Lua::Boolean(b),
        Json::Number(n) => match n.as_i64() {
            Some(i) => Lua::Integer(i),
            None => Lua::Number(n.as_f64().unwrap_or(f64::NAN)),
        },
        Json::String(s) => Lua::String(lua.create_string(&s)?),
        Json::Array(items) => {
            let t = lua.create_table()?;
            for (i, item) in items.into_iter().enumerate() {
                t.raw_set(i + 1, into_lua(item, lua)?)?;
            }
            Lua::Table(t)
        }
        Json::Object(fields) => {
            let t = lua.create_table()?;
            for (key, item) in fields {
                t.raw_set(key, into_lua(item, lua)?)?;
            }
            Lua::Table(t)
        }
    })
}
