# NIST Viewer — Plan

A cross-platform desktop viewer for ANSI/NIST-ITL transaction files (`.nst`, `.an2`, `.eft`). It loads a file and shows every record: fingerprints, faces, latents, palms and minutiae, plus all text fields.

Stack: **Elixir/Phoenix LiveView** for the UI and parsing, **one Rust NIF** for image codecs, and **Tauri + ElixirKit** as the desktop shell.

Related documents: [architecture](architecture.md) (how it is built), [formats](formats.md) (the file format as implemented), [security](security.md) (controls, fuzzing results, open items), [fuzzing](fuzzing.md) (how to fuzz), [decisions](decisions.md) (decision log), [wsq-port](wsq-port.md) (safe-Rust WSQ: research and plan), [jp2-rust-eval](jp2-rust-eval.md) and [jp2-port](jp2-port.md) (JPEG 2000 in safe Rust: the evaluation and the change).

---

## 1. Goals and non-goals

**Goals**
- Open any ANSI/NIST-ITL file in traditional (binary/tagged) encoding, versions 0300–0600. Known producers: Prüm exchange traffic, INT-I 4.22-era files (`VER 0300`), and `0502` files from phantom and abis_next.
- Show the record structure as a tree: Type-1 → logical records → fields → subfields → items.
- Render every image-bearing record, whatever compression it uses.
- Overlay Type-9 minutiae on the matching fingerprint image.
- Ship native builds for macOS (arm64, x86_64), Linux (x86_64, aarch64) and Windows (x64).
- Display only: no biometric data is written to disk.

**Non-goals (v1)**
- Editing or writing NIST files.
- XML encoding (ANSI/NIST-ITL 2-2008 / NIEM). Note: INTERPOL INT-I v6.00.01 (2020) is XML only, so current INT-I files will need this later.
- Validation against domain rules (EBTS, INT-I conformance). Possible later.
- Matching, quality scoring (NFIQ) or any analysis.
- Opening S/MIME or `.eml` envelopes. The input is the NIST file itself.

---

## 2. Record and codec coverage

| Record | Content | Encoding | Image compression | Seen in real files |
|---|---|---|---|---|
| Type-1 | Transaction info | Tagged ASCII | — | All |
| Type-2 | Descriptive text | Tagged ASCII | — | All |
| Type-4 | High-res greyscale fingerprint | Binary, 18-byte header | GCA byte: 0 = none (raw 8-bit), 1 = WSQ | Prüm CPS (14 records per tenprint) |
| Type-9 | Minutiae | Tagged ASCII | — | Prüm MMS/MPS (INCITS 378 / M1); abis_next (EFS) |
| Type-10 | Face / SMT / photo | Tagged + binary 999 | JPEGB, JPEGL, JP2, JP2L, PNG, NONE | phantom (PNG, JPEGB) |
| Type-13 | Latent friction ridge | Tagged + binary 999 | NONE, WSQ20, JPEGB, JPEGL, JP2, JP2L, PNG | Prüm MMS/MPS (`WSQ`); abis_next (PNG) |
| Type-14 | Variable-res fingerprint | Tagged + binary 999 | same as Type-13 | BioCTS (WSQ); phantom (PNG, WSQ20) |
| Type-15 | Palm | Tagged + binary 999 | same as Type-13 | phantom (PNG, WSQ20) |
| Type-17 | Iris | Tagged + binary 999 | NONE, JPEGB, JP2, JP2L, PNG | — |
| Type-18 | DNA | Tagged ASCII | — (text only) | — |
| Others (3, 5–8, 16, 19–22, 98, 99) | Various | Tagged/binary | Parsed and shown as fields; image shown if the codec is supported | — |

**Compression labels.** Real files use older spellings than the 2011 table: Prüm Type-13 records say `WSQ`, not `WSQ20`. Normalise the `.011` CGA value to a codec atom and accept every known alias: `WSQ`/`WSQ20` → `:wsq`, `JPEGB` → `:jpegb`, `JPEGL` → `:jpegl`, `JP2` → `:jp2`, `JP2L` → `:jp2l`, `PNG` → `:png`, `NONE` → `:raw`. For Type-4, map the GCA byte instead. An unknown label shows the record's fields and a "compression not supported" placeholder.

**Minutiae blocks (Type-9).** Two blocks occur in practice and both are v1:
- **INCITS 378 / M1** (fields 9.126–9.150), used by the real Prüm latent and print searches.
- **EFS** (fields 9.300–9.399, minutiae in 9.331), written by abis_next. Units are 10 µm from the ROI's top-left corner, and the angle is in degrees counter-clockwise from +X.

The legacy standard fields 9.005–9.012 and vendor blocks are shown as fields only.

**Unknown or non-standard fields** (e.g. phantom's `14.901` / `15.901`) are shown as generic fields, never rejected.

Codecs (all in v1): WSQ, PNG, JPEG baseline, raw greyscale and RGB, JPEG 2000 (lossy and lossless), JPEG lossless.

---

## 3. Architecture

```
┌──────────────────────────── Tauri shell (Rust) ────────────────────────────┐
│  Native window (WRY webview), menus, file-open dialog, drag-drop,           │
│  single-instance, deep link / file association                              │
│                                                                             │
│   ┌──────────── WebView ────────────┐        ElixirKit PubSub               │
│   │  LiveView UI                    │◄──────── (open-file events) ────┐      │
│   └────────────┬────────────────────┘                                 │      │
└────────────────┼──────────────────────────────────────────────────────┼──────┘
                 │ ws://127.0.0.1:<random port>                          │
┌────────────────▼───────────────── Elixir release (sidecar) ────────────┴─────┐
│  NistView.Parser      pure Elixir, binary pattern matching                  │
│  NistView.Records     typed structs per record type                         │
│  NistView.Imaging     dispatch on compression → codec → PNG bytes in memory │
│  NistView.Minutiae    Type-9 → overlay coordinates                          │
│  NistViewWeb.*        LiveView pages and components                         │
│                                                                             │
│  nist_codecs (Rust NIF, dirty CPU scheduler)                                │
│    ├─ WSQ decode         NBIS C (vendored, built with `cc`)                 │
│    ├─ JPEG lossless      NBIS jpegl (vendored) or Rust crate                │
│    ├─ JPEG 2000          `jpeg2k` crate                                     │
│    ├─ JPEG baseline      `jpeg-decoder` / `zune-jpeg`                       │
│    └─ PNG encode/decode  `png` crate                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Parser (pure Elixir)
- Start from abis_next's `AbisNext.Nist.Record` and `AbisNext.Nist.File` (`~/repos/abis_next/lib/abis_next/nist/`), which already parse real Prüm and BioCTS files correctly. Copy the code instead of sharing it, as phantom did. Changes needed:
  - Return a partial result instead of failing the whole file (see "Parsing is total" below).
  - Decode Type-4's 18-byte header (IDC, IMP, FGP, ISR, HLL, VLL, GCA) instead of returning it as opaque bytes.
  - Split field values into subfields (RS) and items (US) for the tree view.
  - Drop the encode side, including the fixed-point `LEN` calculation. v1 only reads files.
- Type-1 first: read `1.003` (CNT) to get the ordered list of record types and IDCs. That list drives how the rest of the file is parsed. It is required, not optional: legacy binary records (Type-4–8) have no tag, so CNT is the only way to know one comes next. Without a usable CNT, fall back to tag-only parsing, which works for files that are all tagged records.
- Tagged records: split on the separators FS `0x1C` (record), GS `0x1D` (field), RS `0x1E` (subfield) and US `0x1F` (item). Read the `n.001` LEN field first so the binary `n.999` field is sliced by length, not by scanning for separators.
- Binary Type-4 (big-endian):
  ```elixir
  <<len::32, idc, imp, fgp::binary-6, isr,
    hll::16, vll::16, gca, img::binary-size(len - 18), rest::binary>>
  ```
- Output: `%NistFile{records: [%Record{type, idc, fields, image: nil | %ImageRef{}}]}`. Keep image bytes as sub-binaries of the original, with no copying.
- Parsing is total: malformed input gives `{:error, {offset, reason}}` along with whatever records were parsed up to that point, so the UI can still show a partial file.
- *Built in M0* (`NistView.Parser`): problems that don't break framing are warnings on the file instead of errors. These are a CNT type or IDC mismatch, a malformed field (the rest of that record is dropped), trailing bytes, and a binary record shorter than its header. Checked against all 96 BioCTS files.

### 3.2 Codecs (`nist_codecs`, `nist_decode`)
Revised in M5; details in [architecture.md](architecture.md#images).
- **Rust library** `native/nist_codecs`: the decoders, header readers and PNG encoding. Its NIF (`NistView.Codecs`, behind the default `nif` feature) exposes only safe Rust: `encode_png/4` and `ycbcr_to_rgb/1`.
- **Decoding runs out of process**, in the `nist_decode` helper (`native/nist_decode`, built by the `:nist_decode` Mix compiler), one process per image through `NistView.Decoder`: `decode(:wsq | :jpegl | :jp2, bytes) :: {:ok, %{width, height, channels, bit_depth, ppi, colorspace, pixels}} | {:error, reason}`. Crashes and timeouts become errors.
- **WSQ:** our own safe-Rust decoder (`src/wsq.rs`), since 2026-09-30. It follows NBIS 5.0.0's behaviour, and its output is identical to NBIS built without fused multiply-add. NBIS's decoder had memory bugs and is kept only as the test reference (`native/nbis_ref`, development only). Details: [wsq-port.md](wsq-port.md).
- **Lossless JPEG:** our own safe-Rust decoder (`src/jpegl.rs`). NBIS's decoder had many memory bugs and was removed. libjpeg-turbo 3.2 is the reference for testing (dev-only).
- **JPEG 2000:** the safe-Rust `hayro-jpeg2000` crate, a copy with two fixes (`native/hayro-jpeg2000/PATCHES.md`), and our own 8-bit conversion, since 2026-09-30. Lossless output is identical to OpenJPEG's; lossy output is within 1 in a fraction of a percent of samples. OpenJPEG is kept as the test reference (`native/opj_ref`, development only). Details: [jp2-port.md](jp2-port.md).
- Every decoder reads the header first and refuses images over 100 megapixels.
- **Toolchain:** Rust 1.98.1 and Rustler 0.38 (`.tool-versions`).
- **Distribution:** built from source for now. Consider `rustler_precompiled` later; for offline builds, compile from source or use an internal artefact store.

### 3.3 UI (LiveView)
- Left pane: record tree (Type → IDC → fields), with the field number, mnemonic name and value.
- Main pane: the decoded image, with zoom (fit / 1:1 / 2:1), pan, invert, contrast/gamma, pixel-inspection readout and resolution in ppi.
- Fingerprint grid view: all Type-4/14 finger positions laid out as a 10-print card.
- Minutiae overlay: SVG layer from Type-9 (position, angle, type), toggleable. Shown only when the Type-9 record references the same IDC/finger position.
- Hex view of any field or record for debugging.
- Images are delivered as in-memory `data:` URIs or served from an ETS-backed route keyed by a random per-session token. Nothing is written to disk.
- PNG and baseline JPEG go to the webview unchanged, since it decodes them itself. WSQ and uncompressed images are decoded and re-encoded as PNG (`NistView.Imaging.displayable/1`). Invert, gamma and pixel readout can run in the browser on the displayed image.

### 3.4 Desktop shell (Tauri + ElixirKit)
- Follow the ElixirKit "Building Desktop Apps with Tauri" guide: Tauri starts the Elixir release as a child process, and they talk over ElixirKit PubSub.
- Phoenix binds to `127.0.0.1` on a random port, with a per-launch secret checked on the socket connect.
- Tauri plugins: single-instance, dialog (file open), deep-link/file association for `.nst/.an2/.eft`, updater (optional).
- A strict CSP in the webview. No remote origins.

---

## 4. Security and data handling
Details, fuzzing results and open items: [security.md](security.md).
- No network access beyond loopback. No telemetry, no crash-report upload, no auto-update.
- Files and rendered images stay in memory: in-memory uploads, an ETS image store owned by the viewer, `no-store` responses. Nothing is written to disk.
- Local access is gated by a per-launch token; the server binds to loopback only; the CSP is strict.
- **Untrusted input.** Decided in M5, after fuzzing found a memory error in NBIS WSQ within a minute: C decoders run out of process (`nist_decode`), and no C code runs in the BEAM. Next: sandbox the helper.
- Logs contain no field values from Type-2 and no image bytes, and crash reports leave out process state, messages and arguments.

---

## 5. Build and distribution

| Target | Runner | Notes |
|---|---|---|
| macOS arm64 | macos-14 | Sign and notarize |
| macOS x86_64 | macos-13 | Or universal binary |
| Linux x86_64 | Ubuntu 22.04 | webkit2gtk-4.1; build on 22.04 for glibc compatibility; .deb and AppImage |
| Linux aarch64 | Ubuntu 22.04 arm64 | Same |
| Windows x64 | windows-latest | MSI/NSIS; code signing |

- Each target builds natively: NIF (`cargo`), Elixir release (`mix release`, including ERTS) and Tauri bundle (`cargo tauri build`).

---

## 6. Testing
- **Reference data**, in three tiers:
  - **Synthetic, committed:** files generated by phantom (`~/repos/phantom`, NIST export page, or a planned `mix biometrics.export_nist`). They cover Type-1, 2, 10, 14 and 15, in PNG, WSQ20 and JPEGB. They are marked as synthetic in Type-2 `2.004`. Only small subjects are kept (a full PNG export is ~33 MB; WSQ is ~3–8 MB).
  - **Public, fetched:** NIST BioCTS conformance samples. `mix nist.samples` downloads all 96 traditional-encoding files into the gitignored `test/samples/biocts/` (not `priv/`, which ends up in releases). They cover Type-1/2/4/7/8/9 (legacy, M1 and EFS)/10/13–21/98/99, with WSQ, JPEGB, JPEGL, JP2, JP2L, PNG and NONE images.
  - **Restricted, local only:** real Prüm exchange transactions (MMS, MPS, CPS), delivered as base64 attachments in `.eml` files. Kept in a gitignored folder and never committed. Tests pull out the attachment with a small MIME helper (see abis_next's `test/support/nist_eml.ex`) and are skipped when the folder is missing.
- **Expected results from real files** (asserted by abis_next's tests, to reproduce here):
  - MMS/MPS: Type-1, 2, 9 (M1 fields 9.126+) and 13 (`13.011 = WSQ`).
  - CPS: Type-1, 2 and 14 distinct Type-4 records.
  - BioCTS `pass-type-14-mandatory-only.an2`: the WSQ payload matches the source bytes exactly.
  - Phantom files: NBIS `an2ktool -print all` output as a reference.
- **Parser:** unit tests per record type; property-based tests (StreamData) that generate files, round-trip the structure and truncate or corrupt them at random offsets.
- **Codecs:** WSQ output compared pixel for pixel against NBIS `dwsq`. JPEG 2000 compared against `opj_decompress`. `cargo fuzz` targets for every decoder entry point.
- **UI:** LiveView tests for tree navigation and image switching. A manual smoke test on each OS per release.

---

## 7. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Spike ✅ (BioCTS and phantom; Prüm samples still to run) | CLI (`mix nist.dump file.nst`) prints the record tree for the Prüm samples (including the all-Type-4 CPS file) and a phantom enrolment; one WSQ Type-4 image decodes to PNG |
| M1 | Parser complete ✅ (Prüm samples still to run) | All record types in §2 parse; the BioCTS set, the Prüm samples and phantom files parse without error; M1 and EFS minutiae decode; property tests pass |
| M2 | Codecs complete ✅ | WSQ, JPEGB, JPEGL, JP2/JP2L, PNG and raw all decode, with bit-exact WSQ results against NBIS |
| M3 | Viewer UI ✅ | Record tree, image pane, 10-print grid and minutiae overlay working in the browser (`mix phx.server`) |
| M4 | Desktop packaging ✅ macOS arm64 (CI for the other targets untested) | Tauri + ElixirKit app opens files via dialog, drag-drop and file association; CI produces bundles for all five targets |
| M5 | Hardening (in progress: fuzzing ✅, out-of-process ✅, WSQ in Rust ✅ ([wsq-port.md](wsq-port.md)), JPEG 2000 in Rust ✅ ([jp2-port.md](jp2-port.md#where-to-continue)), security review partly; signing blocked on certificates) | Fuzzing done; decision on moving codecs out of process; signing and notarization; security review of data handling |
| M6 | Performance | Make sure loading images is fast and as optimized as possible. 

---

**M0 status (2026-09-29).**
- Done:
  - `mix nist.dump FILE [--decode] [--png DIR] [--full]` prints the record tree.
  - All 96 BioCTS files parse, including three all-Type-4 tenprint cards.
  - All 134 WSQ images in them decode through the NIF.
  - 43 tests; the BioCTS suite is skipped when the samples are missing.
- A phantom-style enrolment built with phantom's own record builders (`test/fixtures/phantom_enrol.an2`, from `scripts/phantom_enrol.exs`) parses without warnings. phantom has no generated subjects on disk, so the images are synthetic.
- Not yet run: the Prüm `.eml` samples (not on this machine).
- Seen in the BioCTS set but not decodable yet: JP2 (12 images), JP2L (22) and JPEGL (2). This makes JPEG 2000 more likely to be needed in v1 than §2 assumed.

**M1 status (2026-09-29).**
- `NistView.Minutiae` decodes four Type-9 blocks: M1, legacy standard (9.005–9.012), FBI/IAFIS (9.014–9.023) and EFS. All four are normalised to millimetres plus an origin, with angles in the INCITS 378 convention.
- The conventions were derived, not assumed. BioCTS encodes one print in three blocks; after normalisation they agree within 1 px and 1°, and a sample test covers this. Two conventions differ from M1:
  - the legacy block's origin is bottom-left
  - its angles are rotated 180°
- EFS angles are assumed to match M1. No available file has EFS minutiae, and abis_next's writer is unverified here.
- StreamData properties: generated transactions round-trip, and truncation, corruption and arbitrary bytes never raise.
- Still to run: the Prüm samples, whose Type-9 is M1.

**M2 status (2026-09-29).**
- **WSQ:** all 47 distinct WSQ images in the BioCTS set decode bit-identically to NBIS 5.0.0 `dwsq`, built from the same release. *(2026-09-30: only when both are built by clang on arm64 with FMA contraction; see [wsq-port.md](wsq-port.md#nbis-output-depends-on-the-compiler-fma).)*
- **JPEG 2000:** `jpeg2k` 0.10 with the bundled OpenJPEG. All 12 distinct JP2/JP2L images in BioCTS decode bit-identically to `opj_decompress` 2.5.4. They are all 8-bit greyscale or sRGB.
  - Components are converted to 8-bit by our own code, not the crate's `get_pixels`. This handles signed samples, precisions above 8 bits (scaled), subsampled components (replicated) and sYCC.
  - CMYK and e-sYCC are refused.
- **Lossless JPEG:** the NBIS `jpegl` decoder, vendored like WSQ, plus a C wrapper that interleaves and upsamples the component planes. *(Replaced in M5 by a safe-Rust decoder after fuzzing found memory errors; see M5 status.)*
  - BioCTS has no real lossless JPEG. Its two `JPEGL` records hold baseline JPEG.
  - Coverage comes from synthetic fixtures made with NBIS `cjpegl`: greyscale, RGB and 4:2:0 YCbCr, all decoded exactly.
- **Format detection:** `NistView.ImageFormat` reads the data's signature, and decoding follows the bytes, not the label.
  - BioCTS has four mislabelled images: two `JPEGL` that are baseline JPEG, and two `JPEGB` in a `fail-*` file that are WSQ.
  - Uncompressed (`NONE`) images are never overridden, since pixel data could start with a signature by chance.
- **YCbCr:** converted to RGB in one place (`NistView.Imaging`), when the decoder reports sYCC or the record's colour space (10.012/17.013) says YCC or SYCC.
- **Size limits:** every decoder reads dimensions from the header first (WSQ SOF, JPEG SOFn, J2K SIZ, JP2 `ihdr`) and refuses images over 100 megapixels.
- **Tests:** sample tests pin SHA-256 hashes of `dwsq` and `opj_decompress` output and check that every image in all 96 BioCTS files displays. Synthetic lossless fixtures check exact pixels, including 16-bit scaling.

**M3 status (2026-09-29).** `NistViewWeb.ViewerLive` at `/` (`mix phx.server`).
- **Opening a file:** drag and drop or a file picker. `NistViewWeb.MemoryUploadWriter` keeps the upload in memory; LiveView's default writer would put it in a temporary file.
- **Record tree:** type, position name, IDC and image summary for each record, arrow keys or `j`/`k` to move, parse errors and warnings in plain language.
- **Fields panel:** field number, mnemonic, and every subfield with its items. There is a hex view of the whole record (file offsets, 4 KB pages) or of one binary field.
- **Image viewer** (a colocated hook, all client-side):
  - fit, 1:1, 2:1 and wheel zoom around the cursor, drag to pan
  - invert, contrast, brightness and gamma (SVG filter)
  - a pixel readout in pixels, millimetres and grey or RGB value
  - keys `f 1 2 + - i r m`
- **Minutiae overlay:** SVG from the Type-9 records with the same IDC. Endings, bifurcations and other minutiae are drawn with direction ticks, plus cores and deltas, a legend and a toggle.
- **Tenprint card:** rolled 1–10 and plain 11–15, which select the record when clicked.
- **Images** are rendered asynchronously and kept in `NistView.ImageStore`: ETS, random tokens, dropped when the LiveView exits. They are served from `/render/:token` with `cache-control: no-store`, so they don't end up in the browser's disk cache.
- **Development only:** `/?path=/file.an2` opens a local file (`config :nist_view, open_path_param: true` in `dev.exs`).
- **Checked:** by screenshot with headless Chrome on BioCTS files (M1 overlay, the Type-4 tenprint card, a 3300 × 4400 JPEG 2000 face, a truncated file, warnings) and by LiveView tests.
- **Build note:** macOS 27 kills the standalone Tailwind 4.1.12 binary (exit 137) because its ad-hoc signature no longer matches. After `mix assets.setup`, run `codesign --force --sign - _build/tailwind-macos-arm64-4.1.12`.

**M4 status (2026-09-29).** `src-tauri/` holds a Tauri 2 shell built on ElixirKit.
- **Result:** `CI=true cargo tauri build` produces `NIST Viewer.app` (41 MB) and a DMG (16 MB) for macOS arm64. Both are signed ad hoc; there's no Developer ID yet.
- **Starting the server:**
  - The shell starts the Elixir release (`mix phx.server` under `cargo tauri dev`) with `PORT=0`, `NIST_VIEW_LAUNCH_TOKEN` (32 random bytes per launch) and `ELIXIRKIT_PUBSUB`.
  - `NistView.Desktop` reports `ready:<url>` once the endpoint listens.
  - The shell opens a window on `<url>/?launch=<token>`.
- **Security:**
  - `NistViewWeb.LaunchToken` (a plug, plus `on_mount` for LiveView) returns 403 to anything without the token or a session that presented it. That covers pages, `/render/:token` images and the LiveView socket.
  - Phoenix listens on 127.0.0.1 only.
  - The CSP is strict (`script-src 'self'`); the root layout's inline theme script was removed.
  - Windows can't navigate away from the server origin and have no Tauri IPC.
- **Opening files:**
  - Drag and drop and the file picker work inside the webview. The Tauri drag-and-drop handler is off, so drops reach the page.
  - File associations for `.an2 .nst .eft .nist`: macOS `Opened` events, argv on Windows and Linux, and a second launch through the single-instance plugin.
  - Each file is sent as `<id>\n<path>` on the `open` topic and gets its own window on `/?open=<id>`. Only the shell can register paths.
- **Ecto, Postgres, Swoosh and DNSCluster removed.** A desktop viewer needs no database.
- **Checked:**
  - The release, run from inside the `.app` (its path contains a space), serves pages and digested assets.
  - It refuses requests without the token and binds to loopback only.
  - The NIF decodes JPEG 2000 in prod.
  - Tests cover the launch token and opening by id, both before and after the window connects.
- **Not yet checked:**
  - The CI workflow (`.github/workflows/desktop.yml`, five targets through `tauri-action`) has never run.
  - Windows is the biggest risk: the vendored NBIS C sources have not been compiled with MSVC. *(2026-09-30: no longer part of the build. Since the JPEG 2000 change there is no C in the build at all, apart from what Tauri and the Erlang runtime bring.)*
  - The file association flow is untested on a real double-click; it needs the app installed.

**M5 status (2026-09-29, in progress).** Full details: [security.md](security.md), [fuzzing.md](fuzzing.md).
- **Fuzzing:** cargo-fuzz targets for WSQ, lossless JPEG, JPEG 2000 and the header readers, with AddressSanitizer on the C code too (`native/nist_codecs/fuzz`).
  - NBIS WSQ: one stack overflow, patched. *Correction (2026-09-30):* not clean afterwards; four more bugs still crash it. See [wsq-port.md](wsq-port.md).
  - NBIS lossless JPEG: many heap and stack overflows, a use-after-free and segfaults.
  - OpenJPEG and the Rust code: no crashes.
- **Decision:** decode out of process. The `nist_decode` helper runs one process per image with a timeout. The NIF has no C left.
- **WSQ (2026-09-30):** a safe-Rust decoder replaces NBIS in the helper, as for lossless JPEG. Identical pixels to NBIS on all 136 BioCTS WSQ streams, three times as fast, and fuzzed for two hours alone (1.5 million inputs) and two hours against NBIS (287,000 inputs) without a finding.
- **JPEG 2000 (2026-09-30):** the safe-Rust `hayro-jpeg2000` crate, patched, replaces OpenJPEG, so the helper has no C at all. Lossless identical to OpenJPEG, lossy within 1; the same pixels on x86_64 and arm64. Fuzzed for 110 minutes (2 million inputs) without a crash; the slow inputs it found came from a quadratic loop in the crate, fixed in our copy ([jp2-port.md](jp2-port.md#slow-inputs)).
- **Lossless JPEG:** a new safe-Rust decoder replaces NBIS.
  - Pixel-identical on the fixtures, which libjpeg-turbo 3.2 also decodes identically.
  - 4.8 million fuzz inputs without a crash.
  - NBIS-produced files need the table-class quirk handled (see [formats.md](formats.md)).
- **Security review:** the controls in place are documented and checked on the built release.
- **Still to do** (see [security.md](security.md#open-items)):
  - the libjpeg-turbo differential fuzz target
  - longer fuzz runs for lossless JPEG, and JPEG 2000 again with the tag-tree fix (WSQ has had two hours per target)
  - minimised regression inputs for lossless JPEG (WSQ has them)
  - a sandbox for the helper, now defence in depth
  - Developer ID signing and notarization, and Windows signing (need certificates)

## 8. Open questions
1. ~~Which record types and compressions actually occur?~~ *Partly answered (§2):* Type-4, 9, 10, 13, 14 and 15, with WSQ, PNG and JPEGB. JPEG 2000 and JPEGL are now supported anyway. Still open: do the files we need to view contain Type-17 iris?
2. ~~Which Type-9 minutiae block?~~ *Answered for Prüm:* INCITS 378 / M1. abis_next writes EFS. Still open: which block INT-I 4.22 files use, and whether we will see vendor-specific blocks.
3. Will we need current INT-I v6 files? They are XML only (see the non-goals).
4. Which platforms are really needed? Is Windows in scope, and is macOS only for development?
5. Code-signing certificates and the internal distribution channel for the restricted network.
6. Is a NIF acceptable for the C codecs, or is out-of-process decoding required from day one?

---

## 9. References
- ANSI/NIST-ITL 1-2011 (Update 2015) and NIST reference data: https://www.nist.gov/itl/iad/image-group/ansinist-itl-standard-references
- NBIS (WSQ, JPEGL, AN2K): https://www.nist.gov/services-resources/software/nist-biometric-image-software-nbis
- Prior work: `~/repos/abis_next/docs/nist_import_export_plan.md` (codec design, verification against real files), `~/repos/phantom/docs/nist-export-plan.md` and `phantom_an2_unify_import.md` (field values, Type-10/15, Unify constraints)
- INTERPOL ANSI/NIST XML implementation: https://github.com/INTERPOL-Innovation-Centre/ANSI-NIST-XML-ITL-Implementation
- `jpeg2k` crate: https://crates.io/crates/jpeg2k
- ElixirKit + Tauri guide: https://hexdocs.pm/elixirkit/tauri.html
- Rustler / rustler_precompiled: https://hexdocs.pm/rustler_precompiled