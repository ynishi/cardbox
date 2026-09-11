//! The read models: that they say what the fold says, that a read sees the write before
//! it, that a rebuild reproduces them, and what `find` / `list` / `lineage` answer.
//!
//! The scripts below are Lua rather than Teal — `Htl::lua().load` takes the interpreter's
//! own language, and the modules they call were type-checked at `cargo build`. That is the
//! point of running them here: this is the surface a host embedding this crate has.

use super::{eval, opened};
use sha2::Digest;

/// The claim the whole projection rests on: `cards.get`, which reads `cb_*`, is the same
/// answer as `cards.fold`, which adds the stream up itself. Field by field, over a card
/// that used every kind.
#[test]
fn the_projection_says_what_the_fold_says() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let blob: String = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'cardbox 0.1.0',
           parents = { 'older_one', 'older_two' }, note = 'the first one', id = 'both_ways',
        })
        cards.append_samples(store, card.id, { { q = '1+1', a = 2 }, { q = '2+2', a = 4 } })
        cards.append_samples(store, card.id, { { q = '3+3', a = 5 } })
        cards.record_eval(store, card.id, { mean_score = 0.75, n = 3 })
        cards.save_checkpoint(store, card.id, 'the weights',
           { format = 'safetensors', note = 'epoch 3' })
        cards.close(store, card.id, {
           ok = true,
           stats = { mean_score = 0.75, n = 3, pass_rate = 0.67, passed = 2 },
           cost = { elapsed_ms = 1200, llm_calls = 9 },
        })

        local read, e1 = cards.get(store, card.id)
        assert(e1 == nil, tostring(e1))
        local folded, e2 = cards.fold(store, card.id)
        assert(e2 == nil, tostring(e2))

        for _, f in ipairs({ 'id', 'pkg', 'scenario', 'source', 'created_by', 'note',
                             'state', 'opened_ms', 'closed_ms', 'error' }) do
           assert(read[f] == folded[f],
              f .. ': ' .. tostring(read[f]) .. ' vs ' .. tostring(folded[f]))
        end
        assert(read.samples.batches == folded.samples.batches, read.samples.batches)
        assert(read.samples.rows == folded.samples.rows, read.samples.rows)
        assert(read.evals == folded.evals, read.evals)
        assert(#read.parents == #folded.parents, #read.parents)
        for i = 1, #folded.parents do
           assert(read.parents[i] == folded.parents[i], read.parents[i])
        end
        assert(#read.checkpoints == #folded.checkpoints, #read.checkpoints)
        for i = 1, #folded.checkpoints do
           assert(read.checkpoints[i].blob == folded.checkpoints[i].blob, 'the same blob')
           assert(read.checkpoints[i].size == folded.checkpoints[i].size, 'the same size')
           assert(read.checkpoints[i].format == folded.checkpoints[i].format, 'the same format')
        end
        for _, f in ipairs({ 'mean_score', 'n', 'pass_rate', 'passed' }) do
           assert(read.stats[f] == folded.stats[f], 'stats.' .. f)
        end
        for _, f in ipairs({ 'elapsed_ms', 'llm_calls' }) do
           assert(read.cost[f] == folded.cost[f], 'cost.' .. f)
        end

        -- And the values themselves, so that the two agreeing on nothing would not pass.
        assert(read.state == 'closed_ok', read.state)
        assert(read.samples.batches == 2 and read.samples.rows == 3, 'two batches, three rows')
        assert(read.evals == 1, read.evals)
        assert(read.stats.passed == 2, read.stats.passed)
        assert(read.cost.llm_calls == 9, read.cost.llm_calls)
        assert(#read.parents == 2 and read.parents[1] == 'older_one', read.parents[1])
        return read.checkpoints[1].blob
        "#,
    )?;
    assert_eq!(blob, hex::encode(sha2::Sha256::digest(b"the weights")));
    Ok(())
}

/// A read right after a write sees it, with nothing in between. `query` catches the
/// projection up under the same lock the write took, so there is no window where the card
/// is in the log and not in the model — and the `catch_up()` afterwards returning 0 is
/// what says the reads did the catching up rather than got lucky.
#[test]
fn a_read_right_after_a_write_sees_it() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let left: i64 = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card = cards.open(store, {
           pkg = 'cot', scenario = 'now', source = 'eval', created_by = 'x', id = 'fresh_1',
        })
        local opened_view = cards.get(store, card.id)
        assert(opened_view.state == 'open', opened_view.state)

        cards.append_samples(store, card.id, { { a = 1 } })
        assert(cards.get(store, card.id).samples.rows == 1, 'the batch is there')

        cards.close(store, card.id, { ok = false, error = 'nope' })
        local closed_view = cards.get(store, card.id)
        assert(closed_view.state == 'closed_failed', closed_view.state)

        local found = cards.find(store, {
           clauses = { { column = 'id', op = '=', value = 'fresh_1' } },
        })
        assert(#found == 1 and found[1].state == 'closed_failed', 'find sees it too')

        local behind, err = store:catch_up()
        assert(err == nil, tostring(err))
        return behind
        "#,
    )?;
    assert_eq!(left, 0, "the reads left nothing for an explicit catch-up");
    Ok(())
}

/// `find` over the columns the close flattened out of `stats`, and over `state`.
#[test]
fn find_selects_on_pkg_on_a_score_and_on_the_state() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let found: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local function run(id, pkg, score)
           cards.open(store, { pkg = pkg, scenario = 'arith', source = 'eval',
                               created_by = 'x', id = id })
           cards.close(store, id, { ok = true, stats = { mean_score = score, n = 10 } })
        end
        run('sc_high', 'cot', 0.9)
        run('sc_mid', 'cot', 0.6)
        run('sc_low', 'cot', 0.2)
        run('sc_other', 'panel', 0.8)

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                            created_by = 'x', id = 'sc_broke' })
        cards.close(store, 'sc_broke', { ok = false, error = 'the provider went away' })

        local by_pkg, e1 = cards.find(store, {
           clauses = { { column = 'pkg', op = '=', value = 'panel' } },
        })
        assert(e1 == nil, tostring(e1))
        assert(#by_pkg == 1 and by_pkg[1].id == 'sc_other', 'one card is in panel')
        assert(by_pkg[1].mean_score == 0.8, by_pkg[1].mean_score)
        assert(by_pkg[1].n == 10, by_pkg[1].n)

        local scored, e2 = cards.find(store, {
           clauses = {
              { column = 'pkg', op = '=', value = 'cot' },
              { column = 'mean_score', op = '>', value = 0.5 },
           },
           order_by = 'mean_score',
        })
        assert(e2 == nil, tostring(e2))
        local ids = {}
        for i = 1, #scored do ids[i] = scored[i].id end
        assert(#ids == 2, table.concat(ids, ','))
        assert(ids[1] == 'sc_high' and ids[2] == 'sc_mid', table.concat(ids, ','))

        -- A card with no score at all is not "above 0.5" and is not "below" it either:
        -- NULL compares false both ways, which is the answer a card that never scored
        -- should give.
        local low, e3 = cards.find(store, {
           clauses = { { column = 'mean_score', op = '<=', value = 0.5 } },
        })
        assert(e3 == nil, tostring(e3))
        assert(#low == 1 and low[1].id == 'sc_low', 'only the one that scored low')

        local either, e4 = cards.find(store, {
           clauses = { { column = 'id', op = 'in', value = { 'sc_high', 'sc_low' } } },
           order_by = 'id', desc = false,
        })
        assert(e4 == nil, tostring(e4))
        assert(#either == 2 and either[1].id == 'sc_high', 'in takes them both')

        local failed, e5 = cards.find(store, {
           clauses = { { column = 'state', op = '=', value = 'closed_failed' } },
        })
        assert(e5 == nil, tostring(e5))
        local out = {}
        for i = 1, #failed do out[i] = failed[i].id end
        return out
        "#,
    )?;
    assert_eq!(found, ["sc_broke"]);
    Ok(())
}

/// `list` is newest first, and the page it hands back is the page it was asked for.
#[test]
fn list_is_newest_first_and_pages() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let page: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        for i = 1, 5 do
           cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                               created_by = 'x', id = 'page_' .. tostring(i) })
        end
        cards.open(store, { pkg = 'panel', scenario = 'arith', source = 'eval',
                            created_by = 'x', id = 'page_other' })

        local all, e1 = cards.list(store, {})
        assert(e1 == nil, tostring(e1))
        assert(#all == 6, #all)
        assert(all[1].id == 'page_other', all[1].id)
        assert(all[6].id == 'page_1', all[6].id)

        local narrowed, e2 = cards.list(store, { pkg = 'cot' })
        assert(e2 == nil, tostring(e2))
        assert(#narrowed == 5, #narrowed)
        assert(narrowed[1].id == 'page_5', narrowed[1].id)

        local closed = cards.list(store, { state = 'closed_ok' })
        assert(#closed == 0, 'none of them closed')

        local out = {}
        local paged, e3 = cards.list(store, { limit = 2, offset = 2 })
        assert(e3 == nil, tostring(e3))
        for i = 1, #paged do out[i] = paged[i].id end
        return out
        "#,
    )?;
    // Six cards, newest first: page_other, page_5, page_4, page_3, page_2, page_1.
    assert_eq!(page, ["page_4", "page_3"]);
    Ok(())
}

/// A ← B ← C, walked both ways, and a parent chain that loops back on itself.
#[test]
fn lineage_walks_both_ways_and_survives_a_cycle() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let out: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local function born(id, parents)
           cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                               created_by = 'x', id = id, parents = parents })
        end
        born('lin_a', nil)
        born('lin_b', { 'lin_a' })
        born('lin_c', { 'lin_b' })

        local c, e1 = cards.lineage(store, 'lin_c')
        assert(e1 == nil, tostring(e1))
        assert(#c.parents == 1 and c.parents[1] == 'lin_b', 'C came from B')
        assert(#c.children == 0, 'nothing came from C')
        assert(#c.ancestors == 2, #c.ancestors)
        assert(c.ancestors[1].id == 'lin_b' and c.ancestors[1].depth == 1, 'B is one step up')
        assert(c.ancestors[2].id == 'lin_a' and c.ancestors[2].depth == 2, 'A is two')

        local a, e2 = cards.lineage(store, 'lin_a')
        assert(e2 == nil, tostring(e2))
        assert(#a.parents == 0, 'A came from nowhere')
        assert(#a.children == 1 and a.children[1] == 'lin_b', 'B came from A')
        assert(#a.descendants == 2, #a.descendants)
        assert(a.descendants[1].id == 'lin_b' and a.descendants[1].depth == 1, 'B is one down')
        assert(a.descendants[2].id == 'lin_c' and a.descendants[2].depth == 2, 'C is two')

        -- The default depth is 3, so a fourth generation is out of view.
        born('lin_d', { 'lin_c' })
        born('lin_e', { 'lin_d' })
        assert(#cards.lineage(store, 'lin_a').descendants == 3, 'three by default')
        assert(#cards.lineage(store, 'lin_a', { depth = 10 }).descendants == 4, 'four at ten')

        -- `open` takes parent ids on trust — a parent may be a card that is not here — so
        -- nothing stops a chain that closes on itself. The reader is where it stops.
        born('cyc_a', { 'cyc_c' })
        born('cyc_b', { 'cyc_a' })
        born('cyc_c', { 'cyc_b' })
        local cyc, e3 = cards.lineage(store, 'cyc_a', { depth = 10 })
        assert(e3 == nil, tostring(e3))
        assert(#cyc.ancestors == 2, #cyc.ancestors)
        for i = 1, #cyc.ancestors do
           assert(cyc.ancestors[i].id ~= 'cyc_a', 'a card is not its own ancestor')
        end

        local missing, e4 = cards.lineage(store, 'never_opened')
        assert(missing == nil, 'an id no card is under is refused')

        return { e4, cyc.ancestors[1].id, cyc.ancestors[2].id }
        "#,
    )?;
    assert_eq!(out, ["no card never_opened", "cyc_c", "cyc_b"]);
    Ok(())
}

/// The refcount step 5's GC reads: the same bytes saved on two cards are one blob with
/// two references, and the two checkpoint rows both name it.
#[test]
fn one_blob_saved_on_two_cards_is_counted_twice() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let refs: i64 = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        for _, id in ipairs({ 'ref_one', 'ref_two' }) do
           cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval',
                               created_by = 'x', id = id })
           cards.save_checkpoint(store, id, 'the same weights', { format = 'safetensors' })
           cards.close(store, id, { ok = true })
        end

        local rows, err = store:query('SELECT hash, size, refs FROM cb_blobs', {})
        assert(err == nil, tostring(err))
        assert(#rows == 1, 'the same bytes are one blob')
        local blob = rows[1]
        assert(blob.size == 16, blob.size)

        local named = store:query(
           'SELECT card_id FROM cb_checkpoints WHERE blob = ? ORDER BY card_id', { blob.hash })
        assert(#named == 2, #named)
        assert(named[1].card_id == 'ref_one', 'both cards name it')

        return blob.refs
        "#,
    )?;
    assert_eq!(refs, 2);
    Ok(())
}

/// A rebuild empties the model and replays the log into it. The count it returns is the
/// events it applied — every event of the five kinds — and the card reads the same after.
#[test]
fn a_rebuild_replays_the_log_and_reads_the_same() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let applied: i64 = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local store = require('store')

        local card = cards.open(store, {
           pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x',
           id = 'rebuilt_1', parents = { 'older_one' },
        })
        cards.append_samples(store, card.id, { { a = 1 }, { a = 2 } })
        cards.record_eval(store, card.id, { mean_score = 0.9, n = 2 })
        cards.save_checkpoint(store, card.id, 'weights', { format = 'safetensors' })
        cards.close(store, card.id, {
           ok = true, stats = { mean_score = 0.9, n = 2 }, cost = { elapsed_ms = 7 },
        })
        local before = cards.get(store, card.id)

        local applied, err = store:rebuild()
        assert(err == nil, tostring(err))

        local after, e2 = cards.get(store, card.id)
        assert(e2 == nil, tostring(e2))
        assert(after.state == before.state, after.state)
        assert(after.samples.batches == before.samples.batches, after.samples.batches)
        assert(after.samples.rows == before.samples.rows, after.samples.rows)
        assert(after.evals == before.evals, after.evals)
        assert(#after.checkpoints == #before.checkpoints, #after.checkpoints)
        assert(after.checkpoints[1].blob == before.checkpoints[1].blob, 'the same blob')
        assert(#after.parents == 1 and after.parents[1] == 'older_one', 'the lineage came back')
        assert(after.stats.mean_score == 0.9, 'the stats came back')
        assert(after.cost.elapsed_ms == 7, 'the cost came back')

        -- And the counts were not doubled by replaying on top of what was there.
        local blobs = store:query('SELECT refs FROM cb_blobs', {})
        assert(#blobs == 1 and blobs[1].refs == 1, 'one reference, not two')

        return applied
        "#,
    )?;
    // card_opened, samples_appended, eval_recorded, checkpoint_saved, card_closed.
    assert_eq!(applied, 5);
    Ok(())
}
