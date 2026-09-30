# Test fixtures

Only synthetic data belongs here. Real or public sample transactions go in the
gitignored `test/samples/` (see `mix nist.samples`).

| File | Content |
|---|---|
| `synthetic.wsq` | 128 × 96 WSQ image at 500 ppi of the ridge-like pattern `128 + 90 * sin(x / 2.5) * cos(y / 3.5)`, encoded with NBIS 5.0.0 `wsq_encode_mem` at 2.25 bits per pixel. Not a fingerprint. |
| `phantom_enrol.an2` | A phantom-style enrolment (Type-1, 2, 10, two Type-14, 15) built by phantom's `Phantom.Nist.*` builders, as of phantom commit `91be0aa`. The images are a generated RGB gradient (PNG face), the ridge pattern as PNG, and `synthetic.wsq` (WSQ20 print and palm). It keeps phantom's non-standard `14.901`/`15.901`. Regenerate with `mix run scripts/phantom_enrol.exs test/fixtures/phantom_enrol.an2`. |
| `synthetic_grey.jpl` | 128 × 96 lossless JPEG (NBIS `cjpegl`), 500 ppi, of the same ridge pattern as `synthetic.wsq`. |
| `synthetic_rgb.jpl` | 128 × 96 lossless JPEG, interleaved RGB `(2x mod 256, 2y mod 256, (x + y) mod 256)`. |
| `synthetic_ycc420.jpl` | 128 × 96 lossless JPEG, YCbCr with 2 × 2-subsampled chroma: Y = `(x + 2y) mod 256`, Cb = `(64 + 2x') mod 256`, Cr = `(200 − 2y') mod 256` on the 64 × 48 chroma grid. |
| `synthetic_grey.jp2` | The ridge pattern as lossless JPEG 2000 (OpenJPEG `opj_compress`), JP2 file. |
| `synthetic_rgb.j2k` | The RGB pattern as lossless JPEG 2000, raw codestream. |
| `synthetic_grey16.jp2` | 16-bit greyscale `(512x + 7y) mod 65536`, lossless JPEG 2000. |
| `jp2/` | 32 JPEG 2000 files of about 131 × 97, made by `scripts/make_jp2_fixtures.sh` from the ridge pattern with added texture: lossless and lossy; 8, 12 and 16 bit; signed; subsampled chroma; tiles; progression orders; code-block styles. `native/opj_ref/tests/compare.rs` decodes each with our decoder and with OpenJPEG. |

`scripts/synthetic_images.py` writes the source patterns and lists the encoder commands.
