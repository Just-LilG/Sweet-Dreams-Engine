#!/system/bin/sh
# cortex/games/seed_profiles.sh - Sweet Dreams Preloaded Game List
#
# CONCEPT PORTED FROM: AZenith's azenithApplist.json - a curated database
# of known games with sensible default per-app settings, so a user doesn't
# have to manually tune every single setting for every game themselves.
# AZenith's own list only covers 11 titles (mostly gacha/visual novel);
# this seeds Sweet Dreams' much larger 42-game KNOWN_GAMES list (see
# webroot/index.html) with real per-genre defaults instead.
#
# HOW IT WORKS: writes a profile file to cortex/games/profiles/<pkg>.txt
# for each known game - but ONLY if that file doesn't already exist. A
# user's own manual profile edits (via the WebUI's per-game settings) are
# never overwritten; this only fills in a sensible starting point for
# games that have never been configured at all. Runs once at install
# time (customize.sh) - not on every boot, so it never fights a user's
# later changes.
#
# DEFAULTS ARE GENRE-BASED, NOT GUESSED PER-TITLE:
#   Competitive shooters (COD Mobile, PUBG, Free Fire) - high refresh
#   lock, no resolution downscale by default (visual clarity matters for
#   aim), gaming profile.
#   Battle royale / open-world (PUBG, Free Fire) - slightly more
#   aggressive thermal headroom since sessions run longer.
#   MOBA (Mobile Legends, Wild Rift) - balanced profile, these are far
#   less GPU-intensive than shooters, no need for max aggression.
#   Heavy 3D / gacha (Genshin, HSR, Wuthering Waves) - resolution
#   downscale defaults ON at 0.8, since these are the titles most likely
#   to actually need the FPS headroom from it, and least likely to be
#   competitive-aim-critical.

MODDIR="/data/adb/modules/sweet_dreams"
PROFILES_DIR="$MODDIR/cortex/games/profiles"
LOGFILE="$MODDIR/boot.log"

log_seed() { echo "[GAME_PROFILES] $1" | tee -a "$LOGFILE"; }

mkdir -p "$PROFILES_DIR"

write_profile_if_missing() {
    local PKG="$1" PROFILE="$2" FPS="$3" RR_LOCK="$4" FPS_LOCK="$5" RES="$6"
    local FILE="$PROFILES_DIR/$(echo "$PKG" | tr '.' '-').txt"
    [ -f "$FILE" ] && return   # never overwrite an existing/user-edited profile

    {
        echo "profile=$PROFILE"
        echo "fps=$FPS"
        echo "rr_lock=$RR_LOCK"
        echo "fps_lock=$FPS_LOCK"
        echo "resolution=default"
        echo "seeded=1"
    } > "$FILE"
}

SEEDED=0

# -- Competitive shooters - clarity over raw FPS, no downscale by default ----─
for PKG in \
    com.activision.callofduty.shooter \
    com.garena.game.codm \
    com.vng.codmvn \
    com.tencent.ig \
    com.pubg.krmobile \
    com.rekoo.pubgm \
    com.vng.pubgmobile \
    com.dts.freefiremax \
    com.dts.freefireth; do
    write_profile_if_missing "$PKG" "gaming" "120" "on" "on" "native"
    SEEDED=$((SEEDED + 1))
done

# -- MOBA - less GPU-intensive, balanced is enough ----------------------------─
for PKG in \
    com.mobile.legends \
    com.riotgames.league.wildrift \
    com.tencent.tmgp.sgame; do
    write_profile_if_missing "$PKG" "balanced" "90" "on" "off" "native"
    SEEDED=$((SEEDED + 1))
done

# -- Heavy 3D / open-world / gacha - benefit most from downscale headroom ----─
for PKG in \
    com.miHoYo.GenshinImpact \
    com.HoYoverse.hkrpgoversea \
    com.miHoYo.Yuanshen \
    com.kurogame.wutheringwaves.global \
    com.tencent.tmgp.sgamece \
    com.netease.dwrg.cn; do
    write_profile_if_missing "$PKG" "gaming" "60" "off" "off" "0.8"
    SEEDED=$((SEEDED + 1))
done

log_seed "pre-tuned $SEEDED games for you - nothing overwritten, just a head start"
