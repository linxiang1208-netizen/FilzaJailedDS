#!/bin/bash
# inject_to_filza.sh - 将编译好的 tweak 注入到 Filza IPA
# 用法: ./inject_to_filza.sh <filza.ipa> <tweak.dylib>

if [ $# -lt 2 ]; then
    echo "Usage: $0 <Filza.ipa> <tweak.dylib>"
    echo "Example: $0 Filza-4.0.0.ipa .theos/obj/FilzaApplySandboxExt.dylib"
    exit 1
fi

FILZA_IPA=$1
TWEAK_DYLIB=$2
OUTPUT_IPA="FilzaJailedDS.ipa"
WORK_DIR="filza_inject_work"

echo "[*] Cleaning up..."
rm -rf $WORK_DIR $OUTPUT_IPA

echo "[*] Extracting IPA..."
mkdir -p $WORK_DIR
unzip -q "$FILZA_IPA" -d $WORK_DIR

echo "[*] Finding Filza binary..."
FILZA_BINARY=$(find $WORK_DIR -name "Filza" -type f | head -1)
if [ -z "$FILZA_BINARY" ]; then
    echo "[-] Filza binary not found!"
    exit 1
fi
echo "[+] Found: $FILZA_BINARY"

echo "[*] Injecting tweak with optool..."
# Install optool: brew install optool
optool install -c load -p "@executable_path/FilzaApplySandboxExt.dylib" -t "$FILZA_BINARY"

echo "[*] Copying tweak dylib..."
cp "$TWEAK_DYLIB" "$(dirname $FILZA_BINARY)/FilzaApplySandboxExt.dylib"

echo "[*] Copying required frameworks..."
# Copy IOSurface framework if needed
mkdir -p "$WORK_DIR/Payload/Filza.app/Frameworks"

echo "[*] Repackaging IPA..."
cd $WORK_DIR
zip -qr "../$OUTPUT_IPA" Payload/
cd ..

echo "[+] Done! Output: $OUTPUT_IPA"
echo "[*] Install with Sideloadly, AltStore, or TrollStore"