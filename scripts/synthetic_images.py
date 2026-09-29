"""Writes the source patterns for the synthetic image fixtures in test/fixtures.

    python3 scripts/synthetic_images.py OUT_DIR

The patterns match the expectations in test/nist_view/codecs_test.exs.
Encode them with (NBIS 5.0.0 cjpegl, OpenJPEG 2.5 opj_compress):

    cjpegl jpl pat_grey.raw -raw_in 128,96,8,500          # synthetic_grey.jpl
    cjpegl jpl pat_rgb.raw -raw_in 128,96,24,500          # synthetic_rgb.jpl
    cjpegl jpl pat_ycc.raw -raw_in 128,96,24,500 -nonintrlv -YCbCr 2,2:1,1:1,1
                                                          # synthetic_ycc420.jpl
    opj_compress -i pat_grey.pgm -o synthetic_grey.jp2    # lossless by default
    opj_compress -i pat_rgb.ppm -o synthetic_rgb.j2k
    opj_compress -i pat_g16.pgm -o synthetic_grey16.jp2

synthetic.wsq predates this script; see test/fixtures/README.md.
"""

import math
import os
import struct
import sys

W, H = 128, 96

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def write(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)


grey = bytes(int(128 + 90 * math.sin(x / 2.5) * math.cos(y / 3.5)) for y in range(H) for x in range(W))
rgb = bytes(v for y in range(H) for x in range(W) for v in ((x * 2) % 256, (y * 2) % 256, (x + y) % 256))
g16 = b"".join(struct.pack(">H", (x * 512 + y * 7) % 65536) for y in range(H) for x in range(W))

# Non-interleaved YCbCr, chroma subsampled 2 x 2: Y is W x H, Cb and Cr W/2 x H/2.
ycc_y = bytes((x + 2 * y) % 256 for y in range(H) for x in range(W))
ycc_cb = bytes((64 + x * 2) % 256 for y in range(H // 2) for x in range(W // 2))
ycc_cr = bytes((200 - y * 2) % 256 for y in range(H // 2) for x in range(W // 2))

write("pat_grey.raw", grey)
write("pat_rgb.raw", rgb)
write("pat_ycc.raw", ycc_y + ycc_cb + ycc_cr)
write("pat_grey.pgm", b"P5\n%d %d\n255\n" % (W, H) + grey)
write("pat_rgb.ppm", b"P6\n%d %d\n255\n" % (W, H) + rgb)
write("pat_g16.pgm", b"P5\n%d %d\n65535\n" % (W, H) + g16)
