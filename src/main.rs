//! The binary: the library holds the host and the module, so this is only the entry
//! script and the arguments it runs with.

use htl::{Htl, include_tl};

const MAIN: &str = include_tl!("src/main.tl"); // checked at cargo build

fn main() -> anyhow::Result<()> {
    let h = Htl::new()?;
    cardbox::preload(&h)?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    h.set_arg("main.tl", &args)?; // `arg[1]`.. as under `htl run`; `exec` alone passes `...`
    // `@<path>` names the Teal source the chunk came from: a run-time failure inside it,
    // and every frame below it, reads `src/main.tl:<line>` and can be opened.
    h.exec(MAIN, "@src/main.tl", &args)?;
    Ok(())
}
