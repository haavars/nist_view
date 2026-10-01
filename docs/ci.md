# CI and release builds on GitHub

Plan, 2026-10-01. Goal: tests on every push, and installers for all four
targets ([plan.md](plan.md#5-build-and-distribution)) from a tag, built on
GitHub-hosted runners. The repository is public, so all runners used here,
including macOS and Linux arm64, cost nothing.

Why GitHub Actions and not another service: every target has to be built
on its own OS (the bundle holds an Erlang runtime, a Rust NIF and helper,
and the platform's webview shell), and GitHub is the only service that
offers all of them for free. Livebook Desktop, built on the same Tauri and
ElixirKit stack, uses the same runners with `setup-beam` and
`tauri-action`. Third-party runners (WarpBuild, Namespace) or a
self-hosted runner on the MacBook are the fallback if the repository goes
private and macOS minutes cost too much; each is a one-line `runs-on`
change.

| Target | Runner |
|---|---|
| macOS arm64 | `macos-15` |
| Linux x86_64 | `ubuntu-22.04` (older glibc, so the build runs on newer distributions) |
| Linux arm64 | `ubuntu-22.04-arm` |
| Windows x64 | `windows-2022` |

macOS x86_64 (Intel) was dropped on 2026-10-01: nobody uses it.

## Steps

1. ✅ (2026-10-01) **Test workflow** (`.github/workflows/ci.yml`), on every
   push to `main` and every pull request: `mix precommit` on `ubuntu-24.04`
   and `macos-15` (the decoder's pixel checks depend on the CPU), then a
   check that it changed no file (it formats in place). Versions come from
   `.tool-versions`. Cached: Mix deps, `_build` with `priv/native` (Rustler
   does not rebuild the NIF when the Elixir code is unchanged, so the
   gitignored `.so` has to be cached too), Cargo, and the BioCTS samples.
   About three minutes.

2. ✅ (2026-10-01) **`desktop.yml` builds all four targets.** Needed, compared
   with the first version: the `ImageOS` workaround for `setup-beam` on
   arm64 Ubuntu (from Livebook), the Tauri CLI pinned to the `tauri` crate
   (`TAURI_CLI_VERSION`; the newest CLI is a 3.0 alpha), ad-hoc signing
   set explicitly (an empty `APPLE_SIGNING_IDENTITY` made ElixirKit's
   `codesign` fail), and a Cargo cache. Windows built on the first try.
   With a warm cache a target takes about four minutes; compiling the
   Tauri CLI into an empty cache (caches expire after 7 days unused) adds
   4 to 10 minutes.

3. ✅ (2026-10-01) **Smoke test in each bundle job**
   (`scripts/release_smoke.exs`): the bundled release decodes a WSQ, a
   lossless JPEG and a JPEG 2000 fixture, which checks its Erlang runtime,
   the NIF and the `nist_decode` helper on every target.

4. **Releases from tags.** A `v*` tag first checks the tag against the
   version in `mix.exs`, `src-tauri/tauri.conf.json` and
   `src-tauri/Cargo.toml`. After the builds, the `release` job attaches
   every installer (spaces in names replaced by `-`) and `SHA256SUMS` to
   a draft release, with `.github/release-notes.md` as its text. A person
   publishes the draft. To release: bump the three versions, merge, then
   tag `main` and push the tag.

5. **Install on clean machines**, by hand, once per target: a machine
   without dev tools, offline. Check that the app starts, opens a file
   from the dialog, by drag and drop and by double-click (the file
   association, untested so far), and decodes every codec. Things to look
   for: the Erlang runtime from `setup-beam` may depend on system
   libraries (OpenSSL 3 on Linux); unsigned builds need a manual override
   (Gatekeeper on macOS, SmartScreen on Windows).

6. **No signing with a certificate** (decided 2026-10-01): no Apple
   Developer ID or notarization, no Windows code-signing certificate.
   macOS builds are signed ad hoc (`APPLE_SIGNING_IDENTITY=-`), which
   Apple Silicon needs to run them at all. Integrity comes from
   `SHA256SUMS` (step 4). Users need these steps once per install, to be
   written into the release notes:
   - macOS: open the app, then allow it in System Settings → Privacy &
     Security → Open Anyway; or remove the download flag with
     `xattr -dr com.apple.quarantine "/Applications/NIST Viewer.app"`.
     Copied from a USB stick, the app often has no such flag.
   - Windows: the installer shows an unknown publisher; on a networked
     machine SmartScreen first needs More info → Run anyway.
   - Machines that only allow signed or notarized software (managed Macs,
     Windows application control) cannot run these builds.

Optional: pin third-party actions to a commit hash instead of a tag, and
let Dependabot update them.

## Who does what

- Pushing tags and merging to `main`: the owner. The `release` job asks
  for permission to write contents itself, so no repository setting is
  needed.
- Steps 1 to 4: done from a session on the Linux machine, with `gh`
  (installed in `~/.local/bin`) to read the run logs.
- Step 5 needs a Mac, a Windows machine and a Linux desktop.
