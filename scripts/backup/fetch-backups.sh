#!/usr/bin/env bash
# DRAFT (S10B design, 2026-10-20): NOT used yet. Pulls COMPLETE encrypted backup sets from the EC2 instance to this computer over SSH
# (run in Git Bash on the laptop; ssh, tar and sha256sum are part of Git for Windows).
#
#   fetch-backups.sh --host ubuntu@<ip> --key <path to the ssh key> [--dest <dir>] [--remote-dir /var/backups/prodflow]
#                    [--latest] [--keep-local <n>] [--dry-run]
#
# - Pull only: nothing is ever deleted or changed on the server (the server prunes itself). The backup directory there is root-only, so the sets
#   are streamed through "sudo -n tar" over the existing SSH connection: no temporary archive on the server, no extra permissions, no extra port.
# - Everything stays encrypted. Integrity: every set is verified against its SHA256SUMS and the sha256 recorded in each manifest before it is
#   marked FETCHED_OK. A set that fails verification is removed from the destination and reported.
# - The destination must NOT be inside a Git work tree (the encrypted dumps must never be committed by accident).
# - The private decryption key is not needed here and never leaves the laptop.
# Exit: 0 = everything requested is present and verified, 1 = a download or verification failed, 2 = usage/precondition error.
set -u -o pipefail
export LC_ALL=C MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
HOST=''; KEY=''; DEST="${HOME:-.}/prodflow-backups-enc"; REMOTE=/var/backups/prodflow; LATEST=0; KEEP_LOCAL=0; DRY=0
usage() { echo "usage: $0 --host user@ip --key <ssh key> [--dest dir] [--remote-dir dir] [--latest] [--keep-local n] [--dry-run]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --dest) DEST=${2:-}; shift 2 ;;
    --remote-dir) REMOTE=${2:-}; shift 2 ;;
    --latest) LATEST=1; shift ;;
    --keep-local) KEEP_LOCAL=${2:-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage; exit 2 ;;
  esac
done
say() { echo "fetch: $*"; }
fail() { echo "fetch: ABORT: $*" >&2; exit 2; }
[[ $HOST =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] || fail "--host must look like user@host"
[ -n "$KEY" ] && [ -f "$KEY" ] || fail "--key must be an existing ssh key file"
[[ $REMOTE =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "--remote-dir must be an absolute path without special characters"
[[ $KEEP_LOCAL =~ ^[0-9]+$ ]] || fail "--keep-local must be a number"
for t in ssh tar sha256sum date awk; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"; done
probe=$DEST; [ -d "$probe" ] || probe=$(dirname "$DEST")
if command -v git >/dev/null 2>&1 && [ "$( cd "$probe" 2>/dev/null && git rev-parse --is-inside-work-tree 2>/dev/null )" = true ]; then
  fail "the destination $DEST is inside a Git work tree; choose a directory outside any repository"
fi
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15)

# the remote command is single-quoted for the server's shell; \$d must reach the server unexpanded
raw=$("${SSH[@]}" "$HOST" "sudo -n sh -c 'cd $REMOTE && for d in set-*; do [ -f \"\$d/SET_OK\" ] && echo \"\$d\"; done; true'" 2>/dev/null) || fail "cannot list the sets on the server"
sets=$(printf '%s\n' "$raw" | grep -E '^set-[0-9]{8}T[0-9]{6}Z$' | sort || true)
[ -n "$sets" ] || { echo "fetch: no complete backup set on the server" >&2; exit 1; }
[ "$LATEST" = 1 ] && sets=$(printf '%s\n' "$sets" | tail -1)

newest=$(printf '%s\n' "$sets" | tail -1); ts=${newest#set-}
iso="${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z"
age_h=$(( ( $(date -u +%s) - $(date -u -d "$iso" +%s 2>/dev/null || echo 0) ) / 3600 ))
say "newest complete set on the server: $newest (about $age_h h old)"
[ "$age_h" -le 26 ] || say "WARNING: the newest set is older than 26 hours"

[ "$DRY" = 1 ] || mkdir -p -m 700 "$DEST"
rc=0
for set in $sets; do
  if [ -f "$DEST/$set/FETCHED_OK" ]; then say "$set already present"; continue; fi
  if [ "$DRY" = 1 ]; then say "would fetch $set"; continue; fi
  part="$DEST/$set.partial"; rm -rf "$part"; mkdir -p -m 700 "$part"
  say "fetching $set"
  "${SSH[@]}" "$HOST" "sudo -n tar -C $REMOTE -cf - $set" | tar -xf - --no-same-owner -C "$part"
  st=("${PIPESTATUS[@]}")
  if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then say "$set: transfer failed (ssh ${st[0]}, tar ${st[1]})"; rm -rf "$part"; rc=1; continue; fi
  d="$part/$set"; bad=0
  [ -f "$d/SET_OK" ] && [ -f "$d/SHA256SUMS" ] || { say "$set: SET_OK or SHA256SUMS missing"; bad=1; }
  [ "$bad" = 0 ] && ( cd "$d" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ) || { say "$set: SHA256SUMS verification failed"; bad=1; }
  if [ "$bad" = 0 ]; then
    for m in "$d"/*.manifest; do
      want=$(sed -n 's/^encrypted_sha256=//p' "$m"); file=$(sed -n 's/^encrypted_file=//p' "$m")
      have=$(sha256sum "$d/$file" 2>/dev/null | awk '{print $1}')
      [ -n "$want" ] && [ "$want" = "$have" ] || { say "$set: $(basename "$m") does not match its dump file"; bad=1; }
    done
  fi
  if [ "$bad" != 0 ]; then rm -rf "$part"; rc=1; continue; fi
  mv "$d" "$DEST/$set" && rmdir "$part" && date -u +%FT%TZ >"$DEST/$set/FETCHED_OK"
  say "$set verified and stored in $DEST/$set"
done

if [ "$KEEP_LOCAL" -gt 0 ] && [ "$DRY" = 0 ]; then
  n=0
  for d in $(ls -1d "$DEST"/set-* 2>/dev/null | sort -r); do
    [ -f "$d/FETCHED_OK" ] || continue
    n=$((n + 1)); [ "$n" -gt "$KEEP_LOCAL" ] && { rm -rf -- "$d"; say "removed old local set $(basename "$d")"; }
  done
fi
exit $rc
