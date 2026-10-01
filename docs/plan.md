# NIST Viewer — Plan

A cross-platform desktop viewer for ANSI/NIST-ITL transaction files (`.nst`,
`.an2`, `.eft`). It loads a file and shows every record: fingerprints, faces,
latents, palms and minutiae, plus all text fields.

Stack: **Elixir/Phoenix LiveView** for the UI and parsing, **safe Rust** for
the image decoders (in a helper process) and PNG encoding (a NIF), and
**Tauri + ElixirKit** as the desktop shell. How it is built:
[architecture.md](architecture.md).

## Goals and non-goals

**Goals**
- Open any ANSI/NIST-ITL file in traditional (tagged/binary) encoding,
  versions 0300–0600. Known producers: Prüm exchange traffic, INT-I
  4.22-era files (`VER 0300`), and `0502` files from phantom and abis_next.
- Show every record, field, subfield and item.
- Render every image-bearing record, whatever its compression.
- Overlay Type-9 minutiae on the matching fingerprint.
- Native builds for macOS (arm64), Linux (x86_64, aarch64) and Windows
  (x64). macOS x86_64 was dropped on 2026-10-01: nobody uses it.
- Display only: no biometric data is written to disk.

**Non-goals (v1)**
- Editing or writing NIST files.
- XML encoding (ANSI/NIST-ITL 2-2008 / NIEM). INTERPOL INT-I v6.00.01 (2020)
  is XML only, so current INT-I files will need this later.
- Validation against domain rules (EBTS, INT-I conformance).
- Matching, quality scoring (NFIQ) or other analysis.
- S/MIME or `.eml` envelopes: the input is the NIST file itself.

## Coverage

| Record | Content | Image compression | Seen in real files |
|---|---|---|---|
| Type-1, 2 | Transaction, descriptive text | — | All |
| Type-4 | High-res greyscale fingerprint (binary) | GCA: none or WSQ | Prüm CPS (14 per tenprint) |
| Type-9 | Minutiae: M1, legacy, FBI, EFS | — | Prüm (M1); abis_next (EFS) |
| Type-10 | Face, SMT, photo | JPEGB, JPEGL, JP2, JP2L, PNG, none | phantom (PNG, JPEGB) |
| Type-13, 14, 15 | Latent, fingerprint, palm | WSQ, JPEGB, JPEGL, JP2, JP2L, PNG, none | Prüm (`WSQ`); abis_next, phantom |
| Type-17 | Iris | JPEGB, JP2, JP2L, PNG, none | — |
| Others | Types 3, 5–8, 16, 18–22, 98, 99 | Shown as fields; images if the codec is supported | BioCTS |

Unknown fields are shown, never rejected. Format details and quirks:
[formats.md](formats.md).

## Status

| # | Milestone | Status |
|---|---|---|
| M0 | Spike: `mix nist.dump` prints the record tree | ✅ BioCTS and phantom; Prüm samples not run |
| M1 | Parser complete, all record types, M1 and EFS minutiae | ✅ Prüm samples not run |
| M2 | Codecs: WSQ, JPEGB, JPEGL, JP2/JP2L, PNG, raw | ✅ |
| M3 | Viewer UI: record list, image pane, tenprint card, minutiae overlay | ✅ Reworked 2026-09-30: toolbars outside the image, resizable panes, status bar, shortcuts panel |
| M4 | Desktop packaging: Tauri + ElixirKit, file associations, CI for four targets | ✅ CI builds and smoke-tests all four ([ci.md](ci.md)); not yet installed on clean machines; double-click opening untested |
| M5 | Hardening | Mostly done: out-of-process decoding, all decoders in safe Rust ([wsq.md](wsq.md), [jp2.md](jp2.md)), fuzzing, security review. Open: [security.md](security.md#open-items) |
| M6 | Performance: images load fast | Not started. Measured below |

**Performance, measured 2026-09-30** (dev build, arm64): parsing is under
10 ms even for a 16 MB file. WSQ is fast: a 14-print tenprint card renders
in 42 ms. A 3300 × 4400 JPEG 2000 face takes 0.5 to 1.2 s and becomes an
11 to 13 MB PNG, the one noticeable wait in the viewer.

## Next

In the suggested order:

1. **Real Prüm files.** Run the M0/M1 checks on the Prüm `.eml` samples
   (M1 minutiae, Type-13 latents, all-Type-4 cards). They have not been
   available on the machines used so far.
2. **Beyond this Mac (M4).** CI builds all four targets
   ([ci.md](ci.md)); install each on a clean, offline machine and open a
   file by double-click (ci.md, step 5); decide whether Windows is needed
   (open question 4).
3. **Large images (M6).** Split the JPEG 2000 time into decoding and PNG
   encoding, then pick the cheapest fix: faster PNG settings, a downscaled
   first view (`target_resolution`), or decoding neighbouring records ahead.
4. **Hardening (M5),** lower priority since the viewer runs airgapped on
   known data: a sandbox for the helper, macOS first; the libjpeg-turbo
   differential target; lossless JPEG regression inputs. No longer fuzz
   runs and no code signing (decisions of 2026-10-01).
5. **Viewer features,** after using it: a ruler in mm, search across
   fields, two images side by side, a light theme.

## Open questions

1. Do the files we need to view contain Type-17 iris?
2. Which minutiae block do INT-I 4.22 files use, and will we see vendor
   blocks? (Prüm uses M1; abis_next writes EFS.)
3. Will we need current INT-I v6 files? They are XML only.
4. Which platforms are really needed? Is Windows in scope, and is macOS only
   for development? (macOS x86_64 is out.)
5. The internal distribution channel for the restricted network. (No
   code-signing certificates: decided 2026-10-01.)

## Build targets

| Target | Runner | Notes |
|---|---|---|
| macOS arm64 | macos-15 | .dmg; signed ad hoc, not notarized |
| Linux x86_64 | ubuntu-22.04 | webkit2gtk-4.1; 22.04 for glibc compatibility; .deb and AppImage |
| Linux aarch64 | ubuntu-22.04-arm | Same |
| Windows x64 | windows-2022 | MSI and NSIS installer; unsigned |

Each target builds natively: the NIF and helper (Cargo), the Elixir release
(including ERTS) and the Tauri bundle. Workflows: `.github/workflows/ci.yml`
(tests) and `.github/workflows/desktop.yml` (installers, and draft releases
from `v*` tags); how they work and what they needed: [ci.md](ci.md).

## References

- ANSI/NIST-ITL 1-2011 (Update 2015) and NIST reference data:
  https://www.nist.gov/itl/iad/image-group/ansinist-itl-standard-references
- NBIS: https://www.nist.gov/services-resources/software/nist-biometric-image-software-nbis
- Prior work: `~/repos/abis_next/docs/nist_import_export_plan.md`,
  `~/repos/phantom/docs/nist-export-plan.md` and
  `phantom_an2_unify_import.md`
- INTERPOL ANSI/NIST XML implementation:
  https://github.com/INTERPOL-Innovation-Centre/ANSI-NIST-XML-ITL-Implementation
- ElixirKit + Tauri guide: https://hexdocs.pm/elixirkit/tauri.html
