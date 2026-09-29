# Test fixtures

Only synthetic data belongs here. Real or public sample transactions go in the
gitignored `test/samples/` (see `mix nist.samples`).

| File | Content |
|---|---|
| `synthetic.wsq` | 128 × 96 WSQ image at 500 ppi of the ridge-like pattern `128 + 90 * sin(x / 2.5) * cos(y / 3.5)`, encoded with NBIS 5.0.0 `wsq_encode_mem` at 2.25 bits per pixel. Not a fingerprint. |
