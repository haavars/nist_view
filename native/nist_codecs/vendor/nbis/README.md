# Vendored NBIS sources

The WSQ and lossless JPEG decoders from NIST Biometric Image Software (NBIS) release 5.0.0
(`https://nigos.nist.gov/nist/nbis/nbis_v5_0_0.zip`), copied without changes.
NBIS is public domain (17 U.S.C. §105); see the licence header in each file.

Only the files the two decoders link against are included:

| Here | NBIS path |
|---|---|
| `src/wsq/` | `imgtools/src/lib/wsq/` (decoder side only) |
| `src/jpegl/` | `imgtools/src/lib/jpegl/` (decoder side; WSQ also uses its Huffman and comment helpers) |
| `src/fet/` | `commonnbis/src/lib/fet/` (NISTCOM comment parsing, used to read the PPI) |
| `src/ioutil/` | `commonnbis/src/lib/ioutil/` |
| `src/util/` | `commonnbis/src/lib/util/` |
| `include/` | `commonnbis/include/`, `imgtools/include/` |

The list was found by linking test programs against `wsq_decode_mem` and
`jpegl_decode_mem` and adding the source file for each missing symbol.
`c/jpegl_glue.c` (outside this directory) turns the lossless JPEG decoder's
component planes into interleaved pixels.

Notes for anyone changing this:

- `__NBISLE__` must be defined on little-endian targets (`build.rs` does it),
  otherwise every marker reads byte-swapped.
- The WSQ decoder keeps its tables in globals (`src/wsq/globals.c`), so the
  NIF serialises WSQ calls with a mutex. The lossless JPEG decoder has none.
- `fatalerr` and `syserr` call `exit()`. The decode path reaches them only when
  `malloc` fails inside the NISTCOM helpers.
