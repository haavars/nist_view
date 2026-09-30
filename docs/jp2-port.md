# JPEG 2000 in safe Rust — plan

Status 2026-09-30: **done and verified on x86_64 and arm64; not merged
yet.** A first fuzz run found no crash but a kind of slow input that has not
been looked into. What to do next is under
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
7. **Partly done.** Fuzz the new decoder (`jp2` target) for hours.
   - One run, 110 minutes with 20 processes on x86_64, stopped by hand:
     2,037,781 inputs, **no crash and no out-of-memory**. Coverage was still
     rising when it stopped (6,586, against 5,681 after two minutes), so it
     had not run out of things to find.
   - **18 slow inputs** were saved (12 `timeout`, 6 `slow-unit`), see
     [Slow inputs](#slow-inputs).
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

Still open besides 7 and 8: memory steps 2 to 4, if real files need them.

## Slow inputs

The fuzz run saved 18 inputs that took more than 10 or 20 seconds under the
fuzzer. In a normal release build they take 1.3 to 9.1 seconds, so none
reaches the helper's 60-second limit, and none uses much memory (about
100 MB for the one measured). What they have in common:

- small files, 787 bytes to 39 KB;
- three components, and **a very long and thin image**: about 20,000 to
  33,000 pixels wide and 96 or 97 high, or 131 wide and 27,745 high. That is
  2 to 4 megapixels, which normally decodes in about 0.2 seconds;
- the one examined in detail (33,411 × 97) also has its first component
  subsampled by 65 horizontally, an image offset of 256 and three tiles.

Not the cause, checked on ordinary large images (9 to 14.5 megapixels, all
about one second or less): position-based progression orders (RPCL, PCRL,
CPRL), 4 × 4 code blocks, and 4:2:0 chroma with each progression order.

Not known: which loop in the crate is slow, whether it is the shape alone or
the subsampling, and how the time grows with size. If it grows with the
pixel count, a thin image near the 100-megapixel limit would take minutes
and end in the helper's timeout, which contains it.

The files are in `native/nist_codecs/fuzz/artifacts/jp2/` on the Linux
machine (gitignored, not committed). To time one in a release build, put
this in `native/nist_codecs/examples/time_jp2.rs` and run
`cargo run --release --no-default-features --example time_jp2 -- FILE`:

```rust
fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let start = std::time::Instant::now();
    let result = nist_codecs::jp2::decode(&data);
    println!("{:?} in {:.1} s", result.map(|p| (p.width, p.height, p.channels)), start.elapsed().as_secs_f64());
}
```

## Where to continue

State on 2026-09-30, end of day. Branch `jp2-rust-eval`, pushed; `main` has
the WSQ port and nothing of this.

1. **Merge `jp2-rust-eval` into `main`** (the owner does this on GitHub).
   arm64 was verified at `65451e1`; the commits after it add documentation
   and `fuzz/overnight.sh`, no decoder code.
2. **Run the fuzzers overnight**, outside a Claude session:
   `native/nist_codecs/fuzz/overnight.sh` (see [fuzzing.md](fuzzing.md),
   "Overnight runs"). Results land in `native/nist_codecs/fuzz/results/`.
   Then read `summary.md` there; a crash in `jp2` or `wsq` is a panic to fix.
3. **Look into the slow inputs** above: find the slow loop (a profiler, or
   timing images of growing width at a fixed height), then decide between
   leaving it to the helper's timeout and a guard in `jp2.rs`, for instance
   refusing extreme aspect ratios or subsampling factors.
4. Optional, only if real files need it: memory steps 2 to 4 above.

After that, the project's open items are in [security.md](security.md#open-items)
and [plan.md](plan.md): sandbox the helper (now defence in depth), run the
Prüm samples, CI for the five desktop targets, the smaller security items,
longer fuzzing of lossless JPEG, signing.
