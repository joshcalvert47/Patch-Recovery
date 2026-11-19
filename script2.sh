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

# ---------------------------------------------------------------------------
# Collect the model/firmware of the recovery being patched, for the release
# ---------------------------------------------------------------------------
prop_get() {
    local file value
    while IFS= read -r file; do
        value=$(awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file")
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    done < <(find . -type f \( -name '*.prop' -o -name 'prop.default' \) | sort)
    return 1
}

or_unknown() {
    if [ -n "$1" ]; then printf '%s' "$1"; else printf 'unknown'; fi
}

recovery_model=$(prop_get ro.product.model || true)
recovery_device=$(or_unknown "$(prop_get ro.product.device || true)")
recovery_firmware=$(prop_get ro.build.display.id || true)
if [ -z "$recovery_firmware" ]; then
    recovery_firmware=$(prop_get ro.build.version.incremental || true)
fi
recovery_firmware=$(or_unknown "$recovery_firmware")
recovery_android=$(or_unknown "$(prop_get ro.build.version.release || true)")
recovery_fingerprint=$(or_unknown "$(prop_get ro.build.fingerprint || true)")
# Some recovery prop files only carry the fingerprint
if [ -z "$recovery_model" ] && [ "$recovery_fingerprint" != unknown ]; then
    recovery_model=$(printf '%s' "$recovery_fingerprint" | cut -d/ -f2)
fi
recovery_model=$(or_unknown "$recovery_model")

{
    printf 'RECOVERY_MODEL=%s\n' "$recovery_model"
    printf 'RECOVERY_DEVICE=%s\n' "$recovery_device"
    printf 'RECOVERY_FIRMWARE=%s\n' "$recovery_firmware"
    printf 'RECOVERY_ANDROID=%s\n' "$recovery_android"
    printf 'RECOVERY_FINGERPRINT=%s\n' "$recovery_fingerprint"
} > ../recovery-info.env

printf 'recovery info: model=%s device=%s firmware=%s android=%s\n' \
    "$recovery_model" "$recovery_device" "$recovery_firmware" "$recovery_android"

cp system/bin/recovery recovery.orig

# Try a patch; a non-matching pattern is not an error (patterns are per-firmware)
patch_hex() {
    if ../magiskboot hexpatch system/bin/recovery "$1" "$2"; then
        echo "MATCHED: $1"
    else
        echo "no match: $1"
    fi
}

patch_hex_file() {
    if ../magiskboot hexpatch "$1" "$2" "$3"; then
        echo "MATCHED: $2 ($1)"
    else
        echo "no match: $2 ($1)"
    fi
}

# Files edited outside system/bin/recovery, re-added to the cpio when repacking
changed_files=""
remember_file() {
    changed_files="$changed_files $1"
}

file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
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

# ---------------------------------------------------------------------------
# Enable root adb in recovery: `adb root` works and `adb shell` is a root shell
# ---------------------------------------------------------------------------
adb_root_enabled=0

# <file> <key> <value>: replace the key in place, or append it
set_prop() {
    local file="$1" key="$2" value="$3"
    local key_re="${key//./\\.}"
    if grep -q "^${key_re}=" "$file"; then
        sed -i.sed.bak "s|^${key_re}=.*|${key}=${value}|" "$file"
        rm -f "$file.sed.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# ro.debuggable allows `adb root`, ro.secure keeps it root by default,
# ro.adb.secure=0 skips adb key auth and service.adb.root=1 starts it as root
while IFS= read -r prop; do
    [ -L "$prop" ] && continue
    cp "$prop" "$prop.adbroot.bak"
    set_prop "$prop" ro.secure 0
    set_prop "$prop" ro.debuggable 1
    set_prop "$prop" ro.adb.secure 0
    set_prop "$prop" persist.service.adb.enable 1
    set_prop "$prop" service.adb.root 1
    if cmp -s "$prop.adbroot.bak" "$prop"; then
        rm -f "$prop.adbroot.bak"
        echo "adb root: $prop already set"
        adb_root_enabled=1
        continue
    fi
    rm -f "$prop.adbroot.bak"
    echo "adb root: patched $prop"
    remember_file "$prop"
    adb_root_enabled=1
done < <(find . -type f \( -name prop.default -o -name default.prop \) | sort)

# adbd only starts in recovery from `on property:ro.debuggable=1`, and only stays
# root with service.adb.root=1, so hook both triggers in the rc that owns adbd
adb_rc=""
while IFS= read -r rc; do
    if [ ! -L "$rc" ] && grep -q '^service adbd ' "$rc"; then
        adb_rc="$rc"
        break
    fi
done < <(find . -type f -name '*.rc' | sort)

if [ -n "$adb_rc" ]; then
    if grep -q 'Patch-Recovery: root adb' "$adb_rc"; then
        echo "adb root: $adb_rc already hooked"
        adb_root_enabled=1
    else
        # Restarting adbd is only needed when the rc has no restart trigger of its own
        have_restart=0
        if grep -q 'on property:service\.adb\.root=1' "$adb_rc"; then
            have_restart=1
        fi
        {
            echo
            echo '# Patch-Recovery: root adb in recovery (`adb root` / root `adb shell`)'
            echo 'on property:ro.debuggable=1'
            echo '    setprop service.adb.root 1'
            if [ "$have_restart" = 0 ]; then
                echo
                echo 'on property:service.adb.root=1'
                echo '    restart adbd'
            fi
        } >> "$adb_rc"
        echo "adb root: hooked adbd in $adb_rc"
        remember_file "$adb_rc"
        adb_root_enabled=1
    fi
else
    echo "WARNING: no rc file defining 'service adbd'; cannot hook root adb" >&2
fi

# A user-build adbd drops from root to uid/gid 2000 (shell) before it even looks
# at those props. Turn that argument into 0 so the daemon stays root (arm64).
for adbd in system/bin/adbd sbin/adbd; do
    [ -f "$adbd" ] || continue
    cp "$adbd" "$adbd.adbroot.bak"
    patch_hex_file "$adbd" 01fa8052 01008052 # mov w1, #0x7d0 -> mov w1, #0
    patch_hex_file "$adbd" 00fa8052 00008052 # mov w0, #0x7d0 -> mov w0, #0
    if cmp -s "$adbd.adbroot.bak" "$adbd"; then
        echo "adb root: adbd privilege drop not found in $adbd (props only)"
    else
        echo "adb root: patched adbd privilege drop in $adbd"
        remember_file "$adbd"
        adb_root_enabled=1
    fi
    rm -f "$adbd.adbroot.bak"
done

if [ "$adb_root_enabled" = 1 ]; then
    echo "adb root: enabled in recovery (adb root / adb shell as root)"
else
    echo "WARNING: could not enable adb root in this recovery ramdisk" >&2
fi

cpio_args=('rm system/bin/recovery' 'add 0755 system/bin/recovery system/bin/recovery')
for f in $changed_files; do
    f="${f#./}"
    cpio_args+=("rm $f" "add $(file_mode "$f") $f $f")
done
../magiskboot cpio "$ramdisk" "${cpio_args[@]}"

if [ "$ramdisk" != "ramdisk.cpio" ]; then
    cp "$ramdisk" ramdisk.cpio
fi

../magiskboot repack ../r.img ../recovery-patched.img

cd ..
test -s recovery-patched.img
