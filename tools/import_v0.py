"""card/v0 (alc's card dir) -> cardbox, through the installed `cardbox` CLI.

    python3 tools/import_v0.py <cardbox root> [<limit>]

The source is alc's default card dir, or `ALC_CARDS_DIR` when set.

One v0 card becomes:
  open   --id <card_id> --params <params + pkg-owned sections> [--model <model.id>]
         --trace-id <metadata.trace_id> --work-url file://<metadata.task_dir>
  samples --file <jsonl>
  eval   per judge_* table (--source llm_judge), review / caveats (--source human)
  close  --ok --stats <[stats] + result-side metadata + extra/outputs> --cost <[cost]>
  tag    set for metadata.group / plugin / run_status, pkg.category, and the v0.* provenance
Aliases from _aliases.toml whose card exists are set afterwards.
Every refusal is logged and the run continues; the run is idempotent per card id.

v0's `model.id` held two different things: an LLM's id (`claude-opus-4-6`) and, far more
often, the name of the flow that ran (`my_orch`, `my_flow`). Only the first is a
model. An id that is not one goes to the tag `flow`, with the original spelling kept under
`v0.model_id`, and the card's `model` is left unset rather than filled with a placeholder.
"""
import json, os, re, subprocess, sys, tomllib, tempfile, time, collections

SRC = os.environ.get("ALC_CARDS_DIR") or os.path.join(os.path.expanduser("~"), ".algocline", "cards")
ROOT = sys.argv[1]
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else None
NAME = re.compile(r"^[A-Za-z0-9_\-]+$")
ENV = dict(os.environ, CARDBOX_ROOT=ROOT)

# What an LLM's id starts with. Anything else in v0's `model.id` is a flow name.
LLM_PREFIXES = ("claude-", "gpt-", "o1", "o3", "o4", "gemini-", "qwen", "llama", "mistral",
                "mixtral", "deepseek", "sonnet", "opus", "haiku", "phi-", "gemma")


def is_llm_id(v):
    return isinstance(v, str) and v.lower().startswith(LLM_PREFIXES)

# v0 top-level tables, by which slot they belong to.
HOST_FIXED = {"card_id", "created_at", "created_by", "schema_version", "pkg", "scenario",
              "stats", "cost", "model", "metadata", "params", "param_fingerprint",
              "review", "caveats", "description"}
# Written at create time by the pkg: input-side. Anything the pkg added as its own
# top-level section (optimize, persona, run, ...) is params.<section>.
INPUT_SECTIONS = {"persona", "run"}
# Result-side leftovers: pointers to outputs and the old `extra` bag.
RESULT_SECTIONS = {"extra", "outputs"}
# metadata keys that are labels people filtered by in v0; trace_id and task_dir are the
# run's identity and go to --trace-id / --work-url, the rest of metadata is result-side.
META_TAGS = {"group", "plugin", "run_status"}

counts = collections.Counter()
refusals = []


def cb(*args, stdin=None):
    r = subprocess.run(["cardbox", *args], env=ENV, capture_output=True, text=True, input=stdin)
    if r.returncode != 0:
        return None, r.stderr.strip()
    return r.stdout, None


def note(kind, card, err):
    counts[f"refused_{kind}"] += 1
    refusals.append((kind, card, err))


def scenario_of(d):
    s = d.get("scenario", {}).get("name")
    if s is None:
        return "none", None
    if NAME.match(s):
        return s, None
    base = os.path.basename(s.rstrip("/")) or "none"
    return (base if NAME.match(base) else "none"), s


def eval_file(cid, payload, source):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as t:
        json.dump(payload, t, default=str)
    out, err = cb("eval", cid, "--file", t.name, "--source", source)
    os.unlink(t.name)
    if err:
        note("eval", cid, err)
    else:
        counts[f"evals_{source}"] += 1


def import_card(fp):
    d = tomllib.load(open(fp, "rb"))
    cid = d["card_id"]
    pkg = d["pkg"]["name"]
    scn, scn_orig = scenario_of(d)
    md = dict(d.get("metadata", {}))

    # ---- params: the pkg's params plus every section the pkg added itself
    params = dict(d.get("params", {}))
    for key, val in d.items():
        if key in HOST_FIXED or key.startswith("judge_") or key in RESULT_SECTIONS:
            continue
        if isinstance(val, dict):
            params[key] = val
    # Provenance of the v0 record itself goes to tags (`v0.*`), not into params: a card
    # that had no params gets no fingerprint, and one that had them prints from them alone.
    tags = {"v0.created_at": str(d.get("created_at")), "v0.schema": str(d.get("schema_version"))}
    if "param_fingerprint" in d:
        tags["v0.fingerprint"] = str(d["param_fingerprint"])
    if scn_orig:
        tags["v0.scenario"] = scn_orig
    if "case_count" in d.get("scenario", {}):
        tags["v0.case_count"] = str(d["scenario"]["case_count"])
    for k in ("session_id", "eval_id"):
        if k in md:
            tags["v0." + k] = str(md.pop(k))

    # model.id: an LLM's id is the card's model; a flow name is the tag `flow`.
    model = d.get("model", {})
    model_id = model.get("id")
    model_arg = []
    if is_llm_id(model_id):
        model_arg = ["--model", model_id]
        counts["model_llm"] += 1
    elif isinstance(model_id, str) and model_id:
        tags["flow"] = model_id
        tags["v0.model_id"] = model_id
        counts["model_as_flow"] += 1
    rest = {k: v for k, v in model.items() if k != "id"}
    if rest:
        params["model"] = rest

    # metadata.prior_card_id is v0's lineage pointer: the parent. cardbox takes the id on
    # trust (the parent may be a card that was never migrated), so nothing is checked here.
    prior = md.pop("prior_card_id", None)
    parent_arg = ["--parent", prior] if isinstance(prior, str) and prior else []
    if parent_arg:
        counts["parents"] += 1

    args = ["open", "--pkg", pkg, "--scenario", scn, "--source", "alc-v0",
            "--created-by", d["created_by"], "--id", cid] + model_arg + parent_arg
    if params:
        args += ["--params", json.dumps(params, default=str)]
    body = d.get("description", {}).get("body")
    if body:
        args += ["--note", body]
    trace = md.pop("trace_id", None)
    if isinstance(trace, str) and trace:
        args += ["--trace-id", trace]
    # task_dir -> work_url: an absolute path becomes file://; a relative one cannot be
    # resolved here and stays as a tag in its original spelling.
    task_dir = md.pop("task_dir", None)
    if isinstance(task_dir, str) and task_dir:
        if task_dir.startswith("/"):
            args += ["--work-url", "file://" + task_dir]
        else:
            tags["v0.task_dir"] = task_dir
    out, err = cb(*args)
    if err:
        if "already" in err:
            counts["skipped_existing"] += 1
        else:
            note("open", cid, err)
        return
    counts["opened"] += 1

    # ---- samples
    sj = fp[:-5] + ".samples.jsonl"
    if os.path.exists(sj) and os.path.getsize(sj) > 0:
        out, err = cb("samples", cid, "--file", sj)
        if err:
            note("samples", cid, err)
        else:
            counts["samples_ok"] += 1
            counts["sample_rows"] += sum(1 for line in open(sj) if line.strip())

    # ---- assessments: judges (llm_judge), review and caveats (human)
    for key in sorted(k for k in d if k.startswith("judge_")):
        eval_file(cid, {"judge": key, **d[key]}, "llm_judge")
    if "review" in d:
        eval_file(cid, {"review": d["review"]}, "human")
    if "caveats" in d:
        eval_file(cid, {"caveats": d["caveats"]}, "human")

    # ---- tags: the labels people filtered by in v0
    for k in META_TAGS:
        v = md.pop(k, None)
        if isinstance(v, str) and v:
            tags[k] = v
    if "category" in d["pkg"]:
        tags["pkg.category"] = str(d["pkg"]["category"])

    # ---- close: stats + result-side metadata + output pointers
    stats = dict(d.get("stats", {}))
    if md:
        stats["metadata"] = md
    for key in RESULT_SECTIONS:
        if key in d:
            stats[key] = d[key]
    args = ["close", cid, "--ok", "--stats", json.dumps(stats, default=str)]
    if "cost" in d:
        args += ["--cost", json.dumps(d["cost"], default=str)]
    out, err = cb(*args)
    if err:
        note("close", cid, err)
    else:
        counts["closed"] += 1

    for k, v in tags.items():
        out, err = cb("tag", "set", cid, k, v)
        if err:
            note("tag", cid, err)
        else:
            counts["tags"] += 1


def main():
    t0 = time.time()
    files = []
    for pkg in sorted(os.listdir(SRC)):
        p = os.path.join(SRC, pkg)
        if os.path.isdir(p):
            files += [os.path.join(p, f) for f in sorted(os.listdir(p)) if f.endswith(".toml")]
    if LIMIT:
        files = files[:LIMIT]
    for i, fp in enumerate(files, 1):
        import_card(fp)
        if i % 100 == 0:
            print(f"  {i}/{len(files)} {time.time()-t0:.0f}s", file=sys.stderr)

    al = tomllib.load(open(os.path.join(SRC, "_aliases.toml"), "rb")).get("alias", [])
    for a in al:
        out, err = cb("get", a["card_id"])
        if err:
            counts["alias_target_missing"] += 1
            continue
        n = a.get("note", "")
        n = f"v0 {a['set_at']}" + (f": {n}" if n else "")
        out, err = cb("alias", "set", a["name"], a["card_id"], "--note", n)
        if err:
            note("alias", a["name"], err)
        else:
            counts["aliases"] += 1

    print(json.dumps(dict(counts), indent=1))
    print(f"elapsed {time.time()-t0:.0f}s")
    if refusals:
        print("refusals (first 20):")
        for r in refusals[:20]:
            print(" ", r)
        with open(os.path.join(ROOT, "import-refusals.jsonl"), "w") as f:
            for r in refusals:
                f.write(json.dumps(r) + "\n")


main()
