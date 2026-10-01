# CI and release builds on GitHub

Plan, 2026-10-01. Goal: tests on every push, and installers for all five
targets ([plan.md](plan.md#5-build-and-distribution)) from a tag, built on
GitHub-hosted runners. The repository is public, so all runners used here,
including macOS and Linux arm64, cost nothing.

Why GitHub Actions and not another service: every target has to be built
on its own OS (the bundle holds an Erlang runtime, a Rust NIF and helper,
and the platform's webview shell), and GitHub is the only service that
offers all five for free. Livebook Desktop, built on the same Tauri and
ElixirKit stack, uses the same five runners with `setup-beam` and
`tauri-action`. Third-party runners (WarpBuild, Namespace) or a
self-hosted runner on the MacBook are the fallback if the repository goes
private and macOS minutes cost too much; each is a one-line `runs-on`
change.

| Target | Runner |
|---|---|
| macOS arm64 | `macos-15` |
| macOS x86_64 | `macos-15-intel` (the last Intel image, supported until about August 2027) |
| Linux x86_64 | `ubuntu-22.04` (older glibc, so the build runs on newer distributions) |
| Linux arm64 | `ubuntu-22.04-arm` |
| Windows x64 | `windows-2022` |

## Steps

1. **Test workflow** (`.github/workflows/ci.yml`), on every push to `main`
   and every pull request.
   - Jobs on `ubuntu-24.04` and `macos-15`: the decoder's pixel checks
     depend on the CPU, so both x86_64 and arm64 run them.
   - Versions from `.tool-versions` (Erlang, Elixir, Rust), so CI and the
     dev machines agree: `setup-beam` with `version-file`.
   - Caches: Mix deps and `_build`, Cargo (`Swatinem/rust-cache`), and the
     BioCTS samples (`mix nist.samples`, 150 MB from nist.gov, keyed on the
     archive URL). Without the samples, `biocts_sample_test.exs` is
     skipped.
   - Run `mix precommit`, then `git diff --exit-code`: precommit formats
     and unlocks unused deps in place, so a change there means something
     was not committed.

2. **Make `desktop.yml` build**, on a branch `ci`, with a temporary
   `push: branches: [ci]` trigger to iterate (a manual run of a workflow
   only appears once the file is on `main`). Known gaps, compared with
   Livebook's working workflow:
   - Linux arm64: `setup-beam` misreads the runner's `ImageOS` (setup-beam
     pull request #462). Livebook strips the `-arm64` suffix around the
     step; copy that.
   - Tauri CLI: with no `package.json`, `tauri-action` installs the newest
     CLI. Install `tauri-cli` at the version matching `src-tauri/Cargo.lock`
     (tauri 2.12) and point `tauriScript` at it.
   - Cargo cache for `src-tauri` and `native/`.
   - Versions from `.tool-versions`, as in step 1.
   Expect more failures than these, since the workflow has never run.
   Windows is the least tested: no release has been built there, and
   `mix release` and ElixirKit have only run on macOS.

3. **Smoke test in each bundle job.** After the build, start the bundled
   release with `rel/bin/nist_view eval` and decode a committed fixture of
   each codec. This checks the Erlang runtime, the NIF and the
   `nist_decode` helper on every target, without a display.

4. **Releases from tags.** A `v*` tag builds all five and attaches them to
   a draft GitHub release, with asset names
   `NIST-Viewer-<platform>-<arch>`. A last job writes `SHA256SUMS` for all
   assets, so whoever carries them into the airgapped network can check
   them. The job fails if the tag differs from the version in `mix.exs` and
   `src-tauri/tauri.conf.json`.

5. **Install on clean machines**, by hand, once per target: a machine
   without dev tools, offline. Check that the app starts, opens a file
   from the dialog, by drag and drop and by double-click (the file
   association, untested so far), and decodes every codec. Things to look
   for: the Erlang runtime from `setup-beam` may depend on system
   libraries (OpenSSL 3 on Linux); unsigned builds need a manual override
   (Gatekeeper on macOS, SmartScreen on Windows).

6. **Signing**, when the certificates exist. The secrets are already passed
   through: `APPLE_*` (Developer ID and notarization) and `AZURE_*`
   (Windows). Add a notarization check (`spctl -a -t exec`) after the macOS
   build, as Livebook does.

Optional: pin third-party actions to a commit hash instead of a tag, and
let Dependabot update them.

## Who does what

- Pushing to GitHub, and the GitHub settings (Actions enabled, workflow
  permission to write contents for releases): the owner.
- Steps 1 to 4: in a session, from this Linux machine; iterating means
  pushing the `ci` branch and reading the run logs.
- Step 5 needs a Mac, a Windows machine and a Linux desktop.
- Step 6 needs the certificates.
