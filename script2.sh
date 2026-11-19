#!/bin/bash
set -euo pipefail

rm -rf unpack
mkdir -p unpack
cd unpack

../magiskboot unpack ../r.img

ramdisk="ramdisk.cpio"
if [ -f vendor_ramdisk/recovery.cpio ]; then
    ramdisk="vendor_ramdisk/recovery.cpio"
elif [ -f vendor_ramdisk_recovery.cpio ]; then
    ramdisk="vendor_ramdisk_recovery.cpio"
fi

../magiskboot cpio "$ramdisk" extract
test -f system/bin/recovery

cp system/bin/recovery recovery.orig

# Try a patch; a non-matching pattern is not an error (patterns are per-firmware)
patch_hex() {
    if ../magiskboot hexpatch system/bin/recovery "$1" "$2"; then
        echo "MATCHED: $1"
    else
        echo "no match: $1"
    fi
}

# Reverse fastbootd ENG mode check
patch_hex e10313aaf40300aa6ecc009420010034 e10313aaf40300aa6ecc0094
patch_hex eec3009420010034 eec3009420010035
patch_hex 3ad3009420010034 3ad3009420010035
patch_hex 50c0009420010034 50c0009420010035
patch_hex 080109aae80000b4 080109aae80000b5
patch_hex 20f0a6ef38b1681c 20f0a6ef38b9681c
patch_hex 23f03aed38b1681c 23f03aed38b9681c
patch_hex 20f09eef38b1681c 20f09eef38b9681c
patch_hex 26f0ceec30b1681c 26f0ceec30b9681c
patch_hex 24f0fcee30b1681c 24f0fcee30b9681c
patch_hex 27f02eeb30b1681c 27f02eeb30b9681c
patch_hex b4f082ee28b1701c b4f082ee28b970c1
patch_hex 9ef0f4ec28b1701c 9ef0f4ec28b970c1
patch_hex 9ef00ced28b1701c 9ef00ced28b970c1
patch_hex 2001597ae0000054 2001597ae1000054
patch_hex 2001597ac0000054 2001597ac1000054
patch_hex 9ef0fcec28b1701c 9ef0fced28b970c1
patch_hex 24f0f2ea30b1681c 24f0f2ea30b9681c
patch_hex e0031f2a8e000014 200080528e000014
patch_hex 41010054a0020012f44f48a9 4101005420008052f44f48a9

# Fail loudly if nothing changed, instead of producing an unpatched image
if cmp -s recovery.orig system/bin/recovery; then
    echo "ERROR: no hex patterns matched this firmware's system/bin/recovery" >&2
    exit 1
fi

../magiskboot cpio "$ramdisk" \
  'rm system/bin/recovery' \
  'add 0755 system/bin/recovery system/bin/recovery'

if [ "$ramdisk" != "ramdisk.cpio" ]; then
    cp "$ramdisk" ramdisk.cpio
fi

../magiskboot repack ../r.img ../recovery-patched.img

cd ..
test -s recovery-patched.img
