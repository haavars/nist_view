# Fuzzing the image decoders

`native/nist_codecs/fuzz` is a cargo-fuzz crate. The targets call the decoders
directly (the `nist_codecs` library with its `nif` feature off), and the run
script instruments the C code (NBIS, OpenJPEG) with AddressSanitizer too, so
memory errors in C are caught where they happen, not only when they crash.

## Targets

| Target | Code under test |
|---|---|
| `wsq` | `nbis::decode_wsq` (NBIS C, patched, from `native/nbis_ref`) |
| `jpegl` | `jpegl::decode` (safe Rust) |
| `jp2` | `jp2::decode` (OpenJPEG C via `jpeg2k`, own 8-bit conversion) |
| `headers` | `headers::{wsq, jpeg, jp2}` (Rust header readers) |

## Setup (once)

```sh
rustup toolchain install nightly --profile minimal
cargo +nightly install cargo-fuzz --locked
brew install llvm                 # macOS: a clang with libFuzzer and ASan
```

On Linux, any clang with compiler-rt works, from the distribution or, without
root, from conda-forge. Its LLVM version should match nightly Rust's
(`rustc +nightly -vV`). Point the scripts at it with `LLVM_PREFIX`:

```sh
conda create -n nist-llvm -c conda-forge clang=23.1.1 compiler-rt=23.1.1 llvm-tools=23.1.1
export LLVM_PREFIX=~/anaconda3/envs/nist-llvm
```

## Running

```sh
mix run native/nist_codecs/fuzz/seed.exs   # seed corpora from fixtures and samples
native/nist_codecs/fuzz/run.sh wsq 600      # target, seconds (FORKS=2 by default)
native/nist_codecs/fuzz/triage.sh wsq       # group crashes by ASan summary and frame
```

- `seed.exs` extracts every embedded image (up to 256 KB) from
  `test/fixtures` and `test/samples` by detected format, plus the synthetic
  image fixtures. Corpora are gitignored: most seeds are real prints.
- `run.sh` sets `CC` to Homebrew clang and
  `CFLAGS=-fsanitize=address,fuzzer-no-link`, and runs libFuzzer in fork mode
  with `-ignore_crashes=1`, so one run collects every distinct crash in
  `fuzz/artifacts/<target>/` instead of stopping at the first.
- `triage.sh` replays up to N artifacts and prints one line per distinct
  AddressSanitizer summary and first non-runtime stack frame.

To reproduce one crash with a full report:

```sh
cd native/nist_codecs
CC=$(brew --prefix llvm)/bin/clang CFLAGS="-fsanitize=address,fuzzer-no-link" \
  cargo +nightly fuzz run wsq fuzz/artifacts/wsq/crash-<hash>
```

## Results (2026-09-29, 10 minutes per target)

See [`security.md`](security.md#fuzzing-results). In short: NBIS WSQ had one
stack overflow (patched), and, correcting an earlier claim, four more bugs
still crash the patched build (see [`wsq-port.md`](wsq-port.md)); NBIS lossless JPEG had many bugs
and was replaced; the Rust decoders, header readers and OpenJPEG had none.

A temporary differential target compared the Rust lossless JPEG decoder with
NBIS: wherever NBIS decoded an image, ours had to produce the same pixels.
Apart from NBIS's own memory errors, it found one disagreement: NBIS ignores
a scan header's declared length, which our decoder (and libjpeg-turbo)
honour. The target was removed with the NBIS decoder.

## Next

- Replace NBIS WSQ with a safe-Rust decoder and a `wsq_diff` differential
  target against NBIS (plan in [`wsq-port.md`](wsq-port.md)).
- Differential target against libjpeg-turbo 3.2 (decided; not written yet):
  build libjpeg-turbo with ASan, link it only into the fuzz crate, correct
  NBIS's table class before handing it the bytes, request no colour
  conversion, and assert identical pixels.
- Longer runs (hours per target) and a scheduled CI job.
- Minimised regression inputs in `fuzz/regressions/<format>/` (run by
  `NistView.DecoderTest`); see [`security.md`](security.md#open-items).
