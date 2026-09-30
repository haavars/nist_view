#!/bin/sh
# Makes the JPEG 2000 test files in test/fixtures/jp2 from synthetic images,
# with OpenJPEG's opj_compress (made with 2.4.0). They cover what the sample files do
# not: lossy coding, 12 and 16 bits, signed samples, subsampled chroma,
# tiles, progression orders and code-block styles. The differential test
# native/opj_ref/tests/compare.rs decodes each with both decoders.
#
#   scripts/make_jp2_fixtures.sh      (needs python3 and opj_compress)
#
# The files are committed; run this only to add or change one.
set -eu
cd "$(dirname "$0")/.."
out=test/fixtures/jp2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# The ridge pattern of the other fixtures, with texture so that lossy coding
# has something to discard. 131 x 97: odd in both directions.
python3 - "$work" <<'PY'
import math, struct, sys
work, w, h = sys.argv[1], 131, 97

def noise(x, y, k):
    n = (x * 73856093) ^ (y * 19349663) ^ (k * 83492791)
    return ((n * 2654435761) >> 7) % 25 - 12

def ridge(x, y, k=0):
    return max(0, min(255, int(128 + 90 * math.sin(x / 2.5) * math.cos(y / 3.5)) + noise(x, y, k)))

grey = bytes(ridge(x, y) for y in range(h) for x in range(w))
open(f"{work}/grey.pgm", "wb").write(b"P5\n%d %d\n255\n" % (w, h) + grey)
open(f"{work}/signed.raw", "wb").write(bytes((v - 128) & 0xFF for v in grey))

rgb = bytes(c for y in range(h) for x in range(w)
            for c in (ridge(x, y, 1), (x * 2 + noise(x, y, 2)) % 256, ridge(y, x, 3)))
open(f"{work}/rgb.ppm", "wb").write(b"P6\n%d %d\n255\n" % (w, h) + rgb)

for bits in (12, 16):
    top = (1 << bits) - 1
    data = b"".join(struct.pack(">H", (ridge(x, y) * top // 255 + noise(x, y, 4) * 3) & top)
                    for y in range(h) for x in range(w))
    open(f"{work}/grey{bits}.pgm", "wb").write(b"P5\n%d %d\n%d\n" % (w, h, top) + data)

# Luma at 132 x 96, the two chroma components at half the size each way.
luma = bytes(ridge(x, y) for y in range(96) for x in range(132))
chroma = [bytes(ridge(2 * x, 2 * y, k) for y in range(48) for x in range(66)) for k in (5, 6)]
open(f"{work}/yuv420.raw", "wb").write(luma + chroma[0] + chroma[1])
PY

c() {
  name=$1
  shift
  opj_compress "$@" -o "$out/$name" > "$work/log" 2>&1 || { cat "$work/log"; exit 1; }
}

lossy="-I -r 6"
c grey_lossless.jp2 -i "$work/grey.pgm"
c grey_lossy.jp2 -i "$work/grey.pgm" $lossy
c grey_lossy_high_ratio.jp2 -i "$work/grey.pgm" -I -r 25
c grey_layers.jp2 -i "$work/grey.pgm" -I -r 30,12,5
c grey_quality.j2k -i "$work/grey.pgm" -I -q 30,38
c grey_one_level.jp2 -i "$work/grey.pgm" -n 1 $lossy
c grey_six_levels.jp2 -i "$work/grey.pgm" -n 6 $lossy
c grey_small_blocks.jp2 -i "$work/grey.pgm" -b 16,16 $lossy
c grey_flat_blocks.jp2 -i "$work/grey.pgm" -b 64,4
c grey_precincts.jp2 -i "$work/grey.pgm" -c '[64,64],[32,32]' -p RPCL $lossy
c grey_tiles.jp2 -i "$work/grey.pgm" -t 50,40 -n 4 $lossy
c grey_tiles_lossless.jp2 -i "$work/grey.pgm" -t 37,31 -n 4
c grey_tile_parts.jp2 -i "$work/grey.pgm" -t 64,64 -n 4 -TP R $lossy
c grey_offset.jp2 -i "$work/grey.pgm" -d 37,21 -T 5,3 -t 64,64 -n 4 $lossy
for order in RLCP PCRL CPRL; do
  c "grey_$order.jp2" -i "$work/grey.pgm" -p $order -c '[64,64],[32,32]' -I -r 12,6
done
c grey_bypass.jp2 -i "$work/grey.pgm" -M 1 $lossy
c grey_all_styles.jp2 -i "$work/grey.pgm" -M 63 $lossy
c grey_all_styles_lossless.jp2 -i "$work/grey.pgm" -M 63
c grey_sop_eph.jp2 -i "$work/grey.pgm" -SOP -EPH $lossy
c grey12_lossless.jp2 -i "$work/grey12.pgm"
c grey12_lossy.jp2 -i "$work/grey12.pgm" $lossy
c grey16_lossy.jp2 -i "$work/grey16.pgm" $lossy
c signed_lossless.j2k -i "$work/signed.raw" -F 131,97,1,8,s
c signed_lossy.j2k -i "$work/signed.raw" -F 131,97,1,8,s $lossy
c rgb_lossless.jp2 -i "$work/rgb.ppm"
c rgb_lossy.jp2 -i "$work/rgb.ppm" -I -r 10
c rgb_no_transform.jp2 -i "$work/rgb.ppm" -mct 0 -I -r 10
c rgb_tiles.j2k -i "$work/rgb.ppm" -t 50,40 -n 4 -p RPCL -I -r 10
c subsampled_lossless.j2k -i "$work/yuv420.raw" -F 132,96,3,8,u@1x1:2x2:2x2
c subsampled_lossy.j2k -i "$work/yuv420.raw" -F 132,96,3,8,u@1x1:2x2:2x2 $lossy

ls "$out" | wc -l
