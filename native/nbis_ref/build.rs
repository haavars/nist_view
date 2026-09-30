// Compiles the vendored NBIS sources (see README.md) into a static library.

use std::path::Path;

fn main() {
    let root = Path::new("vendor/nbis");
    let mut build = cc::Build::new();
    let msvc = std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");

    build.include(root.join("include")).warnings(false);

    // Route NBIS's fprintf through c/glue.c so it stays silent.
    let quiet = Path::new("c/quiet.h").canonicalize().expect("c/quiet.h");
    if msvc {
        build.flag(format!("/FI{}", quiet.display()));
    } else {
        build.flag("-include").flag(quiet.to_str().expect("UTF-8 path"));
    }

    // No fused multiply-add: NBIS's float code then rounds every operation
    // as the C source states it, and gives the same pixels on every platform
    // and compiler (docs/wsq.md).
    build.flag(if msvc { "/fp:precise" } else { "-ffp-contract=off" });

    // NBIS reads big-endian stream markers through byte-swapping helpers
    // that are only enabled with this define.
    if std::env::var("CARGO_CFG_TARGET_ENDIAN").as_deref() == Ok("little") {
        build.define("__NBISLE__", None);
    }

    for dir in ["wsq", "jpegl", "fet", "ioutil", "util"] {
        let dir = root.join("src").join(dir);
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "c"))
            .collect();

        files.sort();
        build.files(files);
    }

    build.file("c/glue.c");
    build.compile("nbis");

    println!("cargo:rerun-if-changed=vendor/nbis");
    println!("cargo:rerun-if-changed=c");
}
