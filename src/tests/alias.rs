//! Aliases: that one cannot be made to point at a card that was never opened, that moving
//! one keeps where it has been, that a promotion picks the same winner twice without
//! writing twice, and that a database written under the previous projection name opens.
//!
//! The scripts are Lua rather than Teal — `Htl::lua().load` takes the interpreter's own
//! language, and the modules they call were type-checked at `cargo build`.

use std::path::Path;

use eventsdb::sqlite::SqliteEventLog;
use eventsdb::{EventLog, EventStore, Position};
use htl::Htl;
use serde_json::json;

use super::{eval, opened};
use crate::store::envelope;
use crate::store::projection::CardsProjection;

/// The refusal the whole step is for. The check is the host's: `bind_alias` reads
/// `card-<id>` for a `card_opened` under the same lock it would write the binding under,
/// and there is no way down from Teal that skips it.
#[test]
fn an_alias_cannot_be_bound_to_a_card_that_was_never_opened() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let err: String = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local rec, err = cards.alias(store, 'champion', 'never_opened')
        assert(rec == nil, 'nothing was bound')
        assert(err ~= nil, 'and it said why')

        -- Not a decline: a decline writes nothing *and* says nothing, and a name pointing
        -- at a card nobody opened is a mistake rather than a state that already holds.
        local events, e2 = store:read_stream('alias-champion')
        assert(e2 == nil, tostring(e2))
        assert(#events == 0, 'the reservation stream was never written to')

        -- And the same refusal for a card id that never even could be one.
        local bad, berr = cards.alias(store, 'champion', 'not a card id')
        assert(bad == nil and berr ~= nil, 'refused before the store')

        return err
        "#,
    )?;
    assert!(
        err.contains("no card never_opened"),
        "the refusal names the card: {err}"
    );
    Ok(())
}

/// Binding, from both ends: the name resolves to the card, and the card knows what it is
/// called.
#[test]
fn a_bound_alias_resolves_to_the_card_and_the_card_lists_the_name() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let names: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                            created_by = 'x', id = 'bind_one' })
        cards.close(store, 'bind_one', { ok = true, stats = { mean_score = 0.8, n = 5 } })

        local rec, err = cards.alias(store, 'champion', 'bind_one', 'the first one')
        assert(err == nil, tostring(err))
        assert(rec ~= nil and rec.kind == 'alias_bound', 'an alias_bound was written')
        assert(rec.stream == 'alias-champion', rec.stream)
        assert(rec.meta.card_id == 'bind_one', 'the card is in the meta')
        assert(rec.meta.pkg == 'cot', 'and the pkg it came from')

        local card, e2 = cards.get_by_alias(store, 'champion')
        assert(e2 == nil, tostring(e2))
        assert(card.id == 'bind_one', card.id)
        assert(card.state == 'closed_ok', card.state)
        assert(card.stats.mean_score == 0.8, 'the whole card, not a stub')

        -- A card may carry several names, and `get` is where a reader sees them.
        local second, e3 = cards.alias(store, 'baseline', 'bind_one')
        assert(e3 == nil and second ~= nil, tostring(e3))

        local view = cards.get(store, 'bind_one')
        local listed = {}
        for i = 1, #view.aliases do listed[i] = view.aliases[i] end

        local entries, e4 = cards.alias_list(store, {})
        assert(e4 == nil, tostring(e4))
        assert(#entries == 2, #entries)
        assert(entries[1].name == 'baseline' and entries[2].name == 'champion', 'in name order')
        assert(entries[2].card_id == 'bind_one', entries[2].card_id)
        assert(entries[2].pkg == 'cot', entries[2].pkg)
        assert(entries[2].note == 'the first one', tostring(entries[2].note))

        local by_card = cards.alias_list(store, { card_id = 'bind_one' })
        assert(#by_card == 2, #by_card)
        assert(#cards.alias_list(store, { pkg = 'panel' }) == 0, 'none in another pkg')

        return listed
        "#,
    )?;
    assert_eq!(names, ["baseline", "champion"]);
    Ok(())
}

/// A rebind moves the name and keeps where it was. Both bindings are on one stream, so
/// the history is the stream — nothing was overwritten to make the move.
#[test]
fn a_rebind_moves_the_name_and_the_history_keeps_both() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let kinds: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local function run(id, score)
           cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                               created_by = 'x', id = id })
           cards.close(store, id, { ok = true, stats = { mean_score = score, n = 5 } })
        end
        run('move_from', 0.5)
        run('move_to', 0.7)

        cards.alias(store, 'champion', 'move_from')
        local rec, err = cards.alias(store, 'champion', 'move_to', 'a better one')
        assert(err == nil, tostring(err))
        assert(rec ~= nil, 'the rebind wrote an event')

        assert(cards.get_by_alias(store, 'champion').id == 'move_to', 'the name moved')
        local entries = cards.alias_list(store, {})
        assert(#entries == 1, 'one name, not two')
        assert(entries[1].card_id == 'move_to', entries[1].card_id)
        assert(entries[1].note == 'a better one', tostring(entries[1].note))

        -- The card it came off is untouched: an alias is a name for a card, not a state on
        -- one, and losing the name is not something that happens *to* the card.
        assert(#cards.get(store, 'move_from').aliases == 0, 'the old card has no names')
        assert(cards.get(store, 'move_from').state == 'closed_ok', 'and is what it was')

        local history, e2 = cards.alias_history(store, 'champion')
        assert(e2 == nil, tostring(e2))
        assert(#history == 2, #history)
        assert(history[1].card_id == 'move_from', history[1].card_id)
        assert(history[2].card_id == 'move_to', history[2].card_id)
        assert(history[1].seq == 1 and history[2].seq == 2, 'in the order they happened')
        assert(history[2].epoch_ms >= history[1].epoch_ms, 'and stamped')

        assert(#cards.alias_history(store, 'nobody_bound_this') == 0, 'no history is not an error')

        local out = {}
        for i = 1, #history do out[i] = history[i].kind end
        return out
        "#,
    )?;
    assert_eq!(kinds, ["alias_bound", "alias_bound"]);
    Ok(())
}

/// Binding a name to where it already points writes nothing. The decision folds the
/// stream and declines, which is `nil, nil` in Teal — not a failure, and not an event.
#[test]
fn rebinding_the_same_card_is_idempotent() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let history: i64 = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                            created_by = 'x', id = 'same_card' })
        cards.close(store, 'same_card', { ok = true, stats = { mean_score = 0.5, n = 5 } })
        cards.alias(store, 'champion', 'same_card')

        local rec, err = cards.alias(store, 'champion', 'same_card', 'again')
        assert(rec == nil and err == nil, 'declined: it already means that card')

        assert(cards.get_by_alias(store, 'champion').id == 'same_card', 'and still does')
        assert(#store:read_stream('alias-champion') == 1, 'one event on the stream')
        return #cards.alias_history(store, 'champion')
        "#,
    )?;
    assert_eq!(history, 1, "the second bind left no line in the history");
    Ok(())
}

/// Releasing: the name stops meaning anything, the history says which card it came off,
/// and releasing again is the same decline a redundant bind is.
#[test]
fn a_released_alias_stops_resolving_and_says_what_it_let_go() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let out: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                            created_by = 'x', id = 'let_go' })
        cards.close(store, 'let_go', { ok = true, stats = { mean_score = 0.5, n = 5 } })
        cards.alias(store, 'champion', 'let_go')

        local rec, err = cards.alias_release(store, 'champion', 'retired')
        assert(err == nil, tostring(err))
        assert(rec ~= nil and rec.kind == 'alias_released', 'an alias_released was written')
        assert(rec.meta.card_id == 'let_go', 'carrying the card it released')

        local card, e2 = cards.get_by_alias(store, 'champion')
        assert(card == nil, 'the name means nothing now')
        assert(#cards.alias_list(store, {}) == 0, 'and is not listed')
        assert(#cards.get(store, 'let_go').aliases == 0, 'the card is not called that either')

        local again, e3 = cards.alias_release(store, 'champion')
        assert(again == nil and e3 == nil, 'releasing an unbound name is a decline')

        local history = cards.alias_history(store, 'champion')
        assert(#history == 2, #history)
        assert(history[2].kind == 'alias_released', history[2].kind)
        assert(history[2].card_id == 'let_go', history[2].card_id)
        assert(history[2].note == 'retired', tostring(history[2].note))

        -- And the name can be used again afterwards: a release is not a tombstone.
        cards.alias(store, 'champion', 'let_go')
        assert(cards.get_by_alias(store, 'champion').id == 'let_go', 'bound again')

        return { e2, tostring(#cards.alias_history(store, 'champion')) }
        "#,
    )?;
    assert_eq!(out, ["alias champion is not bound", "3"]);
    Ok(())
}

/// The promotion rule end to end: the failed run is not a candidate, the lower score is
/// not the winner, a re-run writes nothing, and a better card moves the name.
#[test]
fn promote_picks_the_best_closed_card_and_only_writes_when_it_changes() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let out: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local function scored(id, score, n)
           cards.open(store, { pkg = 'promo', scenario = 'arith', source = 'eval',
                               created_by = 'x', id = id })
           cards.close(store, id, { ok = true, stats = { mean_score = score, n = n } })
        end
        scored('pro_low', 0.4, 20)
        scored('pro_high', 0.8, 20)
        cards.open(store, { pkg = 'promo', scenario = 'arith', source = 'eval',
                            created_by = 'x', id = 'pro_broke' })
        cards.close(store, 'pro_broke', { ok = false, error = 'the provider went away' })

        local first, err = cards.promote(store, { alias = 'champion', pkg = 'promo' })
        assert(err == nil, tostring(err))
        assert(first.card_id == 'pro_high', first.card_id)
        assert(first.metric == 'mean_score' and first.value == 0.8, first.metric)
        assert(first.changed == true, 'it bound the name')
        assert(first.previous_card_id == nil, 'there was nothing to move off')
        assert(cards.get_by_alias(store, 'champion').id == 'pro_high', 'and the name resolves')

        local again, e2 = cards.promote(store, { alias = 'champion', pkg = 'promo' })
        assert(e2 == nil, tostring(e2))
        assert(again.card_id == 'pro_high', again.card_id)
        assert(again.changed == false, 'the same winner, so nothing was written')
        assert(again.previous_card_id == 'pro_high', again.previous_card_id)
        assert(#cards.alias_history(store, 'champion') == 1, 'one event, still')

        scored('pro_best', 0.95, 20)
        local moved, e3 = cards.promote(store, { alias = 'champion', pkg = 'promo', note = 'nightly' })
        assert(e3 == nil, tostring(e3))
        assert(moved.card_id == 'pro_best', moved.card_id)
        assert(moved.changed == true and moved.previous_card_id == 'pro_high', 'it moved')
        assert(#cards.alias_history(store, 'champion') == 2, 'and the move is in the history')

        -- min_n is what keeps a lucky short run from being crowned.
        scored('pro_lucky', 1.0, 2)
        local guarded = cards.promote(store, { alias = 'guarded', pkg = 'promo', min_n = 10 })
        assert(guarded.card_id == 'pro_best', guarded.card_id)
        local loose = cards.promote(store, { alias = 'loose', pkg = 'promo', min_n = 1 })
        assert(loose.card_id == 'pro_lucky', loose.card_id)

        -- A scenario nobody has closed a card in is a refusal that says where it looked.
        local none, e4 = cards.promote(store, { alias = 'champion', pkg = 'promo',
                                                scenario = 'nothing_here' })
        assert(none == nil, 'nothing to promote')
        local empty, e5 = cards.promote(store, { alias = 'champion', pkg = 'no_such_pkg' })
        assert(empty == nil, 'nor here')

        return { e4, e5 }
        "#,
    )?;
    assert_eq!(
        out,
        [
            "no closed_ok card in promo / nothing_here has a mean_score with n >= 1",
            "no closed_ok card in no_such_pkg has a mean_score with n >= 1",
        ]
    );
    Ok(())
}

/// A rebuild empties the model and replays, and the alias tables come back the same —
/// including the history, which is the one of the two that a rebind would otherwise have
/// erased.
#[test]
fn a_rebuild_reproduces_the_bindings_and_their_history() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let applied: i64 = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local function born(id)
           cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                               created_by = 'x', id = id })
           cards.close(store, id, { ok = true, stats = { mean_score = 0.5, n = 5 } })
        end
        born('re_one')
        born('re_two')

        cards.alias(store, 'champion', 're_one')
        cards.alias(store, 'champion', 're_two', 'moved')
        cards.alias(store, 'baseline', 're_one')
        cards.alias_release(store, 'baseline', 'done with it')

        local applied, err = store:rebuild()
        assert(err == nil, tostring(err))

        local entries = cards.alias_list(store, {})
        assert(#entries == 1, #entries)
        assert(entries[1].name == 'champion' and entries[1].card_id == 're_two', entries[1].card_id)
        assert(entries[1].note == 'moved', tostring(entries[1].note))
        assert(cards.get_by_alias(store, 'baseline') == nil, 'the released name stayed released')

        local champion = cards.alias_history(store, 'champion')
        assert(#champion == 2, #champion)
        assert(champion[1].card_id == 're_one' and champion[2].card_id == 're_two', 'both')
        local baseline = cards.alias_history(store, 'baseline')
        assert(#baseline == 2, #baseline)
        assert(baseline[2].kind == 'alias_released', baseline[2].kind)

        assert(#cards.get(store, 're_two').aliases == 1, 'the card knows its name again')
        return applied
        "#,
    )?;
    // 2 cards × (card_opened + card_closed), 3 alias_bound, 1 alias_released.
    assert_eq!(applied, 8);
    Ok(())
}

/// A database folded under the retired projection name opens, reads the same, and takes
/// aliases.
///
/// The old build is reproduced by its *cursor*: a runner named `cards_v1` over the same
/// events, which is what `Store::open` has to recognise. The tables that runner creates
/// are this version's, so what this does not reproduce is the two alias tables being
/// absent — `init` adds them on the way in either way, and they would be empty in both
/// stories because a database written before them holds no alias events.
///
/// `sample_rows` is the assertion that carries the weight. A migration that let the new
/// name simply start at the beginning of the log would fold `samples_appended` onto rows
/// the old cursor had already counted, and the count would double; it is 2 because the
/// model was emptied first.
#[test]
fn a_database_written_under_the_old_projection_name_is_carried_forward() -> anyhow::Result<()> {
    let dir = tempfile::tempdir()?;
    write_under_the_old_name(dir.path())?;

    let h = Htl::new()?;
    crate::preload(&h, dir.path())?;
    let out: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local one, err = cards.get(store, 'mig_one')
        assert(err == nil, tostring(err))
        assert(one.state == 'closed_ok', one.state)
        assert(one.pkg == 'cot' and one.created_by == 'the old build', one.created_by)
        assert(one.stats.mean_score == 0.4, 'the close came back')
        assert(one.samples.batches == 1 and one.samples.rows == 2, one.samples.rows)
        assert(#cards.list(store, {}) == 2, 'both cards are there')

        -- The retired name is still a row — eventsdb has no way to remove one — and it is
        -- where the live model is rather than where the old build left it.
        local marks, e2 = store:query(
           'SELECT consumer, position FROM checkpoints ORDER BY consumer', {})
        assert(e2 == nil, tostring(e2))
        assert(#marks == 2, #marks)
        assert(marks[1].consumer == 'cards_v1' and marks[2].consumer == 'cards_v2', marks[1].consumer)
        assert(marks[1].position == marks[2].position, 'the retired cursor is not behind')

        local rec, e3 = cards.alias(store, 'champion', 'mig_two')
        assert(e3 == nil and rec ~= nil, tostring(e3))
        assert(cards.get_by_alias(store, 'champion').id == 'mig_two', 'aliases work on it')

        local out = {}
        for i, entry in ipairs(cards.list(store, {})) do out[i] = entry.id end
        return out
        "#,
    )?;
    assert_eq!(out, ["mig_two", "mig_one"]);
    Ok(())
}

/// Build a `cards.db` the way the previous commit would have left one: the same events,
/// folded by a runner whose checkpoint is under `cards_v1`.
fn write_under_the_old_name(root: &Path) -> anyhow::Result<()> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()?;
    let log = rt.block_on(SqliteEventLog::open(root.join("cards.db")))?;
    let mut runner = log.runner(CardsProjection::under("cards_v1"))?;
    rt.block_on(runner.init())?;

    let opened = |pkg: &str| json!({ "pkg": pkg, "scenario": "arith", "source": "eval", "created_by": "the old build" });

    let mut one = log.stream_handle("card-mig_one");
    rt.block_on(one.append(envelope(
        "card_opened",
        opened("cot"),
        json!({ "note": "before" }),
    )))?;
    rt.block_on(one.append(envelope(
        "samples_appended",
        json!(null),
        json!({ "n": 2, "rows": [{ "a": 1 }, { "a": 2 }] }),
    )))?;
    rt.block_on(one.append(envelope(
        "card_closed",
        json!({ "outcome": "ok" }),
        json!({ "stats": { "mean_score": 0.4, "n": 2 } }),
    )))?;

    let mut two = log.stream_handle("card-mig_two");
    rt.block_on(two.append(envelope("card_opened", opened("cot"), json!(null))))?;
    rt.block_on(two.append(envelope(
        "card_closed",
        json!({ "outcome": "ok" }),
        json!({ "stats": { "mean_score": 0.9, "n": 6 } }),
    )))?;

    rt.block_on(runner.catch_up())?;

    // What the migration has to recognise: a cursor under the old name and none under
    // this one.
    assert!(rt.block_on(log.checkpoint_load("cards_v1"))? > Position::BEGINNING);
    assert_eq!(
        rt.block_on(log.checkpoint_load(CardsProjection::NAME))?,
        Position::BEGINNING
    );
    Ok(())
}
