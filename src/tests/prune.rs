//! Prune, export, import and the blob GC, from Lua.
//!
//! The properties these are for, in the order the sequence runs them:
//!
//! - a pruned card is gone from the log, from the read models and from `get` — and the
//!   journal entry that says so is not;
//! - a retain with no confirmed export behind it is refused, and the refusal says to run
//!   one;
//! - a blob two cards shared survives the first of them going, and one only the pruned
//!   card used does not;
//! - an aliased card and a parent are not pruned, and neither is touched;
//! - a dry run writes nothing at all;
//! - an export and an import round-trip a store into a fresh one, coordinates included;
//! - a rebuild after a prune succeeds and reads the same, which is the whole of what
//!   `tolerates_truncation` claims;
//! - a second export with nothing new writes no file.
//!
//! The scripts are Lua rather than Teal — `Htl::lua().load` takes the interpreter's own
//! language, and the modules they call were type-checked at `cargo build`.

use std::path::Path;

use htl::Htl;

use super::{eval, opened};

/// Open a card, write one batch of samples, close it. The shortest life a card has, and
/// the one every test below prunes or keeps.
const A_CARD: &str = r#"
local function a_card(store, cards, id, pkg)
   local card, err = cards.open(store, {
      id = id, pkg = pkg, scenario = 'arith', source = 'eval', created_by = 'test',
   })
   assert(err == nil, tostring(err))
   local _, serr = cards.append_samples(store, card.id, { { q = 1, a = 2 } })
   assert(serr == nil, tostring(serr))
   local _, cerr = cards.close(store, card.id, { ok = true, stats = { mean_score = 0.5, n = 1 } })
   assert(cerr == nil, tostring(cerr))
   return card.id
end
"#;

/// The whole sequence on one card, end to end.
#[test]
fn a_pruned_card_leaves_its_stream_its_rows_and_nothing_else() -> anyhow::Result<()> {
    let (dir, h) = opened()?;
    let out: Vec<String> = eval(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        local doomed = a_card(store, cards, 'debris_one', '_test_arith')
        local kept = a_card(store, cards, 'keeper', 'cot')

        local report, err = cards.prune(store, {{
           pkg_like = cards.like_escape('_test_') .. '%',
           reason = 'test debris from the smoke run',
        }})
        assert(err == nil, tostring(err))
        assert(#report.selected == 1 and report.selected[1] == doomed, 'one card selected')
        assert(#report.pruned == 1 and report.pruned[1] == doomed, 'and it was pruned')
        assert(report.dry_run == false, 'not a dry run')
        assert(report.export_file ~= nil, 'the export that vouched for it')
        -- card_opened + samples_appended + card_closed
        assert(report.events_removed == 3, tostring(report.events_removed))

        -- The log has let go.
        local events, e1 = store:read_stream('card-' .. doomed)
        assert(e1 == nil, tostring(e1))
        assert(#events == 0, 'the stream reads empty')

        -- So has the read model, both ways of asking.
        local view, gerr = cards.get(store, doomed)
        assert(view == nil, 'get refuses')
        assert(gerr == 'no card ' .. doomed, gerr)
        local rows, e2 = store:query('SELECT id FROM cb_cards WHERE id = ?', {{ doomed }})
        assert(e2 == nil, tostring(e2))
        assert(#rows == 0, 'the cb_cards row is gone')
        local samples, e3 = store:query('SELECT card_id FROM cb_samples WHERE card_id = ?', {{ doomed }})
        assert(e3 == nil, tostring(e3))
        assert(#samples == 0, 'and so are its samples')

        -- The card nobody asked about is untouched.
        assert(cards.get(store, kept).id == kept, 'the other card is still here')

        -- The journal is what the card left behind.
        local log, lerr = cards.prune_log(store)
        assert(lerr == nil, tostring(lerr))
        assert(#log == 1, #log)
        assert(log[1].count == 1, log[1].count)
        assert(log[1].cards[1] == doomed, log[1].cards[1])
        assert(log[1].reason == 'test debris from the smoke run', log[1].reason)
        assert(log[1].export_file == report.export_file, 'and where the export went')

        return {{ report.export_file }}
        "#
        ),
    )?;

    // The export is a real file of real JSON Lines.
    let export = Path::new(&out[0]);
    assert!(export.starts_with(dir.path().join("export")), "{export:?}");
    let text = std::fs::read_to_string(export)?;
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 6, "two cards, three events each");
    for line in lines {
        let value: serde_json::Value = serde_json::from_str(line)?;
        assert!(value.get("stream").and_then(|s| s.as_str()).is_some());
        assert!(value.get("event").and_then(|e| e.get("kind")).is_some());
    }
    Ok(())
}

/// The guard, from below: `retain_streams` on a store nothing has exported.
#[test]
fn retaining_before_exporting_is_refused_and_says_to_export() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let err: String = eval(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        local id = a_card(store, cards, 'unexported', 'cot')
        local report, err = store:retain_streams({{ 'card-' .. id }})
        assert(report == nil, 'nothing was removed')

        local events, e1 = store:read_stream('card-' .. id)
        assert(e1 == nil, tostring(e1))
        assert(#events == 3, 'the card is all still there')
        return err
        "#
        ),
    )?;
    assert!(err.contains("export"), "{err}");
    assert!(err.contains("confirmed exports reach only"), "{err}");
    Ok(())
}

/// Reference counting, which is the whole of the blob GC's rule.
#[test]
fn a_shared_blob_survives_the_first_card_that_used_it() -> anyhow::Result<()> {
    let (dir, h) = opened()?;
    let out: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local function with_checkpoint(id, pkg, bytes)
           local card, err = cards.open(store, {
              id = id, pkg = pkg, scenario = 'arith', source = 'eval', created_by = 'test',
           })
           assert(err == nil, tostring(err))
           local _, kerr = cards.save_checkpoint(store, card.id, bytes, { format = 'safetensors' })
           assert(kerr == nil, tostring(kerr))
           local _, cerr = cards.close(store, card.id, { ok = true })
           assert(cerr == nil, tostring(cerr))
           return card.id
        end

        -- The same bytes in two cards are one blob, because a blob is named by its bytes.
        local doomed = with_checkpoint('debris_blob', '_test_blob', 'the shared weights')
        local kept = with_checkpoint('keeper_blob', 'cot', 'the shared weights')
        -- And one only the doomed card ever used.
        local _, oerr = cards.save_checkpoint(store, doomed, 'its own weights', { format = 'safetensors' })
        assert(oerr ~= nil, 'the card is closed')

        local lonely = with_checkpoint('debris_lonely', '_test_blob', 'its own weights')

        local shared = store:query(
           'SELECT blob FROM cb_checkpoints WHERE card_id = ?', { kept })[1].blob
        local alone = store:query(
           'SELECT blob FROM cb_checkpoints WHERE card_id = ?', { lonely })[1].blob
        assert(shared ~= alone, 'two different blobs')
        assert(store:query('SELECT refs FROM cb_blobs WHERE hash = ?', { shared })[1].refs == 2, 'two refs')

        local report, err = cards.prune(store, {
           ids = { doomed, lonely }, reason = 'blob refcount test',
        })
        assert(err == nil, tostring(err))
        assert(#report.pruned == 2, #report.pruned)
        assert(report.blobs_deleted == 1, tostring(report.blobs_deleted))

        local left = store:query('SELECT refs FROM cb_blobs WHERE hash = ?', { shared })
        assert(#left == 1 and left[1].refs == 1, 'the shared blob kept one reference')
        assert(#store:query('SELECT refs FROM cb_blobs WHERE hash = ?', { alone }) == 0, 'the row went')
        assert(store:blob_get(shared) == 'the shared weights', 'and the bytes are still readable')
        assert(store:blob_get(alone) == nil, 'the lonely blob is gone')

        return { store:blob_path(shared), store:blob_path(alone) }
        "#,
    )?;
    assert!(Path::new(&out[0]).exists(), "the shared blob is on disk");
    assert!(!Path::new(&out[1]).exists(), "the lonely one is not");
    assert!(dir.path().join("blobs").exists());
    Ok(())
}

/// The two refusals that are about something outside the card.
#[test]
fn an_aliased_card_and_a_parent_are_skipped_and_untouched() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let out: Vec<String> = eval(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        local named = a_card(store, cards, 'debris_named', '_test_skip')
        local parent = a_card(store, cards, 'debris_parent', '_test_skip')
        local plain = a_card(store, cards, 'debris_plain', '_test_skip')

        local _, aerr = cards.alias(store, 'champion', named)
        assert(aerr == nil, tostring(aerr))
        local child, cerr = cards.open(store, {{
           id = 'the_child', pkg = 'cot', scenario = 'arith', source = 'eval',
           created_by = 'test', parents = {{ parent }},
        }})
        assert(cerr == nil, tostring(cerr))

        local report, err = cards.prune(store, {{
           pkg_like = cards.like_escape('_test_skip'), reason = 'skips',
        }})
        assert(err == nil, tostring(err))
        assert(#report.selected == 1 and report.selected[1] == plain, 'only the plain one')
        assert(#report.skipped_aliased == 1 and report.skipped_aliased[1] == named, 'the alias held')
        assert(#report.skipped_parent == 1 and report.skipped_parent[1] == parent, 'the lineage held')

        -- Untouched, not merely unselected.
        assert(cards.get(store, named).id == named, 'the aliased card is here')
        assert(cards.get_by_alias(store, 'champion').id == named, 'and the name still resolves')
        assert(cards.get(store, parent).id == parent, 'the parent is here')
        assert(#cards.lineage(store, child.id, {{}}).parents == 1, 'and so is the edge')
        assert(#store:read_stream('card-' .. named) == 3, 'events and all')

        return {{ report.pruned[1] }}
        "#
        ),
    )?;
    assert_eq!(out, ["debris_plain"]);
    Ok(())
}

/// A dry run is a question about the policy, and asking it writes nothing — not the
/// journal event, not the export, not a retention ledger entry.
#[test]
fn a_dry_run_writes_nothing() -> anyhow::Result<()> {
    let (dir, h) = opened()?;
    eval::<bool>(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        local id = a_card(store, cards, 'debris_dry', '_test_dry')
        local before = store:query('SELECT count(*) AS n FROM events', {{}})[1].n

        local report, err = cards.prune(store, {{
           pkg_like = cards.like_escape('_test_dry'), reason = 'looking only', dry_run = true,
        }})
        assert(err == nil, tostring(err))
        assert(report.dry_run == true, 'it says so')
        assert(#report.selected == 1 and report.selected[1] == id, 'it still selected')
        assert(#report.pruned == 0, 'and pruned nothing')
        assert(report.export_file == nil, 'no export was taken')
        assert(report.events_removed == 0 and report.blobs_deleted == 0, 'nothing removed')

        local after = store:query('SELECT count(*) AS n FROM events', {{}})[1].n
        assert(after == before, 'the log did not move: ' .. tostring(before) .. ' -> ' .. tostring(after))
        assert(#store:query('SELECT id FROM exports', {{}}) == 0, 'no export receipt')
        assert(#cards.prune_log(store) == 0, 'no journal entry')
        assert(cards.get(store, id).id == id, 'the card is here')
        return true
        "#
        ),
    )?;
    // And no file: the directory is not even created.
    assert!(!dir.path().join("export").exists());
    Ok(())
}

/// The other half of retention: history that outlives the file it was written in.
#[test]
fn an_export_imports_into_a_fresh_store_as_the_same_log() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let export: String = eval(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        a_card(store, cards, 'one', 'cot')
        a_card(store, cards, 'two', 'cot')
        local _, aerr = cards.alias(store, 'champion', 'two')
        assert(aerr == nil, tostring(aerr))

        local report, err = cards.export(store)
        assert(err == nil, tostring(err))
        assert(report.file ~= nil, 'a file')
        assert(report.events == 7, tostring(report.events))
        assert(report.from == 0, 'from the beginning of the log')
        return report.file
        "#
        ),
    )?;

    let fresh = tempfile::tempdir()?;
    let into = Htl::new()?;
    crate::preload(&into, fresh.path())?;
    let ids: Vec<String> = eval(
        &into,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local report, err = cards.import(store, {export:?})
        assert(err == nil, tostring(err))
        assert(report.events == 7, tostring(report.events))
        assert(report.reproduced_coordinates == true, 'the same log, not merely the same events')

        local one = cards.get(store, 'one')
        assert(one ~= nil and one.state == 'closed_ok', 'the card came across')
        assert(one.samples.rows == 1, one.samples.rows)
        assert(one.stats.mean_score == 0.5, 'stats and all')
        assert(cards.get_by_alias(store, 'champion').id == 'two', 'and the alias')

        local out = {{}}
        for i, row in ipairs(store:query('SELECT id FROM cb_cards ORDER BY id', {{}})) do
           out[i] = row.id
        end
        return out
        "#
        ),
    )?;
    assert_eq!(ids, ["one", "two"]);
    Ok(())
}

/// What `tolerates_truncation` claims, checked: a rebuild over a log missing the pruned
/// cards' events reproduces the model the fold left behind.
#[test]
fn a_rebuild_after_a_prune_reproduces_the_same_read_models() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    eval::<bool>(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        a_card(store, cards, 'debris_rb', '_test_rb')
        local kept = a_card(store, cards, 'keeper_rb', 'cot')
        local _, aerr = cards.alias(store, 'champion', kept)
        assert(aerr == nil, tostring(aerr))

        local report, err = cards.prune(store, {{
           pkg_like = cards.like_escape('_test_rb'), reason = 'rebuild test',
        }})
        assert(err == nil, tostring(err))
        assert(#report.pruned == 1, #report.pruned)

        local before = cards.get(store, kept)
        local applied, rerr = store:rebuild()
        assert(rerr == nil, tostring(rerr))
        assert(applied > 0, 'it replayed something')

        -- The pruned card does not come back, and nothing else changed.
        assert(cards.get(store, 'debris_rb') == nil, 'still gone')
        local after = cards.get(store, kept)
        assert(after.state == before.state, after.state)
        assert(after.samples.rows == before.samples.rows, after.samples.rows)
        assert(after.stats.mean_score == before.stats.mean_score, 'stats survived the replay')
        assert(after.aliases[1] == 'champion', 'and the alias')
        assert(#cards.prune_log(store) == 1, 'the journal replayed as one entry')

        -- The journal's decrement did not run a second time over a card that is not there.
        local negative = store:query('SELECT hash FROM cb_blobs WHERE refs < 0', {{}})
        assert(#negative == 0, 'no reference count went below zero')
        return true
        "#
        ),
    )?;
    Ok(())
}

/// An export of nothing is not a file holding nothing.
#[test]
fn a_second_export_with_nothing_new_writes_no_file() -> anyhow::Result<()> {
    let (dir, h) = opened()?;
    eval::<bool>(
        &h,
        &format!(
            r#"
        local cards = require('cardbox').cards
        local store = require('store')
        {A_CARD}

        a_card(store, cards, 'once', 'cot')
        local first, err = cards.export(store)
        assert(err == nil, tostring(err))
        assert(first.file ~= nil and first.events == 3, tostring(first.events))

        local again, e2 = cards.export(store)
        assert(e2 == nil, tostring(e2))
        assert(again.file == nil, 'no file')
        assert(again.events == 0, tostring(again.events))
        assert(again.from == first.through, 'and it starts where the first one ended')
        assert(again.through == first.through, 'having gone nowhere')
        return true
        "#
        ),
    )?;

    let files: Vec<_> =
        std::fs::read_dir(dir.path().join("export"))?.collect::<std::io::Result<Vec<_>>>()?;
    assert_eq!(files.len(), 1, "one call, one file");
    Ok(())
}

/// `older_than_ms` is the run's age: a run from years ago written a moment ago is old, and
/// one that started now is not, whatever order the two were written in.
#[test]
fn older_than_is_the_run_s_age_and_not_the_write_s() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let selected: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')
        assert(cards.open(store, { pkg = 'aged', scenario = 'a', source = 'eval',
           created_by = 'x', id = 'fresh' }))
        assert(cards.close(store, 'fresh', { ok = true }))
        assert(cards.open(store, { pkg = 'aged', scenario = 'a', source = 'import',
           created_by = 'x', id = 'imported', started_ms = cards.utc_ms('2020-01-01T00:00:00Z') }))
        assert(cards.close(store, 'imported', { ok = true }))

        local report, err = cards.prune(store, {
           pkg = 'aged', older_than_ms = 24 * 3600 * 1000, reason = 'a day old', dry_run = true,
        })
        assert(err == nil, tostring(err))
        return report.selected
        "#,
    )?;
    assert_eq!(selected, ["imported"]);
    Ok(())
}
