# Decision log

Decisions made while building the viewer, newest last. Each says what was
decided, why, and what it replaced.

## 2026-09-29

**Parser in pure Elixir, derived from abis_next.** abis_next's
`Nist.Record` and `Nist.File` already parsed real Prüm and BioCTS files. Copied
and changed: partial results instead of failing, Type-3 to Type-8 headers
decoded, subfields and items split, encoder dropped. CNT-guided parsing is
required, because binary records carry no tag.

**Parsing is total.** Framing errors return the records read so far with an
offset; other problems become warnings. A viewer should show as much of a
broken file as it can.

**Decode by content, not label.** BioCTS has four mislabelled images, and
Prüm uses the old `WSQ` label. `NistView.ImageFormat` detects the format
from the bytes; uncompressed images keep their label.

**NBIS for WSQ, vendored.** WSQ has no maintained alternative. Only the 23
files the decoder links against are vendored, from NBIS 5.0.0, with
`__NBISLE__`, a mutex for its globals and silenced `fprintf`. WSQ output is
bit-identical to NBIS `dwsq` on all 47 distinct BioCTS WSQ images.

**JPEG 2000 through `jpeg2k`/OpenJPEG, own 8-bit conversion.** The crate's
`get_pixels` rejects sYCC, assumes full-size components and does not clamp.
Output is bit-identical to `opj_decompress` 2.5.4 on all 12 distinct BioCTS
JPEG 2000 images.

**PNG and baseline JPEG are passed to the webview.** It decodes them; only
formats it cannot show are decoded and re-encoded as PNG.

**Toolchain: Rust 1.98.1, Rustler 0.38.** Rust 1.85 needed Rustler 0.37, and
its stripped dylibs were rejected by the macOS 27 loader ("mis-aligned
LINKEDIT string pool"). Upgrading removed both workarounds. Versions pinned in
`.tool-versions`.

**Minutiae conventions from data.** The four Type-9 blocks' units, origins
and angle conventions were derived by comparing three encodings of the same
BioCTS print rather than taken from documentation (see `formats.md`).

**Images through an in-memory store and URLs.** Rendered images go to an ETS
table owned by the LiveView, served by random token with `no-store`, instead
of large data URIs over the socket.

**In-memory uploads.** LiveView's default upload writer uses a temporary
file; `MemoryUploadWriter` keeps the file in memory.

**Streams stay in the DOM.** LiveView does not keep stream items on the
server, so containers are hidden, not removed, when switching tabs and views.

**No database.** Ecto, Postgres, Swoosh and DNSCluster were removed before
packaging: a desktop viewer must not need a database server.

**Tauri + ElixirKit shell with a launch token.** Loopback-only Phoenix on a
random port; a per-launch token and session gate every page, image and
socket; strict CSP; windows locked to the server origin; one window per
opened file; paths passed by one-time id.

**Decoders out of process (M5).** Fuzzing found a memory error in NBIS WSQ
within a minute. C decoders now run in the `nist_decode` helper, one process
per image; the NIF keeps only safe-Rust PNG encoding and colour conversion.

**Own lossless JPEG decoder in safe Rust; libjpeg-turbo as reference.** NBIS's
lossless JPEG decoder had many memory bugs. `jpeg-decoder` cannot read
multi-scan lossless files; libjpeg-turbo 3.2 can (with a table-class fix for
NBIS files) but is C and needs CMake on every build machine. Chosen: ship the
Rust decoder, and use libjpeg-turbo during development as the reference for
differential fuzzing and tests.

**Fixture policy.** Only synthetic data is committed (`test/fixtures`).
BioCTS samples are downloaded into the gitignored `test/samples`; Prüm
samples are never committed. Fuzz corpora and crash inputs derived from them
stay out of git until minimised.

## 2026-09-30

**WSQ to be decoded in safe Rust; NBIS kept only as a reference.** Replaying
the saved fuzz crashes showed that NBIS WSQ still has four memory bugs after
the M5 patch (the M5 docs wrongly said it was clean). As with lossless JPEG,
the fix is our own decoder. NBIS moves to a development-only crate for
differential tests and fuzzing. Details and plan: [wsq-port.md](wsq-port.md).

**WSQ arithmetic without FMA.** NBIS's float code gives different pixels
depending on whether the compiler fuses multiply-adds. It differs on 46 of 48
sample images, in 0.0007 % of pixels, always by 1. The earlier "bit-identical to
`dwsq`" check held only for arm64 clang builds. The Rust decoder uses plain
IEEE operations, so every platform gives the same output. Its reference is
NBIS built with `-ffp-contract=off`, and the pinned hashes will change
accordingly.

**Match NBIS's parsing, not a stricter reading of the spec.** NBIS ignores the
declared lengths of most WSQ segments. Files in the wild are made for
NBIS-derived decoders, so the port follows NBIS wherever NBIS decodes without
memory errors. It is more lenient only where the spec allows it (fill bytes
before markers) or where NBIS fails for no good reason (a `NIST_COM` without
`PPI`).

**NBIS moved to `native/nbis_ref`, built without FMA.** The vendored sources,
their glue and the FFI wrapper are now a crate of their own, compiled with
`-ffp-contract=off` and with two `calloc` patches so its output never depends
on uninitialised memory. gcc and clang on x86_64 give identical pixels on all
48 sample images that way, and clang with FMA on x86_64 reproduces the arm64
output, so the difference is contraction and nothing else. `nist_codecs`
depends on `nbis_ref` until the Rust decoder replaces it; the WSQ hashes in
the sample tests were re-pinned to the no-FMA output.

**Rust WSQ decoder: a literal port of the wavelet synthesis.** `join_lets` is
ported statement by statement, with positions as offsets into the whole
image buffer and a bounds check on every access, instead of a cleaner
line-by-line filter. NBIS's reads reach outside the subband being joined
even for valid images, and a rewrite would have to reproduce that anyway. The
result matches NBIS on all 136 BioCTS streams and on about 29,000 generated
ones, at about 60 % of NBIS's speed before any tuning.

**Small images are errors.** NBIS reads heap memory outside its buffers for
images under 33 pixels in either direction (with the standard filters), so
there is no defined output to match. The Rust decoder rejects them rather
than invent a result.

**WSQ filters of more than 32 taps are refused.** NBIS reads filter lengths
up to 255, and decoding time grows with the length: a 100-megapixel image
would take minutes (before the tuning below). 32 is the specification's
maximum, and real files use 9 and 7. This is the only place where the Rust
decoder rejects input that NBIS decodes correctly.

**Two decoders in one: `decode` and `decode_strict`.** The public `decode`
accepts fill bytes before a marker and a `NIST_COM` without `PPI`.
`decode_strict` rejects them as NBIS does, which gives the differential tests
a simple rule: if `decode_strict` succeeds, NBIS must succeed with the same
image.

**WSQ speed: bulk computation of the middle of each line, not a rewrite.**
The literal port of `join_lets` stays and handles the ends of every line.
For the stretch where the filters do not reflect, which is nearly all of a
line, the same sums are computed in bulk: row by row across all columns for
the column pass, and a whole line per filter coefficient for the row pass.
No sample's operations change or change order, so the output stays identical
to NBIS, which the differential test confirms. The decoder went from 14 to 70
megapixels per second; NBIS does 23.

**JPEG 2000 with `hayro-jpeg2000` instead of OpenJPEG.** OpenJPEG was the
last C that parsed untrusted data. The alternatives were a sandbox for the
helper on three operating systems, or our own decoder, which for JPEG 2000
is far more work than WSQ was. The crate is written from scratch in safe
Rust. Evaluation showed it identical to OpenJPEG on lossless images and
0.6 to 2.1 dB worse on lossy ones, because it reconstructed coefficients at
the low end of their interval; with that fixed it is within 1 of OpenJPEG in
a fraction of a percent of samples, as ffmpeg's decoder is.

**The crate is a patched copy in the repository.** The fix is not in any
release. A path dependency keeps builds offline and the change visible;
`PATCHES.md` says how to drop the copy once a release has the fix. It is
not reported upstream: the viewer is a proof of concept for now.

**Built without SIMD and without the crate's `std` feature.** SIMD brings in
`unsafe` and gained nothing in our measurement. The `std` feature makes the
crate use fused multiply-add on arm64 but not on x86_64, the problem WSQ
had; without it the arithmetic is the same everywhere.

**"The same as OpenJPEG" is exact only for lossless.** For WSQ the port
reproduced the reference's arithmetic and could be bit-exact. Two independent
JPEG 2000 decoders differ in the last bit on lossy images, so the test
allows 1 per sample in at most 0.5 % of samples; lossless must be identical.

**A memory limit besides the pixel limit.** The crate works in `f32` and
holds every component's coefficients and samples at once: 13 bytes per pixel
for greyscale, 30 for RGB, about double OpenJPEG. A decode is refused when
its estimate passes 2 GiB.

**Slow JPEG 2000 inputs fixed in the crate, not guarded against.** The
fuzzer's slow inputs were long, thin images; the crate built its tag trees
in time that grew with the square of a precinct's longer side. A guard in
`jp2.rs` (refusing extreme aspect ratios) would have refused valid images
and left the loop in place for tiled ones, which are slow at ordinary
shapes. The fix is one early return that builds the same trees, so it is
carried in our copy next to the reconstruction fix and, like it, not
reported upstream.
