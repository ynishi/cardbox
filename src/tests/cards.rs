//! A card's life through `cardbox.cards`: what a run leaves behind when it succeeds, what
//! it leaves behind when it fails, and what is refused outside the open span.

use super::{eval, opened};
use sha2::Digest;

/// The whole of a successful run, through the policy module rather than the store:
/// open, two batches of samples, an eval, a checkpoint, close — and then `get`, which
/// has to add all of it back up.
#[test]
fn a_card_takes_samples_an_eval_and_a_checkpoint_and_then_closes() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let blob: String = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card, err = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval',
           created_by = 'cardbox 0.1.0',
           parents = { 'cot_arith_20260101T000000_abcdef' },
           note = 'the first one',
        })
        assert(err == nil, tostring(err))
        assert(card.state == 'open', card.state)
        assert(card.stream == 'card-' .. card.id, card.stream)

        local one, e1 = cards.append_samples(store, card.id,
           { { q = '1+1', a = 2 }, { q = '2+2', a = 4 } })
        assert(e1 == nil, tostring(e1))
        assert(one.n == 2, one.n)
        assert(one.blob == nil, 'a small batch stays in the event')

        local two, e2 = cards.append_samples(store, card.id, { { q = '3+3', a = 5 } })
        assert(e2 == nil, tostring(e2))
        assert(two.n == 1, two.n)

        local ev, e3 = cards.record_eval(store, card.id,
           { mean_score = 0.75, n = 3, failures = { '3+3' } })
        assert(e3 == nil, tostring(e3))
        assert(ev.kind == 'eval_recorded', ev.kind)

        local cp, e4 = cards.save_checkpoint(store, card.id, 'the weights',
           { format = 'safetensors', note = 'epoch 3' })
        assert(e4 == nil, tostring(e4))
        assert(cp.data.size == 11, cp.data.size)

        local closed, e5 = cards.close(store, card.id, {
           ok = true,
           stats = { mean_score = 0.75, n = 3, pass_rate = 0.67, passed = 2 },
           cost = { elapsed_ms = 1200, llm_calls = 9 },
        })
        assert(e5 == nil, tostring(e5))
        assert(closed.meta.outcome == 'ok', tostring(closed.meta.outcome))

        local view, e6 = cards.get(store, card.id)
        assert(e6 == nil, tostring(e6))
        assert(view.state == 'closed_ok', view.state)
        assert(view.pkg == 'cot' and view.scenario == 'arith', 'the meta came back')
        assert(view.source == 'eval', view.source)
        assert(view.created_by == 'cardbox 0.1.0', view.created_by)
        assert(view.note == 'the first one', tostring(view.note))
        assert(#view.parents == 1, #view.parents)
        assert(view.samples.batches == 2, view.samples.batches)
        assert(view.samples.rows == 3, view.samples.rows)
        assert(view.evals == 1, view.evals)
        assert(#view.checkpoints == 1, #view.checkpoints)
        assert(view.checkpoints[1].format == 'safetensors', view.checkpoints[1].format)
        assert(view.checkpoints[1].size == 11, view.checkpoints[1].size)
        assert(view.stats.passed == 2, 'the stats came back')
        assert(view.cost.llm_calls == 9, 'the cost came back')
        assert(view.error == nil, 'a card closed ok carries no error')
        assert(view.opened_ms > 0, view.opened_ms)
        assert(view.closed_ms >= view.opened_ms, 'it closed no earlier than it opened')

        return view.checkpoints[1].blob
        "#,
    )?;
    assert_eq!(blob, hex::encode(sha2::Sha256::digest(b"the weights")));
    Ok(())
}

/// A run that failed still leaves a card. This is the requirement the whole design
/// turns on — the card is opened at the start, so the only thing failure changes is
/// how it closes — and it is why `card_opened` is not written at the end.
#[test]
fn a_run_that_failed_leaves_a_card_saying_so() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let reported: String = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card, err = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'cardbox 0.1.0',
        })
        assert(err == nil, tostring(err))

        local rec, e1 = cards.close(store, card.id, {
           ok = false,
           error = 'the provider timed out after 3 retries',
           cost = { elapsed_ms = 90000, llm_calls = 3 },
        })
        assert(e1 == nil, tostring(e1))
        assert(rec.meta.outcome == 'failed', tostring(rec.meta.outcome))

        local view, e2 = cards.get(store, card.id)
        assert(e2 == nil, tostring(e2))
        assert(view.state == 'closed_failed', view.state)
        assert(view.samples.batches == 0 and view.evals == 0, 'it produced nothing')
        assert(view.cost.elapsed_ms == 90000, 'what it cost is still recorded')
        return view.error
        "#,
    )?;
    assert_eq!(reported, "the provider timed out after 3 retries");
    Ok(())
}

/// Samples cannot be written outside a card's open span, and the two ways of being
/// outside it are different mistakes: the wrong id, and an id whose run is over.
#[test]
fn samples_are_refused_before_the_open_and_after_the_close_with_different_words()
-> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let msgs: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local never, e1 = cards.append_samples(store, 'nobody_home', { { a = 1 } })
        assert(never == nil, 'nothing is written to a card that was never opened')
        assert(e1 ~= nil, 'and it says so')

        local card = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'shut_1',
        })
        cards.close(store, card.id, { ok = true })
        local after, e2 = cards.append_samples(store, 'shut_1', { { a = 1 } })
        assert(after == nil, 'nothing is written to a closed card')

        local view = cards.get(store, 'shut_1')
        assert(view.samples.batches == 0, view.samples.batches)
        return { e1, e2 }
        "#,
    )?;
    assert!(msgs[0].contains("no card was opened"), "{}", msgs[0]);
    assert!(msgs[1].contains("it is closed"), "{}", msgs[1]);
    assert_ne!(msgs[0], msgs[1]);
    Ok(())
}

#[test]
fn opening_the_same_id_twice_is_refused_and_the_message_names_it() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let msg: String = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')
        local spec = {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'only_once',
        }
        local first, e1 = cards.open(store, spec)
        assert(e1 == nil, tostring(e1))
        assert(first.id == 'only_once', first.id)
        local second, e2 = cards.open(store, spec)
        assert(second == nil, 'the second open writes nothing')
        assert(#store:read_stream('card-only_once', { 'card_opened' }) == 1, 'one open event')
        return e2
        "#,
    )?;
    assert!(msg.contains("only_once"), "{msg}");
    Ok(())
}

/// Over the inline limit the rows leave the event for a blob, and the event keeps the
/// count — so `get` still totals the card's rows without reading a byte of the blob.
#[test]
fn a_batch_over_the_inline_limit_lands_in_a_blob() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let size: i64 = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card, err = cards.open(store, {
           pkg = 'cot', scenario = 'big', source = 'bake', created_by = 'x', id = 'big_one',
        })
        assert(err == nil, tostring(err))
        assert(card.id == 'big_one', card.id)

        local payload = string.rep('x', 2000)
        local rows = {}
        for i = 1, 40 do rows[i] = { i = i, payload = payload } end

        local out, e1 = cards.append_samples(store, 'big_one', rows)
        assert(e1 == nil, tostring(e1))
        assert(out.n == 40, out.n)
        assert(out.blob ~= nil, 'a batch over the limit is a blob')
        assert(out.size > 64 * 1024, out.size)

        local events = store:read_stream('card-big_one', { 'samples_appended' })
        assert(#events == 1, #events)
        local data = events[1].data
        assert(data.rows == nil, 'the rows are not in the event')
        assert(data.blob == out.blob, 'the event names the blob')
        assert(data.n == 40, data.n)

        local view = cards.get(store, 'big_one')
        assert(view.samples.batches == 1, view.samples.batches)
        assert(view.samples.rows == 40, view.samples.rows)

        local back, e2 = store:blob_get(out.blob)
        assert(e2 == nil, tostring(e2))
        assert(#back == out.size, 'the blob is the text that was measured')
        return out.size
        "#,
    )?;
    assert!(size > 64 * 1024, "{size}");
    Ok(())
}

#[test]
fn closing_twice_is_refused() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let msgs: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 'closer_1',
        })
        local first, e1 = cards.close(store, card.id, { ok = true })
        assert(e1 == nil, tostring(e1))
        assert(first ~= nil, 'the first close writes')

        local second, e2 = cards.close(store, card.id, { ok = false, error = 'no' })
        assert(second == nil, 'the second close writes nothing')

        local missing, e3 = cards.close(store, 'never_opened', { ok = true })
        assert(missing == nil, 'closing a card nobody opened writes nothing')

        assert(#store:read_stream('card-closer_1', { 'card_closed' }) == 1, 'one close event')
        local view = cards.get(store, 'closer_1')
        assert(view.state == 'closed_ok', view.state)
        return { e2, e3 }
        "#,
    )?;
    assert!(msgs[0].contains("already closed"), "{}", msgs[0]);
    assert!(msgs[1].contains("no card was opened"), "{}", msgs[1]);
    Ok(())
}
