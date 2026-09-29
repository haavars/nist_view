# NIST Viewer — Plan

A cross-platform desktop viewer for ANSI/NIST-ITL transaction files (`.nst`, `.an2`, `.eft`). It loads a file and shows every record: fingerprints, faces, latents, palms and minutiae, plus all text fields.

Stack: **Elixir/Phoenix LiveView** for the UI and parsing, **one Rust NIF** for image codecs, and **Tauri + ElixirKit** as the desktop shell.

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

Codecs, in priority order:
1. **v1 (seen in real files):** WSQ, PNG, JPEG baseline, raw greyscale.
2. **Later (in the standard, not seen yet):** JPEG lossless, JPEG 2000 (lossy and lossless).

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

### 3.2 Codecs (`nist_codecs` Rust NIF)
- API (all run on dirty CPU schedulers), as built in M0 (`NistView.Codecs`):
  - `decode_wsq(bytes) :: {:ok, %{width, height, channels, bit_depth, ppi, pixels}} | {:error, reason}`. Further decoders follow the same shape, and `NistView.Imaging` dispatches on the compression.
  - `encode_png(pixels, width, height, channels) :: {:ok, binary} | {:error, reason}`
- WSQ and JPEGL come from vendored NBIS sources (public domain), compiled via `cc` in `build.rs`. For WSQ that is 23 files from NBIS 5.0.0 (`native/nist_codecs/vendor/nbis/README.md`). Findings:
  - `__NBISLE__` must be defined on little-endian targets.
  - The WSQ decoder keeps its tables in globals, so calls are serialised with a mutex.
  - NBIS prints errors to stderr; a force-included header routes them to a no-op.
  - The WSQ frame header is read in Rust first, so images over 100 megapixels are refused before NBIS allocates.
  - NBIS `exit()`s only when `malloc` fails.
- Toolchain: the local Rust is 1.85, so rustler is pinned to 0.37 (0.38 needs 1.91), and release stripping is off, because the macOS 27 loader rejects dylibs stripped by that toolchain ("mis-aligned LINKEDIT string pool").
- JPEG 2000: `jpeg2k` with the default `openjpeg-sys` backend. Evaluate its optional pure-Rust `openjp2` backend to remove the C dependency.
- Distribution: `rustler_precompiled` for release builds. For offline or air-gapped builds, compile from source (`RUSTLER_PRECOMPILED_FORCE_BUILD`) or point `base_url` at an internal artifact store.

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
- No network access beyond loopback. No telemetry, no crash-report upload, no auto-update in restricted builds.
- Untrusted input: C codecs (NBIS, OpenJPEG) run on attacker-controllable data, and a segfault in a NIF takes down the whole BEAM.
  - v1: bounds-check headers in Elixir before calling the NIF (dimensions, lengths), and cap maximum pixel count.
  - Hardening option: move the codecs out of process, into a small Rust CLI run via an Erlang Port or as a Tauri sidecar. A crash then kills only the decoder. Decide after fuzzing (M5).
- Logs contain no field values from Type-2 and no image bytes.

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
| M0 | Spike ✅ (BioCTS; Prüm and phantom files still to run) | CLI (`mix nist.dump file.nst`) prints the record tree for the Prüm samples (including the all-Type-4 CPS file) and a phantom enrolment; one WSQ Type-4 image decodes to PNG |
| M1 | Parser complete | All record types in §2 parse; the BioCTS set, the Prüm samples and phantom files parse without error; M1 and EFS minutiae decode; property tests pass |
| M2 | Codecs complete | WSQ, JPEGB, PNG and raw decode, with bit-exact WSQ results against NBIS `dwsq`. JPEGL and JP2/JP2L follow once a real file needs them |
| M3 | Viewer UI | Record tree, image pane, 10-print grid and minutiae overlay working in the browser (`mix phx.server`) |
| M4 | Desktop packaging | Tauri + ElixirKit app opens files via dialog, drag-drop and file association; CI produces bundles for all five targets |
| M5 | Hardening | Fuzzing done; decision on moving codecs out of process; signing and notarization; security review of data handling |

---

**M0 status (2026-09-29).**
- Done:
  - `mix nist.dump FILE [--decode] [--png DIR] [--full]` prints the record tree.
  - All 96 BioCTS files parse, including three all-Type-4 tenprint cards.
  - All 134 WSQ images in them decode through the NIF.
  - 43 tests; the BioCTS suite is skipped when the samples are missing.
- Not yet run:
  - the Prüm `.eml` samples (not on this machine)
  - a phantom enrolment export
- Seen in the BioCTS set but not decodable yet: JP2 (12 images), JP2L (22) and JPEGL (2). This makes JPEG 2000 more likely to be needed in v1 than §2 assumed.

## 8. Open questions
1. ~~Which record types and compressions actually occur?~~ *Partly answered (§2):* Type-4, 9, 10, 13, 14 and 15, with WSQ, PNG and JPEGB. Still open: do any files we need to view use JPEG 2000 (common at 1000 ppi) or JPEGL, or contain Type-17 iris?
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