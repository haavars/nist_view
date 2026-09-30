# Fuzzing the image decoders

`native/nist_codecs/fuzz` is a cargo-fuzz crate. The targets call the decoders
directly (the `nist_codecs` library with its `nif` feature off), and the run
script builds with AddressSanitizer. The decoders are all Rust; the only C is
the WSQ reference decoder (NBIS) in two of the targets, instrumented too, so
its memory errors are caught where they happen.

## Targets

| Target | Code under test |
|---|---|
| `wsq` | `wsq::decode` (safe Rust) |
| `wsq_diff` | `wsq::decode_strict` against NBIS (`native/nbis_ref`, C with ASan): whatever the Rust decoder accepts, NBIS must decode to the same pixels, size and PPI without a memory error. NBIS is not run on what the Rust decoder rejects |
| `nbis_wsq` | NBIS's WSQ decoder alone. Not shipped; this target reproduces and minimises the inputs that crash it (`fuzz/regressions/wsq`) |
| `jpegl` | `jpegl::decode` (safe Rust) |
| `jp2` | `jp2::decode` (the `hayro-jpeg2000` crate, safe Rust, with our own 8-bit conversion) |
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

## Overnight runs

`overnight.sh` fuzzes several targets side by side for hours and writes what
it found to disk, so it can be started in the evening and read the next day
(or in a later session).

```sh
# Once per machine: see Setup. On Linux without root:
export LLVM_PREFIX=~/anaconda3/envs/nist-llvm

mix run native/nist_codecs/fuzz/seed.exs      # only if fuzz/corpus is empty
native/nist_codecs/fuzz/overnight.sh          # 8 hours: jp2, wsq, wsq_diff, jpegl
native/nist_codecs/fuzz/overnight.sh 10 jp2   # or: hours, then targets
```

It stays in the terminal and prints one line per target every minute:

```
23:41  1:12 of 8 hours
  jp2          1654999 inputs   coverage 6513   corpus 2281   out of memory/timeout/crash 0/5/0    files saved 6
  wsq           798743 inputs   coverage 1380   corpus 492    out of memory/timeout/crash 0/0/0    files saved 0
```

- **Ctrl-C stops it**: the fuzzers are interrupted and the summary is still
  written, marked as stopped early. Closing the terminal does the same.
- `--detach` as the first argument runs it in the background instead, where
  it survives the terminal; it prints the `kill` command that stops it and
  the log to follow.
- The cores are shared out between the targets, two left free.

The run gets a directory of its own,
`native/nist_codecs/fuzz/results/<date>_<time>/` (gitignored):

| File | What |
|---|---|
| `status` | `running`, then `finished` or `stopped` |
| `summary.md` | Written when the run ends, and printed. Per target: inputs tried, coverage, corpus size, the counts of out-of-memory, timeout and crash, and the files the fuzzer saved during this run; for crashes, their kind and first decoder function |
| `<target>.log` | libFuzzer's own output |

- Saved inputs are in `fuzz/artifacts/<target>/`, as with `run.sh`. Keep
  them: they are what a later look needs.
- The corpus in `fuzz/corpus/<target>/` grows and is reused, so a second
  night continues from the first.
- Coverage still rising at the end of a run (compare the figure an hour
  apart) means a longer run would reach more code.

What to do with the result: a **crash** in a Rust decoder is a panic and a
bug to fix; minimise it with `minimise.py` and add it to
`fuzz/regressions/`. A crash in `wsq_diff` is a disagreement with NBIS or a
memory error in NBIS on input our decoder accepts, both worth a look. A
**timeout** is an input that takes long, contained in the application by the
helper's time limit; worth a look when a small file costs many seconds.

To reproduce one crash with a full report:

```sh
cd native/nist_codecs
CC=$(brew --prefix llvm)/bin/clang CFLAGS="-fsanitize=address,fuzzer-no-link" \
  cargo +nightly fuzz run wsq fuzz/artifacts/wsq/crash-<hash>
```

## Results so far

| Target | Longest run | Result |
|---|---|---|
| `wsq` | 115 min, 10 processes, 1.5 million inputs (x86_64) | No crash, timeout or out-of-memory |
| `wsq_diff` | 115 min, 12 processes, 287,000 inputs | No difference from NBIS, no memory error in NBIS |
| `jp2` | 110 min, 20 processes, 2.0 million inputs | No crash; 18 slow inputs, since fixed ([jp2.md](jp2.md#slow-inputs)) |
| `jpegl` | 10 min, 4.8 million inputs | No crash |
| `headers` | 10 min, 25 million inputs | No crash |

Earlier findings, all fixed by replacing the C: seven memory bugs in NBIS WSQ
([wsq.md](wsq.md#why-not-nbis)) and many in NBIS lossless JPEG. A temporary
differential target against NBIS lossless JPEG found one real disagreement
(NBIS ignores a scan header's declared length; we and libjpeg-turbo honour
it) and was removed with that decoder. Under the full 100-megapixel limit,
`wsq` reported a 12 KB file declaring 17 megapixels as a timeout, which led
to the lower limit under cargo-fuzz.

## Next

- Differential target against libjpeg-turbo 3.2 (decided, not written):
  build it with ASan, link it only into the fuzz crate, correct NBIS's table
  class before handing it the bytes, request no colour conversion, and
  assert identical pixels.
- Runs of hours for `jpegl`, `jp2` (with the tag-tree fix) and `headers`
  (`overnight.sh`), on arm64 too, and perhaps a scheduled CI job.
- Regression inputs for lossless JPEG in `fuzz/regressions/jpegl/`.
