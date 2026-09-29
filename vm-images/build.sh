#!/bin/bash
# =============================================================================
# build.sh DISTRO ROLE [--ref GIT_REF] [--size MB] [--test] [--firmware bios|uefi|both]
#   DISTRO  debian-13            (the directory with the Dockerfile)
#   ROLE    node | hub           node: what the hub clones for every stack; hub: the same plus DCS and its first start
# Builds the root file system in Docker, assembles a bootable disk from it without root (BIOS and UEFI in one),
# and writes out/dcs-ROLE-DISTRO.qcow2 (+ .sha256). --test boots it the way Proxmox does and checks it.
# The hub image carries the DCS checkout at GIT_REF of this repository (default: HEAD).
# =============================================================================
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
DISTRO=${1:?usage: build.sh DISTRO ROLE [--ref GIT_REF] [--size MB] [--test] [--firmware bios|uefi|both]}; ROLE=${2:?role: node or hub}; shift 2
REF=HEAD; SIZE=4096; TEST=0; FWS="bios uefi"
while [[ $# -gt 0 ]]; do case "$1" in
    --ref) REF=$2; shift 2 ;; --size) SIZE=$2; shift 2 ;; --test) TEST=1; shift ;;
    --firmware) [[ $2 == both ]] && FWS="bios uefi" || FWS=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac; done
[[ -f "$HERE/$DISTRO/Dockerfile" ]] || { echo "no $DISTRO/Dockerfile" >&2; exit 2; }
[[ "$ROLE" == node || "$ROLE" == hub ]] || { echo "role is node or hub" >&2; exit 2; }
OUT=${OUT:-$HERE/out}; NAME=dcs-$ROLE-$DISTRO
WORK=$(mktemp -d /tmp/dcs-build.XXXXXX); trap 'docker run --rm -v "$WORK":/w debian:trixie-slim rm -rf /w/* >/dev/null 2>&1; rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/in"

echo "== tools"
docker build -q -t dcs-vm-tools:local -f "$HERE/tools/Dockerfile" "$HERE/tools" >/dev/null

echo "== $ROLE root file system ($DISTRO)"
ARGS=(--target "$ROLE" -t "dcs-vm-$DISTRO-$ROLE:local" -f "$HERE/$DISTRO/Dockerfile")
if [[ $ROLE == hub ]]; then
    # a clean checkout of the ref (never this working tree with its local state), talking to the same origin
    git clone -q --no-hardlinks "$ROOT" "$WORK/dcs"
    git -C "$WORK/dcs" checkout -q "$(git -C "$ROOT" rev-parse "$REF")"
    ORIGIN=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
    [[ -n "$ORIGIN" ]] && git -C "$WORK/dcs" remote set-url origin "$ORIGIN"
    echo "   DCS $(cat "$WORK/dcs/VERSION" 2>/dev/null) at $(git -C "$WORK/dcs" rev-parse --short HEAD)"
    ARGS+=(--build-context "dcs=$WORK/dcs")
fi
docker build -q "${ARGS[@]}" "$HERE" >/dev/null
echo "   $(docker image inspect "dcs-vm-$DISTRO-$ROLE:local" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1048576}') of files"

echo "== disk"
cid=$(docker create "dcs-vm-$DISTRO-$ROLE:local" /bin/true); docker export "$cid" -o "$WORK/in/rootfs.tar"; docker rm "$cid" >/dev/null
docker run --rm --tmpfs /tmp:size=9g -v "$WORK/in":/in:ro -v "$OUT":/out dcs-vm-tools:local assemble.sh "$NAME" "$SIZE" | sed 's/^/   /'
echo "   $OUT/$NAME.qcow2"

if [[ $TEST == 1 ]]; then
    rc=0
    for fw in $FWS; do echo; "$HERE/tests/boot-test.sh" "$OUT/$NAME.qcow2" --firmware "$fw" --role "$ROLE" || rc=1; done
    exit $rc
fi
