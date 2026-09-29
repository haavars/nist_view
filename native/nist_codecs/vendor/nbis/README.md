# Vendored NBIS sources

The WSQ decoder from NIST Biometric Image Software (NBIS) release 5.0.0
(`https://nigos.nist.gov/nist/nbis/nbis_v5_0_0.zip`), with the local patches
listed below. NBIS is public domain (17 U.S.C. §105); see the licence header
in each file.

Only the files the WSQ decoder links against are included (23 files):

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
minutes. Lossless JPEG is decoded by the safe-Rust `src/jpegl.rs` instead (see
`docs/security.md`).

## Local patches

Every change is marked with a `nist_view:` comment.

| File | Change | Why |
|---|---|---|
| `src/wsq/decoder.c` `decode_data_mem`, `decode_data_file` | Stop after `MAX_HUFFBITS` bits (`-100`); check the Huffman value index against `MAX_HUFFCOUNTS_WSQ` (`-101`) | A corrupt Huffman table made the code-length loop read past the 17-entry `maxcode[]` stack array (stack buffer overflow, found by fuzzing) |

## Notes for anyone changing this

- `__NBISLE__` must be defined on little-endian targets (`build.rs` does it),
  otherwise every marker reads byte-swapped.
- The decoder keeps its tables in globals (`src/wsq/globals.c`), so calls are
  serialised with a mutex.
- NBIS prints errors with `fprintf`; `c/quiet.h` is force-included to route
  that to a no-op in `c/glue.c`.
- `fatalerr` and `syserr` call `exit()`. The decode path reaches them only when
  `malloc` fails inside the NISTCOM helpers.
- This code runs only in the `nist_decode` helper process, never in the BEAM.
- The files were read-only in the NBIS archive; they were made writable to
  apply the patches.
