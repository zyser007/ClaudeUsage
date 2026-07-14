#!/usr/bin/env python3
"""Builds Resources/AppIcon.icns from a source PNG.

The artwork is blocky, so the master is upscaled with nearest-neighbour to keep
the edges hard; the smaller iconset sizes are downscaled by sips afterwards,
where smoothing genuinely helps legibility. Pure stdlib — no PIL on this machine.
"""
import struct, zlib, sys, os

def read_rgba(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f"{path}: ไม่ใช่ไฟล์ PNG")
    pos, idat, plte, trns = 8, b'', None, None
    w = h = ct = None
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        c = data[pos+8:pos+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', c[:10])
            if bd != 8:
                sys.exit(f"รองรับเฉพาะ bit depth 8 (ไฟล์นี้ {bd})")
        elif typ == b'PLTE': plte = c
        elif typ == b'tRNS': trns = c
        elif typ == b'IDAT': idat += c
        pos += 12 + ln

    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    stride = w * ch
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        for i in range(stride):
            a = line[i-ch] if i >= ch else 0
            b = prev[i]
            cc = prev[i-ch] if i >= ch else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - cc
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-cc)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else cc)
                line[i] = (line[i] + pr) & 255
        out += line; prev = line

    rgba = bytearray(w * h * 4)
    for i in range(w * h):
        if ct == 3:
            idx = out[i]
            rgba[i*4:i*4+3] = plte[idx*3:idx*3+3]
            rgba[i*4+3] = trns[idx] if (trns and idx < len(trns)) else 255
        elif ct == 6:
            rgba[i*4:i*4+4] = out[i*4:i*4+4]
        elif ct == 2:
            rgba[i*4:i*4+3] = out[i*3:i*3+3]; rgba[i*4+3] = 255
        elif ct == 0:
            g = out[i]; rgba[i*4:i*4+3] = bytes([g, g, g]); rgba[i*4+3] = 255
        elif ct == 4:
            g = out[i*2]; rgba[i*4:i*4+3] = bytes([g, g, g]); rgba[i*4+3] = out[i*2+1]
    return w, h, rgba

def write_rgba(path, w, h, px):
    raw = b''.join(b'\x00' + bytes(px[y*w*4:(y+1)*w*4]) for y in range(h))
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 9))
           + chunk(b'IEND', b''))
    open(path, 'wb').write(png)

def trim(w, h, px):
    """Crop to the alpha bounding box so canvas padding doesn't shrink the art."""
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if px[(y*w+x)*4+3] > 0:
                minx = min(minx, x); maxx = max(maxx, x)
                miny = min(miny, y); maxy = max(maxy, y)
    if maxx < minx:
        sys.exit("ภาพโปร่งใสทั้งหมด")
    cw, chh = maxx-minx+1, maxy-miny+1
    out = bytearray(cw*chh*4)
    for y in range(chh):
        src = ((y+miny)*w + minx) * 4
        out[y*cw*4:(y+1)*cw*4] = px[src:src+cw*4]
    return cw, chh, out

def scale_nn(sw, sh, px, dw, dh):
    """Nearest-neighbour: blocky art must not go soft when enlarged."""
    out = bytearray(dw*dh*4)
    for y in range(dh):
        sy = y * sh // dh
        for x in range(dw):
            sx = x * sw // dw
            s = (sy*sw + sx) * 4
            out[(y*dw+x)*4:(y*dw+x)*4+4] = px[s:s+4]
    return out

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "Resources/MenuIcon.png"
    SIZE = 1024
    # Keep this near zero: macOS composites the artwork into its own rounded
    # tile and insets it while doing so, so padding added here stacks with the
    # system's and leaves the mascot marooned in the middle. Just enough margin
    # to keep the blocks off the very edge.
    PAD = 0.02

    w, h, px = read_rgba(src)
    cw, ch, cpx = trim(w, h, px)
    print(f"source {w}x{h} → ตัดขอบโปร่งใสเหลือ {cw}x{ch}")

    box = int(SIZE * (1 - 2*PAD))
    scale = min(box / cw, box / ch)
    tw, th = max(1, int(cw*scale)), max(1, int(ch*scale))
    art = scale_nn(cw, ch, cpx, tw, th)

    canvas = bytearray(SIZE*SIZE*4)
    ox, oy = (SIZE-tw)//2, (SIZE-th)//2
    for y in range(th):
        d = ((y+oy)*SIZE + ox) * 4
        canvas[d:d+tw*4] = art[y*tw*4:(y+1)*tw*4]

    os.makedirs("Resources", exist_ok=True)
    write_rgba("Resources/AppIcon-master.png", SIZE, SIZE, canvas)
    print(f"master {SIZE}x{SIZE} (art {tw}x{th}, padding {int(PAD*100)}%) → Resources/AppIcon-master.png")

if __name__ == "__main__":
    main()
