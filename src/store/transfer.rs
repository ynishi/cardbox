//! Moving the log out, bringing it back, and removing what the move has vouched for.
//!
//! Four mechanisms, one order. The order is the whole of what this file is about, so it
//! is written down before any of them:
//!
//! ```text
//!   cards.prune (policy, src/cardbox/prune.tl)
//!     1 select + refuse            — an aliased card, a parent, an open card: not pruned
//!     2 store:export()             — the WHOLE log, from the end of the confirmed chain
//!     3 append cards_pruned        — the journal event, on the stream `prune`
//!                                    the projection folds it and purges the read models
//!     4 store:retain_streams(..)   — Guard::Exported, then reclaim: the bytes go
//!     5 store:blob_gc()            — the blobs nothing points at any more
//! ```
//!
//! # Why the export is the whole log and not the streams being pruned
//!
//! [`Guard::Exported`] does not ask "was this stream exported". It chains the **confirmed,
//! unfiltered** export receipts from position 0 and refuses any plan that would remove
//! past the chain's end. A filtered export — only the streams about to go — is recorded
//! with `whole = 0` and never extends that chain, so exporting exactly what is to be
//! removed would leave the guard exactly where it was and the retain would be refused.
//!
//! That is not a quirk to work around. The guard's claim is "the history that would be
//! missing afterwards exists somewhere else", and a history with a hole in it cannot make
//! that claim. So [`Store::export`] pages the whole log with [`Filter::all`] from the end
//! of the chain to the end of the log, which makes `<root>/export/` an append-only JSONL
//! backup that grows by one file per call — the backup a prune leans on, reached by
//! doing the only thing the guard accepts.
//!
//! # Where the cursor comes from
//!
//! There is no host-owned table for it. `SqliteEventLog::exported_through()` is the chain's
//! end, read out of eventsdb's own `exports` ledger, and it is exactly where the next
//! export has to start: a page read from there either extends the chain or is a page
//! nobody confirmed, and a re-export of the same range is a duplicate file rather than a
//! lost one.
//!
//! # Confirm after the rename, not before
//!
//! The pages of one call go to a `.part-` file and the receipts are confirmed only once
//! that file has been renamed to its final name and the directory synced. Confirming a
//! page the instant its bytes are `fsync`ed would be one step more eager and one step less
//! honest: a crash between the last page and the rename would leave the chain vouching for
//! a file under a name nothing will look for. Failing the other way costs a duplicate
//! export of the same range, which the next call does on its own.

use std::io::Write;
use std::path::Path;

use eventsdb::sqlite::{Guard, Plan};
use eventsdb::{Error as LogError, EventLog, ExportedEvent, Filter, Position};
use serde_json::Value as Json;

use super::{BlobGcReport, ExportReport, ImportReport, RetainReport, Store};

/// Events per page, in both directions. eventsdb pages an export off a reader and writes
/// one receipt per page; an import is one transaction per page. A thousand is large enough
/// that a store of a few hundred cards is one or two pages and small enough that a failure
/// costs re-reading one of them.
const PAGE: usize = 1000;

impl Store {
    /// The body of [`Store::export`]. The caller holds `command`.
    pub(crate) fn run_export(&self) -> anyhow::Result<ExportReport> {
        let from = self.rt.block_on(self.log.exported_through())?;
        // Asked before `export_recorded`, because that call writes an `exports` row
        // whatever it finds, and a store with nothing new should not collect a row per
        // poll saying so.
        let ahead = self
            .rt
            .block_on(self.log.read_all(from, &Filter::all(), 1))?;
        if ahead.is_empty() {
            return Ok(ExportReport {
                file: None,
                from: from.get(),
                through: from.get(),
                events: 0,
            });
        }

        let dir = self.root.join("export");
        std::fs::create_dir_all(&dir)?;
        let part = dir.join(format!(".part-{}-{}.jsonl", std::process::id(), from.get()));
        let written = match self.write_export(&part, from) {
            Ok(written) => written,
            Err(e) => {
                // A half-written export is evidence of nothing: no receipt was confirmed,
                // so the next call reads the same range again.
                let _ = std::fs::remove_file(&part);
                return Err(e);
            }
        };

        let path = dir.join(format!(
            "{}-{}-{}.jsonl",
            utc_stamp(now_ms()),
            from.get(),
            written.through.get()
        ));
        std::fs::rename(&part, &path)?;
        // The rename itself has to be durable before the chain vouches for the name.
        std::fs::File::open(&dir)?.sync_all()?;
        for receipt in written.receipts {
            self.rt.block_on(self.log.confirm_export(receipt))?;
        }

        Ok(ExportReport {
            file: Some(path.display().to_string()),
            from: from.get(),
            through: written.through.get(),
            events: written.events,
        })
    }

    /// Page the log from `from` into `part` as JSON Lines. Nothing is confirmed here.
    fn write_export(&self, part: &Path, from: Position) -> anyhow::Result<Written> {
        let mut file = std::fs::File::create(part)?;
        let mut at = from;
        let mut events = 0u64;
        let mut receipts = Vec::new();

        loop {
            let (page, receipt) =
                self.rt
                    .block_on(self.log.export_recorded(at, &Filter::all(), PAGE))?;
            // `Filter::all()` is unfiltered, so this holds by construction. It is checked
            // rather than assumed because a receipt that is not whole cannot extend the
            // chain, and a retain refused later with no explanation would be the symptom.
            if !receipt.whole {
                anyhow::bail!(
                    "the export of positions {}..{} was recorded as filtered, so it cannot \
                     vouch for the history it covers",
                    receipt.from.get(),
                    receipt.through.get()
                );
            }
            let short = page.len() < PAGE;
            for record in &page {
                let mut line = serde_json::to_string(&record.to_json())?;
                line.push('\n');
                file.write_all(line.as_bytes())?;
            }
            events += page.len() as u64;
            at = receipt.through;
            receipts.push(receipt.id);
            file.sync_all()?;
            if short {
                break;
            }
        }

        Ok(Written {
            through: at,
            events,
            receipts,
        })
    }

    /// The body of [`Store::import`]. The caller holds `command`.
    pub(crate) fn run_import(&self, path: &str) -> anyhow::Result<ImportReport> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("cannot read the export {path}: {e}"))?;
        let mut batch: Vec<ExportedEvent> = Vec::new();
        let mut events = 0u64;
        // One false page makes the whole import false: the claim is about the run, and a
        // run that landed on its own coordinates for half of itself did not reproduce the
        // log.
        let mut reproduced = true;

        for (n, line) in text.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let value: Json = serde_json::from_str(line)
                .map_err(|e| anyhow::anyhow!("{path}:{}: not JSON: {e}", n + 1))?;
            let record = ExportedEvent::from_json(value)
                .map_err(|e| anyhow::anyhow!("{path}:{}: not an exported event: {e}", n + 1))?;
            batch.push(record);
            if batch.len() == PAGE {
                let report = self
                    .rt
                    .block_on(self.log.import(std::mem::take(&mut batch)))?;
                events += report.imported as u64;
                reproduced = reproduced && report.reproduced_coordinates;
            }
        }
        if !batch.is_empty() {
            let report = self.rt.block_on(self.log.import(batch))?;
            events += report.imported as u64;
            reproduced = reproduced && report.reproduced_coordinates;
        }

        // The read models are what everything above this reads through, so an import that
        // left them behind would be a store holding a card `cards.get` cannot find.
        self.caught_up()?;
        Ok(ImportReport {
            events,
            reproduced_coordinates: reproduced,
        })
    }

    /// The body of [`Store::retain_streams`]. The caller holds `command`.
    pub(crate) fn run_retain(&self, streams: Vec<String>) -> anyhow::Result<RetainReport> {
        // Both of these are about the guard's *other* half, `ConsumerBehind`. The live
        // model has to have folded the journal event that announced this removal — that is
        // the "read model purges before the physical delete" order — and the retired names
        // have to be dragged up again, because `Store::open` last did it when the store was
        // opened and the log has grown since.
        self.caught_up()?;
        self.drag_retired()?;

        let report = match self
            .rt
            .block_on(self.log.retain(Plan::Streams(streams), Guard::Exported))
        {
            Ok(report) => report,
            Err(LogError::NotExported {
                up_to,
                exported_through,
            }) => {
                anyhow::bail!(
                    "removing these streams would reach position {up_to}, and confirmed \
                     exports reach only {exported_through}: run export first \
                     (cards.export / store:export()), which writes the whole log to \
                     <root>/export and confirms it, and then prune again"
                );
            }
            Err(LogError::ConsumerBehind {
                consumer,
                cursor,
                up_to,
            }) => {
                anyhow::bail!(
                    "removing these streams would reach position {up_to}, and the read \
                     model {consumer:?} has folded only to {cursor}: what this removes is \
                     history it would never see. Catch it up (store:catch_up()) — or, if \
                     {consumer:?} is a projection this build retired, reopen the store, \
                     which drags a retired cursor forward"
                );
            }
            Err(other) => return Err(other.into()),
        };

        // Deleting rows hands the pages back to SQLite, not to the filesystem.
        self.rt.block_on(self.log.reclaim())?;
        Ok(RetainReport {
            removed: report.removed as u64,
            streams: report.streams_affected as u64,
        })
    }

    /// The body of [`Store::blob_gc`]. The caller holds `command`.
    ///
    /// The row goes inside the transaction and the file goes after it commits. The other
    /// order would leave a row promising bytes that are not there, which is the failure a
    /// reader cannot tell from corruption; this one leaves at worst a file nothing points
    /// at, which is what a content-addressed directory tolerates by construction.
    pub(crate) fn run_blob_gc(&self) -> anyhow::Result<BlobGcReport> {
        // `refs` is the projection's count, so it is only right once the projection has
        // seen the journal event that decremented it.
        self.caught_up()?;

        let orphans: Vec<(String, i64)> = self.rt.block_on(self.log.with_transaction(|tx| {
            let mut stmt = tx
                .prepare("SELECT hash, COALESCE(size, 0) FROM cb_blobs WHERE refs <= 0")
                .map_err(storage)?;
            let rows = stmt
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(storage)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(storage)?;
            drop(stmt);
            tx.execute("DELETE FROM cb_blobs WHERE refs <= 0", [])
                .map_err(storage)?;
            Ok(rows)
        }))?;

        let mut deleted = 0u64;
        let mut bytes = 0u64;
        for (hash, size) in orphans {
            let path = self.blobs().join(&hash);
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                // Already gone: the row is what this was reclaiming, and it is gone too.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(anyhow::anyhow!("cannot remove the blob {hash}: {e}")),
            }
            deleted += 1;
            bytes += size.max(0) as u64;
        }
        Ok(BlobGcReport { deleted, bytes })
    }

    /// Drag every retired projection name up to where the live model stands.
    ///
    /// [`Store::carry_forward`] under the store's own locks, so retention can run it
    /// again: the drag at `open` is only right until the next append.
    fn drag_retired(&self) -> anyhow::Result<()> {
        let mut runner = self.runner();
        Store::carry_forward(&self.rt, &self.log, &mut runner)
    }
}

/// What [`Store::write_export`] left in the `.part` file.
struct Written {
    through: Position,
    events: u64,
    receipts: Vec<u64>,
}

fn storage(e: eventsdb::sqlite::rusqlite::Error) -> eventsdb::Error {
    eventsdb::Error::storage(e.to_string())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// `1757592000000` -> `20250911T120000Z`, which sorts as it reads and needs no dependency.
fn utc_stamp(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let tod = secs.rem_euclid(86_400);
    format!(
        "{y:04}{m:02}{d:02}T{:02}{:02}{:02}Z",
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

/// Days since the epoch to a civil date — Howard Hinnant's `civil_from_days`, whose eras
/// are what make it branchless about leap years rather than a table of month lengths.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

#[cfg(test)]
mod tests {
    use super::utc_stamp;

    #[test]
    fn the_stamp_is_utc_and_sorts_as_it_reads() {
        assert_eq!(utc_stamp(0), "19700101T000000Z");
        assert_eq!(utc_stamp(1_757_592_000_000), "20250911T120000Z");
        // A leap day, which the era arithmetic is the reason to trust.
        assert_eq!(utc_stamp(1_709_164_800_000), "20240229T000000Z");
    }
}
