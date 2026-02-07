#!/usr/bin/env python3
"""Generate an .icns file from a 1024x1024 PNG source image.

Creates all required icon sizes for macOS app icons:
  16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024
  (plus @2x retina variants)

Usage: python3 create-icns.py [source.png] [output.icns]
"""

import struct
import sys
import io
from PIL import Image

# macOS .icns icon types and their sizes
# Format: (ostype, pixel_size)
ICON_SIZES = [
    (b'ic04', 16),     # 16x16
    (b'ic05', 32),     # 32x32 (also 16x16@2x)
    (b'ic06', 64),     # 64x64 (also 32x32@2x)
    (b'ic07', 128),    # 128x128
    (b'ic08', 256),    # 256x256 (also 128x128@2x)
    (b'ic09', 512),    # 512x512 (also 256x256@2x)
    (b'ic10', 1024),   # 1024x1024 (also 512x512@2x)
]

def create_icns(source_path, output_path):
    """Create an .icns file from a source PNG."""
    img = Image.open(source_path)

    # Ensure RGBA
    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    # Ensure 1024x1024
    if img.size != (1024, 1024):
        img = img.resize((1024, 1024), Image.LANCZOS)

    # Build icon entries
    entries = []
    for ostype, size in ICON_SIZES:
        resized = img.resize((size, size), Image.LANCZOS)
        buf = io.BytesIO()
        resized.save(buf, format='PNG')
        png_data = buf.getvalue()

        # Each entry: 4-byte type + 4-byte length (includes type+length) + data
        entry_length = 8 + len(png_data)
        entry = ostype + struct.pack('>I', entry_length) + png_data
        entries.append(entry)

    # Build the .icns file
    # Header: 'icns' + 4-byte total file size
    body = b''.join(entries)
    total_size = 8 + len(body)
    icns_data = b'icns' + struct.pack('>I', total_size) + body

    with open(output_path, 'wb') as f:
        f.write(icns_data)

    print(f"Created {output_path} ({total_size:,} bytes)")
    print(f"  Sizes: {', '.join(f'{s}x{s}' for _, s in ICON_SIZES)}")

if __name__ == '__main__':
    source = sys.argv[1] if len(sys.argv) > 1 else 'image.png'
    output = sys.argv[2] if len(sys.argv) > 2 else 'AppIcon.icns'
    create_icns(source, output)
