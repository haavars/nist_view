//! Times the Rust WSQ decoder against NBIS on a directory of WSQ files.
//!
//!     mix run scripts/extract_wsq.exs /tmp/wsq_ref      (from the repo root)
//!     cargo run --release --example wsq_bench -- /tmp/wsq_ref
//!
//! Each file is decoded three times by each decoder and the best time
//! counts. The output also says whether the pixels agree.

use std::time::Instant;

fn best(decode: &dyn Fn()) -> f64 {
    (0..3)
        .map(|_| {
            let start = Instant::now();
            decode();
            start.elapsed().as_secs_f64()
        })
        .fold(f64::MAX, f64::min)
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: wsq_bench DIR");
    let mut files: Vec<_> = std::fs::read_dir(&dir)
        .unwrap_or_else(|error| panic!("{dir}: {error}"))
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "wsq"))
        .collect();
    files.sort();

    let (mut rust_total, mut nbis_total, mut pixels, mut same) = (0.0, 0.0, 0usize, 0);
    let mut largest = (0, 0.0, 0.0);

    for file in &files {
        let data = std::fs::read(file).unwrap();
        let rust_image = nist_codecs::wsq::decode(&data).expect("the Rust decoder decodes it");
        let nbis_image = nbis_ref::decode_wsq(&data).expect("NBIS decodes it");
        same += (rust_image.data == nbis_image.pixels) as usize;

        let rust = best(&|| drop(nist_codecs::wsq::decode(&data)));
        let nbis = best(&|| drop(nbis_ref::decode_wsq(&data)));
        rust_total += rust;
        nbis_total += nbis;
        pixels += nbis_image.pixels.len();
        if nbis_image.pixels.len() > largest.0 {
            largest = (nbis_image.pixels.len(), rust, nbis);
        }
    }

    let megapixels = pixels as f64 / 1e6;
    println!("{} images, {megapixels:.1} megapixels, {same} identical to NBIS", files.len());
    println!("Rust: {:.2} s, {:.1} megapixels per second", rust_total, megapixels / rust_total);
    println!("NBIS: {:.2} s, {:.1} megapixels per second", nbis_total, megapixels / nbis_total);
    println!(
        "largest image ({:.2} megapixels): Rust {:.0} ms, NBIS {:.0} ms",
        largest.0 as f64 / 1e6,
        largest.1 * 1e3,
        largest.2 * 1e3
    );
}
