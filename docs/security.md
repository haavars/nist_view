# NIST Viewer — Security and data handling

Status as of 2026-09-30. What the viewer protects, how, what fuzzing found,
and what is still open.

## What we protect against

1. **Hostile files.** A transaction may be crafted to exploit the parser or
   an image decoder. Decoders are the largest attack surface, especially C.
2. **Leaking biometric data** to disk, logs, caches or other programs.
3. **Other local software** (another user's process, a web page in a
   browser, DNS rebinding) reaching the viewer's local HTTP server.

Out of scope: an attacker who already runs code as the same user, and
network attackers (the viewer makes no network connections).

The viewer runs airgapped, on known data (2026-10-01), so hostile files are
an unlikely threat; the controls against them stay, but further work on them
has low priority.

## Controls in place

### Hostile files

| Control | Where |
|---|---|
| Parser in pure Elixir; records sliced by declared length; parsing is total (errors are values, never crashes) | `NistView.Parser` |
| Property tests: generated transactions round-trip; truncation, corruption and arbitrary bytes never raise | `test/nist_view/parser_property_test.exs` |
| Decoders read the image size from the header and refuse images over 100 megapixels before allocating | `native/nist_codecs/src/headers.rs`, `check_dimensions` |
| JPEG 2000 decoding is also bounded by an estimate of its memory, 2 GiB, which a 100-megapixel colour image would exceed | `native/nist_codecs/src/jp2.rs`, `MAX_DECODE_BYTES` |
| A decode is bounded, not cheap: a WSQ file of a few hundred bytes can declare 100 megapixels and then costs 1 to 3 seconds of CPU and about 1 GB in the helper. The timeout below ends anything slower | [`wsq.md`](wsq.md#speed) |
| **Image decoders run in a separate process** (`nist_decode`), one per image, with a 60 s timeout. A crash or hang is reported, not fatal. The NIF loaded into the BEAM has only PNG encoding and colour conversion | `NistView.Decoder`, `native/nist_decode` |
| **No C parses a file.** WSQ and lossless JPEG are decoded by our own safe-Rust decoders, JPEG 2000 by a patched copy of the safe-Rust `hayro-jpeg2000`. NBIS and OpenJPEG are development-time references only | [`wsq.md`](wsq.md), [`jp2.md`](jp2.md), `native/nist_codecs/src/jpegl.rs` |
| Fuzzing of every decoder with AddressSanitizer | [`fuzzing.md`](fuzzing.md) |
| Format detection by content, so a label cannot route data to the wrong decoder | `NistView.ImageFormat` |
| Atoms are never created from input (`String.to_existing_atom` only for known values) | `ViewerLive` |
| Client events are validated: malformed, out-of-range or unknown events are ignored, not crashed on | `ViewerLive` |

### Data handling

| Control | Where |
|---|---|
| Files are read into memory only. Browser uploads use an in-memory upload writer instead of LiveView's temporary file | `MemoryUploadWriter` |
| Rendered images are held in ETS, owned by the viewer process and dropped when it exits or opens another file | `NistView.ImageStore` |
| Images are served with `cache-control: no-store`, so the webview does not write them to its disk cache | `ImageController` |
| No writes to disk anywhere in the app. (`mix nist.dump --png` writes files only on explicit request; it is a development tool) | — |
| No database (Ecto and Postgres removed), no mailer, no telemetry upload | — |
| Logs contain request paths, not field values or image bytes; the image token parameter is filtered | Phoenix logger |
| Crash reports leave out process state, the last message and stack-trace arguments; fields and images do not show their contents in `inspect`. An exception that itself carries a raw binary or plain map from the file (a `MatchError` on a field's value, say) can still show it, up to the inspect limit | `NistView.LogRedaction`, `NistView.Field`, `NistView.ImageRef` |
| No browser storage: panel sizes last for the window only, since `localStorage` is written to disk. No clipboard copy of field values | `ViewerComponents.splitter/1` |

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
| The shell opens windows only on a `ready:` URL that carries its per-launch secret (constant-time compare) and is `http://127.0.0.1:<port>`. The shell's PubSub socket accepts the first local connection, so without this a process that got there first could have had a viewer window opened on its own page, launch token included | `src-tauri/src/lib.rs`, `NistView.Desktop` |

Verified on the built release: 403 without the token, a wrong token and for
image URLs; redirect strips the token; CSP header present; `lsof` shows the
socket bound to 127.0.0.1; a script that connected to the PubSub socket first
and sent forged `ready:` messages got nothing back and no window opened. What
it can still do is keep the app from starting (it stays up without a window).

## Fuzzing results

With AddressSanitizer. How to run and details: [`fuzzing.md`](fuzzing.md).

| Decoder | Result | Action |
|---|---|---|
| NBIS WSQ (C) | Seven memory bugs reachable from a file: stack, heap and global overflows, a NULL write, a double free, a negative `memcpy` ([wsq.md](wsq.md#why-not-nbis)) | Replaced by our own Rust decoder; NBIS kept as a development reference, one regression input per bug |
| NBIS lossless JPEG (C) | Many: heap and stack overflows, a use-after-free, segfaults; 797 crashing inputs in 10 minutes | Replaced by our own Rust decoder; removed |
| OpenJPEG (C) | No crash in 10 minutes | Replaced anyway, to have no C on untrusted input ([jp2.md](jp2.md)) |
| Rust WSQ | 1.5 million inputs in 115 minutes, and 287,000 against NBIS: no crash, no difference from NBIS | — |
| Rust JPEG 2000 | 2.0 million inputs in 110 minutes: no crash; 18 slow inputs | Slow tag trees, fixed in our copy of the crate ([jp2.md](jp2.md#slow-inputs)) |
| Rust lossless JPEG | 4.8 million inputs: no crash | Only ten minutes; a long run is open |
| Rust header readers | 25 million inputs: no crash | — |

Decision (M5): **decode out of process.** The first WSQ bug was found within
a minute, in code that would otherwise have run inside the BEAM, where a
memory error could corrupt state silently rather than crash.

## Open items

1. **Sandbox the helper** (defence in depth). No C parses untrusted data any
   more, but the helper still runs with the user's privileges and needs only
   stdin and stdout: a sandbox profile on macOS, seccomp and landlock on
   Linux, a job object and a restricted token on Windows.
2. **libjpeg-turbo differential target.** Decided: fuzz the lossless JPEG
   decoder against libjpeg-turbo 3.2 (development only). Checked by hand on
   the NBIS fixtures; the target is not written.
3. **Lossless JPEG regression inputs.** WSQ has them. The lossless JPEG crash
   inputs are mutations of real BioCTS prints and would have to be minimised
   first, against an NBIS build that was removed.
4. **Updater.** None. If added, it must be off in restricted builds.

Done on 2026-09-30, with the reasons in [decisions.md](decisions.md): WSQ and
JPEG 2000 in safe Rust, crash-report redaction, client event validation, and
the `ready:` secret.

Decided on 2026-10-01 ([decisions.md](decisions.md)): **no longer fuzz
runs** (about two hours each for WSQ and JPEG 2000 is enough here; the 18
slow JPEG 2000 inputs take about a second each with the fix), and **no code
signing** (macOS builds are signed ad hoc, Windows builds are unsigned,
releases carry `SHA256SUMS`; install steps in [ci.md](ci.md)).
