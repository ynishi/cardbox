//! The binary: the library holds the host and the modules, so this is only the root the
//! store opens on, the entry script, the arguments it runs with — and the exit status,
//! which is the one thing a Teal chunk cannot set for itself.

use std::path::PathBuf;

use htl::{Htl, include_tl};

const MAIN: &str = include_tl!("src/main.tl"); // checked at cargo build

/// The marker `src/main.tl` puts in front of a refusal. Everything else that comes back
/// from a run is a bug in this program rather than a mistake by whoever typed the command,
/// and the two are printed differently: a refusal alone, a bug with its frames.
const REFUSAL: &str = "cardbox-refusal: ";

/// `CARDBOX_ROOT`, else `$HOME/.cardbox`. One env var rather than a flag: every entry
/// point (this binary, a test, another crate) resolves the root before `preload`, and the
/// CLI's own options are about cards rather than about which store they are in.
fn root() -> anyhow::Result<PathBuf> {
    if let Some(set) = std::env::var_os("CARDBOX_ROOT") {
        return Ok(PathBuf::from(set));
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| anyhow::anyhow!("neither CARDBOX_ROOT nor HOME is set"))?;
    Ok(PathBuf::from(home).join(".cardbox"))
}

/// One command, and the status it earned. Everything opened here is dropped when this
/// returns — which is why the exit is in `main` and not in the arm that printed the
/// message: `process::exit` runs no destructor, and the store would be left to the
/// operating system instead of closing.
fn run() -> anyhow::Result<i32> {
    let h = Htl::new()?;
    cardbox::preload(&h, &root()?)?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    h.set_arg("main.tl", &args)?; // `arg[1]`.. as under `htl run`; `exec` alone passes `...`
    // `@<path>` names the Teal source the chunk came from: a run-time failure inside it,
    // and every frame below it, reads `src/main.tl:<line>` and can be opened.
    match h.exec(MAIN, "@src/main.tl", &args) {
        Ok(()) => Ok(0),
        Err(e) => {
            let message = htl::user_message(&e);
            match message.split_once(REFUSAL) {
                // A refusal: the API's own sentence, or the CLI's. It is the whole of what
                // is useful here, so it is the whole of what is printed.
                Some((_, refusal)) => eprintln!("cardbox: {refusal}"),
                // Anything else got here without anybody deciding it should, so whoever is
                // looking at it needs the frames.
                None => eprintln!("cardbox: {}", htl::developer_message(&e)),
            }
            Ok(1)
        }
    }
}

fn main() -> anyhow::Result<()> {
    std::process::exit(run()?)
}
