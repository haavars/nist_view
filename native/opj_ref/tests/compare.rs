//! The Rust JPEG 2000 decoder (`nist_codecs::jp2`, on a patched
//! hayro-jpeg2000) against OpenJPEG.
//!
//! Reversible (lossless) streams must give identical pixels. Irreversible
//! ones may differ by 1 in a few samples: two correct decoders do, because
//! they order their floating-point arithmetic differently (ffmpeg's decoder
//! differs from OpenJPEG by as much). What they may not do is differ by
//! more, or in many samples: before its midpoint fix the crate differed in
//! a quarter to a half of all samples.

use std::path::{Path, PathBuf};

/// The most an irreversible stream may differ: samples in a thousand, each
/// by 1. Measured: 0.2 per mille on the large sample images, up to 2 on the
/// small textured fixtures.
const LOSSY_SAMPLES_PER_MILLE: usize = 5;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Whether the codestream's default coding style (the COD marker of the
/// main header) selects the reversible 5/3 wavelet.
fn reversible(data: &[u8]) -> bool {
    // SOC, then SIZ: the codestream, whether or not it is inside a JP2 file.
    let start = data.windows(4).position(|w| w == [0xFF, 0x4F, 0xFF, 0x51]).expect("a codestream");
    let mut pos = start + 2;

    loop {
        let marker = [data[pos], data[pos + 1]];
        let length = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
        match marker {
            // Lcod, Scod, four bytes of SGcod, then levels, block width and
            // height, block style and the transformation.
            [0xFF, 0x52] => return data[pos + 13] == 1,
            [0xFF, 0x90] => panic!("no COD marker before the first tile"),
            _ => pos += 2 + length,
        }
    }
}

/// Compares the decoders on one image. Returns whether the pixels are
/// identical.
fn same(name: &str, data: &[u8]) -> bool {
    let rust = nist_codecs::jp2::decode(data).unwrap_or_else(|error| panic!("{name}: the Rust decoder fails with {error:?}"));
    let opj = opj_ref::decode(data).unwrap_or_else(|| panic!("{name}: OpenJPEG fails"));

    assert_eq!((rust.width, rust.height, rust.channels), (opj.width, opj.height, opj.channels), "{name}");
    let colorspace = match rust.colorspace {
        nist_codecs::ColorSpace::Gray => opj_ref::ColorSpace::Gray,
        nist_codecs::ColorSpace::Srgb => opj_ref::ColorSpace::Srgb,
        nist_codecs::ColorSpace::Sycc => opj_ref::ColorSpace::Sycc,
        nist_codecs::ColorSpace::Unspecified => opj_ref::ColorSpace::Unspecified,
    };
    assert_eq!(colorspace, opj.colorspace, "{name}");
    assert_eq!(rust.data.len(), opj.pixels.len(), "{name}");

    let differences = rust.data.iter().zip(&opj.pixels).filter(|(a, b)| a != b);
    let differing = differences.clone().count();
    let largest = differences.map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
    let summary = format!("{name}: {differing} of {} samples differ, by up to {largest}", opj.pixels.len());

    if reversible(data) {
        assert_eq!(differing, 0, "{summary} (reversible)");
    } else {
        assert!(largest <= 1 && differing * 1000 <= opj.pixels.len() * LOSSY_SAMPLES_PER_MILLE, "{summary}");
    }
    differing == 0
}

fn files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|error| panic!("{}: {error}", dir.display()))
        .map(|entry| entry.unwrap().path())
        .collect();
    files.sort();
    files
}

/// The synthetic files: three lossless ones, and those made by
/// scripts/make_jp2_fixtures.sh, which cover lossy coding, other bit
/// depths, signed and subsampled components, tiles, progression orders and
/// code-block styles.
#[test]
fn fixtures() {
    let fixtures = repo().join("test/fixtures");
    let mut paths = files(&fixtures.join("jp2"));
    paths.extend(["synthetic_grey.jp2", "synthetic_grey16.jp2", "synthetic_rgb.j2k"].map(|name| fixtures.join(name)));

    let (mut lossless, mut lossy, mut identical) = (0, 0, 0);
    for path in &paths {
        let data = std::fs::read(path).unwrap();
        let name = path.file_name().unwrap().to_string_lossy();

        if reversible(&data) { lossless += 1 } else { lossy += 1 }
        identical += same(&name, &data) as usize;
    }

    eprintln!("{lossless} reversible and {lossy} irreversible files; {identical} identical to OpenJPEG");
    assert_eq!((lossless, lossy), (11, 24));
}

/// The end of the JP2 file that starts at `start`: the end of its
/// codestream box. Boxes are a length, a type and content.
fn jp2_end(data: &[u8], start: usize) -> usize {
    let mut pos = start;

    while let Some(header) = data.get(pos..pos + 8) {
        let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;

        if &header[4..] == b"jp2c" && length == 0 {
            // The box runs "to the end of the file", which here is the rest
            // of the transaction. The codestream ends with EOC (FFD9), and
            // after its first tile starts (SOT, FF90) no FF9x or above can
            // occur in it except markers.
            let find = |from: usize, marker: [u8; 2]| data[from..].windows(2).position(|w| w == marker).map(|at| from + at);
            let tile = find(pos, [0xFF, 0x90]).unwrap_or(data.len());
            return find(tile, [0xFF, 0xD9]).map_or(data.len(), |eoc| eoc + 2);
        }
        if length < 8 || pos + length > data.len() {
            return data.len();
        }
        if &header[4..] == b"jp2c" {
            return pos + length;
        }
        pos += length;
    }

    data.len()
}

/// Every JPEG 2000 image in the BioCTS sample transactions
/// (`mix nist.samples`), found by the JP2 signature box.
#[test]
fn biocts_samples() {
    const SIGNATURE: &[u8] = b"\x00\x00\x00\x0C\x6A\x50\x20\x20\x0D\x0A\x87\x0A";

    let dir = repo().join("test/samples/biocts");
    if !dir.is_dir() {
        eprintln!("skipped: no samples in {}", dir.display());
        return;
    }

    let (mut images, mut seen, mut identical) = (0, std::collections::HashSet::new(), 0);
    for file in files(&dir).iter().filter(|file| file.extension().is_some_and(|ext| ext == "an2")) {
        let data = std::fs::read(file).unwrap();
        let name = file.file_name().unwrap().to_string_lossy();

        for start in 0..data.len().saturating_sub(SIGNATURE.len()) {
            if !data[start..].starts_with(SIGNATURE) {
                continue;
            }
            images += 1;

            // Many transactions carry the same images.
            let image = &data[start..jp2_end(&data, start)];
            if seen.insert(image.to_vec()) {
                identical += same(&format!("{name} at {start}"), image) as usize;
            }
        }
    }

    // The set is fixed: 34 images, 12 of them distinct, 8 of those lossless.
    eprintln!("{images} images, {} distinct, {identical} identical to OpenJPEG", seen.len());
    assert_eq!((images, seen.len(), identical), (34, 12, 8));
}
