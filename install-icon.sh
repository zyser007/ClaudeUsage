#!/bin/bash
# Installs a custom menu bar icon.
#
#   ./install-icon.sh <image>              keep the image as-is
#   ./install-icon.sh <image> --strip-bg   make the corner colour transparent
#
# --strip-bg samples the top-left pixel and clears every pixel matching it,
# which suits flat-background pixel art. It will eat parts of the subject if
# the subject shares that exact colour.
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-}"
STRIP="${2:-}"

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "usage: ./install-icon.sh <image.png> [--strip-bg]" >&2
    exit 1
fi

mkdir -p Resources
OUT="Resources/MenuIcon.png"

if [ "$STRIP" = "--strip-bg" ]; then
    python3 - "$SRC" "$OUT" <<'PY'
import sys, subprocess, tempfile, os, struct, zlib

src, out = sys.argv[1], sys.argv[2]

# Normalise whatever was handed in into RGBA PNG bytes via sips + a raw read.
tmp = tempfile.mktemp(suffix=".png")
subprocess.run(["sips", "-s", "format", "png", src, "--out", tmp],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# Decode with CoreGraphics through a tiny Swift-free path: use `sips` to get
# dimensions, then read pixels with PNG decoding in pure Python.
import binascii

def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, idat, w = 8, b"", None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            assert depth == 8 and interlace == 0, "need 8-bit non-interlaced"
            assert color in (2, 6), "need RGB or RGBA"
        elif typ == b"IDAT":
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = 4 if color == 6 else 3
    stride = w * ch
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i+stride]); i += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line)); prev = line
    return w, h, ch, rows

w, h, ch, rows = read_png(tmp)
os.unlink(tmp)

bg = tuple(rows[0][0:3])
print(f"background sampled at top-left: rgb{bg}")

def close(p, q, tol=18):
    return all(abs(p[i] - q[i]) <= tol for i in range(3))

cleared = 0
out_rows = []
for r in rows:
    o = bytearray()
    for x in range(w):
        px = r[x*ch:(x+1)*ch]
        rgb = tuple(px[0:3])
        if close(rgb, bg):
            o += bytes((0, 0, 0, 0)); cleared += 1
        else:
            o += bytes(rgb) + bytes((px[3] if ch == 4 else 255,))
    out_rows.append(bytes(o))

def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", binascii.crc32(c) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)

write_png(out, w, h, out_rows)
print(f"{w}x{h}, cleared {cleared}/{w*h} px to transparent -> {out}")
PY
else
    sips -s format png "$SRC" --out "$OUT" >/dev/null
    echo "copied as-is -> $OUT"
fi

./build.sh
echo "done — restart the app:  pkill -f ClaudeUsage.app; open ClaudeUsage.app"
