#!/system/bin/sh
# Persist user settings outside the module directory.
# Magisk/KernelSU updates replace every file that ships in the zip, so
# cortex/*.txt values the WebUI wrote would otherwise reset every flash.
# Mirror lives at /data/adb/sweet_dreams_persist/ and is restored at
# install (customize.sh) and boot (service.sh).

MODDIR="${MODDIR:-/data/adb/modules/sweet_dreams}"
CORTEX="${CORTEX:-$MODDIR/cortex}"
PERSIST="/data/adb/sweet_dreams_persist"

mkdir -p "$PERSIST" 2>/dev/null

is_live_file() {
    case "$1" in
        */health/*|*/fake/*|*/icon_cache/*|*/label_cache.txt|*/last_verify.txt|*/mounted.list|*/session.log|*/status_live.txt|*/resolution_applied_pkg.txt|*/resolution_applied_factor.txt|*/resolution_relaunch_grace.txt|*/wm_size_backup.txt|*/cpuinfo_mounted.txt|*/spoof_c_session.txt|*/override_active.txt|*/saved_profile.txt)
            return 0
            ;;
    esac
    return 1
}

persist_rel() {
    printf '%s' "$1" | sed "s|^$CORTEX/||"
}

cmd_save() {
    mkdir -p "$PERSIST"
    find "$CORTEX" -type f \( -name '*.txt' -o -name '*.spoof_c' \) 2>/dev/null | while IFS= read -r f; do
        is_live_file "$f" && continue
        rel=$(persist_rel "$f")
        [ -z "$rel" ] && continue
        mkdir -p "$PERSIST/$(dirname "$rel")"
        cp -f "$f" "$PERSIST/$rel" 2>/dev/null
    done
}

cmd_restore() {
    [ -d "$PERSIST" ] || return 0
    find "$PERSIST" -type f 2>/dev/null | while IFS= read -r f; do
        rel=${f#$PERSIST/}
        dest="$CORTEX/$rel"
        mkdir -p "$(dirname "$dest")"
        cp -f "$f" "$dest" 2>/dev/null
    done
}

cmd_file() {
    src="$1"
    [ -f "$src" ] || return 0
    rel=$(persist_rel "$src")
    [ -z "$rel" ] && return 0
    mkdir -p "$PERSIST/$(dirname "$rel")"
    cp -f "$src" "$PERSIST/$rel" 2>/dev/null
}

case "$1" in
    save) cmd_save ;;
    restore) cmd_restore ;;
    file) cmd_file "$2" ;;
    *)
        echo "usage: persist.sh save|restore|file <path>" >&2
        exit 1
        ;;
esac
