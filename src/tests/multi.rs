//! Two `Store`s on one root, in one process: what a second process would see.
//!
//! `command` is per `Store`, so two `Store`s on the same `cards.db` are exactly the
//! situation two processes are in — nothing above SQLite is shared. What these check is
//! what eventsdb's `IMMEDIATE` transactions and the checkpoint read inside them give on
//! their own: a write in one is read in the other, the projection folds each event once
//! however many runners race for it, and two writers appending at once are serialised
//! rather than failed. The window `bind_alias` documents — a card pruned between the read
//! of its `card_opened` and the write of the alias — is not closed by any of this, and is
//! not something these tests can reach without a hook between the two calls.

use crate::store::{Store, Value};
use serde_json::json;

fn v(j: serde_json::Value) -> Value {
    Value(j)
}

fn open_card(s: &Store, id: &str) -> anyhow::Result<()> {
    s.append(
        &format!("card-{id}"),
        "card_opened",
        v(json!({ "pkg": "cot", "scenario": "arith", "source": "eval" })),
        v(json!({})),
    )?;
    Ok(())
}

fn one_row(s: &Store, sql: &str, params: Vec<Value>) -> anyhow::Result<serde_json::Value> {
    let rows = s.query(sql, params)?;
    Ok(rows
        .into_iter()
        .next()
        .map(|r| r.0)
        .unwrap_or(serde_json::Value::Null))
}

/// A write in one store is read in the other, and the fold counts it once whichever
/// store's runner gets to it, because the cursor lives in the database and not in the
/// runner.
#[test]
fn a_second_store_reads_the_first_ones_writes_and_folds_them_once() -> anyhow::Result<()> {
    let dir = tempfile::tempdir()?;
    let a = Store::open(dir.path())?;
    let b = Store::open(dir.path())?;

    open_card(&a, "m1")?;
    let rec = b.append_if(
        "card-m1",
        "open_unclosed",
        "samples_appended",
        v(json!({})),
        v(json!({ "n": 3 })),
    )?;
    assert!(rec.is_some(), "b sees the card a opened and appends to it");

    let sql = "SELECT sample_batches, sample_rows FROM cb_cards WHERE id = ?1";
    let from_a = one_row(&a, sql, vec![v(json!("m1"))])?;
    assert_eq!(from_a["sample_batches"], 1);
    assert_eq!(from_a["sample_rows"], 3);

    // b's runner has never folded; its cursor is a's, read from the file.
    assert_eq!(b.catch_up()?, 0, "nothing left for b to fold");
    let from_b = one_row(&b, sql, vec![v(json!("m1"))])?;
    assert_eq!(from_b, from_a, "the same row, not a second fold of it");
    Ok(())
}

/// A name bound from one store is a binding in the other, and the idempotence of a
/// rebind to the same card holds across stores.
#[test]
fn an_alias_bound_in_one_store_is_the_binding_in_the_other() -> anyhow::Result<()> {
    let dir = tempfile::tempdir()?;
    let a = Store::open(dir.path())?;
    let b = Store::open(dir.path())?;

    open_card(&a, "m2")?;
    let bound = b.bind_alias("champion", "m2", None)?;
    assert!(bound.is_some(), "b binds to a card only a wrote");

    let row = one_row(
        &a,
        "SELECT card_id FROM cb_aliases WHERE name = ?1",
        vec![v(json!("champion"))],
    )?;
    assert_eq!(row["card_id"], "m2");

    assert!(
        a.bind_alias("champion", "m2", None)?.is_none(),
        "a declines a rebind to the same card b already bound"
    );
    assert!(
        b.bind_alias("champion", "nobody", None).is_err(),
        "a card no store opened is refused"
    );
    Ok(())
}

/// Two writers at once, each in its own store, each on its own stream. eventsdb's
/// `busy_timeout` and retry are what stand between them, and every append lands.
#[test]
fn two_stores_appending_at_once_are_serialised_not_failed() -> anyhow::Result<()> {
    const EACH: usize = 100;
    let dir = tempfile::tempdir()?;
    let root = dir.path().to_path_buf();

    let writer = |id: &'static str| {
        let root = root.clone();
        std::thread::spawn(move || -> anyhow::Result<()> {
            let s = Store::open(&root)?;
            open_card(&s, id)?;
            for i in 0..EACH {
                let rec = s.append_if(
                    &format!("card-{id}"),
                    "open_unclosed",
                    "samples_appended",
                    v(json!({})),
                    v(json!({ "n": 1, "i": i })),
                )?;
                anyhow::ensure!(rec.is_some(), "{id}: append {i} declined");
            }
            Ok(())
        })
    };
    let ta = writer("ta");
    let tb = writer("tb");
    ta.join().expect("thread a")?;
    tb.join().expect("thread b")?;

    let s = Store::open(dir.path())?;
    assert_eq!(s.read_stream("card-ta", None)?.len(), EACH + 1);
    assert_eq!(s.read_stream("card-tb", None)?.len(), EACH + 1);
    let total = one_row(&s, "SELECT COUNT(*) AS c FROM cb_samples", vec![])?;
    assert_eq!(total["c"], (2 * EACH) as i64);
    let rows = one_row(&s, "SELECT SUM(sample_rows) AS r FROM cb_cards", vec![])?;
    assert_eq!(
        rows["r"],
        (2 * EACH) as i64,
        "each event counted exactly once"
    );
    Ok(())
}
