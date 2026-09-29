# Test fixtures

Only synthetic data belongs here. Real or public sample transactions go in the
gitignored `test/samples/` (see `mix nist.samples`).

| File | Content |
|---|---|
| `synthetic.wsq` | 128 × 96 WSQ image at 500 ppi of the ridge-like pattern `128 + 90 * sin(x / 2.5) * cos(y / 3.5)`, encoded with NBIS 5.0.0 `wsq_encode_mem` at 2.25 bits per pixel. Not a fingerprint. |
| `phantom_enrol.an2` | A phantom-style enrolment (Type-1, 2, 10, two Type-14, 15) built by phantom's `Phantom.Nist.*` builders, as of phantom commit `91be0aa`. The images are a generated RGB gradient (PNG face), the ridge pattern as PNG, and `synthetic.wsq` (WSQ20 print and palm). It keeps phantom's non-standard `14.901`/`15.901`. Regenerate with `mix run scripts/phantom_enrol.exs test/fixtures/phantom_enrol.an2`. |
