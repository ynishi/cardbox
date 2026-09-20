#!/usr/bin/env bash
#
# The whole life of a card, through the installed binary.
#
# What this is for: everything else in this project runs the Teal or the Rust in process.
# This runs `cardbox` — the one `cargo install --path .` put on PATH — against a store it
# creates from nothing, in the order a person would: open, write, close, name, find, prune,
# export, import. Nothing is stubbed and nothing is left in the repository; the two roots
# are directories under /tmp named after this process.
#
# `just e2e` installs first and then runs this. Run it on its own only when the binary is
# already the one you meant to test: it reads $CARDBOX from the environment, so
#   CARDBOX=target/debug/cardbox bash e2e/run.sh
# checks a debug build instead.
#
# Every step prints `OK <step>`; the first failure ends the run non-zero.

set -euo pipefail

CARDBOX="${CARDBOX:-$HOME/.cargo/bin/cardbox}"
ROOT="/tmp/cardbox-e2e-$$"
ROOT2="/tmp/cardbox-e2e-$$-restored"
FIXTURES="$ROOT/fixtures"

mkdir -p "$FIXTURES"
export CARDBOX_ROOT="$ROOT"

fail() {
   echo "FAIL $1" >&2
   exit 1
}

ok() {
   echo "OK $1"
}

# `assert <what> <json> <jq argument>...`, the last of which is the filter. `jq -e` exits
# non-zero on false and on null, which is the whole of the assertion.
assert() {
   local what="$1" json="$2"
   shift 2
   printf '%s' "$json" | jq -e "$@" >/dev/null || fail "$what -- $json"
}

# ------------------------------------------------------------------ fixtures

cat >"$FIXTURES/rows.jsonl" <<'JSONL'
{"q": "1+1", "a": 2, "score": 1.0}
{"q": "2+2", "a": 4, "score": 1.0}
{"q": "3+3", "a": 7, "score": 0.0}
JSONL

cat >"$FIXTURES/eval.json" <<'JSON'
{"mean_score": 0.8, "n": 5, "pass_rate": 0.8, "passed": 4, "failures": ["3+3"]}
JSON

# 200 bytes that are not text-shaped, standing in for a checkpoint.
head -c 200 /dev/urandom >"$FIXTURES/weights.bin"
test "$(wc -c <"$FIXTURES/weights.bin")" -eq 200 || fail "the checkpoint fixture is not 200 bytes"

# ------------------------------------------------------------------ the store

VERSION="$($CARDBOX version)"
assert "version" "$VERSION" '.cardbox | test("^[0-9]")'
assert "root" "$($CARDBOX root)" --arg r "$ROOT" '.root == $r'
ok "version $(printf '%s' "$VERSION" | jq -r .cardbox), root $ROOT"

# ------------------------------------------------------------------ two cards

PARENT_JSON="$($CARDBOX open --pkg demo --scenario arith --source e2e --note 'the first run' \
   --params '{"temperature": 0.2, "variant": "b"}' --model demo-model --trace-id tr-e2e \
   --work-url "file://$FIXTURES")"
assert "the open minted a fingerprint" "$PARENT_JSON" '(.fingerprint | length) == 16'
assert "open the parent" "$PARENT_JSON" '.state == "open" and .pkg == "demo"'
PARENT="$(printf '%s' "$PARENT_JSON" | jq -r .id)"

CHILD_JSON="$($CARDBOX open --pkg demo --scenario arith --source e2e --parent "$PARENT")"
assert "open the child" "$CHILD_JSON" '.state == "open"'
CHILD="$(printf '%s' "$CHILD_JSON" | jq -r .id)"
ok "open $PARENT, and $CHILD as its child"

# ------------------------------------------------------------------ samples

assert "samples from a file" \
   "$($CARDBOX samples "$PARENT" --file "$FIXTURES/rows.jsonl")" '.n == 3'

assert "samples from stdin" \
   "$(printf '%s\n%s\n' \
      '{"q": "4+4", "a": 8, "score": 1.0}' \
      '{"q": "5+5", "a": 10, "score": 1.0}' | $CARDBOX samples "$PARENT")" '.n == 2'
ok "samples: 3 from a file, 2 from stdin"

# ------------------------------------------------------------------ eval

assert "eval" "$($CARDBOX eval "$PARENT" --file "$FIXTURES/eval.json")" '.kind == "eval_recorded"'
ok "eval recorded"

# ------------------------------------------------------------------ checkpoint

CHECKPOINT="$($CARDBOX checkpoint "$PARENT" --file "$FIXTURES/weights.bin" \
   --format safetensors --note 'epoch 3')"
assert "checkpoint" "$CHECKPOINT" '.size == 200 and (.blob | length) == 64'
ok "checkpoint: 200 bytes, blob $(printf '%s' "$CHECKPOINT" | jq -r '.blob[0:12]')..."

# ------------------------------------------------------------------ close both

assert "close --ok" "$($CARDBOX close "$PARENT" --ok \
   --stats '{"mean_score": 0.8, "n": 5, "pass_rate": 0.8, "passed": 4}' \
   --cost '{"elapsed_ms": 1200, "llm_calls": 9}')" '.state == "closed_ok"'

assert "close --failed" \
   "$($CARDBOX close "$CHILD" --failed --error 'the provider timed out')" \
   '.state == "closed_failed"'
ok "close: one ok, one failed"

# ------------------------------------------------------------------ get both

PARENT_VIEW="$($CARDBOX get "$PARENT")"
assert "the parent is closed_ok" "$PARENT_VIEW" '.state == "closed_ok"'
assert "the parent has 5 sample rows" "$PARENT_VIEW" '.samples.rows == 5'
assert "the parent has 2 sample batches" "$PARENT_VIEW" '.samples.batches == 2'
assert "the parent has one eval" "$PARENT_VIEW" '.evals == 1'
assert "the parent's checkpoint hash" "$PARENT_VIEW" \
   '(.checkpoints | length) == 1 and (.checkpoints[0].blob | length) == 64'
assert "the parent's stats came back" "$PARENT_VIEW" '.stats.mean_score == 0.8'

assert "the parent's params came back" "$PARENT_VIEW" '.params.variant == "b" and .model == "demo-model"'

CHILD_VIEW="$($CARDBOX get "$CHILD")"
assert "the child is closed_failed" "$CHILD_VIEW" '.state == "closed_failed"'
assert "the child kept why it failed" "$CHILD_VIEW" '.error == "the provider timed out"'
ok "get both: closed_ok with 5 rows and a checkpoint, closed_failed with its reason"

# ------------------------------------------------------------------ said about a closed card

assert "a human eval on a closed card" \
   "$(printf '%s' '{"verdict": "ship"}' >"$FIXTURES/review.json"; \
      $CARDBOX eval "$PARENT" --file "$FIXTURES/review.json" --source human)" \
   '.source == "human"'
assert "tag set" "$($CARDBOX tag set "$PARENT" stage prod)" '.changed == true'
assert "tag set again writes nothing" "$($CARDBOX tag set "$PARENT" stage prod)" '.changed == false'
assert "the card carries the tag and two evals" "$($CARDBOX get "$PARENT")" \
   '.tags.stage == "prod" and .evals == 2'
assert "find by params and by tag" \
   "$($CARDBOX find --where 'params.variant = b' --where 'tags.stage = prod' --where 'model = demo-model')" \
   --arg p "$PARENT" 'length == 1 and .[0].id == $p'
assert "tag unset" "$($CARDBOX tag unset "$PARENT" stage)" '.changed == true'
ok "closed card: a human eval, a tag set once, found by params.variant and tags.stage, tag unset"

# ------------------------------------------------------------------ alias

assert "alias set" "$($CARDBOX alias set best "$PARENT" --note 'the one to beat')" '.changed == true'

BY_ALIAS="$($CARDBOX alias get best)"
assert "alias get" "$BY_ALIAS" --arg id "$PARENT" '.id == $id'
assert "the card knows its own name" "$BY_ALIAS" '.aliases | index("best") != null'
ok "alias best -> $PARENT"

# ------------------------------------------------------------------ find

HITS="$($CARDBOX find --where 'mean_score > 0.5')"
assert "find on a score" "$HITS" 'length == 1'
assert "find found the right card" "$HITS" --arg id "$PARENT" '.[0].id == $id'
ok "find --where 'mean_score > 0.5' -> 1 card"

# ------------------------------------------------------------------ lineage

TREE="$($CARDBOX lineage "$CHILD")"
assert "lineage: the child's parent" "$TREE" --arg id "$PARENT" '.parents == [$id]'
assert "lineage: one generation up" "$TREE" --arg id "$PARENT" \
   '.ancestors[0].id == $id and .ancestors[0].depth == 1'
assert "lineage: the parent's child" "$($CARDBOX lineage "$PARENT")" --arg id "$CHILD" \
   '.children == [$id]'
ok "lineage: $CHILD <- $PARENT, both ways"

# ------------------------------------------------------------------ promote

PROMOTED="$($CARDBOX promote --alias champion --pkg demo)"
assert "promote picked the best card" "$PROMOTED" --arg id "$PARENT" '.card_id == $id'
assert "promote bound the name" "$PROMOTED" '.changed == true and .metric == "mean_score"'
ok "promote champion -> $(printf '%s' "$PROMOTED" | jq -r .card_id)"

# ------------------------------------------------------------------ debris

DEBRIS="$($CARDBOX open --pkg _test_x --scenario arith --source e2e | jq -r .id)"
$CARDBOX close "$DEBRIS" --ok >/dev/null
ok "a _test_x card to throw away: $DEBRIS"

# `--pkg-like` is a LIKE pattern, so the `_` of `_test_` is escaped: the query carries
# ESCAPE '\', and `\_test\_%` is every pkg whose name starts with those six characters.
DRY="$($CARDBOX prune --reason 'test debris' --pkg-like '\_test\_%' --dry-run)"
assert "the dry run selected the debris" "$DRY" --arg id "$DEBRIS" '.selected == [$id]'
# `(.pruned | length) == 0` rather than `.pruned == []`: the store's encoder writes a Lua
# table with no sequence part as an object, so an empty list reaches stdout as `{}`. Lua
# cannot tell `{}` from `[]` and the encoder chose the shape that round-trips a record with
# every field cleared (`src/store/json.rs`); a reader of this output counts rather than
# compares.
assert "the dry run removed nothing" "$DRY" \
   '.dry_run == true and (.pruned | length) == 0 and .events_removed == 0'
assert "the card is still there after a dry run" "$($CARDBOX get "$DEBRIS")" '.state == "closed_ok"'
ok "prune --dry-run: selected 1, removed 0"

PRUNED="$($CARDBOX prune --reason 'test debris' --pkg-like '\_test\_%')"
assert "prune removed the debris" "$PRUNED" --arg id "$DEBRIS" '.pruned == [$id]'
assert "prune removed its events" "$PRUNED" '.events_removed > 0'
EXPORT_FILE="$(printf '%s' "$PRUNED" | jq -r .export_file)"
test -f "$EXPORT_FILE" || fail "the export the prune leaned on is not a file: $EXPORT_FILE"
if $CARDBOX get "$DEBRIS" >/dev/null 2>&1; then
   fail "the pruned card is still readable"
fi
ok "prune: 1 card, $(printf '%s' "$PRUNED" | jq -r .events_removed) events, export $EXPORT_FILE"

# ------------------------------------------------------------------ the journal

LOG="$($CARDBOX prune-log)"
assert "one entry in the prune log" "$LOG" 'length == 1'
assert "the journal says what went and why" "$LOG" --arg id "$DEBRIS" \
   '.[0].cards == [$id] and .[0].reason == "test debris"'
assert "the journal names the export" "$LOG" --arg f "$EXPORT_FILE" '.[0].export_file == $f'
ok "prune-log: 1 entry naming $DEBRIS and its export"

# The prune exported the log and then wrote its journal event, so that event is the only
# thing past the confirmed chain: this is an export of exactly one.
assert "the export after a prune is the journal event alone" "$($CARDBOX export)" '.events == 1'
ok "export after the prune: 1 event, the journal entry"

# ------------------------------------------------------------------ restore

CARDBOX_ROOT="$ROOT2" $CARDBOX import "$EXPORT_FILE" >/dev/null
RESTORED="$(CARDBOX_ROOT="$ROOT2" $CARDBOX alias get champion)"
assert "the champion came back with its id" "$RESTORED" --arg id "$PARENT" '.id == $id'
assert "and with its state" "$RESTORED" '.state == "closed_ok" and .samples.rows == 5'
ok "import into $ROOT2: champion is $PARENT, closed_ok, 5 rows"

# ------------------------------------------------------------------ a refusal

set +e
REFUSAL="$(printf '%s\n' '{"q": "6+6", "a": 12}' | $CARDBOX samples "$PARENT" 2>&1 >/dev/null)"
STATUS=$?
set -e
test "$STATUS" -eq 1 || fail "a closed card took samples (exit $STATUS)"
case "$REFUSAL" in
   "cardbox: cannot append samples to card $PARENT: it is closed") ;;
   *) fail "the refusal is not the API's own sentence: $REFUSAL" ;;
esac
ok "samples on a closed card: exit 1, \"$REFUSAL\""

echo "E2E OK"
