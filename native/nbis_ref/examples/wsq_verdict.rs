//! Says what the Rust WSQ decoder makes of every file in the directories
//! given: one line per file, `ok` or the error, a tab and the path. Used by
//! native/nist_codecs/fuzz/replay.sh.
//!
//!     cargo run --release --example wsq_verdict -- DIR...

use std::io::Write;

fn main() {
    let mut out = std::io::stdout().lock();

    for dir in std::env::args().skip(1) {
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .unwrap_or_else(|error| panic!("{dir}: {error}"))
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.is_file())
            .collect();
        files.sort();

        for file in files {
            let verdict = match nist_codecs::wsq::decode_strict(&std::fs::read(&file).unwrap()) {
                Ok(_) => "ok".to_string(),
                Err(error) => format!("{error:?}"),
            };
            writeln!(out, "{verdict}\t{}", file.display()).unwrap();
        }
    }
}
