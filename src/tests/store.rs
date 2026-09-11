//! The mechanism, from Lua: what an append does, what each decision decides, what a blob
//! is named, and what the hatch can see.

use super::{eval, opened};
use sha2::Digest;

#[test]
fn an_append_comes_back_out_of_the_stream_it_went_into() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let seq: i64 = eval(
        &h,
        r#"
        local store = require('store')
        local rec, err = store:append('card-1', 'card_opened', { pkg = 'cot' }, { n = 3 })
        assert(err == nil, tostring(err))
        assert(rec.seq == 1, 'the first append is seq 1')
        local all, err2 = store:read_stream('card-1')
        assert(err2 == nil, tostring(err2))
        assert(#all == 1, 'one event')
        assert(all[1].kind == 'card_opened', all[1].kind)
        assert(all[1].meta.pkg == 'cot', 'meta round-trips')
        assert(all[1].data.n == 3, 'data round-trips')
        assert(all[1].stream == 'card-1')
        return all[1].seq
        "#,
    )?;
    assert_eq!(seq, 1);
    Ok(())
}

/// The fold step 2 is built on: a dependent event may be written while the card is
/// open, and not before it opened or after it closed.
#[test]
fn open_unclosed_declines_before_the_open_and_after_the_close() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let kinds: Vec<String> = eval(
        &h,
        r#"
        local store = require('store')
        local s = 'card-2'

        local rec, err = store:append_if(s, 'open_unclosed', 'samples_appended', nil, { n = 1 })
        assert(rec == nil and err == nil, 'an empty stream is not open')

        store:append(s, 'card_opened', nil, nil)
        local rec2, err2 = store:append_if(s, 'open_unclosed', 'samples_appended', nil, { n = 2 })
        assert(err2 == nil, tostring(err2))
        assert(rec2 ~= nil, 'an opened card takes a dependent event')

        store:append(s, 'card_closed', nil, { outcome = 'ok' })
        local rec3, err3 = store:append_if(s, 'open_unclosed', 'samples_appended', nil, { n = 3 })
        assert(rec3 == nil and err3 == nil, 'a closed card takes nothing more')

        local all = store:read_stream(s)
        local out = {}
        for i = 1, #all do out[i] = all[i].kind end
        return out
        "#,
    )?;
    assert_eq!(kinds, ["card_opened", "samples_appended", "card_closed"]);
    Ok(())
}

#[test]
fn unwritten_accepts_once() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let count: i64 = eval(
        &h,
        r#"
        local store = require('store')
        local first, err = store:append_if('card-3', 'unwritten', 'card_opened', nil, nil)
        assert(err == nil, tostring(err))
        assert(first ~= nil and first.seq == 1, 'the first one writes')
        local second, err2 = store:append_if('card-3', 'unwritten', 'card_opened', nil, nil)
        assert(second == nil and err2 == nil, 'the second one declines')
        return #store:read_stream('card-3')
        "#,
    )?;
    assert_eq!(count, 1);
    Ok(())
}

/// `closed_absent` is what a close runs: the second close finds the first and stops.
#[test]
fn closed_absent_lets_a_card_close_once() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let count: i64 = eval(
        &h,
        r#"
        local store = require('store')
        store:append('card-4', 'card_opened', nil, nil)
        local first = store:append_if('card-4', 'closed_absent', 'card_closed', nil, { outcome = 'ok' })
        assert(first ~= nil, 'the first close writes')
        local second, err = store:append_if('card-4', 'closed_absent', 'card_closed', nil, { outcome = 'failed' })
        assert(second == nil and err == nil, 'the second close declines')
        return #store:read_stream('card-4', { 'card_closed' })
        "#,
    )?;
    assert_eq!(count, 1);
    Ok(())
}

#[test]
fn a_blob_is_its_own_name_and_writing_it_twice_writes_one_file() -> anyhow::Result<()> {
    let (dir, h) = opened()?;
    let hash: String = eval(
        &h,
        r#"
        local store = require('store')
        local b, err = store:blob_put('the bytes')
        assert(err == nil, tostring(err))
        assert(b.size == 9, b.size)
        local again = store:blob_put('the bytes')
        assert(again.hash == b.hash, 'the same bytes are the same blob')
        local back, err2 = store:blob_get(b.hash)
        assert(err2 == nil, tostring(err2))
        assert(back == 'the bytes', tostring(back))
        local missing, err3 = store:blob_get('0000')
        assert(missing == nil and err3 == nil, 'an unknown hash is nothing, not an error')
        return b.hash
        "#,
    )?;
    // The name is the content and nothing else, and the file is under `blobs/`.
    let expected = hex::encode(sha2::Sha256::digest(b"the bytes"));
    assert_eq!(hash, expected);
    assert!(dir.path().join("blobs").join(&hash).is_file());
    // The atomic write leaves nothing behind: `blobs/` holds the one file.
    let left: Vec<_> = std::fs::read_dir(dir.path().join("blobs"))?
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(left.len(), 1, "{left:?}");
    Ok(())
}

#[test]
fn the_hatch_sees_what_was_appended() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let kinds: Vec<String> = eval(
        &h,
        r#"
        local store = require('store')
        store:append('card-5', 'card_opened', nil, nil)
        store:append('card-5', 'card_closed', nil, nil)
        local rows, err = store:query('SELECT stream, kind FROM events ORDER BY position', {})
        assert(err == nil, tostring(err))
        local out = {}
        for i = 1, #rows do
           local row = rows[i]
           assert(row.stream == 'card-5', row.stream)
           out[i] = row.kind
        end
        return out
        "#,
    )?;
    assert_eq!(kinds, ["card_opened", "card_closed"]);
    Ok(())
}

#[test]
fn an_unknown_decision_says_which_ones_exist() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let err: String = eval(
        &h,
        r#"
        local store = require('store')
        local rec, err = store:append_if('card-6', 'whenever', 'card_opened', nil, nil)
        assert(rec == nil, 'nothing is written')
        return err
        "#,
    )?;
    assert!(err.contains("whenever"), "{err}");
    assert!(err.contains("unwritten"), "{err}");
    assert!(err.contains("open_unclosed"), "{err}");
    assert!(err.contains("closed_absent"), "{err}");
    Ok(())
}

#[test]
fn the_root_is_the_directory_the_store_was_opened_on() -> anyhow::Result<()> {
    let (dir, h) = opened()?;
    let root: String = eval(&h, "return require('store'):root()")?;
    assert_eq!(root, dir.path().display().to_string());
    Ok(())
}

#[test]
fn json_goes_out_and_comes_back() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let text: String = eval(
        &h,
        r#"
        local store = require('store')
        local text, err = store:json_encode({ { a = 1 }, { a = 2 } })
        assert(err == nil, tostring(err))
        local back, err2 = store:json_decode(text)
        assert(err2 == nil, tostring(err2))
        assert(#back == 2 and back[2].a == 2, 'the array round-trips')
        local bad, err3 = store:json_decode('{not json')
        assert(bad == nil and err3 ~= nil, 'a parse failure is an error, not a nil')
        return text
        "#,
    )?;
    assert_eq!(text, r#"[{"a":1},{"a":2}]"#);
    Ok(())
}
