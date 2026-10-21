#!/usr/bin/env bash
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
rc=0

log() { printf '%s arc-prune: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
run() { "$@" || { log "failed: $*"; rc=1; }; }
disk() { read -r total available < <(df -B1 --output=size,avail / | tail -n 1); }
enough_space() { disk && [ "$available" -ge "$target" ]; }
policy() {
  local settings
  settings=$(/usr/local/bin/k3s kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz" |
    jq -er '.kubeletconfig | [.imageGCHighThresholdPercent, .imageGCLowThresholdPercent] | @tsv') || return 1
  read -r high low <<< "$settings"
  [[ "$high" =~ ^[0-9]+$ && "$low" =~ ^[0-9]+$ ]] &&
    [ "$low" -gt 0 ] && [ "$high" -gt "$low" ] && [ "$high" -lt 100 ] || return 1
  disk || return 1
  target=$(( (total * (100 - low) + 99) / 100 ))
}
buildkit() {
  enough_space && return 0
  run /usr/local/bin/k3s kubectl -n "$1" exec "deployment/$2" -- \
    buildctl --addr tcp://127.0.0.1:1234 prune --all --free-storage "$(( (target + 999999) / 1000000 ))"
}
test_cache() {
  enough_space && return 0
  run /opt/build-server/ci-test-cache.sh gc "$1/test-cache" "$target"
}

case "${1:-}" in
  --if-needed)
    policy || { log 'cannot read kubelet disk policy'; exit 1; }
    if [ "$(( (total - available) * 100 / total ))" -ge "$high" ]; then
      log "disk reached kubelet high watermark ($high%); scheduling cleanup"
      systemctl start --no-block arc-prune.service
    fi
    exit "$?"
    ;;
  '') ;;
  *) log 'usage: arc-prune.sh [--if-needed]'; exit 2 ;;
esac

if policy; then
  log "available=$available target=$target high=$high% low=$low%"
  buildkit arc-miraj buildkitd
  test_cache /opt/ci-tier/pr/cache
  test_cache /opt/ci-tier/pr-containers
  buildkit arc-izi-x buildkitd
  test_cache /opt/ci-tier/trusted/cache
  test_cache /opt/ci-tier/trusted-containers
  buildkit arc-izi-x buildkitd-trusted
else
  log 'cannot read kubelet disk policy; continuing host cleanup'
  target=0
  rc=1
fi

run /usr/local/bin/k3s crictl rmi --prune
if command -v docker >/dev/null; then
  docker system prune -af --filter until=48h || log 'optional Docker image cleanup failed'
  docker builder prune -af --filter until=48h || log 'optional Docker builder cleanup failed'
  docker volume prune -af || log 'optional Docker volume cleanup failed'
fi
run /usr/bin/journalctl --vacuum-time=7d
if [ "$target" -gt 0 ]; then
  if enough_space; then
    log "cleanup complete: available=$available target=$target"
  else
    log "cleanup incomplete: available=$available target=$target; active data was retained"
    rc=1
  fi
fi
exit "$rc"
