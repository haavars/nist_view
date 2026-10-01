# JPEG 2000 in safe Rust — plan

Status 2026-09-30: **done, verified on x86_64 and arm64, and merged into
`main`** (pull request #2). A first fuzz run found no crash; the slow inputs
it found came from a quadratic loop in the crate, now fixed in our copy
([Slow inputs](#slow-inputs)). What is left is under
[Where to continue](#where-to-continue). The choice
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
  version 0.4.0 as published, plus the midpoint fix and, since the fuzz run,
  a fix for slow tag trees ([Slow inputs](#slow-inputs)). A path
  dependency, so builds need no network and the patches are visible in the
  history. It goes away when a release upstream has both fixes.
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
- An image wider or higher than 60,000 pixels is refused by the crate,
  whatever its area. OpenJPEG decoded it if it was within 100 megapixels.
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
7. ✅ Fuzz the new decoder (`jp2` target).
   - One run, 110 minutes with 20 processes on x86_64, stopped by hand:
     2,037,781 inputs, **no crash and no out-of-memory**. Coverage was still
     rising when it stopped (6,586, against 5,681 after two minutes), so it
     had not run out of things to find.
   - **18 slow inputs** were saved (12 `timeout`, 6 `slow-unit`). Cause
     found and fixed in our copy of the crate, see
     [Slow inputs](#slow-inputs).
   - A longer run is not needed (2026-10-01): the viewer runs airgapped on known
     data, and the 18 slow inputs take about a second each with the fix.
   - A differential target against OpenJPEG needs a rule for damaged files,
     where the two may legitimately differ; not written.
8. ✅ (2026-09-30) A run on arm64 (macOS 27.0.1, Apple clang 21.0.0), at
   commit `65451e1`: `mix precommit` passes; the lossy image pinned in
   `test/nist_view/biocts_sample_test.exs`, whose hash was computed on
   x86_64, gives the same hash; the differential test gives the same counts
   (11 + 8 identical, all 24 + 4 irreversible ones within the limit). So the
   decoder computes the same pixels on both architectures.
9. ✅ Docs: `security.md`, `formats.md` ("JPEG 2000 as decoded"),
   `architecture.md`, `decisions.md`, `plan.md`, `fuzzing.md`.

Still open besides 7: memory steps 2 to 4, if real files need them.

## Slow inputs

Solved 2026-09-30. The fuzz run saved 18 inputs that took more than 10 or
20 seconds under the fuzzer and 1.2 to 7.8 seconds in a release build. All
are small files (787 bytes to 39 KB) declaring **a long, thin image** of 2 to
4 megapixels, 20,000 to 33,000 pixels wide and 96 or 97 high, or 131 wide
and 27,745 high. Most have 4 × 4 code blocks.

**Cause: building tag trees took time in the square of the longer side.**
Each precinct has two tag trees over its grid of code blocks. The crate
built a tree recursively and went into all four children of a node even
when a child was empty, so it visited the whole `2^n × 2^n` square around
the grid, `n` set by the longer side. A precinct 8192 code blocks wide and
one high (the widest a precinct gets with 4 × 4 blocks) took 4^13 = 67
million calls per tree, for about 16,000 real nodes. Sampling the stacks
(gdb; `perf` is not allowed on the Linux machine) put 94 to 98 % of the time
in `TagNode::build` for each input checked.

It did not depend on subsampling, progression order or file size; only on
the shape of each precinct's grid of code blocks. Thin tiles make thin
grids, and multiply them, whatever the shape of the image: a square
4096 × 4096 greyscale image in tiles 4 high took 11.8 seconds, and a valid
171 KB file, 60,000 × 64 greyscale in 16 tiles 4 high, took 23.5 seconds; in
colour it would have reached the helper's 60-second timeout. The crate's
limit of 60,000 pixels a side bounds a single tree, but not the number of
trees.

**Fix, in our copy of the crate** (`native/hayro-jpeg2000/PATCHES.md`):
`TagNode::build` returns at once for an empty node. No empty node or any of
its descendants was ever kept, so the trees are the same. A new test
checks this by counting the nodes of trees of several shapes, and passes on
the published code too; a second builds a tree 2^20 code blocks wide and
one high, which the published code would take hours over. The differential
test against OpenJPEG gives the same counts as before.

| | Before | After |
|---|---|---|
| The 18 fuzz inputs | 1.2 to 7.8 s | 0.06 to 0.20 s |
| 60,000 × 64 grey, 16 tiles 4 high (171 KB) | 23.5 s | 0.08 s |
| 4096 × 4096 grey, 1024 tiles 4 high (778 KB) | 11.8 s | 0.34 s |
| 32,768 × 96 grey, 4 × 4 code blocks | 1.13 s | 0.38 s |
| 1,774 × 1,774 grey, the same area, for comparison | 0.42 s | 0.40 s |

Time now follows the area, as for any other image. No guard in `jp2.rs`
(aspect ratio, subsampling) is needed.

To time a file in a release build, with what its SIZ and COD markers
declare:
`cargo run --release --no-default-features --example time_jp2 -- FILE...`
in `native/nist_codecs`. The 18 inputs are in
`native/nist_codecs/fuzz/artifacts/jp2/` on the Linux machine (gitignored).

## Where to continue

State on 2026-09-30, evening. `jp2-rust-eval` is merged into `main`
(pull request #2), and the tag-tree fix too (branch `jp2-slow-inputs`,
merged locally).

1. ✅ Merge `jp2-rust-eval` into `main`.
2. ✅ The slow inputs: found and fixed, see above. The fix changes no
   pixels (the differential test is unchanged), so a new arm64 run is not
   needed.
3. ✅ Fuzzing: the two-hour run is enough, see step 7 above.
4. Optional, only if real files need it: memory steps 2 to 4 above.

After that, the project's open items are in [security.md](security.md#open-items)
and [plan.md](plan.md): sandbox the helper (now defence in depth), run the
Prüm samples, CI for the five desktop targets, the smaller security items,
signing.
