#!/usr/bin/env bash
# Retire disk cache generations hidden by the node_modules tmpfs mounts.
set -euo pipefail

root=$(realpath -e -- "${1:-/opt/ci-tier}")
under=
cleanup() {
  if [ -n "$under" ]; then
    mountpoint -q "$under" && umount "$under"
    rmdir "$under"
    under=
  fi
}
trap cleanup EXIT

for parent in "$root/pr/cache" "$root/trusted/cache" "$root/pr-containers" "$root/trusted-containers"; do
  [ -d "$parent/node_modules" ] || continue
  [ "$(realpath -e -- "$parent/node_modules")" = "$parent/node_modules" ] || exit 1
  mountpoint -q "$parent/node_modules" || continue
  [ "$(findmnt -n -o FSTYPE -T "$parent/node_modules")" = tmpfs ] || continue

  under=$(mktemp -d /run/ci-cache-underlay.XXXXXX)
  # A non-recursive parent bind exposes the disk directory, keeping live RAM
  # generations mounted and untouched. Apply the same seven-day retention.
  mount --bind "$parent" "$under"
  [ "$(findmnt -n -o FSTYPE -T "$under/node_modules")" != tmpfs ]
  find "$under/node_modules" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf -- {} +
  cleanup
done
