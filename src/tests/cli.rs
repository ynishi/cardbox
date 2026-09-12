//! The CLI through the embedded path: `preload` registers `cardbox.cli` beside everything
//! else, and `cli.run` is called with the words a shell would have handed it.
//!
//! No process is spawned. What this proves is the half `tests/cli_test.tl` cannot — the
//! module loads with the Rust host in the room, the dispatch reaches `cards.*`, and what
//! goes to stdout is JSON the store's own encoder wrote — and the half `e2e/run.sh` proves
//! more slowly.

use super::{eval, opened};

/// Open a card and read it back, as two command lines.
#[test]
fn open_then_get_runs_through_the_dispatch() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let state: String = eval(
        &h,
        r#"
        local cli = require('cardbox.cli')
        local store = require('store')

        local opened, err = cli.run(store, {
           'open', '--pkg', 'demo', '--scenario', 'smoke', '--source', 'cli-test',
           '--note', 'the first one',
        })
        assert(err == nil, tostring(err))

        local card = store:json_decode(opened)
        assert(card.state == 'open', tostring(card.state))
        assert(card.pkg == 'demo', tostring(card.pkg))
        -- `--created-by` was not given, so the CLI's own default is what is on the card
        assert(card.created_by:match('^cardbox '), tostring(card.created_by))

        local got, gerr = cli.run(store, { 'get', card.id })
        assert(gerr == nil, tostring(gerr))
        local view = store:json_decode(got)
        assert(view.id == card.id, tostring(view.id))
        assert(view.note == 'the first one', tostring(view.note))
        assert(view.created_by == card.created_by, tostring(view.created_by))
        return view.state
        "#,
    )?;
    assert_eq!(state, "open");
    Ok(())
}

/// A refusal from the API comes back as a refusal from the dispatch, word for word and
/// with no output beside it.
#[test]
fn a_refusal_comes_back_as_text_and_no_output() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let message: String = eval(
        &h,
        r#"
        local cli = require('cardbox.cli')
        local store = require('store')
        local out, err = cli.run(store, { 'get', 'nothing_is_under_this_id' })
        assert(out == nil, tostring(out))
        return err
        "#,
    )?;
    assert_eq!(message, "no card nothing_is_under_this_id");
    Ok(())
}

/// A mistyped option is refused by name rather than read as a positional.
#[test]
fn an_undeclared_option_is_refused_by_name() -> anyhow::Result<()> {
    let (_dir, h) = opened()?;
    let message: String = eval(
        &h,
        r#"
        local cli = require('cardbox.cli')
        local store = require('store')
        local out, err = cli.run(store, {
           'open', '--pkg', 'demo', '--scenarion', 'smoke', '--source', 'x',
        })
        assert(out == nil, tostring(out))
        return err
        "#,
    )?;
    assert_eq!(message, "unknown option --scenarion");
    Ok(())
}
