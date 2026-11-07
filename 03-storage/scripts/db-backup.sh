#!/bin/bash
set -euo pipefail
export LVM_SUPPRESS_FD_WARNINGS=1

VG=vg_data
LV=lv_db
SNAP=lv_db_snap
SNAP_SIZE=500M
KEY=/etc/luks-keys/db.key
MAP=db_snap
MNT=/mnt/db-snap
SRC_MNT=/var/lib/postgresql
DEST=/backup/db
KEEP=7
STAMP=$(date +%F_%H%M%S)

log() {
  logger -t db-backup "$*"
  echo "[db-backup] $*"
}

exec 9>/run/db-backup.lock
flock -n 9 || { echo "already running"; exit 1; }

FROZEN=0
cleanup() {
  rc=$?
  if [[ $FROZEN -eq 1 ]]; then
    fsfreeze -u "$SRC_MNT" || true
  fi
  if mountpoint -q "$MNT"; then
    umount "$MNT" || true
  fi
  if [[ -e /dev/mapper/$MAP ]]; then
    cryptsetup close "$MAP" || true
  fi
  if lvs "$VG/$SNAP" &>/dev/null; then
    lvremove -y "$VG/$SNAP" >/dev/null || true
  fi
  if [[ $rc -eq 0 ]]; then
    log "OK: $DEST/$STAMP"
  else
    log "FAILED rc=$rc, cleanup done"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mountpoint -q "$SRC_MNT"
mkdir -p "$MNT" "$DEST"

log "freeze + snapshot"
fsfreeze -f "$SRC_MNT"
FROZEN=1
lvcreate -s -L "$SNAP_SIZE" -n "$SNAP" "$VG/$LV" >/dev/null
fsfreeze -u "$SRC_MNT"
FROZEN=0

log "open + mount snapshot"
cryptsetup open --key-file "$KEY" "/dev/$VG/$SNAP" "$MAP"
mount -o ro,nouuid "/dev/mapper/$MAP" "$MNT"

if [[ -n ${BREAK_TEST:-} ]]; then
  log "BREAK_TEST: simulated failure"
  exit 1
fi

PREV=$(ls -1d "$DEST"/20* 2>/dev/null | tail -n1 || true)
log "rsync (link-dest: ${PREV:-none})"
rsync -aHAX --delete ${PREV:+--link-dest="$PREV"} \
  "$MNT"/ "$DEST/$STAMP"/

ls -1d "$DEST"/20* | head -n -"$KEEP" | xargs -r rm -rf --
