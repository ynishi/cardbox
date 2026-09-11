//! The binary: the library holds the host and the module, so this is only the root the
//! store opens on, the entry script and the arguments it runs with.

use std::path::PathBuf;

use htl::{Htl, include_tl};

const MAIN: &str = include_tl!("src/main.tl"); // checked at cargo build

/// `CARDBOX_ROOT`, else `$HOME/.cardbox`. One env var rather than a flag: every entry
/// point (this binary, a test, another crate) resolves the root before `preload`, and a
/// flag would be the CLI's to parse — which step 6 writes.
fn root() -> anyhow::Result<PathBuf> {
    if let Some(set) = std::env::var_os("CARDBOX_ROOT") {
        return Ok(PathBuf::from(set));
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| anyhow::anyhow!("neither CARDBOX_ROOT nor HOME is set"))?;
    Ok(PathBuf::from(home).join(".cardbox"))
}

fn main() -> anyhow::Result<()> {
    let h = Htl::new()?;
    cardbox::preload(&h, &root()?)?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    h.set_arg("main.tl", &args)?; // `arg[1]`.. as under `htl run`; `exec` alone passes `...`
    // `@<path>` names the Teal source the chunk came from: a run-time failure inside it,
    // and every frame below it, reads `src/main.tl:<line>` and can be opened.
    h.exec(MAIN, "@src/main.tl", &args)?;
    Ok(())
}
