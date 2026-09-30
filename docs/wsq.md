# WSQ decoder

WSQ (FBI IAFIS-IC-0110 v3.1) is decoded by our own safe-Rust decoder,
`native/nist_codecs/src/wsq.rs` (about 2,000 lines, no `unsafe`, no
dependencies). It replaced NBIS 5.0.0 on 2026-09-30. For every input that
NBIS decodes without touching memory outside its buffers, it gives the same
pixels and resolution as NBIS built without fused multiply-add. What a user
needs to know when a file does not decode is in
[formats.md](formats.md#wsq-as-decoded); this document is for changing the
decoder.

## Why not NBIS

Fuzzing found seven memory bugs in NBIS's WSQ decoder that a file can reach.
One was patched in M5; the others were still there. WSQ is the format of the
real Prüm traffic, so it is the most exposed decoder.

| Crash | Cause (in `native/nbis_ref/vendor/nbis/src/`) |
|---|---|
| Stack overflow in `huffman_decode_data_mem` (patched) | The code-length loop runs past the 17-entry `maxcode[]` on a corrupt Huffman table |
| NULL write in `getc_nextbits_wsq` | A read that spans a byte boundary recurses with `marker = NULL`; `FF xx` with exactly one bit still needed writes through it |
| Heap overflow in `getc_transform_table` | A filter length of 0: an `unsigned char` wraps to 255 and 256 coefficients go into a zero-length `calloc` |
| Global overflow in `getc_huffman_table_wsq` | The table id is not checked against 8; the block header's table selector likewise |
| Double free in `free_wsq_decoder_resources` | Error paths of `getc_transform_table` free the filters without clearing the pointers |
| Negative size in `getc_bytes` | A comment of length 1 asks `memcpy` for −1 bytes |
| Out of bounds in `unquantize`, `join_lets` | Reads and writes follow the subband tree and coefficient stream without bounds; subband positions are `short` and wrap above 32,767 |

Found by reading, not hit by the fuzzer: a 257-value Huffman table overflows
`build_huffsizes`; `huffman_decode_data_mem` writes one `short` past `qdata`
when the stream is exactly full; `string2fet` copies `NIST_COM` tokens into
512-byte stack buffers unchecked; `qdata` and the reconstruction scratch are
read before being written for some inputs.

The six unpatched bugs each have a regression input in
`native/nist_codecs/fuzz/regressions/wsq/`, which `NistView.DecoderTest`
decodes and expects to fail.

## The reference: NBIS without fused multiply-add

NBIS computes in `float`. A compiler that fuses `a * b + c` rounds once
instead of twice, which clang does by default on arm64. Over the 48 distinct
sample images (47 from BioCTS plus `test/fixtures/synthetic.wsq`):

- Fused and unfused NBIS differ on 46 images, in 285 of 39 million pixels,
  always by 1. Both are within the specification's tolerance (99.9 % of
  pixels equal, none off by more than 1).
- Without contraction, gcc and clang at `-O2` and `-O3`, on x86_64 and
  arm64, give identical pixels.

So the reference is NBIS built with `-ffp-contract=off` (`native/nbis_ref`,
development only), and the Rust decoder never uses `mul_add`. It gives the
same pixels on every platform. To compare builds of NBIS yourself:
`scripts/extract_wsq.exs` extracts the sample images and `scripts/dwsq_min.c`
is a minimal driver (build commands in its header).

## NBIS behaviour reproduced

Files in circulation are made for NBIS-derived decoders, so the decoder
follows NBIS rather than a stricter reading of the specification. The parts
that look odd are deliberate:

- **Segment lengths are ignored** for the frame header, transform and
  quantisation tables and block headers; they are read field by field. But
  NBIS finds the resolution with a separate scan that skips segments by
  length up to the first block, and fails the decode if that scan fails. So
  the lengths must be right up to the first SOB after all (`nistcom_ppi`).
- **Resolution:** the first COM before the first SOB whose text starts with
  `NIST_COM`, tokenised as `string2fet` does (a name ends at space, tab or
  NUL; a value at newline or NUL); the last `PPI` entry wins if it is a
  positive `int`.
- **Scaled values** are `u16` (or `u32`) divided by 10 once per exponent
  step, in `f64`, rounded to `f32` at each step.
- **Transform table:** the first length byte is the highpass length. The
  synthesis filters are built by mirroring with sign rules that differ for
  odd and even lengths (`Transform::read` in `wsq.rs`).
- **Huffman tables:** ids 0 to 7. The first table in a DHT segment may
  redefine an existing id, later tables in the same segment may not. Tables
  persist between blocks and each block rebuilds its decoding table from the
  one it selects.
- **Bit reader:** a block start drops any partial byte. `FF 00` is a stuffed
  `FF`. `FF xx` is a marker only where a new code starts; anywhere else it
  is an error.
- **Coefficient stream:** NBIS checks the limit before storing, so it
  accepts one coefficient more than the transmitted subbands hold; we do the
  same and fail only when a store would leave the buffer. A short stream
  leaves zeros (NBIS leaves uninitialised memory). Comments may follow the
  third block.
- **Subband trees** are ported literally, including the call order
  (`q_tree16` at 3, 19, 48, 35, then `q_tree4` at 0, which overwrites
  subband 3).
- **Wavelet synthesis (`join_lets`)** walks the whole image buffer with
  NBIS's offsets, which reach outside the subband being joined even for
  valid images, with a bounds check on every access. The scratch writes
  start at offset 0 of the scratch buffer. The order of operations is kept:
  `(hpx · hi) · sfac`, then the add.
- **Pixels:** `t = img · r_scale + m_shift` in `f32`, then
  `((t as f64) + 0.5) as f32`, clamped to 0–255 and truncated; NaN gives 0.

Where we differ from NBIS:

| Input | NBIS | Here |
|---|---|---|
| Fill bytes (`FF FF … FF xx`) before a marker | error | accepted (the specification allows them) |
| `NIST_COM` without `PPI` | whole decode fails | no resolution |
| Under 33 pixels a side (standard filters) | reads heap memory outside its buffers | error |
| Lowpass filter of length 1 | reads past the filter | error |
| Filter longer than 32 taps | accepted up to 255 | error: the specification's maximum; time grows with length |
| Restart intervals (DRI) | error | error (no encoder writes them; no test data) |

`decode_strict` turns off the first two leniencies, so that "`decode_strict`
succeeds" implies "NBIS succeeds with the same image". That is the property
the differential tests check.

## Speed

94 % of the time was in `join_lets`. The literal port still handles the ends
of every line, where the filters reflect; the middle of each line, nearly all
of it, is computed in bulk (row by row across all columns for the column
pass, a whole line per filter coefficient for the row pass). Every sample gets
the same operations in the same order, so the pixels do not change.

- 70 megapixels per second on x86_64 (NBIS: 23); about five times NBIS on
  arm64. The largest sample (2.25 megapixels) takes 40 ms.
- Time follows the declared size, not the file size: a few hundred bytes can
  declare 100 megapixels, which costs 1.3 s and 0.8 GB (2.4 s with 32-tap
  filters). The helper's timeout contains anything worse.
- Huffman decoding is still bit by bit, as in NBIS: about 12 % of the time.

## Verification

- **Differential test** (`native/nbis_ref/tests/compare.rs`), against NBIS:
  all 136 WSQ streams in the BioCTS files (skipped without the samples) and
  about 58,000 generated streams (592 sizes, 14 filter pairs, 7 block
  contents). The decoder accepts about 29,000 of them, all identical to NBIS
  in pixels, size and PPI. With AddressSanitizer, NBIS decoded cleanly
  exactly the generated streams the Rust decoder accepts, and had a memory
  error on each one it rejects.
- **Unit tests** in `wsq.rs` (23): the fixture's pinned hash, every
  truncation, 3,000 corrupted copies, table ids, filter lengths, the bit
  reader's marker rules, subband geometry up to 70 × 70, `NIST_COM` parsing.
- **Fuzzing** ([fuzzing.md](fuzzing.md)): `wsq` 1.5 million inputs and
  `wsq_diff` 287,000 inputs in two hours each, no finding; `replay.sh` found
  nothing that NBIS decodes cleanly and we reject.
- Checked on x86_64 Linux and arm64 macOS; the pinned hashes in
  `test/nist_view/biocts_sample_test.exs` match on both.
