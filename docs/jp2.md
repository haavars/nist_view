# JPEG 2000 decoder

JPEG 2000 (`JP2` and `JP2L` records, JP2 files and raw codestreams) is
decoded by the safe-Rust `hayro-jpeg2000` crate, with our own conversion of
the components to 8 bits (`native/nist_codecs/src/jp2.rs`). It replaced
OpenJPEG on 2026-09-30, which left no C parsing untrusted data anywhere in the
application. What a user needs to know when an image looks wrong is in
[formats.md](formats.md#jpeg-2000-as-decoded); this document is for changing
the decoder.

## The crate, patched

`native/hayro-jpeg2000` is a copy of version 0.4.0 (written from scratch,
`#![forbid(unsafe_code)]`, Apache-2.0 or MIT) with two fixes that no release
has. It is a path dependency, so builds need no network and the changes are
in our history. `PATCHES.md` there lists them and how to update the copy. The
fixes are not reported upstream: decided 2026-09-30, while the viewer is a
proof of concept.

- **Midpoint reconstruction.** The published crate counts the bits that were
  not transmitted as zero, which puts every coefficient at the low end of its
  quantisation interval. OpenJPEG and ffmpeg (and the standard's
  recommendation) use the midpoint. The fix stores magnitudes shifted up one
  bit with a marker below the last decoded bit. Lossless output is
  unchanged; the marker costs one of the 31 magnitude bits, so streams with
  more than 30 bit planes are refused (8-bit images use about 12).
- **Tag trees in linear time** (see [Slow inputs](#slow-inputs)).

It is built with `default-features = false`: no SIMD (which brings `unsafe`
and gained no speed) and no `std` feature (which makes the crate use fused
multiply-add on arm64 but not x86_64, the problem WSQ had). That leaves no
`unsafe`, no dependencies, and the same arithmetic on every platform.

## Accuracy

OpenJPEG is the reference (`native/opj_ref`, development only, through
`jpeg2k`). Lossless images must be identical. Two independent JPEG 2000
decoders differ in the last bit on lossy images, so there the test allows 1
per sample in at most 0.5 % of samples.

| Images | Published crate | Patched |
|---|---|---|
| Lossless (BioCTS, fixtures, generated 8, 12 and 16 bit, signed, subsampled) | identical | identical |
| 4 lossy BioCTS faces, 3300 × 4400 | 27–29 % of samples differ, by up to 5 | 0.02 % differ, by 1 |
| 30 lossy generated files | 16–57 % differ, by up to 38 | 0.02–0.07 % differ, by 1 |

ffmpeg's decoder differs from OpenJPEG by the same amount as the patched
crate. Against the original images, the published crate lost 0.6 to 2.1 dB
PSNR on a fingerprint at 5:1 to 40:1 and on a face; patched, it matches
OpenJPEG to three decimals.

The options weighed were this crate as published (the same safety, lossy
images visibly worse), this crate with the fix (chosen), or keeping OpenJPEG
in a sandbox on three operating systems.

## Differences from OpenJPEG

- Lossy images: within 1 in a fraction of a percent of samples (above).
- sYCC comes back as RGB (the crate converts). No sample has sYCC.
- Damaged files may decode partly where OpenJPEG gave an error: the crate is
  lenient.
- An image wider or higher than 60,000 pixels is refused, whatever its area.
- Region-of-interest (RGN) markers are ignored.
- Memory is about double.

## Memory

The crate works in `f32` and holds every component's coefficients and output
at once. On the largest sample, 3300 × 4400 RGB:

| What | Size | Bytes per pixel |
|---|---|---|
| Coefficients, all components | 174 MB | 12 |
| Output samples | 174 MB | 12 |
| Wavelet scratch, one component | 58 MB | 4 |
| Code-block state | 15 MB | 1 |
| **Peak** | **428 MB** | **29.5** |
| OpenJPEG, whole process | 228 MB | 15.7 |

Greyscale needs 13 bytes per pixel. A decode is refused when its estimate
passes 2 GiB (`MAX_DECODE_BYTES`): a 100-megapixel greyscale image fits, a
colour image over about 67 megapixels does not. It all happens in the helper
process and is returned when the image is done.

Not done, if real files need it: decode one component at a time (about −29 %
for colour), let the last wavelet level write into the output (about
−58 MB), or decode at the resolution shown first (`target_resolution`, a
quarter of the memory and time per level). The first two change the crate's
internals, which makes updating the copy harder.

## Slow inputs

The first fuzz run saved 18 small files (787 bytes to 39 KB) that took 1.2
to 7.8 s: long, thin images, 20,000 to 33,000 pixels wide and 96 high. The
cause was `TagNode::build`, which recursed into empty children and so visited
the whole `2^n × 2^n` square around a precinct's grid of code blocks, `n` set
by its longer side: 67 million calls for a grid 8192 wide and one high, for
about 16,000 real nodes. Thin tiles made thin grids at ordinary image shapes
too: a valid 171 KB file of 60,000 × 64 pixels in tiles 4 high took 23.5 s.

The fix returns at once for an empty node, which builds the same trees (a
test counts their nodes, and passes on the published code too). The 18
inputs now take 0.06 to 0.20 s, the 171 KB file 0.08 s, and time follows the
area as for any other image. `cargo run --release --no-default-features
--example time_jp2 -- FILE...` in `native/nist_codecs` times a file and
prints what its SIZ and COD markers declare.

## Verification

- **Differential test** (`native/opj_ref/tests/compare.rs`): the 34 JPEG 2000
  images in the BioCTS files (12 distinct; 8 lossless identical, 4 lossy
  within the limit) and 35 synthetic files, 32 of them from
  `scripts/make_jp2_fixtures.sh` in `test/fixtures/jp2` (11 reversible
  identical, 24 irreversible within the limit).
- One lossy image is pinned by hash in `test/nist_view/biocts_sample_test.exs`;
  it and the differential counts are the same on x86_64 and arm64.
- **Fuzzing:** 2.0 million inputs in 110 minutes, no crash or out-of-memory;
  coverage was still rising. The slow inputs above came from this run. A
  longer run with the fix is still to do ([fuzzing.md](fuzzing.md)).
- 30,000 mutated inputs before the change: no panic, slowest 0.04 s.
