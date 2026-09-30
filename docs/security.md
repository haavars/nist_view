# NIST Viewer — Security and data handling

Status as of 2026-09-29 (M5 in progress). What the viewer protects, how,
what fuzzing found, and what is still open.

## What we protect against

1. **Hostile files.** A transaction may be crafted to exploit the parser or
   an image decoder. Decoders are the largest attack surface, especially C.
2. **Leaking biometric data** to disk, logs, caches or other programs.
3. **Other local software** (another user's process, a web page in a
   browser, DNS rebinding) reaching the viewer's local HTTP server.

Out of scope: an attacker who already runs code as the same user, and
network attackers (the viewer makes no network connections).

## Controls in place

### Hostile files

| Control | Where |
|---|---|
| Parser in pure Elixir; records sliced by declared length; parsing is total (errors are values, never crashes) | `NistView.Parser` |
| Property tests: generated transactions round-trip; truncation, corruption and arbitrary bytes never raise | `test/nist_view/parser_property_test.exs` |
| Decoders read the image size from the header and refuse images over 100 megapixels before allocating | `native/nist_codecs/src/headers.rs`, `check_dimensions` |
| JPEG 2000 decoding is also bounded by an estimate of its memory, 2 GiB, which a 100-megapixel colour image would exceed | `native/nist_codecs/src/jp2.rs`, `MAX_DECODE_BYTES` |
| A decode is bounded, not cheap: a WSQ file of a few hundred bytes can declare 100 megapixels and then costs 1 to 3 seconds of CPU and about 1 GB in the helper (measured; filters are capped at the specification's 32 taps). The timeout below is what ends anything slower | `native/nist_codecs/src/wsq.rs`, [`wsq-port.md`](wsq-port.md#found-while-porting) |
| **Image decoders run in a separate process** (`nist_decode`), one per image, with a 60 s timeout. All three decoders are safe Rust; nothing in the helper is C. A crash or hang is reported, not fatal. No C code is loaded into the BEAM: the NIF only has safe-Rust PNG encoding and colour conversion | `NistView.Decoder`, `native/nist_decode` |
| Lossless JPEG decoded by our own safe-Rust decoder instead of NBIS | `native/nist_codecs/src/jpegl.rs` |
| WSQ decoded by our own safe-Rust decoder instead of NBIS (2026-09-30), and tested to give the same pixels. NBIS had seven memory bugs reachable from a file (one patched in our copy, six not); it is now only a development-time reference | `native/nist_codecs/src/wsq.rs`, `native/nbis_ref/README.md`, [`wsq-port.md`](wsq-port.md) |
| Fuzzing of every decoder with AddressSanitizer on both Rust and C | [`fuzzing.md`](fuzzing.md) |
| Format detection by content, so a label cannot route data to the wrong decoder | `NistView.ImageFormat` |
| Atoms are never created from input (`String.to_existing_atom` only for known values) | `ViewerLive` |

### Data handling

| Control | Where |
|---|---|
| Files are read into memory only. Browser uploads use an in-memory upload writer instead of LiveView's temporary file | `MemoryUploadWriter` |
| Rendered images are held in ETS, owned by the viewer process and dropped when it exits or opens another file | `NistView.ImageStore` |
| Images are served with `cache-control: no-store`, so the webview does not write them to its disk cache | `ImageController` |
| No writes to disk anywhere in the app. (`mix nist.dump --png` writes files only on explicit request; it is a development tool) | — |
| No database (Ecto and Postgres removed), no mailer, no telemetry upload | — |
| Logs contain request paths, not field values or image bytes; the image token parameter is filtered | Phoenix logger |

### Local access

| Control | Where |
|---|---|
| Phoenix listens on 127.0.0.1 only, on a random port | `config/runtime.exs` |
| Per-launch launch token (32 random bytes from the shell). Without it or a session that presented it: 403 for pages, images and the LiveView socket. DNS-rebinding pages and other local users get 403 | `NistViewWeb.LaunchToken` |
| Per-launch random `secret_key_base` | `config/runtime.exs` |
| `check_origin` limited to 127.0.0.1 | `config/runtime.exs` |
| Strict CSP: `script-src 'self'`, no inline scripts, `frame-ancestors 'none'`, `object-src 'none'` | `NistViewWeb.Router` |
| Windows cannot navigate away from the server origin and have no Tauri IPC | `src-tauri/src/lib.rs` |
| Paths to open come only from the shell, by one-time random id; the dev-only `?path=` is disabled in releases | `NistView.Desktop`, `config/dev.exs` |

Verified on the built release: 403 without the token, a wrong token and for
image URLs; redirect strips the token; CSP header present; `lsof` shows the
socket bound to 127.0.0.1.

## Fuzzing results

Ten-minute campaigns per decoder with AddressSanitizer on the C code
(2026-09-29). Details and how to rerun: [`fuzzing.md`](fuzzing.md).

| Decoder | Result | Action |
|---|---|---|
| NBIS WSQ | Stack buffer overflow in `huffman_decode_data_mem` (unbounded code-length loop over `maxcode[]`), hit by 23 inputs. **Correction (2026-09-30):** the "0 crashes after the patch" result was wrong. The 9 saved inputs in `fuzz/artifacts/wsq/` still crash the patched build: NULL write in `getc_nextbits_wsq` (6), heap overflow in `unquantize` (1), heap overflow in `getc_transform_table` (1), global overflow in `getc_huffman_table_wsq` (1) | First bug patched. The rest are to be fixed by replacing NBIS with a safe-Rust decoder; root causes and plan in [`wsq-port.md`](wsq-port.md) |
| NBIS lossless JPEG | Many bugs: heap buffer overflows (`decode_data`, `getc_byte`, `jpegl_decode_mem`), stack buffer overflow and underflow and a use-after-free in `update_IMG_DAT_decode`, segfaults; 797 crashing inputs in 10 minutes | Replaced by a safe-Rust decoder; NBIS code removed |
| Rust lossless JPEG (new) | 0 crashes in 4.8 million inputs | — |
| Rust WSQ (new, 2026-09-30) | 115 minutes: 0 crashes, timeouts or out-of-memory in 1.5 million inputs. Against NBIS (`wsq_diff`, 115 minutes, 287,000 inputs): no difference in pixels, size or PPI, and no memory error in NBIS on anything the Rust decoder accepts | One finding in the first ten minutes, before the long run: decoding time follows the size a file declares (see Controls). NBIS: seven memory bugs in all; the six that are not patched in the reference each have a regression input |
| OpenJPEG (JPEG 2000) | 0 crashes | Replaced on 2026-09-30 by a safe-Rust decoder, to have no C on untrusted input |
| Rust JPEG 2000 (new, 2026-09-30) | Two minutes, 64,000 inputs: 0 crashes. A two-hour run is in progress | — |
| Header readers (Rust) | 0 crashes in 25 million inputs | — |

Decision (the plan's M5 question): **decode out of process.** The WSQ bug
was found within the first minute, in code that would otherwise have run
inside the BEAM, where a memory error could corrupt state silently rather
than crash.

## Open items

0. ~~Replace NBIS WSQ with safe Rust.~~ Done 2026-09-30
   ([`wsq-port.md`](wsq-port.md)): decoded in safe Rust, identical to NBIS on
   all samples, fuzzed alone and against NBIS.
1. **Sandbox the helper** (defence in depth). No C parses untrusted data
   any more: JPEG 2000 has been decoded by the safe-Rust `hayro-jpeg2000`
   since 2026-09-30 ([`jp2-port.md`](jp2-port.md); the options that were
   weighed are in [`jp2-rust-eval.md`](jp2-rust-eval.md)). A memory-safety
   bug would now have to be in the Rust compiler or standard library. The
   helper still runs with the user's privileges and needs only stdin and
   stdout, so dropping the rest remains worth doing, at lower priority: a
   sandbox profile on macOS, seccomp and landlock on Linux, a job object and
   a restricted token on Windows.
   - Still open from the JPEG 2000 change: the decoder has not run on
     arm64. The fix it needs is carried in our copy of the crate
     (`native/hayro-jpeg2000/PATCHES.md`) and is deliberately not reported
     upstream while this is a proof of concept.
2. **libjpeg-turbo as reference.** Decided: fuzz our lossless JPEG decoder
   differentially against libjpeg-turbo 3.2 (dev-only, not shipped).
   Verified by hand that it decodes the NBIS fixtures identically; the fuzz
   target is not written yet.
3. **Longer fuzzing.** WSQ has had two hours per target; lossless JPEG,
   JPEG 2000 and the header readers only ten minutes, which is a smoke test.
   Run each for hours, and consider OSS-Fuzz-style continuous runs in CI.
4. **Regression inputs.** Done for WSQ: six inputs, one per NBIS bug, in
   `native/nist_codecs/fuzz/regressions/wsq/`, which `NistView.DecoderTest`
   runs. Not done for lossless JPEG: those crash inputs are mutations of
   real BioCTS prints and would have to be minimised first
   (`fuzz/minimise.py`), against a build of the NBIS decoder that was
   removed.
5. **ElixirKit PubSub authentication.** The shell's PubSub socket on
   127.0.0.1 accepts the first connection; a local process racing the
   release could send a fake `ready:` URL, and the shell would put the launch
   token in that URL. Fix: include a shared secret in `ready:` and check it
   in the shell.
6. **Crash reports.** A LiveView crash report can include assigns (file
   bytes, Type-2 text) in the log. Fix: custom `Inspect` for `NistFile`,
   `Field` and `ImageRef` that redacts values and data.
7. **Client event validation.** `select` and `hex_*` events parse integers
   from the client with `String.to_integer`; bad input crashes that LiveView
   process only. Validate and ignore instead.
8. **Signing and notarization.** macOS builds are signed ad hoc; Developer ID
   signing and notarization need the certificates (CI secrets are wired in
   `.github/workflows/desktop.yml`). Windows signing likewise.
9. **Updater.** None. If added, it must be off in restricted builds.
