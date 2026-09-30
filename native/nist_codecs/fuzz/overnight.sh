#!/bin/sh
# Fuzzes several targets side by side for hours and leaves the result on
# disk for a later look.
#
#   fuzz/overnight.sh [--detach] [HOURS [TARGET...]]
#
# Defaults: 8 hours, and the targets jp2, wsq, wsq_diff and jpegl.
#
# It shows the progress of every target once a minute (INTERVAL=seconds to
# change that). Ctrl-C stops the fuzzers and still writes the summary.
# Closing the terminal does the same; with --detach it runs in the
# background instead, survives the terminal, and is stopped with the `kill`
# command it prints.
#
# Everything about a run is in fuzz/results/<date>_<time>/:
#
#   status        "running", then "finished" or "stopped"
#   summary.md    per target: inputs, coverage, crashes, timeouts, and the
#                 files the fuzzer saved (written when the run ends)
#   <target>.log  libFuzzer's output
#
# The inputs it saves are in fuzz/artifacts/<target>/, and the corpus it
# grows is in fuzz/corpus/<target>/, as with run.sh; a later run continues
# from that corpus. Needs what run.sh needs (docs/fuzzing.md): nightly Rust,
# cargo-fuzz and an LLVM clang, found through LLVM_PREFIX.
set -eu
cd "$(dirname "$0")/.."

mode=foreground
case ${1:-} in
  --detach | --run)
    mode=${1#--}
    shift
    ;;
esac

if [ "$mode" = run ]; then
  # What --detach starts.
  results=$1
  hours=$2
  shift 2
else
  hours=${1:-8}
  [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || set -- jp2 wsq wsq_diff jpegl

  llvm=${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || echo /usr)}
  if [ ! -x "$llvm/bin/clang" ]; then
    echo "No clang in $llvm/bin: set LLVM_PREFIX (see docs/fuzzing.md)." >&2
    exit 1
  fi
  for target in "$@"; do
    seeds=$target
    case $target in wsq_diff | nbis_wsq) seeds=wsq ;; esac
    if [ -z "$(ls "fuzz/corpus/$seeds" 2>/dev/null)" ]; then
      echo "fuzz/corpus/$seeds is empty: run 'mix run native/nist_codecs/fuzz/seed.exs' from the repository root first." >&2
      exit 1
    fi
  done

  results=fuzz/results/$(date +%Y-%m-%d_%H%M)
  mkdir -p "$results"
  echo running > "$results/status"

  if [ "$mode" = detach ]; then
    nohup "$0" --run "$results" "$hours" "$@" > "$results/overnight.log" 2>&1 &
    echo "Fuzzing $* for $hours hours each, in the background."
    echo "Progress: tail -f native/nist_codecs/$results/overnight.log"
    echo "Stop:     kill $!   (the summary is still written)"
    echo "Result:   native/nist_codecs/$results/summary.md, when 'status' there no longer says 'running'"
    exit 0
  fi

  echo "Fuzzing $* for $hours hours each. Ctrl-C stops it and writes the summary."
  echo "Results: native/nist_codecs/$results"
fi

seconds=$(awk "BEGIN { printf \"%d\", $hours * 3600 }")
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
forks=$(( (cores - 2) / $# ))
[ "$forks" -ge 1 ] || forks=1
started=$(date '+%Y-%m-%d %H:%M')
start=$(date +%s)
touch "$results/started"

new_artifacts() {
  find "fuzz/artifacts/$1" -type f -newer "$results/started" 2>/dev/null | sort
}

# libFuzzer's last status line of a target, as: inputs coverage corpus
# out-of-memory/timeout/crash.
last_status() {
  grep -E '^#[0-9]+:' "$results/$1.log" 2>/dev/null | tail -n 1 |
    awk '{ gsub(/[#:]/, "", $1); print $1, $3, $7, $11 }'
}

progress() {
  elapsed=$(( $(date +%s) - start ))
  printf '%s  %d:%02d of %s hours\n' "$(date +%H:%M)" $((elapsed / 3600)) $((elapsed % 3600 / 60)) "$hours"
  for target in "$@"; do
    set_status=$(last_status "$target")
    if [ -z "$set_status" ]; then
      printf '  %-9s building or starting\n' "$target"
    else
      echo "$set_status" | awk -v target="$target" -v saved="$(new_artifacts "$target" | wc -l | tr -d ' ')" \
        '{ printf "  %-9s %10s inputs   coverage %-6s corpus %-6s out of memory/timeout/crash %-8s files saved %s\n", target, $1, $2, $3, $4, saved }'
    fi
  done
}

# Interrupts the fuzzers of this run. They are found by the path of their
# binaries, which also finds them from a detached run.
outcome=finished
stop() {
  outcome=stopped
  for target in "$@"; do
    pkill -INT -f "fuzz/target/[^ ]*/release/$target -" 2>/dev/null || true
  done
}
trap 'stop "$@"' INT TERM HUP

pids=
for target in "$@"; do
  FORKS=$forks fuzz/run.sh "$target" "$seconds" > "$results/$target.log" 2>&1 &
  pids="$pids $!"
done

running() {
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

while running && [ "$outcome" = finished ]; do
  sleep "${INTERVAL:-60}" &
  wait $! 2>/dev/null || true
  running && [ "$outcome" = finished ] && progress "$@"
done
# A signal interrupts `wait`, so wait until they are really gone.
while running; do
  wait 2>/dev/null || true
done

{
  echo "# Fuzz run $(basename "$results")"
  echo
  if [ "$outcome" = stopped ]; then
    echo "- **Stopped early**, after $(( ($(date +%s) - start) / 60 )) minutes of the $hours hours asked for."
  fi
  echo "- From $started to $(date '+%Y-%m-%d %H:%M'): $hours hours per target, $forks processes each, on $(uname -m) $(uname -s)."
  echo "- Commit $(git rev-parse --short HEAD)$(git diff --quiet HEAD 2>/dev/null || echo ', with uncommitted changes')."
  echo
  echo "| Target | Inputs | Coverage | Corpus | Out of memory / timeout / crash | Files saved |"
  echo "|---|---|---|---|---|---|"
  for target in "$@"; do
    status=$(last_status "$target")
    if [ -z "$status" ]; then
      echo "| \`$target\` | did not run: see $target.log | | | | |"
      continue
    fi
    echo "$status" | awk -v target="$target" -v saved="$(new_artifacts "$target" | wc -l | tr -d ' ')" \
      '{ printf "| `%s` | %s | %s | %s | %s | %s |\n", target, $1, $2, $3, $4, saved }'
  done

  for target in "$@"; do
    files=$(new_artifacts "$target")
    [ -n "$files" ] || continue
    echo
    echo "## $target: files saved"
    echo
    echo '```'
    for file in $files; do
      echo "$(wc -c < "$file" | tr -d ' ') bytes  $file"
    done
    echo '```'
    if ls "fuzz/artifacts/$target"/crash-* > /dev/null 2>&1; then
      echo
      echo "Crashes by kind and first decoder function (fuzz/triage.sh, all crash files of this target, also older ones):"
      echo
      echo '```'
      fuzz/triage.sh "$target" 500 2>&1
      echo '```'
    fi
  done

  echo
  echo "A timeout is an input that took more than 20 seconds under the fuzzer; a slow-unit one that took more than 10. Neither is a crash."
} > "$results/summary.md"

echo "$outcome" > "$results/status"
echo
cat "$results/summary.md"
