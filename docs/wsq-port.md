# WSQ in safe Rust — research and plan

Status 2026-09-30: **research done, implementation not started.** This
document is the hand-over: everything found so far, the design decided, and
the steps to build it. Related: [security.md](security.md),
[fuzzing.md](fuzzing.md), [formats.md](formats.md),
[decisions.md](decisions.md).

## Why

The M5 docs said NBIS WSQ was "patched, clean afterwards". That was wrong.
Replaying the 9 saved crash inputs in `native/nist_codecs/fuzz/artifacts/wsq/`
against a fresh AddressSanitizer build of the `wsq` fuzz target (NBIS with the
M5 patch) still crashes on all of them:

```
6 SEGV                   @ getc_nextbits_wsq
1 heap-buffer-overflow   @ unquantize
1 heap-buffer-overflow   @ getc_transform_table
1 global-buffer-overflow @ getc_huffman_table_wsq
```

(`fuzz/triage.sh wsq` after `cargo +nightly fuzz build wsq` with the `CC`/`CFLAGS`
from `fuzz/run.sh`.) The artifacts are gitignored; on another machine,
regenerate them with `fuzz/run.sh wsq 600` or copy the directory over.

WSQ runs in the `nist_decode` helper, so a hostile file only produces
`{:error, :decoder_crashed}`. But the helper is not sandboxed yet, and WSQ is
the format of the real Prüm traffic, so it is the most exposed decoder. As with
lossless JPEG in M5, the fix is a safe-Rust decoder, with NBIS kept only as a
development-time reference.

## Root causes of the NBIS bugs

All in `native/nist_codecs/vendor/nbis/src/`:

| Crash | Cause |
|---|---|
| SEGV in `getc_nextbits_wsq` (`wsq/decoder.c`) | A read that spans a byte boundary recurses with `marker = NULL`. If the next byte is `0xFF` followed by a non-zero byte and exactly 1 bit is still needed, it writes `*marker` through the NULL pointer. |
| heap overflow in `getc_transform_table` (`wsq/tableio.c`) | A filter length (`hisz`/`losz`) of 0: `a_size` is an `unsigned char`, `a_size--` wraps to 255, and the loop writes 256 coefficients into a zero-length `calloc`. |
| global overflow in `getc_huffman_table_wsq` (`wsq/tableio.c`) | The table id byte is not checked against `MAX_DHT_TABLES` (8) before `dht_table + table_id`. The block header's table selector has the same problem (`decoder.c`, `(dht_table+hufftable_id)->tabdef`). |
| heap overflow in `unquantize` (`wsq/util.c`) | Reads and writes follow the subband tree and the coefficient stream without bounds; related out-of-range walks exist in `join_lets` (filter longer than a subband, zero-length lines). |

Latent bugs found while reading (not hit by the fuzzer yet):

- `build_huffsizes` (`jpegl/huff.c`) writes a terminator at index 257 of a
  257-entry table when a Huffman table has 257 values (one `HUFFCODE` past the
  end).
- `huffman_decode_data_mem` checks `ipc > ipc_mx` *before* writing, so with
  `ipc == ipc_mx == width*height` it writes one `short` past `qdata`.
- `string2fet` (`fet/strfet.c`), used to read the PPI from a `NIST_COM`
  comment, copies names and values into 512-byte stack buffers with no length
  check: a long token in a comment overflows the stack.
- `getc_nistcom_wsq` calls `strncmp(cbufptr + 2, "NIST_COM", 8)` without
  checking that those bytes are inside the buffer.
- `qdata` (`malloc`) and the reconstruction scratch `fdata1` (`malloc`) are
  read without being fully written for some inputs, so NBIS output can depend
  on uninitialised memory.
- `Q_TREE` fields are `short`: widths or heights above 32767 wrap.

## The WSQ specification

FBI IAFIS-IC-0110 v3.1 (2010-10-04),
<https://fbibiospecs.fbi.gov/file-repository/wsq_gray-scale_specification_version_3_1_final.pdf>.
The PDF has a text layer; on macOS, PDFKit extracts it (a 5-line Swift script:
`PDFDocument(url:)`, then `page(at:).string` for each page).

What matters for the decoder:

- **Decoder conformance (Annex AA.3):** at least 99.9 % of reconstructed
  pixels identical to the reference, and none off by more than 1. So "bit for
  bit" is our own stricter target, not a spec requirement.
- **Markers:** SOI `FFA0`, EOI `FFA1`, SOF `FFA2`, SOB `FFA3`, DTT `FFA4`,
  DQT `FFA5`, DHT `FFA6`, DRI `FFA7`, COM `FFA8`, RST0–7 `FFB0`–`FFB7`. Any
  marker may be preceded by `0xFF` fill bytes. Entropy-coded data stuffs a
  `0x00` after every `0xFF` and is padded with 1-bits to a byte boundary.
- **Frame header:** Lf, A (black), B (white), Y (height), X (width), Em, M,
  Er, R, Ev (encoder number), Sf (software). Scaled values are an 8-bit
  exponent `E` and a 16-bit value `V`, meaning V / 10^E.
- **Transform table:** Lt, L0 (analysis lowpass length), L1 (analysis
  highpass length), then for each transmitted coefficient: sign byte, scale
  byte, 32-bit value; right halves only. The maximum filter lengths are 31
  (whole-sample symmetric) and 32 (half-sample).
- **Quantization table:** Lq, Ec, C (bin centre), then 64 × (Eq, Q, Ez, Z).
  Q = 0 means the subband is not transmitted.
- **Huffman table:** Lh, then one or more of: Th (id 0–7), 16 counts, values.
  At most 8 tables. Codes up to 16 bits; the all-ones code is reserved.
- **Blocks:** at least three, breaking between subbands 18/19 and 51/52.
  Block header: Ls, Td (table selector).
- **Symbols (Table A.2):** 1–100 zero run of that length; 101/102 positive or
  negative 8-bit coefficient follows; 103/104 the same with 16 bits; 105/106
  zero run with 8/16-bit length; 107–254 coefficient `symbol − 180`.
- **Dequantisation (A.3):** a = Q·(p − C) + Z/2 for p > 0, 0 for p = 0,
  Q·(p + C) − Z/2 for p < 0.
- **Restart intervals (DRI/RSTm)** are defined by the spec. NBIS does not
  support them (DRI is rejected), and the FBI encoders do not write them.
- Decoders need not handle images narrower or shorter than 400 pixels
  (Part 2, 2.5). NBIS decodes smaller ones (the 128 × 96 fixture), and so
  must we.

## Other implementations

- No WSQ decoder crate exists for Rust (the `wsq` crate on crates.io is a
  WebSocket library).
- JNBIS (<https://github.com/Java-Project-Group/jnbis>, Apache-2.0,
  `src/main/java/org/jnbis/internal/WsqDecoder.java`) is a line-by-line Java
  port of NBIS 1.1. Nothing to learn beyond NBIS itself. Java's strict float
  semantics give the same results as NBIS built without FMA (see below).
- The NBIS changelog has no WSQ decoder fixes after 1.2.0 (2007), which added
  reading comments after the last block (the `blk == 3` special case in
  `huffman_decode_data_mem`). 5.0.0 (2015) is the last release.

## NBIS output depends on the compiler: FMA

NBIS does its arithmetic in `float`, for example `*limg += *lpx * lo[i]` in
`join_lets` and `(*img * r_scale) + m_shift` in `conv_img_2_uchar`. Clang's
default `-ffp-contract=on` fuses these into FMA instructions on arm64; x86_64
builds without `-mfma`, MSVC builds and JNBIS round each operation separately.

Experiment (2026-09-30, Apple clang, arm64): NBIS built from
`vendor/nbis` with `-ffp-contract=on`, `off` and `fast`, run on the 48
distinct WSQ images (47 from BioCTS plus `test/fixtures/synthetic.wsq`):

| Comparison | Result |
|---|---|
| `on` vs `fast` | identical on all 48 |
| `on` vs `off` | differ on 46 of 48 images |
| size of the difference | 285 of 39,226,464 pixels (0.0007 %), all by exactly 1 |
| pinned hashes in `test/nist_view/biocts_sample_test.exs` | match `on` (FMA), not `off` |

So the earlier claim "bit-identical to `dwsq`" holds only for an arm64 clang
build. Both results are well within the spec's tolerance.

**Decision:** the Rust decoder uses plain IEEE `f32`/`f64` operations, no
`mul_add`. It then gives the same output on every platform, and its reference
is NBIS built with `-ffp-contract=off` (the arithmetic as the C source
states it). The pinned hashes change for that reason (they will match
`-ffp-contract=off`). Timing reference: NBIS decodes the largest BioCTS WSQ
image (2.25 megapixels) in 0.11 s.

Reproduce:

```sh
# Extract the WSQ images (needs `mix nist.samples` for the BioCTS set).
mix run scripts/extract_wsq.exs /tmp/wsq_ref

cd native/nist_codecs
for mode in on off; do
  clang -O2 -ffp-contract=$mode -w -D__NBISLE__ -include c/quiet.h \
    -Ivendor/nbis/include vendor/nbis/src/{wsq,jpegl,fet,ioutil,util}/*.c \
    c/glue.c ../../scripts/dwsq_min.c -o dwsq_$mode
  TAG=$mode ./dwsq_$mode /tmp/wsq_ref/*.wsq
done
```

`scripts/dwsq_min.c` is a 20-line `main` that reads each file named on the command line, calls
`wsq_decode_mem` and writes the pixels to `<file>.<tag>.raw`.

## NBIS behaviour the port must reproduce

The goal: **for every input that NBIS (built with `-ffp-contract=off`)
decodes without touching memory outside its buffers or uninitialised
memory, produce the same pixels and PPI.** Where NBIS fails or has undefined
behaviour, return `Error::InvalidWsq` (or be more lenient where the spec says
so). All of this comes from reading `wsq/decoder.c`, `wsq/tableio.c`,
`wsq/util.c`, `wsq/tree.c`, `jpegl/huff.c`, `wsq/ppi.c` and `fet/*.c`.

### Parsing

- SOI, then DTT/DQT/DHT/COM segments in any order, then SOF. EOI, SOB or DRI
  before SOF is an error.
- **Segment lengths are ignored except for DHT and COM.** NBIS reads the
  frame header, transform table, quantisation table and block header field by
  field. Match that: honouring the lengths could reject files that NBIS-based
  systems accept.
- Frame header: black, white, height, width, then M and R as scaled values,
  encoder byte, software u16.
- **Scaled values:** `v = (float)u16` (or `(float)u32` for filter
  coefficients), then per exponent step `v = (float)((double)v / 10.0)`. Do
  the division in `f64` and round to `f32` at every step.
- Transform table: read `hisz` (the first length byte, L0) and then `losz`.
  The first group of `ceil(hisz/2)` coefficients becomes the *synthesis*
  highpass `hifilt` and the second group of `ceil(losz/2)` becomes `lofilt`.
  With `a = ceil(n/2) − 1` and `s(k) = (−1)^k`:
  - `hifilt`, `hisz` odd: `hi[a+k] = s(k)·c[k]`, and for `k > 0`
    `hi[a−k] = hi[a+k]`.
  - `hifilt`, `hisz` even: `hi[a+k+1] = s(k)·c[k]` and
    `hi[a−k] = −hi[a+k+1]`.
  - `lofilt`, `losz` odd: `lo[a+k] = s(k)·c[k]`, mirrored for `k > 0`.
  - `lofilt`, `losz` even: `lo[a+k+1] = s(k+1)·c[k]` and
    `lo[a−k] = lo[a+k+1]`.
  - A sign byte ≠ 0 negates. A length of 0 is an error (the NBIS overflow).
- Quantisation table: bin centre C, then 64 × (Q, Z), all scaled values.
- **DHT:** `bytes_left = Lh − 2`; if ≤ 0, error. Then repeat: id, 16 counts,
  `n = Σcounts` (more than 257 is an error), n values; subtract 17 + n. The
  first table in a segment may redefine an existing id. **Later tables in
  the same segment may not** (error if already defined, even by an earlier
  segment). Stop when `bytes_left == 0`; if negative, error. Ids ≥ 8 are an
  error.
- Tables persist and may be redefined between blocks. Each block rebuilds its
  decoding table from the DHT selected at that point.
- **PPI:** the first COM segment before the first SOB whose text starts with
  `NIST_COM`. Truncate the text at the first NUL. Tokenise as `string2fet`
  does:
  - The name runs to a space, tab or NUL. A newline does *not* end a name.
  - Skip spaces and tabs; the value runs to a newline or NUL; then skip
    spaces, tabs and newlines.
  - The last `PPI` entry wins. PPI = `atoi(value)`, and it counts only if > 0.
  - NBIS *fails the whole decode* when a `NIST_COM` has no `PPI` entry or an
    empty name. We return `ppi: None` instead.

### Huffman tables and decoding

- Code sizes from the counts; canonical codes in `u16` with wrapping
  (`build_huffcodes`); `maxcode[l] = −1` for empty lengths, otherwise
  `valptr`, `mincode`, `maxcode` as in `gen_decode_table`. The all-ones check
  only warns in NBIS: ignore it.
- Decode a symbol bit by bit:
  - `code > maxcode[len]` means read another bit.
  - Longer than 16 bits is an error (the M5 patch).
  - The value index `valptr + code − mincode` must be in 0..=256.

### Bit reader (`getc_nextbits_wsq`)

- State: the current byte and `bit_count`. `bit_count` is reset to 0 at
  every block start, so a partial byte is dropped.
- **Loading a byte** (when `bit_count == 0`):
  - Read the byte. If it is `0xFF`, read the next byte too.
  - `FF 00` is a stuffed `0xFF` data byte.
  - `FF xx` (xx ≠ 0) is a marker when exactly 1 bit was requested and that
    read is not the continuation of a longer read. The marker is returned and
    the symbol becomes "marker".
  - Otherwise `FF xx` is an error (NBIS: `-41`, or the NULL write for a
    1-bit continuation).
- **Reads of up to 16 bits** take the high bits of the current byte first,
  then continue into the next bytes.
- **Accept fill bytes:** `FF FF … FF xx` should be read as the marker `FFxx`.
  That is spec-compliant and more lenient than NBIS.

### Coefficient stream (`huffman_decode_data_mem`)

- Set `ipc = 0` and `ipc_mx = width·height`.
- At the start of each block (after its table segments):
  - The first time a DQT is defined, subtract from `ipc_mx` the size of every
    subband 0–63 whose Q = 0. This happens only once.
  - Then read the block header: length (ignored), then the table selector (≥ 8
    or undefined is an error).
- **For each symbol:**
  1. A marker ends the block. If `blk == 3` and it is COM, read comment
     segments. Then continue at the top: EOI ends the loop; another marker
     starts a new block (tables until SOB; only DTT/DQT/DHT/COM allowed,
     anything else is an error).
  2. If `ipc > ipc_mx`, error.
  3. By symbol:
     - 1–100: a zero run. `ipc += n`; if `ipc > ipc_mx`, error.
     - 107–254: store `sym − 180`.
     - 101/103: store `bits as i16` (8 or 16 bits).
     - 102/104: store the negative, wrapping to `i16`.
     - 105/106: zero run of an 8/16-bit length, with the `ipc` check.
     - 0 and 255: error.
- **Store limits:** writes must stay below `width·height` (error otherwise).
  A short stream leaves zeros (NBIS leaves uninitialised memory).
- **Stream ends:** the first marker after SOF must be a table marker or SOB
  (EOI is an error), so there is at least one block. After EOI, a missing DQT
  or DTT is an error.

### Subband trees (`tree.c`)

- Port `build_w_tree`/`w_tree4` (20 nodes with `inv_rw`/`inv_cl` flags) and
  `build_q_tree`/`q_tree16`/`q_tree4` (64 subbands) literally, in `i32`.
- The call order matters: `q_tree16` at 3, 19, 48 and 35, then `q_tree4` at
  0, which overwrites subband 3.
- **Error cases:**
  - any `q_tree` value that does not fit in `i16` (NBIS wraps)
  - any rectangle outside the image

### Dequantisation (`unquantize`)

- A zeroed `f32` image.
- For subbands 0–59 with Q ≠ 0, in order, take the coefficients sequentially
  and fill the subband rectangle row by row.
- **Formula:** `(q * (p as f32 − C)) as f64 + (z as f64) / 2.0`, rounded
  to `f32`; for negative p, `(q * (p as f32 + C)) as f64 − (z as f64) / 2.0`.
- Subbands 60–63 stay zero.

### Reconstruction (`wsq_reconstruct`, `join_lets`)

- One scratch buffer the size of the image, zeroed (NBIS `malloc`s it).
- For node 19 down to 0:
  1. `join_lets(scratch ← image at node offset; len1 = lenx, len2 = leny, pitch 1, stride width, inv = inv_cl)`
  2. `join_lets(image at node offset ← scratch; len1 = leny, len2 = lenx, pitch width, stride 1, inv = inv_rw)`
- **The scratch writes start at offset 0 of the scratch buffer, not at the
  node's offset.**
- **Port `join_lets` as pointer arithmetic over the whole buffers:** `isize`
  offsets and a bounds check on every read and write, erroring only when an
  access leaves the buffer. Do **not** copy lines out:
  - NBIS reads outside the current subband even for valid images. On the
    128 × 96 fixture, `loc = (lsz−1)/4 = 2` puts the first lowpass read past a
    2-sample band, into the neighbouring data.
  - The initial `*himg = 0; *(himg+stride) = 0` writes one sample past a
    1-sample line.

  Faithful offsets reproduce all of that.
- For even-length filters NBIS negates `hi` in place and restores it
  afterwards. Use a negated copy (the same values, including −0.0).
- **Keep the operation order exactly:**
  - `*limg = *lpx * lo[tap]`, then `*limg += *lpx * lo[i]`
  - `*himg += *hpx * hi[i] * sfac`, which is `((hpx·hi)·sfac)` and then the add
  - `sfac = fhre as f32`

  Rust never fuses these, which gives the `-ffp-contract=off` result.

### Pixels (`conv_img_2_uchar`)

1. `t = img * r_scale + m_shift` in `f32`.
2. `t = ((t as f64) + 0.5) as f32`.
3. `t < 0.0` gives 0; `t > 255.0` gives 255; otherwise `t as u8` (truncate).
   NaN gives 0.

## Design

- **New `native/nist_codecs/src/wsq.rs`** with `pub fn decode(data: &[u8]) ->
  Result<Pixels, Error>`, in the style of `jpegl.rs`. The existing
  `check_dimensions` (100 megapixels) runs on the frame header before any
  allocation. No `unsafe`, no globals, no mutex.
- **Delete `src/nbis.rs`, `build.rs`, `c/` and `vendor/` from `nist_codecs`.**
  The crate then compiles no C of its own; only OpenJPEG remains, through
  `jpeg2k`. Drop the `cc` build dependency.
- **`nist_decode`:** `W` calls `wsq::decode`. The helper stays; JPEG 2000 is
  still C, and a separate process also contains panics, OOM and timeouts.
  Update the module docs (`main.rs`, `NistView.Decoder`, `NistView.Codecs`),
  which say WSQ is C.
- **Dev-only reference crate `native/nbis_ref`:** the vendored NBIS, moved
  from `nist_codecs/vendor/nbis` with `c/glue.c` and `c/quiet.h`.
  - Its `build.rs` compiles with `-ffp-contract=off` (`/fp:precise` on MSVC).
  - Patches, each marked `nist_view:`:
    - the existing two
    - `qdata` and `fdata1` allocated with `calloc`, so its output does not
      depend on uninitialised memory
  - It exposes `decode_wsq(&[u8]) -> Option<(w, h, ppi, Vec<u8>)>` (unsafe
    FFI inside, mutex for the globals).
  - Never a dependency of `nist_codecs` or `nist_decode`.
- **Differential test** `native/nbis_ref/tests/compare.rs`: for every WSQ
  image in `test/fixtures` and `test/samples` (skipped when the samples are
  missing), Rust and NBIS pixels and PPI must be identical. Include the images
  extracted from `.an2` files (parse the NIST container minimally, or have
  `mix` write them to a gitignored directory first).
- **Fuzzing:**
  - `fuzz_targets/wsq.rs` switches to `nist_codecs::wsq::decode`.
  - New `wsq_diff` target (depends on `nbis_ref`, ASan on the C code): run
    Rust first. If it succeeds, NBIS must also succeed with the same pixels,
    and any ASan report or mismatch is a finding. If Rust fails, skip NBIS,
    since NBIS has known memory bugs on such inputs.
  - A batch script replays the corpus through both to find inputs NBIS
    accepts cleanly but Rust rejects. It runs NBIS in a child process, e.g.
    the `dwsq_min` harness built with ASan.
  - Then run `wsq`, and `wsq_diff` if time allows, for hours, not minutes.
- **Regression inputs:** minimise the 9 crash artifacts with
  `cargo fuzz tmin` until no print content remains, and commit them to
  `native/nist_codecs/fuzz/regressions/wsq/`. `NistView.DecoderTest` already
  asserts `{:error, _}` for every file there.
- **Tests to update:**
  - `test/nist_view/biocts_sample_test.exs`: re-pin the `dwsq` SHA-256 hashes
    to the `-ffp-contract=off` output and explain why. Consider pinning more
    than two images.
  - `codecs_test.exs` WSQ tests keep passing unchanged (the synthetic
    pattern's mean error is < 1).
  - Rust unit tests in `wsq.rs`:
    - the synthetic fixture's hash
    - every truncation of it returns an error, never a panic
    - a zero-length filter
    - a table id ≥ 8
    - an `FF xx` inside a multi-bit read
    - fill bytes before markers
    - tree geometry for odd and small sizes
- **Docs when done:**
  - `security.md`: the fuzzing table and the controls
  - `fuzzing.md`
  - `formats.md`: a WSQ section with the quirks above
  - `architecture.md`: images
  - `decisions.md`
  - `plan.md`: M2 and M5 status
  - `nbis_ref`'s README, moved from `vendor/nbis/README.md`

## Steps

1. Create `native/nbis_ref` by moving `vendor/nbis`, `c/` and `build.rs`
   from `nist_codecs`; add the `-ffp-contract=off` flag and the `calloc`
   patches. Check that it reproduces the `off` hashes on the 48 images.
2. Write `wsq.rs` by following the behaviour list above, section by section.
3. Write the differential test and get it to 48/48 identical, then unit tests.
4. Switch `nist_decode` and the fuzz target; delete `nbis.rs`; re-pin the
   Elixir hashes; `mix precommit`.
5. Add the `wsq_diff` target and the corpus replay script; fuzz; minimise
   and commit the regression inputs.
6. Measure speed against NBIS (0.11 s for 2.25 megapixels).
7. Update the docs listed above.

Open question for later: support restart intervals (DRI/RSTm)? The spec
defines them, and NBIS and the FBI encoders don't use them. There is no test
data. For now they are an error.
