#!/bin/sh
# Looks for inputs that NBIS decodes but the Rust WSQ decoder rejects: the
# direction the wsq_diff target cannot see, because it never runs NBIS on
# what the Rust decoder rejects.
#
#   fuzz/replay.sh [DIR...]     # default: the WSQ corpora and artifacts
#
# Every file goes through the Rust decoder (decode_strict, release build,
# the real size limit). Each one it rejects is given to NBIS, built with
# AddressSanitizer, in a process of its own, since NBIS may crash on it.
# The result is a count per pair of verdicts and the list of files that
# NBIS decodes without a memory error.
#
# Needs an LLVM clang, as run.sh does (LLVM_PREFIX).
set -eu
cd "$(dirname "$0")/.."

llvm=${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || echo /usr)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ $# -gt 0 ] || set -- $(ls -d fuzz/corpus/wsq* fuzz/artifacts/wsq* 2>/dev/null)

nbis=../nbis_ref
"$llvm/bin/clang" -O1 -g -fsanitize=address -ffp-contract=off -w -D__NBISLE__ \
  -include "$nbis/c/quiet.h" -I"$nbis/vendor/nbis/include" \
  "$nbis"/vendor/nbis/src/wsq/*.c "$nbis"/vendor/nbis/src/jpegl/*.c \
  "$nbis"/vendor/nbis/src/fet/*.c "$nbis"/vendor/nbis/src/ioutil/*.c \
  "$nbis"/vendor/nbis/src/util/*.c "$nbis/c/glue.c" ../../scripts/dwsq_min.c \
  -lm -o "$work/dwsq"

cargo build --release --quiet --manifest-path "$nbis/Cargo.toml" --example wsq_verdict
"$nbis/target/release/examples/wsq_verdict" "$@" > "$work/verdicts"

export ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1
[ -x "$llvm/bin/llvm-symbolizer" ] && export ASAN_SYMBOLIZER_PATH="$llvm/bin/llvm-symbolizer"

tab=$(printf '\t')
while IFS=$tab read -r rust file; do
  if [ "$rust" = ok ]; then
    echo "ok${tab}-${tab}$file"
    continue
  fi

  if out=$(timeout 60 "$work/dwsq" "$file" 2>&1); then status=0; else status=$?; fi
  case $out in
    *"ERROR: AddressSanitizer"*)
      nbis_verdict="memory error ($(echo "$out" | sed -n 's/.*ERROR: AddressSanitizer: //p' | sed 's/ on .*//' | head -n 1))" ;;
    *" ERR "*) nbis_verdict="error" ;;
    *" OK "*) nbis_verdict="decodes" ;;
    *) nbis_verdict="exit $status" ;;
  esac
  echo "$rust${tab}$nbis_verdict${tab}$file"
done < "$work/verdicts" > "$work/pairs"

echo "Rust verdict, NBIS verdict, files:"
cut -f 1,2 "$work/pairs" | sort | uniq -c | sort -rn

echo
echo "Rejected by the Rust decoder, decoded by NBIS without a memory error:"
awk -F "$tab" '$1 != "ok" && $2 == "decodes" { print "  " $1 "  " $3 }' "$work/pairs"
