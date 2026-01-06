#!/bin/bash
# Setup script for v86 VM
# Downloads all required v86 assets for local/S3 hosting

set -e

echo "=== VM Setup ==="
echo ""

# Create directories
mkdir -p assets/bios
mkdir -p assets/images

echo "Downloading v86 library files..."

# The npm package on jsdelivr should have the built files
# Try jsdelivr first (CORS-friendly CDN)
echo "  Attempting jsdelivr CDN..."
curl -L --fail -o assets/libv86.js "https://cdn.jsdelivr.net/npm/v86@latest/build/libv86.js" 2>/dev/null || {
    echo "  jsdelivr build/libv86.js not found, trying alternative paths..."
    # Try without build/ path (npm package might expose it differently)
    curl -L --fail -o assets/libv86.js "https://cdn.jsdelivr.net/npm/v86@latest" 2>/dev/null || {
        echo "  Trying unpkg..."
        curl -L --fail -o assets/libv86.js "https://unpkg.com/v86@latest/build/libv86.js" 2>/dev/null || {
            echo ""
            echo "  ⚠️  Could not download libv86.js from CDN."
            echo "  You'll need to build it manually:"
            echo "    git clone https://github.com/copy/v86.git"
            echo "    cd v86 && make build/libv86.js"
            echo "    cp build/libv86.js ../assets/"
            echo ""
        }
    }
}

echo "  Downloading v86.wasm..."
curl -L --fail -o assets/v86.wasm "https://cdn.jsdelivr.net/npm/v86@latest/build/v86.wasm" 2>/dev/null || {
    curl -L --fail -o assets/v86.wasm "https://unpkg.com/v86@latest/build/v86.wasm" 2>/dev/null || {
        echo "  ⚠️  Could not download v86.wasm from CDN."
        echo "  Build instructions same as above."
    }
}

# Download BIOS files from jsdelivr (these should be in the npm package)
echo ""
echo "Downloading BIOS files..."
curl -L --fail -o assets/bios/seabios.bin "https://cdn.jsdelivr.net/npm/v86@latest/bios/seabios.bin" 2>/dev/null || {
    curl -L --fail -o assets/bios/seabios.bin "https://unpkg.com/v86@latest/bios/seabios.bin" 2>/dev/null || {
        echo "  ⚠️  Could not download seabios.bin"
    }
}

curl -L --fail -o assets/bios/vgabios.bin "https://cdn.jsdelivr.net/npm/v86@latest/bios/vgabios.bin" 2>/dev/null || {
    curl -L --fail -o assets/bios/vgabios.bin "https://unpkg.com/v86@latest/bios/vgabios.bin" 2>/dev/null || {
        echo "  ⚠️  Could not download vgabios.bin"
    }
}

# Download OS images from copy.sh CDN (these are large binary files not in npm)
echo ""
echo "Downloading Linux images from i.copy.sh..."
echo "  - buildroot-bzimage68.bin (minimal Linux with Python, curl, etc.)"

# Use the correct URL from the latest README: https://i.copy.sh/
curl -L --fail -o assets/images/buildroot-bzimage.bin "https://i.copy.sh/buildroot-bzimage68.bin" 2>/dev/null || {
    # Try older filename
    curl -L --fail -o assets/images/buildroot-bzimage.bin "https://k.copy.sh/buildroot-bzimage.bin" 2>/dev/null || {
        echo "  ⚠️  Could not download buildroot image"
        echo "  Try manually: curl -L -o assets/images/buildroot-bzimage.bin https://i.copy.sh/buildroot-bzimage68.bin"
    }
}

# Check what we got
echo ""
echo "=== Download Results ==="
echo ""
for f in assets/libv86.js assets/v86.wasm assets/bios/seabios.bin assets/bios/vgabios.bin assets/images/buildroot-bzimage.bin; do
    if [ -f "$f" ] && [ -s "$f" ]; then
        size=$(ls -lh "$f" | awk '{print $5}')
        echo "  ✓ $f ($size)"
    else
        echo "  ✗ $f (missing or empty)"
    fi
done

echo ""
echo "=== Alternative: Build from source ==="
echo ""
echo "If CDN downloads failed, build v86 from source:"
echo ""
echo "  git clone https://github.com/copy/v86.git"
echo "  cd v86"
echo "  make build/libv86.js build/v86.wasm"
echo "  cp build/libv86.js build/v86.wasm ../assets/"
echo "  cp bios/*.bin ../assets/bios/"
echo ""
echo "Download images directly:"
echo "  curl -L -o assets/images/buildroot-bzimage.bin https://i.copy.sh/buildroot-bzimage68.bin"
echo ""

# Check if we have enough to run
if [ -f "assets/libv86.js" ] && [ -s "assets/libv86.js" ] && \
   [ -f "assets/v86.wasm" ] && [ -s "assets/v86.wasm" ] && \
   [ -f "assets/bios/seabios.bin" ] && [ -s "assets/bios/seabios.bin" ] && \
   [ -f "assets/images/buildroot-bzimage.bin" ] && [ -s "assets/images/buildroot-bzimage.bin" ]; then
    echo "=== Ready to run! ==="
    echo ""
    echo "Start local server:"
    echo "  python3 -m http.server 8080"
    echo ""
    echo "Then open:"
    echo "  http://localhost:8080/index-local.html"
else
    echo "=== Some files missing ==="
    echo ""
    echo "Please download missing files manually before running."
fi
