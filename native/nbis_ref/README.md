# nbis_ref: the NBIS WSQ decoder as a reference

A small Rust crate around the WSQ decoder from NIST Biometric Image Software
(NBIS) release 5.0.0 (`https://nigos.nist.gov/nist/nbis/nbis_v5_0_0.zip`),
with the local patches listed below. NBIS is public domain (17 U.S.C. §105);
see the licence header in each file.

It exists to check the safe-Rust WSQ decoder against: `nbis_ref::decode_wsq`
is the reference for differential tests and fuzzing (`docs/wsq-port.md`). It
has known memory bugs and must not ship: neither `nist_codecs` nor
`nist_decode` depends on it. Its own tests (`tests/compare.rs`) depend on
`nist_codecs` to compare the two decoders.

| Here | What |
|---|---|
| `src/lib.rs` | `decode_wsq`: the FFI call, behind a mutex |
| `build.rs` | Compiles the C sources with `cc`, without fused multiply-add |
| `c/` | `fprintf` silencing and the `debug` global that NBIS expects |
| `vendor/nbis/` | The NBIS sources |

## Vendored sources

Only the files the WSQ decoder links against are included (23 files), under
`vendor/nbis/`:

| Here | NBIS path |
|---|---|
| `src/wsq/` | `imgtools/src/lib/wsq/` (decoder side only) |
| `src/jpegl/huff.c`, `huftable.c`, `tableio.c` | `imgtools/src/lib/jpegl/` (Huffman and comment helpers that WSQ shares) |
| `src/fet/` | `commonnbis/src/lib/fet/` (NISTCOM comment parsing, used to read the PPI) |
| `src/ioutil/` | `commonnbis/src/lib/ioutil/` |
| `src/util/` | `commonnbis/src/lib/util/` |
| `include/` | `commonnbis/include/`, `imgtools/include/` |

The list was found by linking a test program against `wsq_decode_mem` and
adding the source file for each missing symbol.

## Lossless JPEG is not decoded here

NBIS's lossless JPEG decoder (`jpegl/decoder.c`, `imgdat.c`, `ppi.c`,
`util.c`) was vendored for a while and removed on 2026-09-29. Fuzzing found
heap and stack buffer overflows, a use-after-free and segfaults in it within
minutes. Lossless JPEG is decoded by the safe-Rust
`nist_codecs/src/jpegl.rs` instead (see `docs/security.md`).

## Local patches

Every change is marked with a `nist_view:` comment.

| File | Change | Why |
|---|---|---|
| `src/wsq/decoder.c` `decode_data_mem`, `decode_data_file` | Stop after `MAX_HUFFBITS` bits (`-100`); check the Huffman value index against `MAX_HUFFCOUNTS_WSQ` (`-101`) | A corrupt Huffman table made the code-length loop read past the 17-entry `maxcode[]` stack array (stack buffer overflow, found by fuzzing) |
| `src/wsq/decoder.c` `wsq_decode_mem`, `wsq_decode_file` | `qdata` allocated with `calloc` | A stream with fewer coefficients than the image needs left the rest uninitialised, so the output depended on heap contents |
| `src/wsq/util.c` `wsq_reconstruct` | `fdata1` allocated with `calloc` | `join_lets` reads parts of this scratch buffer before writing them |

The two `calloc` patches change nothing for the 48 sample images (checked
2026-09-30); they make the reference deterministic on the inputs a fuzzer
produces.

## Floating point: no fused multiply-add

`build.rs` passes `-ffp-contract=off` (`/fp:precise` with MSVC). NBIS computes
in `float`, and a compiler that fuses `a * b + c` into one instruction rounds
once instead of twice. Clang does that by default where the target has FMA
(arm64), which changes 285 of 39 million pixels by 1 across the sample images.
Without contraction, gcc and clang at `-O2` and `-O3` on x86_64 give identical
pixels on all 48 images. See `docs/wsq-port.md`.

## Known unpatched bugs

Six kinds of input still crash this code after the patch above: a NULL write
in `getc_nextbits_wsq`, heap overflows in `getc_transform_table` and
`unquantize`, a global overflow in `getc_huffman_table_wsq`, a double free of
the filter arrays after a truncated transform table, and a `memcpy` of −1
bytes for a comment of length 1. There are latent ones too. Root causes are
in `docs/wsq-port.md`, and one input for each is in
`native/nist_codecs/fuzz/regressions/wsq`. They are left unpatched on
purpose: the Rust decoder replaced this code, and the reference is only given
input that the Rust decoder accepts.

## Notes for anyone changing this

- `__NBISLE__` must be defined on little-endian targets (`build.rs` does it),
  otherwise every marker reads byte-swapped.
- The decoder keeps its tables in globals (`src/wsq/globals.c`), so calls are
  serialised with a mutex (`src/lib.rs`).
- NBIS prints errors with `fprintf`; `c/quiet.h` is force-included to route
  that to a no-op in `c/glue.c`.
- `fatalerr` and `syserr` call `exit()`. The decode path reaches them only when
  `malloc` fails inside the NISTCOM helpers.
- The application used this code, in the `nist_decode` helper process, until
  the Rust decoder replaced it on 2026-09-30.
- The files were read-only in the NBIS archive; they were made writable to
  apply the patches.
