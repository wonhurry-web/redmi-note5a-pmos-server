import struct, zlib, sys

W, H = 720, 1280
STRIDE = 2944  # bytes per row (720*4 + padding)
src = sys.argv[1]
dst = sys.argv[2]

with open(src, 'rb') as f:
    data = f.read()

def png_chunk(typ, payload):
    c = struct.pack('>I', len(payload)) + typ + payload
    c += struct.pack('>I', zlib.crc32(typ + payload) & 0xffffffff)
    return c

raw = bytearray()
for y in range(H):
    raw.append(0)  # filter type 0
    row_start = y * STRIDE
    for x in range(W):
        i = row_start + x * 4
        b, g, r, a = data[i], data[i+1], data[i+2], data[i+3]
        raw += bytes((r, g, b))

ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)  # 8-bit RGB
png = b'\x89PNG\r\n\x1a\n'
png += png_chunk(b'IHDR', ihdr)
png += png_chunk(b'IDAT', zlib.compress(bytes(raw), 6))
png += png_chunk(b'IEND', b'')

with open(dst, 'wb') as f:
    f.write(png)
print("wrote", dst, len(png), "bytes")
