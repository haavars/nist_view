# JPEG 2000 in safe Rust: evaluation of `hayro-jpeg2000`

Status 2026-09-30: **evaluated, not adopted.** No code in the application has
changed. This is the evidence for the choice described in
[security.md](security.md#open-items): replace OpenJPEG, the last C that
parses untrusted data, or sandbox the helper.

## Result in short

- **Lossless images: identical to OpenJPEG** in every test, including 12 and
  16 bit, signed and subsampled ones.
- **Lossy images: the published crate is less accurate** than OpenJPEG. It
  reconstructs every quantised coefficient at the low end of its interval
  instead of the middle. That costs 0.6 to 2.1 dB on a fingerprint and
  changes pixels by up to 44 grey levels.
- **A patch of about 40 lines fixes it** ([jp2-rust-eval.patch](jp2-rust-eval.patch)).
  With it, lossy output differs from OpenJPEG in at most 0.07 % of samples,
  by 1, which is also how much ffmpeg's independent decoder differs.
- Speed equals OpenJPEG; memory is about double; 30,000 corrupted inputs gave
  no panic.

So it is usable, but only with the fix, which does not exist upstream yet.

## What was tested

`hayro-jpeg2000` 0.4.0 (Apache-2.0 or MIT, about 9,600 lines, written from
scratch, `#![forbid(unsafe_code)]`), built with `default-features = false`:
no SIMD, no `std` feature, and then no dependencies at all. OpenJPEG is the
one the application uses today (`jpeg2k` 0.10 with `openjpeg-sys`), through
`nist_codecs::jp2::decode`. Both outputs went through the same 8-bit
conversion as today (`jp2.rs`): hayro's own `data_u8` scales 16-bit samples
differently, so its components were used instead. x86_64 Linux, Rust 1.98.1.

| Set | Files |
|---|---|
| BioCTS | The 12 distinct JPEG 2000 images in the sample transactions: 8 lossless (greyscale prints and one RGB face), 4 lossy RGB faces of 3300 × 4400 |
| Fixtures | The 3 synthetic ones in `test/fixtures` |
| Generated | 42 files made with `opj_compress` 2.5 from crops of two BioCTS images: lossless and lossy; 8, 12 and 16 bit; signed; chroma subsampled 2 × 2; 2 and 8 resolution levels; code blocks of 16 × 16 and 64 × 4; precincts; tiles, tile parts and image offsets; all five progression orders; every code-block style; SOP and EPH markers; a region of interest; several quality layers |
| With a known original | Two lossless BioCTS images (a face, a fingerprint) compressed at four ratios, to measure each decoder against the original |

## Pixels

| Files | Published 0.4.0 against OpenJPEG | With the patch |
|---|---|---|
| 8 lossless BioCTS, 3 fixtures | identical | identical |
| 4 lossy BioCTS faces | 27 to 29 % of samples differ, by up to 5 | 0.02 % differ, by 1 |
| 12 lossless generated | identical | identical |
| 30 lossy generated | 16 to 57 % differ, by up to 38 | 0.02 to 0.07 % differ, by 1 |

Which decoder is right was settled with a third one and with originals:

- ffmpeg's own JPEG 2000 decoder agrees with OpenJPEG to within 0.02 to
  0.06 % of samples, by 1. The published hayro is the outlier.
- Against the original image (PSNR in dB; OpenJPEG and ffmpeg give the same
  to three decimals):

  | Image | Ratio | OpenJPEG | hayro 0.4.0 | hayro patched |
  |---|---|---|---|---|
  | Fingerprint, 2924 × 3146 grey | 5:1 | 46.67 | 44.55 | 46.67 |
  | | 10:1 | 40.14 | 38.44 | 40.14 |
  | | 20:1 | 34.45 | 33.03 | 34.45 |
  | | 40:1 | 30.75 | 30.20 | 30.75 |
  | Face, 3300 × 4400 RGB | about 24:1 | 54.34 | 53.66 | 54.34 |
  | | 40:1 | 52.35 | 51.50 | 52.35 |

## The cause, and the patch

In `src/j2c/decode.rs` the crate computes a coefficient as the decoded
magnitude times the quantiser step. The bits that were not transmitted count
as zero. OpenJPEG (and the standard's recommendation) adds half of the last
decoded bit, the midpoint of what is unknown.

The patch stores magnitudes shifted up by one bit with a marker below the
last decoded bit, moves the marker on every refinement bit (zero bits too,
which the crate skipped), and halves the value when it is converted. For
reversible (lossless) coding the half is dropped again, so lossless output
does not change.

It is evaluation quality. It takes one of the 31 magnitude bits, so a stream
with 31 bit planes would overflow into the sign; a real fix has to reject or
widen that. It has been run on the files above and nothing else.

## Other measurements

| | OpenJPEG | hayro (patched, no SIMD) |
|---|---|---|
| Speed, 15 BioCTS and fixture files, 100.8 megapixels | 14.9 megapixels per second | 14.7 |
| Peak memory, 3300 × 4400 RGB | 228 MB | 425 MB |
| 30,000 mutated inputs (truncations and changed bytes, 43 seed files) | not run | 18,227 decoded, 11,773 errors, 0 panics, slowest 0.04 s |

- **The `simd` feature** (on by default in the crate, brings in
  `fearless_simd` and its `unsafe`) made no difference to speed here, and
  changes a few lossy pixels. Leave it off.
- **The `std` feature** makes the crate use fused multiply-add where the
  target has it, which is always on arm64 and not on a default x86_64
  build. That is the WSQ problem again: lossy output would differ between
  the two machines. Without `std` it computes `a * b + c` everywhere. Leave
  it off, and check on arm64 before relying on it.
- **Signed samples:** the crate ignores the flag. The signed test files
  still came out identical to OpenJPEG, which shifts them, so the results
  agree.
- **sYCC** is converted to RGB inside the crate. Today the decoder returns
  sYCC and the Elixir side converts. No sample has sYCC, so this path is
  untested either way.
- **Non-strict by default:** it decodes what it can of a damaged file
  (18,227 of the 30,000 mutated inputs gave an image). OpenJPEG was not run
  on those, so how the two differ on damaged files is not known.

## Not tested

- arm64.
- Fuzzing proper (coverage-guided, hours), and a differential fuzz target
  against OpenJPEG.
- CMYK, palettes, ICC profiles, sYCC, more than three components. The
  application refuses CMYK and e-sYCC today.
- Images over 14.5 megapixels. At 100 megapixels RGB the memory would be
  around 3 GB.

## The choice

| Option | What it takes | What you get |
|---|---|---|
| A. Adopt hayro with the midpoint fix | Get the fix upstream (an issue or a pull request to `LaurenzV/hayro`), or carry a patched copy until it is. Then the WSQ pattern: swap the decoder, keep OpenJPEG as a development-only reference, a differential test, fuzzing, a run on arm64 | No C parses untrusted data on any platform. Lossless identical to today, lossy within 1 of today in under 0.1 % of samples. Double the memory |
| B. Adopt hayro as published | The swap only | The same safety, but lossy prints and faces lose 0.6 to 2.1 dB against today |
| C. Keep OpenJPEG and sandbox the helper | Three sandboxes (macOS, Linux, Windows), each tested on its system | Today's pixels exactly. C still parses the file, contained |

## Reproducing

The work was done in a scratch crate outside the repository, depending on
`nist_codecs` (for OpenJPEG) and `hayro-jpeg2000`, with
`[patch.crates-io]` pointing at a copy of the crate with
[jp2-rust-eval.patch](jp2-rust-eval.patch) applied (`patch -p1` in the
crate's directory). The generated files came from `opj_compress` with
options such as `-I -r 10`, `-t 200,150`, `-p RPCL`, `-M 63`,
`-F 640,480,3,8,u@1x1:2x2:2x2`; the third decoder was
`ffmpeg -c:v jpeg2000`.
