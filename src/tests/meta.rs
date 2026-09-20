//! What is said about a run besides what it produced: the params it was given and their
//! fingerprint, the identity it ran under, the assessments a judge or a person add after
//! it closed, and the tags that move. The three slots BP converged on — immutable input,
//! append-only assessment, mutable label — and the one rule (`opened`) that lets the
//! last two land on a closed card.

use super::{eval, opened};

/// The open carries params and identity; `get` and `fold` agree on all of it; and the
/// fingerprint is of the params' content, not of the order a table was built in.
#[test]
fn params_and_identity_are_written_at_the_open_and_read_back_whole() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let prints: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card, err = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'p1',
           params = { temperature = 0.2, variant = 'b', thresholds = { 1, 2 } },
           model = 'claude-opus-4-6', trace_id = 'tr-9', work_url = 'file:///tmp/t9',
        })
        assert(err == nil, tostring(err))

        local bare, berr = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', work_url = '/tmp/t9',
        })
        assert(bare == nil and berr:find('scheme'), 'a bare path is refused: ' .. tostring(berr))
        local rel, relerr = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', work_url = 'tasks/x',
        })
        assert(rel == nil and relerr:find('scheme'), 'a relative path too: ' .. tostring(relerr))
        assert(type(card.fingerprint) == 'string' and #card.fingerprint == 16, tostring(card.fingerprint))

        local view = cards.get(store, 'p1')
        assert(view.model == 'claude-opus-4-6', tostring(view.model))
        assert(view.trace_id == 'tr-9' and view.work_url == 'file:///tmp/t9', 'identity read back')
        assert(view.fingerprint == card.fingerprint, 'the fingerprint is on the card')
        assert(view.params.temperature == 0.2 and view.params.variant == 'b', 'params read back')
        assert(view.params.thresholds[2] == 2, 'nested params read back')

        local folded = cards.fold(store, 'p1')
        assert(folded.model == view.model and folded.fingerprint == view.fingerprint, 'fold agrees')
        assert(folded.params.variant == 'b', 'fold carries params')

        -- The same knobs in another order print the same; a different value does not.
        local same = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'p2',
           params = { thresholds = { 1, 2 }, variant = 'b', temperature = 0.2 },
        })
        local other = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'p3',
           params = { thresholds = { 1, 2 }, variant = 'b', temperature = 0.3 },
        })
        local bare = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'p4',
        })
        assert(bare.fingerprint == nil and cards.get(store, 'p4').params == nil, 'no params, no print')

        local refused, rerr = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', params = 'lr=1',
        })
        assert(refused == nil and rerr:find('params as a table'), tostring(rerr))

        return { card.fingerprint, same.fingerprint, other.fingerprint }
        "#,
    )?;
    assert_eq!(
        prints[0], prints[1],
        "order does not change the fingerprint"
    );
    assert_ne!(prints[0], prints[2], "a value does");
    Ok(())
}

/// `find` reaches the params by path and the identity by column, and `fingerprint` is
/// what "the runs given these knobs" is asked with.
#[test]
fn a_card_is_found_by_its_params_its_model_and_its_fingerprint() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let ids: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local a = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'f1',
           params = { lr = 0.1, opt = { name = 'adam' } }, model = 'm-a',
        })
        cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'f2',
           params = { lr = 0.5, opt = { name = 'sgd' } }, model = 'm-b',
        })
        cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'f3',
           params = { lr = 0.1, opt = { name = 'adam' } }, model = 'm-b',
        })

        local function ids(q)
           local rows, err = cards.find(store, q)
           assert(err == nil, tostring(err))
           local out = {}
           for i, r in ipairs(rows) do out[i] = r.id end
           table.sort(out)
           return table.concat(out, ',')
        end

        return {
           ids({ clauses = { { column = 'params.opt.name', op = '=', value = 'adam' } } }),
           ids({ clauses = { { column = 'params.lr', op = '>', value = 0.2 } } }),
           ids({ clauses = { { column = 'model', op = '=', value = 'm-b' } } }),
           ids({ clauses = { { column = 'fingerprint', op = '=', value = a.fingerprint } } }),
           ids({ clauses = {
              { column = 'fingerprint', op = '=', value = a.fingerprint },
              { column = 'model', op = '=', value = 'm-b' },
           } }),
        }
        "#,
    )?;
    assert_eq!(ids, ["f1,f3", "f2", "f2,f3", "f1,f3", "f3"]);
    Ok(())
}

/// An assessment lands on a closed card, says who made it, and is counted; samples still
/// do not, because they are the run's own output and the run is over.
#[test]
fn an_eval_is_taken_on_a_closed_card_and_carries_its_source() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let sources: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'e1' })
        local own, e1 = cards.record_eval(store, 'e1', { score = 0.7 })
        assert(e1 == nil and own.meta.source == 'code', 'the default source is the run itself')
        cards.close(store, 'e1', { ok = true, stats = { mean_score = 0.7 } })

        local judged, e2 = cards.record_eval(store, 'e1', { plugin = 'judge', score = 0.6 }, 'llm_judge')
        assert(e2 == nil and judged ~= nil, tostring(e2))
        local seen, e3 = cards.record_eval(store, 'e1', { verdict = 'ship' }, 'human')
        assert(e3 == nil and seen ~= nil, tostring(e3))
        assert(cards.get(store, 'e1').evals == 3, 'all three counted')
        assert(cards.fold(store, 'e1').evals == 3, 'and folded')

        local bad, e4 = cards.record_eval(store, 'e1', { x = 1 }, 'oracle')
        assert(bad == nil and e4:find('code, llm_judge, human'), tostring(e4))

        local none, e5 = cards.record_eval(store, 'nobody', { x = 1 })
        assert(none == nil and e5:find('no card was opened'), tostring(e5))

        local rows, e6 = cards.append_samples(store, 'e1', { { q = 1 } })
        assert(rows == nil and e6:find('it is closed'), 'samples are still refused: ' .. tostring(e6))

        local rec = store:query('SELECT source FROM cb_evals WHERE card_id = ? ORDER BY seq', { 'e1' })
        local out = {}
        for i, r in ipairs(rec) do out[i] = r.source end
        return out
        "#,
    )?;
    assert_eq!(sources, ["code", "llm_judge", "human"]);
    Ok(())
}

/// A tag is set, moved, found by, and taken off, on a closed card; setting what is
/// already there writes nothing; the history is the stream and the fold agrees with the
/// table.
#[test]
fn a_tag_moves_and_the_fold_and_the_table_agree() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let kinds: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 't1' })
        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 't2' })
        cards.close(store, 't1', { ok = true })

        local rec, err = cards.tag(store, 't1', 'stage', 'staging')
        assert(err == nil and rec ~= nil, tostring(err))
        local again, e2 = cards.tag(store, 't1', 'stage', 'staging')
        assert(again == nil and e2 == nil, 'the same value writes nothing')
        local moved, e3 = cards.tag(store, 't1', 'stage', 'prod')
        assert(e3 == nil and moved ~= nil, tostring(e3))
        local verdict, e4 = cards.tag(store, 't1', 'review.verdict', 'ship')
        assert(e4 == nil and verdict ~= nil, tostring(e4))
        cards.tag(store, 't2', 'stage', 'staging')

        local view = cards.get(store, 't1')
        assert(view.tags.stage == 'prod' and view.tags['review.verdict'] == 'ship', 'current values')
        local folded = cards.fold(store, 't1')
        assert(folded.tags.stage == 'prod' and folded.tags['review.verdict'] == 'ship', 'fold agrees')

        local found = cards.find(store, { clauses = { { column = 'tags.stage', op = '=', value = 'prod' } } })
        assert(#found == 1 and found[1].id == 't1', 'found by tag')
        local none = cards.find(store, { clauses = { { column = 'tags.stage', op = '=', value = 'dev' } } })
        assert(#none == 0, 'not found by a value nobody has')

        local off, e5 = cards.untag(store, 't1', 'stage')
        assert(e5 == nil and off ~= nil, tostring(e5))
        local nothing, e6 = cards.untag(store, 't1', 'stage')
        assert(nothing == nil and e6 == nil, 'already off: nothing to write')
        assert(cards.get(store, 't1').tags.stage == nil, 'gone from the table')
        assert(cards.fold(store, 't1').tags.stage == nil, 'gone from the fold')

        local bad, e7 = cards.tag(store, 't1', 'a key', 'v')
        assert(bad == nil and e7:find('tag key'), tostring(e7))
        local empty, e8 = cards.tag(store, 't1', 'k', '')
        assert(empty == nil and e8:find('non%-empty'), tostring(e8))
        local ghost, e9 = cards.untag(store, 'nobody', 'k')
        assert(ghost == nil and e9:find('no card was opened'), tostring(e9))

        local events = store:read_stream('card-t1', { 'tag_set', 'tag_unset' })
        local out = {}
        for i, e in ipairs(events) do out[i] = e.kind .. ':' .. e.meta.key .. '=' .. tostring(e.meta.value) end
        return out
        "#,
    )?;
    assert_eq!(
        kinds,
        [
            "tag_set:stage=staging",
            "tag_set:stage=prod",
            "tag_set:review.verdict=ship",
            "tag_unset:stage=nil",
        ]
    );
    Ok(())
}

/// A pruned card's tags go with it, and a rebuild brings back the tags of the cards that
/// stayed and nothing for the one that went.
#[test]
fn a_prune_takes_the_tags_and_a_rebuild_puts_the_rest_back() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let left: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'pr1' })
        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'pr2' })
        cards.close(store, 'pr1', { ok = true })
        cards.close(store, 'pr2', { ok = true })
        cards.tag(store, 'pr1', 'stage', 'dev')
        cards.tag(store, 'pr2', 'stage', 'prod')

        local report, err = cards.prune(store, { ids = { 'pr1' }, reason = 'test' })
        assert(err == nil and #report.pruned == 1, tostring(err))
        assert(store:rebuild() > 0, 'replayed')

        local rows = store:query('SELECT card_id, value FROM cb_tags ORDER BY card_id', {})
        local out = {}
        for i, r in ipairs(rows) do out[i] = r.card_id .. '=' .. r.value end
        return out
        "#,
    )?;
    assert_eq!(left, ["pr2=prod"]);
    Ok(())
}
