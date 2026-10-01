# NIST Viewer — Architecture

How the viewer is built, as of 2026-09-30. Goals and status:
[`plan.md`](plan.md). The file format: [`formats.md`](formats.md). The two
decoders we wrote or patched: [`wsq.md`](wsq.md), [`jp2.md`](jp2.md).
Security: [`security.md`](security.md); fuzzing: [`fuzzing.md`](fuzzing.md);
why things are the way they are: [`decisions.md`](decisions.md).

## Processes

```
┌─ Tauri shell (Rust, src-tauri) ─────────────────────────────────────────┐
│  windows (system webview) → http://127.0.0.1:<random port>/?launch=…   │
│  file associations, argv, second launch → "open" messages               │
└───────┬──────────────────────────────────────────────▲──────────────────┘
        │ starts; env PORT=0, NIST_VIEW_LAUNCH_TOKEN,  │ ElixirKit PubSub
        │ NIST_VIEW_READY_SECRET, ELIXIRKIT_PUBSUB     │ (TCP, loopback)
┌───────▼─────── Elixir release (BEAM) ────────────────┴──────────────────┐
│  Phoenix + LiveView on 127.0.0.1 only                                   │
│  Parser, Minutiae, Viewer, Imaging (pure Elixir)                        │
│  NistView.Codecs NIF: PNG encoding, YCbCr→RGB (safe Rust, no C)          │
└───────┬─────────────────────────────────────────────────────────────────┘
        │ one short-lived process per image, {:packet, 4} over stdio
┌───────▼─────── nist_decode helper (Rust) ───────────────────────────────┐
│  WSQ · lossless JPEG · JPEG 2000: all safe Rust, no C                    │
└─────────────────────────────────────────────────────────────────────────┘
```

In a browser during development (`mix phx.server`), the shell is absent: no
launch token is required and `/?path=…` opens a local file.

## Source layout

| Path | What |
|---|---|
| `lib/nist_view/parser.ex` | ANSI/NIST-ITL parser (tagged and binary records) |
| `lib/nist_view/{nist_file,record,field,image_ref}.ex` | Parsed data structures |
| `lib/nist_view/compression.ex`, `image_format.ex` | Compression labels and format detection from bytes |
| `lib/nist_view/minutiae.ex` | Type-9 minutiae: M1, legacy standard, FBI, EFS |
| `lib/nist_view/field_names.ex`, `positions.ex` | Field mnemonics, finger and palm position names |
| `lib/nist_view/imaging.ex` | Image → displayable PNG or JPEG bytes |
| `lib/nist_view/decoder.ex` | Client for the `nist_decode` helper process |
| `lib/nist_view/codecs.ex` | NIF: `encode_png/4`, `ycbcr_to_rgb/1` |
| `lib/nist_view/image_store.ex` | In-memory store of rendered images (ETS), by random token |
| `lib/nist_view/viewer.ex` | Pure view logic: summary, titles, tenprint, minutiae matching, hex, messages |
| `lib/nist_view/desktop.ex` | Elixir side of the shell: `ready:` URL, paths to open |
| `lib/nist_view/log_redaction.ex` | Logger translator that keeps file contents out of crash reports |
| `lib/nist_view_web/live/viewer_live.ex` | The viewer LiveView |
| `lib/nist_view_web/components/viewer_components.ex` | Its components and the colocated JS hooks (`.ImageViewer`, `.Splitter`, `.Shortcuts`) |
| `lib/nist_view_web/launch_token.ex` | Launch-token plug and `on_mount` hook |
| `lib/nist_view_web/memory_upload_writer.ex` | Keeps uploads in memory |
| `lib/nist_view_web/controllers/image_controller.ex` | Serves `/render/:token` |
| `lib/mix/tasks/` | `nist.dump`, `nist.samples`, `compile.nist_decode` |
| `native/nist_codecs/` | Rust library: decoders, header readers, PNG; NIF behind the `nif` feature |
| `native/nbis_ref/` | NBIS's WSQ decoder, vendored and patched: the reference for the Rust WSQ decoder. Development only |
| `native/hayro-jpeg2000/` | The JPEG 2000 decoder: a copy of the `hayro-jpeg2000` crate with two fixes (`PATCHES.md`) |
| `native/opj_ref/` | OpenJPEG (C) through `jpeg2k`: the reference for the JPEG 2000 decoder. Development only |
| `native/nist_codecs/fuzz/` | cargo-fuzz targets and scripts |
| `native/nist_decode/` | The helper executable |
| `src-tauri/` | The desktop shell |
| `scripts/` | Fixture generators and tools for comparing decoders |
| `test/fixtures/` | Synthetic test data (committed) |
| `test/samples/` | Downloaded or restricted sample files (gitignored) |

## Parsing

`NistView.Parser.parse/1` reads Type-1 first. Its CNT field (1.003) lists
every other record's type and IDC, which decides how each record is read:
tagged records by their `T.001` length, legacy binary records (Type-3 to 8)
by their 4-byte length and fixed layout. Without a usable CNT every record is
read as tagged.

- Records are sliced by declared length, never by searching for separators,
  since image data may contain separator bytes.
- Field values and image data are sub-binaries of the input: nothing is
  copied.
- Parsing is total. Framing errors stop parsing and return the records read
  so far with `{offset, reason}`; problems that keep the framing intact are
  warnings on the file (CNT type or IDC mismatch, malformed field, trailing
  bytes, short binary record, missing FS).
- Each image record gets an `ImageRef` with the label's `compression` and the
  `format` detected from its bytes (`NistView.ImageFormat`), which decoding
  follows.

Details and quirks: [`formats.md`](formats.md).

## Images

`NistView.Imaging.displayable/1` turns an `ImageRef` into bytes for the
webview:

| Format | Path |
|---|---|
| PNG, baseline JPEG | Passed through unchanged; the webview decodes them |
| WSQ | `nist_decode` (`nist_codecs::wsq`, our own, [wsq.md](wsq.md)) → PNG (NIF) |
| JPEG 2000 (JP2, J2K) | `nist_decode` (`nist_codecs::jp2`: `hayro-jpeg2000` with our own 8-bit conversion, [jp2.md](jp2.md)) → PNG |
| Lossless JPEG | `nist_decode` (`nist_codecs::jpegl`, safe Rust) → PNG |
| Uncompressed | 8-bit grey or RGB → PNG |

`Imaging.preview/2` does the same for a large JPEG 2000 image at a reduced
resolution of at least 800 × 800 (`jp2::decode_at`, the helper's `P`
request), skipping the finer wavelet levels: a 3300 × 4400 face decodes at
825 × 1100 in 0.15 s instead of 0.6 to 1.5 s.

YCbCr is converted to RGB in one place (`Imaging`), when the decoder reports
sYCC or the record's colour space field (10.012, 17.013) says YCC or SYCC.
Samples above 8 bits are scaled to 8 for display.

Every decoder reads the image size from its header first (WSQ SOF, JPEG SOFn,
J2K SIZ, JP2 `ihdr`) and refuses images over 100 megapixels before
allocating.

### The decoder helper

`NistView.Decoder.decode(format, data)` starts `priv/native/nist_decode`,
sends one `{:packet, 4}` request (format byte + image), and reads one reply
(dimensions, colour space, pixels, or an error name). A helper killed by a
signal gives `{:error, :decoder_crashed}`; one that exceeds the timeout
(default 60 s) is killed and gives `{:error, :decoder_timeout}`. The
`:compile.nist_decode` Mix compiler builds it with Cargo and copies it into
`priv/native` on every `mix compile`.

## The viewer

`NistViewWeb.ViewerLive` at `/`:

- **Opening:** drag and drop, file picker (LiveView upload with
  `MemoryUploadWriter`, so no temporary file), `/?open=<id>` from the shell,
  `/?path=…` in development.
- **State:** the file binary and parsed `NistFile` live in the LiveView
  process. The record, field and hex lists are LiveView streams; their
  containers stay in the DOM while hidden, because stream items are not kept
  on the server. Every event checks its parameters and ignores anything
  malformed, out of range or sent with no file open.
- **Rendering:** images are decoded in `start_async` tasks, keyed by a
  generation counter so results for a previously open file are dropped.
  The selected record (or every finger in the tenprint view) is decoded at
  once; a large JPEG 2000 image first as a preview, then in full. After
  that the file's other images are decoded ahead, at most two at a time.
  The bytes go to `ImageStore` under a random token, owned by the LiveView
  process and dropped when it exits; `/render/:token` serves them with
  `cache-control: no-store`. A full image keeps its preview's URL.
- **Image in the page:** the `.ImageViewer` hook places the `<img>` itself
  (the server sends the URLs, the full size and a key for file and record
  on `#viewer-stage`). It shows a preview while the full image loads, and
  keeps the last eight loaded images in memory, so going back to a record
  needs no fetch.
- **Layout:** a header (file name and Type-1 facts), the record list, and the
  selected record: its image with a toolbar strip above and a strip for the
  minutiae legend and pixel readout below, then the fields or hex panel. A
  status bar at the bottom. The record list and the fields panel are resized
  by `.Splitter` handles, which set CSS variables on the document element;
  the sizes last for the window and are not stored, since browser storage
  is written to disk.
- **Image viewer hook** (`.ImageViewer`): zoom (fit, 1:1, 2:1, wheel around
  the cursor), pan, invert, contrast, brightness, gamma (SVG filter), pixel
  readout in px, mm and value. The stage's `style` is set by the hook and
  excluded from patches with `JS.ignore_attributes/1`.
- **Keys:** ↑/↓ or `j`/`k` for records (server side); `f 1 2 + - i r m` in the
  image viewer; `?` opens the shortcuts panel (`.Shortcuts`).
- **Fields:** number, mnemonic and value; repeated subfields (such as 9.012
  MRC or 1.003 CNT) as a table with one row per subfield. Binary fields open
  in the hex view.
- **Minutiae overlay:** SVG in image pixels from every Type-9 block with the
  image record's IDC, converted with the image's resolution and height.
- **Tenprint card:** Type-4 and Type-14 positions 1–10 and 11–15.

## Desktop shell

`src-tauri/src/lib.rs`:

1. Listens on an ElixirKit PubSub socket and starts the Elixir release
   (`mix phx.server` in `cargo tauri dev`) with `PORT=0`, a 32-byte random
   `NIST_VIEW_LAUNCH_TOKEN`, a 32-byte random `NIST_VIEW_READY_SECRET` and
   `ELIXIRKIT_PUBSUB`.
2. `NistView.Desktop` broadcasts `ready:<secret> http://127.0.0.1:<port>`
   once the endpoint listens. The shell checks the secret and that the URL
   is on 127.0.0.1, takes the first such message only, and opens a window on
   `<url>/?launch=<token>`.
3. Files from macOS `Opened` events, argv (Windows, Linux) and second
   launches (single-instance plugin) are queued until ready, then sent as
   `<id>\n<path>` on the `open` topic, each followed by a window on
   `/?open=<id>`.
4. Windows cannot navigate away from the server's origin, have the Tauri
   drag-and-drop handler off (so drops reach the page) and no Tauri IPC.

The release is built by `mix desktop.release` (always `MIX_ENV=prod`,
ElixirKit codesigning on macOS) into `src-tauri/target/rel`, which Tauri
bundles as a resource.

## Build and toolchain

- Versions in `.tool-versions`: Erlang 28.3, Elixir 1.19.4-otp-28, Rust 1.98.1.
- `mix compile` builds the NIF (Rustler 0.38) and the helper (Cargo).
- `mix precommit`: compile with warnings as errors, format, Elixir tests,
  Rust tests.
- Desktop: `cd src-tauri && CI=true cargo tauri build` (see README).
- No database: Ecto, Postgres, Swoosh and DNSCluster were removed.

## Testing

- **Test data**, in three tiers:
  - `test/fixtures/`: synthetic, committed. A phantom-style enrolment
    (Type-1, 2, 10, 14, 15 in PNG, WSQ20 and JPEGB, built with phantom's own
    record builders by `scripts/phantom_enrol.exs`) and synthetic WSQ,
    lossless JPEG and JPEG 2000 images.
  - `test/samples/biocts/`: NIST's 96 BioCTS files, fetched by
    `mix nist.samples` (gitignored: real people's prints and faces). Tests
    that need them are skipped without them.
  - Prüm `.eml` transactions: restricted, never committed, local only. Not
    yet run.
- **Parser:** unit tests per record type, and StreamData properties:
  generated transactions round-trip, and truncation, corruption and
  arbitrary bytes never raise. All 96 BioCTS files parse.
- **Decoders:** Rust unit tests; differential tests against the references
  (`nbis_ref` for WSQ, `opj_ref` for JPEG 2000); pinned hashes of decoded
  sample images in `test/nist_view/biocts_sample_test.exs`, which also
  checks that every image in every sample file displays; regression inputs
  from fuzzing (`native/nist_codecs/fuzz/regressions/`).
- **Viewer:** LiveView tests for opening, navigation, hex, tenprint,
  minutiae, bad events and crash-report redaction. Screenshots with
  headless Chrome for layout; a manual smoke test in the built app.
