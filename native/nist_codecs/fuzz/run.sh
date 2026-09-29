#!/bin/sh
# Fuzzes one decoder with AddressSanitizer in both the Rust and the C code
# (NBIS, OpenJPEG). Needs nightly Rust, cargo-fuzz and an LLVM clang with
# libFuzzer (Homebrew `llvm` on macOS).
#
#   fuzz/run.sh wsq 600      # target, seconds
#
# Seeds come from test/fixtures and, when present, test/samples (images
# extracted by fuzz/seed.exs). Crashes land in fuzz/artifacts/<target>/.
set -eu
cd "$(dirname "$0")/.."

target=${1:?target: wsq, jpegl, jp2 or headers}
seconds=${2:-300}
llvm=${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || echo /usr)}

export CC="$llvm/bin/clang"
export CFLAGS="-fsanitize=address,fuzzer-no-link -fno-omit-frame-pointer -g -O1"

mkdir -p "fuzz/corpus/$target"

# Fork mode keeps going after a crash, so one run collects every distinct
# crash, out-of-memory and timeout as an artifact.
cargo +nightly fuzz run "$target" "fuzz/corpus/$target" -- \
  -max_total_time="$seconds" -max_len=262144 -rss_limit_mb=4096 -timeout=20 \
  -fork="${FORKS:-2}" -ignore_crashes=1 -ignore_ooms=1 -ignore_timeouts=1
