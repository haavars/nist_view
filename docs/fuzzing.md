# Fuzzing the image decoders

`native/nist_codecs/fuzz` is a cargo-fuzz crate. The targets call the decoders
directly (the `nist_codecs` library with its `nif` feature off), and the run
script instruments the C code (OpenJPEG) with AddressSanitizer too, so
memory errors in C are caught where they happen, not only when they crash.

## Targets

| Target | Code under test |
|---|---|
| `wsq` | `wsq::decode` (safe Rust) |
| `wsq_diff` | `wsq::decode_strict` against NBIS (`native/nbis_ref`, C with ASan): whatever the Rust decoder accepts, NBIS must decode to the same pixels, size and PPI without a memory error. NBIS is not run on what the Rust decoder rejects |
| `nbis_wsq` | NBIS's WSQ decoder alone. Not shipped; this target reproduces and minimises the inputs that crash it (`fuzz/regressions/wsq`) |
| `jpegl` | `jpegl::decode` (safe Rust) |
| `jp2` | `jp2::decode` (OpenJPEG C via `jpeg2k`, own 8-bit conversion) |
| `headers` | `headers::{jpeg, jp2}` (Rust header readers) |

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
native/nist_codecs/fuzz/replay.sh           # WSQ: inputs NBIS decodes but Rust rejects
native/nist_codecs/fuzz/minimise.py nbis_wsq crash-<hash> out.wsq   # shrink, same crash
```

- `seed.exs` extracts every embedded image (up to 256 KB) from
  `test/fixtures` and `test/samples` by detected format, plus the synthetic
  image fixtures. Corpora are gitignored: most seeds are real prints.
- `run.sh` sets `CC` to Homebrew clang and
  `CFLAGS=-fsanitize=address,fuzzer-no-link`, and runs libFuzzer in fork mode
  with `-ignore_crashes=1`, so one run collects every distinct crash in
  `fuzz/artifacts/<target>/` instead of stopping at the first.
- Under cargo-fuzz (`cfg(fuzzing)`) the size limit is 4 megapixels instead
  of 100 (`MAX_PIXELS`). A WSQ or JPEG 2000 file of a few hundred bytes can
  declare a huge image, and decoding it takes seconds; with the full limit
  the fuzzer spends its time there and reports timeouts.
- `triage.sh` replays up to N artifacts and prints one line per distinct
  AddressSanitizer summary and first non-runtime stack frame.
- `wsq_diff` and `nbis_wsq` start from the `wsq` corpus.
- `replay.sh` covers the direction `wsq_diff` cannot: it gives every file in
  the WSQ corpora and artifacts to the Rust decoder, and each one that is
  rejected to an ASan build of NBIS in a process of its own. It lists the
  files that NBIS decodes without a memory error. Every such file is either
  a documented difference (a filter longer than 32 taps) or a bug in the
  Rust decoder.
- `minimise.py` shrinks a crashing input while the AddressSanitizer error
  and the decoder function it is in stay the same, then zeroes every byte
  the crash does not need. `cargo fuzz tmin` is no use for NBIS: it accepts
  any crash, and every input ends up as the same six bytes (a comment of
  length 0, which makes `calloc` fail under ASan).

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
NBIS WSQ was replaced by a safe-Rust decoder on 2026-09-30; the `wsq` target
fuzzes that decoder from then on.

## Results for the Rust WSQ decoder (2026-09-30, 115 minutes per target)

x86_64 Linux, clang 23.1, both targets running side by side.

| Target | Processes | Inputs | Result |
|---|---|---|---|
| `wsq` | 10 | 1,504,967 | no crash, timeout or out-of-memory |
| `wsq_diff` | 12 | 287,115 | no difference from NBIS, no memory error in NBIS |

`replay.sh` afterwards, over 1,141 corpus and crash files: nothing that NBIS
decodes cleanly and the Rust decoder rejects. It did show a sixth NBIS bug, a
`memcpy` of −1 bytes for a comment of length 1.

An earlier ten-minute run, with the full 100-megapixel limit, reported one
timeout: a 12 KB file declaring 17 megapixels. That led to the lower limit
under cargo-fuzz described above.

A temporary differential target compared the Rust lossless JPEG decoder with
NBIS: wherever NBIS decoded an image, ours had to produce the same pixels.
Apart from NBIS's own memory errors, it found one disagreement: NBIS ignores
a scan header's declared length, which our decoder (and libjpeg-turbo)
honour. The target was removed with the NBIS decoder.

## Next

- Differential target against libjpeg-turbo 3.2 (decided; not written yet):
  build libjpeg-turbo with ASan, link it only into the fuzz crate, correct
  NBIS's table class before handing it the bytes, request no colour
  conversion, and assert identical pixels.
- Longer runs (hours per target) for `jpegl`, `jp2` and `headers`, and a
  scheduled CI job. The WSQ targets have not been run on arm64.
- Regression inputs for lossless JPEG in `fuzz/regressions/jpegl/` (WSQ has
  them); see [`security.md`](security.md#open-items).
