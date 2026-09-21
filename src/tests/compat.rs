//! alc's card/v0 surface with a store in the room: `compat.find` answers v0 summary rows
//! out of a cardbox query, and `compat.samples` answers a card's rows, filtered and paged,
//! whether the batches were inline or went to a blob. The pure halves — the translation
//! and the row predicate — are `tests/compat_test.tl`.

use super::{eval, opened};

/// The arguments the two real callers pass (`pkg` + `limit`, and a nested `where`), and
/// the summary shape they read (`card_id`, `pkg`, `model`, `pass_rate`, and `tags`).
#[test]
fn compat_find_answers_v0_summaries_out_of_a_cardbox_query() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let ids: Vec<String> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local compat = require('cardbox').compat
        local store = require('store')

        local function card(id, model, variant, rounds, pass_rate)
           cards.open(store, {
              pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = id,
              model = model, params = { variant = variant, optimize = { rounds = rounds } },
           })
           cards.close(store, id, { ok = true, stats = { pass_rate = pass_rate, n = 4 } })
        end
        card('c1', 'm-a', 'blue', 3, 0.9)
        card('c2', 'm-b', 'blue', 1, 0.6)
        card('c3', 'm-a', 'green', 2, 0.3)
        cards.tag(store, 'c2', 'group', 'run')

        local all, err = compat.find(store, { pkg = 'cot', limit = 10 })
        assert(err == nil, tostring(err))
        assert(#all == 3, #all)
        local row = all[1]
        assert(row.card_id ~= nil and row.pkg == 'cot' and row.model ~= nil, 'v0 summary shape')
        assert(row.pass_rate ~= nil and row.state == 'closed_ok', 'with the close numbers')

        -- The shape alc's own callers send: `where` as the key, nested sections, an
        -- operator object at the leaf, and `-path` to order descending.
        local found, ferr = compat.find(store, {
           ['where'] = {
              params = { variant = 'blue' },
              optimize = { rounds = { gte = 1 } },
              stats = { pass_rate = { gt = 0.5 } },
           },
           order_by = '-stats.pass_rate',
        })
        assert(ferr == nil, tostring(ferr))
        local out = {}
        for i, r in ipairs(found) do out[i] = r.card_id end

        local tagged = compat.find(store, { ['where'] = { metadata = { group = 'run' } } })
        assert(#tagged == 1 and tagged[1].card_id == 'c2', 'metadata.group is tags.group')
        assert(tagged[1].tags.group == 'run', 'and the row carries the tag it was found by')
        assert(next(all[3].tags) == nil, 'a card with no tags carries an empty table')

        local by_model = compat.find(store, { ['where'] = { model = { id = 'm-a' } }, order_by = 'card_id' })
        assert(#by_model == 2 and by_model[1].card_id == 'c1', 'model.id is the model column')

        local none = compat.find(store, { ['where'] = { params = { variant = 'red' } } })
        assert(#none == 0, 'an empty answer is a list')

        local refused, rerr = compat.find(store, { ['where'] = { _or = { { pkg = 'a' } } } })
        assert(refused == nil and rerr:find('AND%-only'), tostring(rerr))
        return out
        "#,
    )?;
    assert_eq!(ids, ["c1", "c2"]);
    Ok(())
}

/// Rows come back in batch order whether a batch was inline or a blob; the `where` runs
/// over each row with the whole DSL; offset and limit page what the filter kept.
#[test]
fn compat_samples_reads_rows_across_inline_and_blob_batches_and_pages_them() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let counts: Vec<i64> = eval(
        &h,
        r#"
        local cards = require('cardbox').cards
        local compat = require('cardbox').compat
        local store = require('store')

        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 's1' })
        cards.open(store, { pkg = 'cot', scenario = 'arith', source = 'eval', created_by = 'x', id = 's2' })

        -- Batch 1 inline: three rows. Batch 2 over the inline limit: 1200 rows of ~100
        -- bytes, which goes to a blob.
        cards.append_samples(store, 's1', {
           { i = 1, score = 0.2, variant_id = 'v1' },
           { i = 2, score = 0.9, variant_id = 'v1' },
           { i = 3, score = 0.4 },
        })
        local big = {}
        for i = 1, 1200 do
           big[i] = { i = 100 + i, score = (i % 2 == 0) and 0.1 or 0.8, variant_id = 'v2',
                      pad = string.rep('x', 60) }
        end
        local appended = cards.append_samples(store, 's1', big)
        assert(appended.blob ~= nil, 'the second batch went to a blob')

        local all, err = compat.samples(store, 's1', {})
        assert(err == nil, tostring(err))
        assert(all[1].i == 1 and all[3].i == 3 and all[4].i == 101 and all[#all].i == 1300, 'batch order')

        local low = compat.samples(store, 's1', { ['where'] = { score = { lt = 0.5 } } })
        local v2 = compat.samples(store, 's1', { filter = { variant_id = 'v2', score = { gt = 0.5 } } })
        local no_variant = compat.samples(store, 's1', { filter = { variant_id = { exists = false } } })
        local page = compat.samples(store, 's1', { filter = { variant_id = 'v2' }, offset = 10, limit = 5 })
        assert(page[1].i == 111 and page[5].i == 115, 'offset and limit apply after the filter')

        local empty = compat.samples(store, 's2', {})
        assert(#empty == 0, 'no samples is []')
        local nobody, nerr = compat.samples(store, 'nobody', {})
        assert(nobody == nil and nerr:find('no card'), tostring(nerr))

        return { #all, #low, #v2, #no_variant, #page }
        "#,
    )?;
    assert_eq!(counts, [1203, 602, 600, 1, 5]);
    Ok(())
}
