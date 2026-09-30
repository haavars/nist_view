#!/bin/sh
# Groups a target's crash artifacts by their AddressSanitizer summary and
# top NBIS/OpenJPEG frame, so each distinct bug shows up once.
#
#   fuzz/triage.sh jpegl [max-artifacts]
set -u
cd "$(dirname "$0")/.."
target=$1
max=${2:-60}

# Function names in the reports need llvm-symbolizer, which is not on the
# PATH everywhere.
llvm=${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || echo /usr)}
[ -x "$llvm/bin/llvm-symbolizer" ] && export ASAN_SYMBOLIZER_PATH="$llvm/bin/llvm-symbolizer"
bin=fuzz/target/aarch64-apple-darwin/release/$target
[ -x "$bin" ] || bin=$(ls -d fuzz/target/*/release/$target | head -1)

for a in $(ls fuzz/artifacts/$target/crash-* | head -n "$max"); do
  "$bin" "$a" 2>&1 | awk '
    /SUMMARY: AddressSanitizer/ { sub(/.*SUMMARY: AddressSanitizer: /, ""); s = $1 }
    /^    #[0-9]+ / && !f && !/(asan|__interceptor|libsystem|_platform|wrap_|rust_|core::|std::)/ { f = $4 }
    END { print s " @ " f }'
done | sort | uniq -c | sort -rn
