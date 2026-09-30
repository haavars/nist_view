# ANSI/NIST-ITL: what the viewer supports

Notes on the file format as implemented, including what real and sample
files turned out to contain. Sources: ANSI/NIST-ITL 1-2011 Update:2015, NIST's
BioCTS sample set (96 traditional-encoding files), phantom and abis_next
output, and the abis_next notes on real Prüm traffic.

## Transaction structure

- Traditional (tagged/binary) encoding only; XML (INT-I v6) is not supported.
- Type-1 comes first. Its CNT field (1.003) is `1<US>n`, then one
  `type<US>idc` subfield per remaining record, and it drives parsing.
- Tagged records: `T.NNN:value` fields separated by GS (0x1D), subfields by
  RS (0x1E), items by US (0x1F), ending with FS (0x1C). Field 001 is the
  record length including itself. Field 999 is last and runs to the final FS.
- Binary records (Type-3 to Type-8) have no tags; the parser gives their
  fixed fields the standard numbers so they display like tagged fields:

| Type | Layout |
|---|---|
| 3, 4, 5, 6 | LEN (4), IDC, IMP, FGP (6 bytes, 255 = unused), ISR, HLL (2), VLL (2), GCA, image |
| 7 | LEN (4), IDC, user-defined data |
| 8 | LEN (4), IDC, SIG, SRT, ISR, HLL (2), VLL (2), signature data |

- Resolution: tagged image records use SLC (1 = ppi, 2 = pixels per cm) and
  THPS. Type-3/4/5/6 with ISR 0 use the nominal 250 ppi (Type-3, 5) or
  500 ppi (Type-4, 6); ISR 1 uses Type-1 NSR (1.011, pixels per mm).

## Record types seen

Parsed as structure for every type. In BioCTS: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
13, 14, 15, 16, 17, 18, 19, 20, 21, 98, 99. Images are recognised in any
tagged record with field 999 and a compression label (011).

## Compression

`.011` labels (and the Type-3/4 GCA byte) are normalised to one codec:

| Label | GCA | Codec |
|---|---|---|
| `NONE` | 0 | uncompressed |
| `WSQ`, `WSQ20` | 1 | WSQ (Prüm files say `WSQ`) |
| `JPEGB` | 2 | baseline JPEG |
| `JPEGL` | 3 | lossless JPEG |
| `JP2` | 4 | JPEG 2000 |
| `JP2L` | 5 | JPEG 2000 lossless |
| `PNG` | 6 | PNG |

Labels can be wrong, so decoding follows the bytes (`NistView.ImageFormat`):
WSQ `FF A0`, PNG signature, JP2 signature box or J2K `FF 4F FF 51`, and for
JPEG the first frame marker (SOF0–2 baseline/progressive, SOF3 lossless).
Uncompressed images keep their label, since pixel data could start with a
signature by chance. BioCTS has four mislabelled images:

| File | Label | Actually |
|---|---|---|
| `pass-type-10-14-17-piv-index-iris-replacedCorruptImages_fixedAspectRatio.an2` (2 × Type-14) | `JPEGL` | baseline JPEG (written by Paint.NET) |
| `fail-all-supported-types-L2.an2` (a Type-15) | `JPEGB` | WSQ |
| `fail-type-4-L2.an2` (a Type-4) | GCA 2 (`JPEGB`) | WSQ |

## Minutiae (Type-9)

Four blocks are decoded and normalised to millimetres (with an origin) and
angles in the INCITS 378 convention: degrees counter-clockwise from +x as
displayed. The conventions were derived by comparing the three blocks BioCTS
provides for the same print (48 minutiae, one core, one delta), which agree
within 1 px and 1° after normalisation:

| Block | Fields | Position units | Origin | Angle | Types |
|---|---|---|---|---|---|
| INCITS 378 (M1) | 9.137 FMD, 9.139 CIN, 9.140 DIN; resolution 9.130–9.132 | pixels | top-left | 2° units | 1 ending, 2 bifurcation, 0 other |
| Legacy standard | 9.012 MRC (`XXXXYYYYTTT`), 9.008 CRP, 9.009 DLT | 0.01 mm | **bottom-left** | degrees, **M1 − 180°** | A ending, B bifurcation, C/D other |
| FBI/IAFIS | 9.023 (`XXXXYYYYTTT`), 9.021, 9.022 | 0.01 mm | top-left | degrees, as M1 | A, B, others |
| EFS | 9.331 MIN, 9.320 COR, 9.321 DEL | 0.01 mm | top-left | degrees, assumed as M1 | E ending, B bifurcation, X either |

The EFS angle convention is not verified against an independent file: no
available file has EFS minutiae. The overlay matches Type-9 to an image by
IDC. Prüm files use M1.

## WSQ as decoded

WSQ (FBI IAFIS-IC-0110 v3.1) is decoded by our own decoder
(`native/nist_codecs/src/wsq.rs`). Where the specification and NBIS 5.0.0
differ, it follows NBIS, because the files in circulation were made for
NBIS-derived decoders. The details and how this was established are in
[wsq-port.md](wsq-port.md); what matters when a file does not decode:

- **Layout.** SOI (`FFA0`), then tables and comments in any order (DTT
  `FFA4`, DQT `FFA5`, DHT `FFA6`, COM `FFA8`), the frame header (SOF `FFA2`),
  then blocks (SOB `FFA3`), each of which may be preceded by more tables, and
  EOI (`FFA1`). All 48 distinct BioCTS images have one comment, the 9 and 7
  tap filter pair, two Huffman table segments and three blocks.
- **Segment lengths.** The length fields of the frame header, the transform
  and quantisation tables and the block headers are not used for decoding.
  They must still be right before the first block, because the resolution is
  found by a scan that skips segments by length.
- **Resolution.** From the first comment before the first block whose text
  starts with `NIST_COM`: the last `PPI` entry, if it is a positive number.
  Without such a comment, or without `PPI` in it, the image has no
  resolution of its own. (The viewer shows the resolution from the record's
  fields in any case; the decoder reports the image's own beside it.)
- **Markers in the coded data.** A marker ends a block only at a byte
  boundary where a new code starts. `FF` fill bytes before it are accepted
  (NBIS rejects them). `FF` followed by anything but `00` elsewhere is an
  error.
- **Short streams.** A block may end early, and an image may have fewer than
  three blocks: the missing coefficients are zero. Comments may follow the
  third block.
- **Filters.** Any lengths from 1 to 32, odd or even; a lowpass length of 1
  is an error. The specification allows 31 and 32, NBIS up to 255.
- **Sizes.** At least 33 pixels in each direction with the standard filters:
  below that NBIS reads outside its buffers, so there is no reference output,
  and the decoder returns an error. At most 100 megapixels, and no subband
  may start beyond 32,767 pixels (NBIS keeps positions in 16 bits).
- **Huffman tables.** Ids 0 to 7; a table used by a block may have at most
  256 codes. A segment's first table may replace an earlier one, its later
  tables may not.
- **Restart intervals** (DRI `FFA7`) are an error, as in NBIS. The
  specification defines them; no encoder we know of writes them.
- **Pixels.** Identical to NBIS built without fused multiply-add, on every
  platform. An NBIS build that fuses (clang's default on arm64) differs by 1
  in about 7 of a million pixels, which is within the specification's
  tolerance for decoders (99.9 % of pixels equal, none off by more than 1).

## Lossless JPEG quirks (NBIS encoder)

Files written by NBIS `cjpegl` are not conformant, and both
`jpeg-decoder` (Rust) and libjpeg-turbo reject them as written:

- The Huffman tables are declared as class 1 (AC) although lossless scans
  select DC tables. Our decoder ignores the class.
- Colour images are written as one scan per component (non-interleaved), each
  preceded by its own table.
- Chroma may be subsampled (the fixture uses 2×2 on Cb and Cr).

libjpeg-turbo 3.2 decodes all three NBIS fixtures identically to our
decoder once the table class is corrected and no colour conversion is
requested. `jpeg-decoder` 0.3.2 cannot decode multi-scan lossless files: it
stores each scan's plane by its index within the scan.

NBIS also ignores the scan header's declared length; our decoder and
libjpeg-turbo honour it.

## Position codes

Finger positions 0–15 and palm positions 20–30 have names in
`NistView.Positions`. The tenprint card shows rolled 1–10, plain 11–14
(laid out left four, left thumb, right thumb, right four) and 15 (both
thumbs).

## Sample data

- `test/fixtures/` — synthetic only (committed): WSQ, lossless JPEG and JPEG
  2000 patterns, and a phantom-style enrolment built with phantom's own
  record builders. See `test/fixtures/README.md`.
- `test/samples/biocts/` — NIST BioCTS samples, fetched by `mix nist.samples`
  (gitignored: real people's prints and faces).
- Prüm `.eml` samples — not available on this machine.
