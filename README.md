# NIST Viewer

A desktop viewer for ANSI/NIST-ITL transaction files (`.an2`, `.nst`, `.eft`):
every record and field, every image (WSQ, JPEG, JPEG 2000, lossless JPEG,
PNG, uncompressed) and Type-9 minutiae overlaid on their prints. Files are
read into memory only. See [`docs/plan.md`](docs/plan.md).

Versions are pinned in `.tool-versions` (Erlang, Elixir, Rust).

## In the browser (development)

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000> and drop a file, or open a local file with
`http://localhost:4000/?path=/full/path/file.an2` (development only).

## Desktop app (Tauri)

Needs the Tauri CLI: `cargo install tauri-cli --version "^2.11" --locked`.

```sh
mix deps.get                 # also fetches ElixirKit, which src-tauri builds against
cd src-tauri
cargo tauri dev              # runs `mix phx.server` from source in a window
CI=true cargo tauri build    # release bundles in src-tauri/target/release/bundle/
```

`cargo tauri build` runs `mix desktop.release` (always `MIX_ENV=prod`) to put
the Elixir release in `src-tauri/target/rel`, which is bundled into the app.
`CI=true` skips the Finder styling of the DMG window, which fails without a
GUI session or Finder automation permission.

On macOS 27 the standalone Tailwind binary is killed on launch until it is
re-signed: `codesign --force --sign - _build/tailwind-macos-arm64-*`.

## Tests

```sh
mix precommit        # compile, format, Elixir tests and the Rust codec tests
mix nist.samples     # optional: NIST's BioCTS sample files for the sample tests
```
