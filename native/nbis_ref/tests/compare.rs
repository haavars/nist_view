//! The safe-Rust WSQ decoder against NBIS: wherever the Rust decoder
//! succeeds, NBIS must succeed with the same pixels, size and resolution.
//!
//! `decode_strict` is compared, since `decode` accepts a few inputs that
//! NBIS rejects; the two Rust variants must agree with each other.

use nist_codecs::wsq;
use std::path::{Path, PathBuf};

const SYNTHETIC: &[u8] = include_bytes!("../../../test/fixtures/synthetic.wsq");

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Compares the decoders on one input. Returns false, without running NBIS,
/// when the Rust decoder rejects it: NBIS has memory bugs on bad input.
fn same(name: &str, data: &[u8]) -> bool {
    let Ok(rust) = wsq::decode_strict(data) else {
        return false;
    };
    let nbis = nbis_ref::decode_wsq(data).unwrap_or_else(|| panic!("{name}: Rust decodes it, NBIS does not"));

    assert_eq!((rust.width, rust.height, rust.ppi), (nbis.width, nbis.height, nbis.ppi), "{name}");
    let differing = rust.data.iter().zip(&nbis.pixels).filter(|(a, b)| a != b).count();
    assert!(
        rust.data == nbis.pixels,
        "{name}: {differing} of {} pixels differ ({} × {})",
        nbis.pixels.len(),
        nbis.width,
        nbis.height
    );

    let lenient = wsq::decode(data).unwrap_or_else(|error| panic!("{name}: decode fails with {error:?}"));
    assert!(lenient.data == rust.data && lenient.ppi == rust.ppi, "{name}: decode and decode_strict differ");
    true
}

#[test]
fn synthetic_fixture() {
    assert!(same("synthetic.wsq", SYNTHETIC));
}

/// Every WSQ image in the BioCTS sample transactions (`mix nist.samples`).
/// The images are found by their first two markers instead of parsing the
/// ANSI/NIST records; both decoders stop at EOI, so the rest of the file
/// after an image does not matter.
#[test]
fn biocts_samples() {
    let dir = repo().join("test/samples/biocts");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        eprintln!("skipped: no samples in {}", dir.display());
        return;
    };

    let mut files: Vec<PathBuf> = entries.map(|entry| entry.unwrap().path()).collect();
    files.sort();

    let (mut images, mut seen) = (0, std::collections::HashSet::new());
    for file in files.iter().filter(|file| file.extension().is_some_and(|ext| ext == "an2")) {
        let data = std::fs::read(file).unwrap();
        let name = file.file_name().unwrap().to_string_lossy();

        for start in 0..data.len().saturating_sub(4) {
            // SOI, then a comment, a table or the frame header.
            if data[start..start + 3] != [0xFF, 0xA0, 0xFF] || !matches!(data[start + 3], 0xA2 | 0xA4..=0xA6 | 0xA8) {
                continue;
            }
            images += 1;

            // Many transactions carry the same images; this skips most of
            // the repeats.
            let stream = &data[start..];
            if seen.insert(stream[..stream.len().min(65_536)].to_vec()) {
                assert!(same(&format!("{name} at {start}"), stream), "{name} at {start}: Rust rejects it");
            }
        }
    }

    // The set is fixed.
    assert_eq!(images, 136);
}

/// What a test stream carries after its frame header.
#[derive(Clone, Copy, Debug)]
enum Block {
    /// The fixture's first Huffman table and the first bytes of its first
    /// block.
    Fixture(usize),
    /// Generated coefficients for this share (in percent) of the
    /// transmitted subbands, in a block with a table of its own.
    Generated(usize),
}

/// A stream built from the synthetic fixture's segments: another size,
/// other filters, another block.
fn variant(width: u16, height: u16, filters: Option<(u8, u8)>, block: Block) -> Vec<u8> {
    // Segment offsets in the fixture.
    const DTT: usize = 125;
    const DQT: usize = 185;
    const SOF: usize = 576;
    const BLOCK_DATA: usize = 744;

    // SOI and the NIST_COM comment.
    let mut out = SYNTHETIC[..DTT].to_vec();

    match filters {
        None => out.extend_from_slice(&SYNTHETIC[DTT..DQT]),
        Some((hisz, losz)) => {
            let coefficients = hisz.div_ceil(2) as u16 + losz.div_ceil(2) as u16;
            out.extend_from_slice(&[0xFF, 0xA4]);
            out.extend_from_slice(&(4 + 6 * coefficients).to_be_bytes());
            out.extend_from_slice(&[hisz, losz]);
            for k in 0..coefficients as u32 {
                // Sign, decimal exponent, value: magnitudes below 0.6.
                let value = (k + 3).wrapping_mul(2_654_435_761) % 600_000_000;
                out.extend_from_slice(&[(k % 3 == 1) as u8, 9]);
                out.extend_from_slice(&value.to_be_bytes());
            }
        }
    }

    let frame = |out: &mut Vec<u8>| {
        out.extend_from_slice(&SYNTHETIC[SOF..SOF + 6]);
        out.extend_from_slice(&height.to_be_bytes());
        out.extend_from_slice(&width.to_be_bytes());
        out.extend_from_slice(&SYNTHETIC[SOF + 10..SOF + 19]);
    };

    match block {
        Block::Fixture(data) => {
            out.extend_from_slice(&SYNTHETIC[DQT..SOF]);
            frame(&mut out);
            out.extend_from_slice(&SYNTHETIC[SOF + 19..BLOCK_DATA + data]);
        }
        Block::Generated(percent) => {
            // Every subband but the last four is transmitted: bin centre
            // 0.44, then a bin width and a zero bin width per subband.
            out.extend_from_slice(&[0xFF, 0xA5]);
            out.extend_from_slice(&(5 + 6 * 64u16).to_be_bytes());
            out.extend_from_slice(&[2, 0, 44]);
            for subband in 0..64u16 {
                let q = if subband < 60 { 30 + 5 * subband } else { 0 };
                out.extend_from_slice(&[2, (q >> 8) as u8, q as u8, 2, (q * 6 / 5 >> 8) as u8, (q * 6 / 5) as u8]);
            }
            frame(&mut out);

            // 248 codes of 8 bits, so a symbol is a byte and never `FF`:
            // first the coefficients -73 to 74, then zero runs of 1 to 100.
            out.extend_from_slice(&[0xFF, 0xA6]);
            out.extend_from_slice(&(2 + 1 + 16 + 248u16).to_be_bytes());
            out.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 248, 0, 0, 0, 0, 0, 0, 0, 0]);
            out.extend(107..=254u8);
            out.extend(1..=100u8);
            out.extend_from_slice(&[0xFF, 0xA3, 0, 3, 0]);

            // The last four subbands are the quarter with the high halves
            // of both directions.
            let (w, h) = (width as usize, height as usize);
            let mut left = (w * h - (w / 2) * (h / 2)) * percent / 100;
            let mut state = 0x2545_F491u32 ^ (w * 65_537 + h) as u32;
            while left > 0 {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let random = (state >> 8) as usize;
                if random % 16 == 0 {
                    let run = (1 + (random >> 4) % 100).min(left);
                    out.push((148 + run - 1) as u8);
                    left -= run;
                } else {
                    out.push(((random >> 4) % 148) as u8);
                    left -= 1;
                }
            }
        }
    }

    out.extend_from_slice(&[0xFF, 0xA1]);
    out
}

#[test]
fn the_unchanged_variant_is_the_fixture_up_to_its_first_block() {
    assert_eq!(variant(128, 96, None, Block::Fixture(994))[..1738], SYNTHETIC[..1738]);
}

/// Sizes, filter lengths and streams that no sample file has: odd and small
/// images, even-length filters, streams that stop early.
///
/// NBIS reads outside its buffers for most images under 33 pixels wide or
/// high, and for a lowpass filter of length 1; the Rust decoder rejects
/// those, so they are not compared.
#[test]
fn sizes_and_filters() {
    let square = |range: std::ops::RangeInclusive<u16>| {
        range.clone().flat_map(move |width| range.clone().map(move |height| (width, height)))
    };
    let sizes = square(1..=12)
        .chain(square(30..=50))
        .chain([(127, 95), (129, 97), (255, 33), (33, 255), (101, 3), (3, 101), (400, 401)]);
    let filters = [
        None,
        Some((7, 9)),
        Some((8, 8)),
        Some((2, 2)),
        Some((4, 4)),
        Some((6, 2)),
        Some((2, 6)),
        Some((1, 1)),
        Some((3, 5)),
        Some((10, 18)),
        Some((5, 4)),
        Some((4, 5)),
        Some((32, 31)),
        Some((31, 32)),
    ];
    let blocks = [
        Block::Generated(100),
        Block::Generated(37),
        Block::Fixture(0),
        Block::Fixture(3),
        Block::Fixture(40),
        Block::Fixture(400),
        Block::Fixture(994),
    ];
    let mut accepted = vec![0; filters.len()];

    for (width, height) in sizes {
        for (index, &filter) in filters.iter().enumerate() {
            for block in blocks {
                let name = format!("{width} × {height}, filters {filter:?}, {block:?}");
                if same(&name, &variant(width, height, filter, block)) {
                    accepted[index] += 1;
                }
            }
        }
    }

    eprintln!("accepted by the Rust decoder, per filter pair: {accepted:?}");
    for (&filter, &count) in filters.iter().zip(&accepted) {
        assert_eq!(count > 0, filter != Some((1, 1)), "filters {filter:?}: {count} accepted");
    }
}

/// The generated streams are only a test if they give varied pixels.
#[test]
fn generated_streams_decode_to_varied_images() {
    for filters in [None, Some((8, 8)), Some((31, 32))] {
        let image = wsq::decode_strict(&variant(129, 97, filters, Block::Generated(100))).unwrap();
        let mut counts = [0usize; 256];
        for &pixel in &image.data {
            counts[pixel as usize] += 1;
        }
        let distinct = counts.iter().filter(|&&count| count > 0).count();
        let clamped = counts[0] + counts[255];
        eprintln!("filters {filters:?}: {distinct} distinct values, {clamped} of {} clamped", image.data.len());
        assert!(distinct >= 16 && clamped < image.data.len() / 2, "filters {filters:?}");
    }
}
