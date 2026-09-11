# What to run, and when. The names say the moment rather than the tool: `pre-commit` is
# what a commit has to be green under, `e2e` is what a change to the CLI or the host owes
# before it is believed. The parts are here on their own too, because a fast loop is
# `just test` and nothing else.

default:
    @just --list

# Both formatters, writing. `htl fmt` takes its indent from `htl.toml`.
fmt:
    cargo fmt --all
    htl fmt .

# Both formatters, reading. This is the half `pre-commit` runs: a formatter that writes
# would make the gate pass by changing the thing it was asked about.
fmt-check:
    cargo fmt --all --check
    htl fmt --check .

# Both suites. `cargo test` drives the Teal through `preload`, so it is the Rust host and
# the policy together; `htl test` is the policy alone, with no host in the room.
test:
    cargo test
    htl test

clippy:
    cargo clippy --all-targets -- -D warnings

# The Teal type check and its lints. `cargo build` runs the same checker inside
# `include_tl!`, so this is the faster way to the same answer while editing.
check:
    htl check .

# What a commit has to be green under. Nothing here touches the filesystem outside the
# project and nothing here needs the binary installed.
pre-commit: fmt-check test clippy check

# The binary, into ~/.cargo/bin.
install:
    cargo install --path .

# The whole life of a card, through the installed binary, in a store under /tmp. This is
# the verification that the unit tests cannot do: a real process, a real root, real files
# read from the command line. It installs first, because a stale binary passing is worse
# than no answer.
e2e: install
    bash e2e/run.sh
