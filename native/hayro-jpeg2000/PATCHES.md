# hayro-jpeg2000, patched copy

`hayro-jpeg2000` 0.4.0 as published on crates.io (repository
`https://github.com/LaurenzV/hayro`, commit
`175acf7c5129e34c80687c9489b73505e101103c`, directory `hayro-jpeg2000`), by
Laurenz Stampfl and contributors, under Apache-2.0 or MIT (`LICENSE-APACHE`,
`LICENSE-MIT`; the ICC profiles in `assets/` are CC0).

It is here, instead of being a registry dependency, because of two fixes that
no release has yet. `nist_codecs` uses it with `default-features = false`:
no SIMD and no `std` feature, which leaves no `unsafe`, no dependencies and
no fused multiply-add. Why and how it was chosen: `docs/jp2.md`.

## What differs from the published crate

Left out: `examples/`, and the example and development dependencies in
`Cargo.toml`. `README.md` is the crate's own. Added: `.gitignore`, for
running the crate's tests here.

Changed, each marked with a `nist_view:` comment:

| File | Change | Why |
|---|---|---|
| `src/j2c/bitplane.rs` `Coefficient::push_bit_at`, and the two magnitude refinement passes | A coefficient is stored as twice its magnitude plus a marker bit below the last decoded bit. Refinement passes push zero bits too, so the marker moves | Midpoint reconstruction. The published crate takes the bits that were not transmitted as zero, which puts every coefficient at the low end of its quantisation interval. On lossy images that costs 0.6 to 2.1 dB against OpenJPEG and ffmpeg, which both reconstruct at the midpoint |
| `src/j2c/decode.rs` `decode_sub_band_bitplanes` | Halves the stored value when converting it; for reversible (lossless) coding by integer division, which drops the marker | The other half of the same fix. Lossless output is unchanged |
| `src/j2c/decode.rs`, the bit-plane limit | 30 bit planes at most, where the crate allows 32 | The marker takes one of the 31 magnitude bits |
| `src/j2c/tag_tree.rs` `TagNode::build` (2026-09-30), and a `tests` module there | Returns at once for a node of width or height 0 | Speed. Building a tag tree visited the whole square of the tree's longer side, most of it empty, so a precinct 8192 code blocks wide and one high took 4^13 calls instead of about 16,000. A small file declaring a long, thin image took seconds (up to 7.8 s among the fuzzer's inputs; 11.8 s for a valid 4096 × 4096 file in tiles 4 high); now 0.1 to 0.3 s. The trees built are the same: one test counts their nodes and passes on the published code too; the other builds a tree 2^20 wide and one high, which took hours before |

## Known limits of the crate that matter here

- Region-of-interest (RGN) markers are skipped. An image whose whole
  component is shifted still decodes; one with a real region would not.
- Signed components are treated as unsigned ones with a level shift, which
  gives the same samples as OpenJPEG for the files tested.
- An image wider or higher than 60,000 pixels is refused
  (`src/j2c/codestream.rs`, `MAX_DIMENSIONS`). OpenJPEG has no such limit.

## Updating

Take the new release from crates.io, copy `src/`, `assets/`, the licences
and `README.md` over this directory, and compare. If the release has
midpoint reconstruction, drop this copy and depend on the registry crate.
Otherwise reapply the changes above (`git log -p` on this directory shows
them), then run `cargo test --release --no-default-features` here and
`cargo test --release` in `native/opj_ref`.
