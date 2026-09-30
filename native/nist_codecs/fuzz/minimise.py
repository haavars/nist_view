#!/usr/bin/env python3
"""Shrinks an input that crashes a fuzz target, keeping the same crash.

    fuzz/minimise.py TARGET INPUT OUTPUT      e.g. nbis_wsq crash-1234 out.wsq

`cargo fuzz tmin` accepts any crash, and with NBIS it drifts from the bug at
hand to whichever crash needs the fewest bytes. This keeps the
AddressSanitizer error and the first decoder function on its stack the same
while it removes bytes (delta debugging), and then sets to zero every byte
that the crash does not need. What is left of an input that came from a real
print is its headers and tables and a few bytes of data.

Needs the target built (`cargo +nightly fuzz build`, with CC and CFLAGS as in
run.sh) and llvm-symbolizer, found through LLVM_PREFIX as in run.sh.
"""

import glob
import os
import re
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
target, source, output = sys.argv[1:4]
binary = glob.glob(os.path.join(here, "target", "*", "release", target))[0]

env = dict(os.environ, ASAN_OPTIONS="allocator_may_return_null=1:detect_leaks=0")
symbolizer = os.path.join(os.environ.get("LLVM_PREFIX", "/usr"), "bin", "llvm-symbolizer")
if os.path.exists(symbolizer):
    env["ASAN_SYMBOLIZER_PATH"] = symbolizer

runtime = re.compile(r"asan|__interceptor|libfuzzer|fuzzer::|std::|core::|rust_| in (free|malloc|calloc|realloc) ")


def crash(data):
    """The kind of memory error and the decoder function it is in, or None."""
    with tempfile.NamedTemporaryFile() as file:
        file.write(data)
        file.flush()
        report = subprocess.run([binary, file.name], env=env, capture_output=True, text=True, errors="replace").stderr

    kind = re.search(r"ERROR: AddressSanitizer: (.*?) on ", report)
    frames = [line.split()[3] for line in report.splitlines() if re.match(r"\s+#\d+ 0x\w+ in ", line) and not runtime.search(line)]
    return (kind.group(1), frames[0]) if kind and frames else None


data = open(source, "rb").read()
wanted = crash(data)
if wanted is None:
    sys.exit(f"{source} does not crash {target}")

# Remove ever smaller pieces while the crash stays the same.
size = len(data) // 2
while size >= 1:
    position = 0
    while position < len(data):
        shorter = data[:position] + data[position + size:]
        if crash(shorter) == wanted:
            data = shorter
        else:
            position += size
    size //= 2

# Zero what is left but not needed.
for position in range(len(data)):
    if data[position] != 0:
        zeroed = data[:position] + b"\0" + data[position + 1:]
        if crash(zeroed) == wanted:
            data = zeroed

open(output, "wb").write(data)
print(f"{wanted[0]} in {wanted[1]}: {os.path.getsize(source)} -> {len(data)} bytes")
