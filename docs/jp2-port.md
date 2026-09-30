# JPEG 2000 in safe Rust — plan

Status 2026-09-30: **steps 1 to 6 and 9 done on x86_64; fuzzing running;
arm64 still open** (see [Steps](#steps)). The choice
was option A of [jp2-rust-eval.md](jp2-rust-eval.md): replace OpenJPEG with
`hayro-jpeg2000` plus the midpoint fix. Related: [security.md](security.md),
[wsq-port.md](wsq-port.md) (the same pattern, done for WSQ).

## Why

OpenJPEG is the last C that parses untrusted data. With it gone, nothing the
application ships reads a file with memory-unsafe code, on any platform, and
the sandbox for the helper becomes defence in depth instead of the main
containment.

## Design

- **A patched copy of the crate in the repository**, `native/hayro-jpeg2000`:
  version 0.4.0 as published, plus the midpoint fix. A path dependency, so
  builds need no network and the patch is visible in the history. It goes
  away when a release upstream has the fix.
  - The fix takes one of the 31 magnitude bits, so the copy refuses streams
    with more than 30 bit planes (8-bit images use about 12).
  - Built with `default-features = false`: no SIMD and no `std` feature. That
    leaves no `unsafe` and no dependencies, and no fused multiply-add, so the
    arithmetic is the same on x86_64 and arm64.
- **`nist_codecs::jp2`** decodes with it and keeps our own conversion of the
  components to 8 bits (the crate's own packing scales 16-bit samples
  differently).
- **`native/opj_ref`**, development only: OpenJPEG through `jpeg2k`, with
  the conversion the application has used so far. The reference for the
  differential test, as `nbis_ref` is for WSQ. Never a dependency of
  `nist_codecs` or `nist_decode`.
- **What "the same as OpenJPEG" means here.** Lossless images: identical.
  Lossy images: no sample off by more than 1, and few off at all: 0.02 %
  of samples on the large sample images, up to 0.2 % on the small textured
  test files, with 0.5 % as the test's limit. (WSQ could be exact because the port reproduced NBIS's
  arithmetic; here the decoder is someone else's, and two correct JPEG 2000
  decoders differ in the last bit. ffmpeg's differs from OpenJPEG by the
  same amount.)
- **The reconstruction problem is not reported upstream.** Decided
  2026-09-30: this is a proof of concept, so the fix stays in our copy.

## Behaviour that changes

- Lossy images: pixels within 1 of OpenJPEG's in a fraction of a percent of
  samples. The two hashes that were pinned are of lossless images and did
  not change; one lossy image is now pinned as well, to show that every
  platform computes the same pixels.
- sYCC images come back as RGB (the crate converts), where today the decoder
  returns sYCC and the Elixir side converts. No sample has sYCC.
- A damaged file may decode partly where OpenJPEG gave an error: the crate
  is lenient unless told otherwise.
- Memory: about double (see below).

## Memory

Measured on the largest sample, 3300 × 4400 RGB (14.5 megapixels), by
counting allocations. The crate works in `f32`, 4 bytes per sample:

| What | Size | Bytes per pixel (RGB) |
|---|---|---|
| Coefficients of all components, one allocation | 174 MB | 12 |
| Output samples, one buffer per component | 174 MB | 12 |
| Wavelet scratch, one component | 58 MB | 4 |
| Code-block state | 15 MB | 1 |
| **Peak, all held until the decoder context is dropped** | **428 MB** | **29.5** |
| OpenJPEG on the same image (whole process) | 228 MB | 15.7 |

A greyscale image needs 13 bytes per pixel (one component of each). At the
100-megapixel limit that is 1.3 GB for greyscale and 3 GB for RGB. The WSQ
decoder needs 11 bytes per pixel. All of it is in the helper process and is
returned when the image is done, in a second or two.

Plan, cheapest first:

1. **Bound it** (ours, small): refuse an image by its estimated memory
   (pixels × components × bytes), not by pixels alone, so RGB at 100
   megapixels does not take 3 GB. Drop the decoder context as soon as the
   components are converted.
2. **One component's coefficients at a time** (in the crate): decode,
   transform and release per component instead of allocating for all three.
   Peak about 305 MB for the sample (−29 %); nothing gained for greyscale.
3. **No separate wavelet scratch** (in the crate): let the last wavelet level
   write into the output buffer. About 58 MB less; with step 2, about 247 MB
   for the sample and 9 bytes per pixel for greyscale.
4. **Decode at the resolution shown** (application): the crate can stop at a
   lower resolution level (`target_resolution`), a quarter of the memory and
   time per level. The viewer would decode small first and the full image
   when the user zooms in. A change to how the viewer loads images, not to
   the decoder.

Steps 2 and 3 change the crate's internals, and every change carried in
our copy makes an upstream update harder to take. Decide after step 1
whether the numbers still hurt.

## Steps

1. ✅ (2026-09-30) Put the patched crate in `native/hayro-jpeg2000` and
   check it reproduces the evaluation results. `PATCHES.md` there lists what
   differs from the published crate and how to update it.
2. ✅ Create `native/opj_ref` from the previous `jp2.rs` and its OpenJPEG
   dependency.
3. ✅ Rewrite `nist_codecs::jp2` on the crate. A codestream on its own
   still reports three components as unspecified, as before.
4. ✅ Differential test `native/opj_ref/tests/compare.rs`:
   - the 34 JPEG 2000 images in the BioCTS files (12 distinct): the 8
     lossless ones identical, the 4 lossy ones within the limit;
   - 35 synthetic files, 32 of them made by `scripts/make_jp2_fixtures.sh`
     and committed under `test/fixtures/jp2`: all 11 reversible ones
     identical, all 24 irreversible ones within the limit.
5. ✅ Remove OpenJPEG from `nist_codecs`; `mix precommit` passes. The helper
   and the NIF now link no C of ours at all: `nist_decode`'s dependency tree
   is Rust only.
6. ✅ Memory step 1: `MAX_DECODE_BYTES`, 2 GiB by estimate. A 100-megapixel
   greyscale image fits, a colour one over about 67 megapixels is refused.
7. **Running.** Fuzz the new decoder (`jp2` target) for hours. A first two
   minutes (64,000 inputs) found nothing. A differential target against
   OpenJPEG needs a rule for damaged files, where the two may legitimately
   differ; not written.
8. A run on arm64. The pinned lossy hash in
   `test/nist_view/biocts_sample_test.exs` was computed on x86_64; if arm64
   computes different pixels, that test fails there.
9. ✅ Docs: `security.md`, `formats.md` ("JPEG 2000 as decoded"),
   `architecture.md`, `decisions.md`, `plan.md`, `fuzzing.md`.

Still open besides 7 and 8: memory steps 2 to 4, if real files need them.
