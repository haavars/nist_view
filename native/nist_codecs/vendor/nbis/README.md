# Vendored NBIS sources

The WSQ decoder from NIST Biometric Image Software (NBIS) release 5.0.0
(`https://nigos.nist.gov/nist/nbis/nbis_v5_0_0.zip`), copied without changes.
NBIS is public domain (17 U.S.C. §105); see the licence header in each file.

Only the files the WSQ decoder links against are included:

| Here | NBIS path |
|---|---|
| `src/wsq/` | `imgtools/src/lib/wsq/` (decoder side only) |
| `src/jpegl/huff.c`, `huftable.c`, `tableio.c` | `imgtools/src/lib/jpegl/` (shared Huffman and comment helpers) |
| `src/fet/` | `commonnbis/src/lib/fet/` (NISTCOM comment parsing, used to read the PPI) |
| `src/ioutil/` | `commonnbis/src/lib/ioutil/` |
| `src/util/` | `commonnbis/src/lib/util/` |
| `include/` | `commonnbis/include/`, `imgtools/include/` |

The list was found by linking a test program against `wsq_decode_mem` and
adding the source file for each missing symbol.

Notes for anyone changing this:

- `__NBISLE__` must be defined on little-endian targets (`build.rs` does it),
  otherwise every marker reads byte-swapped.
- The decoder keeps its tables in globals (`src/wsq/globals.c`), so the NIF
  serialises calls with a mutex.
- `fatalerr` and `syserr` call `exit()`. The decode path reaches them only when
  `malloc` fails inside the NISTCOM helpers.
