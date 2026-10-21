#!/usr/bin/env bash
set -euo pipefail

log() { printf 'test-cache: %s\n' "$*" >&2; }

new_generation() {
  generation=$(basename "$(mktemp -d "$namespace/data/g.XXXXXXXX")")
  chmod 0755 "$namespace/data/$generation"
  touch "$namespace/locks/$generation" "$namespace/used/$generation"
  chown --reference="$namespace" "$namespace/data/$generation" \
    "$namespace/locks/$generation" "$namespace/used/$generation"
  local pointer
  pointer=$(mktemp "$namespace/.current.XXXXXXXX")
  printf '%s\n' "$generation" > "$pointer"
  chmod 0644 "$pointer"
  chown --reference="$namespace" "$pointer"
  mv -f -- "$pointer" "$namespace/current"
}

read_generation() {
  IFS= read -r generation < "$namespace/current"
  [[ "$generation" =~ ^g\.[[:alnum:]]+$ ]] || {
    log "invalid generation in $namespace/current"; return 1;
  }
  [ -d "$namespace/data/$generation" ] && [ ! -L "$namespace/data/$generation" ]
}

run_cached() {
  local package="${1:?package required}"
  shift
  [ "${1:-}" != -- ] || shift
  [ "$#" -gt 0 ] || { log 'test command required'; return 2; }
  case "$package" in api|crm) ;; *) log "unsupported package: $package"; return 2 ;; esac
  local root=/ci-cache/test-cache key major digest namespace generation cache rc=0
  major=$(node -p 'process.versions.node.split(".")[0]')
  digest=$(sha256sum package-lock.json | cut -c1-16)
  key="$package-node$major-$digest"
  namespace="$root/$key"
  mkdir -p "$namespace/data" "$namespace/locks" "$namespace/used"
  exec 8>>"$namespace/gate"
  flock -x 8
  if [ -f "$namespace/current" ]; then read_generation; else new_generation; fi
  exec 9>>"$namespace/locks/$generation"
  flock -s 9
  touch "$namespace/used/$generation"
  exec 8>&-
  cache="$namespace/data/$generation"
  log "using $cache"
  case "$package" in
    crm) export VITEST_FS_CACHE="$cache" ;;
    api) set -- "$@" "--cacheDirectory=$cache" ;;
  esac
  "$@" || rc=$?
  touch "$namespace/used/$generation" || { [ "$rc" -ne 0 ] || rc=1; }
  exec 9>&-
  return "$rc"
}

enough_space() {
  local available
  available=$(df -B1 --output=avail / | tail -n 1)
  [ "$available" -ge "$target" ]
}

collect() {
  local root="${1:?cache root required}" target="${2:?free bytes required}"
  case "$root" in
    /opt/ci-tier/pr/cache/test-cache|/opt/ci-tier/trusted/cache/test-cache|\
    /opt/ci-tier/pr-containers/test-cache|/opt/ci-tier/trusted-containers/test-cache) ;;
    *) log "refusing unmanaged root: $root"; return 2 ;;
  esac
  [[ "$target" =~ ^[0-9]+$ ]] || return 2
  [ -d "$root" ] || return 0
  [ "$(realpath -e -- "$root")" = "$root" ] || return 2
  local namespace generation old key candidate stamp trash rc=0
  mkdir -p "$root/.trash"
  # These directories were detached only after obtaining an exclusive lease.
  while IFS= read -r -d '' trash; do
    rm -rf --one-file-system -- "$trash"
  done < <(find "$root/.trash" -mindepth 1 -maxdepth 1 -type d -name 'retired.*' -print0)
  while IFS=' ' read -r stamp candidate; do
    enough_space && break
    [ -n "$candidate" ] || continue
    namespace=${candidate%/data/*}
    key=${namespace##*/}
    old=${candidate##*/}
    [[ "$key" =~ ^(api|crm)-node[0-9]+-[a-f0-9]{16}$ ]] || continue
    [[ "$old" =~ ^g\.[[:alnum:]]+$ ]] || continue
    [ ! -L "$namespace" ] && [ ! -L "$candidate" ] || return 2
    exec 8>>"$namespace/gate"
    flock -x 8
    if [ ! -d "$candidate" ]; then exec 8>&-; continue; fi
    read_generation
    exec 9>>"$namespace/locks/$old"
    if ! flock -xn 9; then
      if [ "$old" = "$generation" ]; then
        new_generation
        log "retired busy $candidate; new jobs use $generation"
      fi
      exec 9>&-
      exec 8>&-
      continue
    fi
    [ "$old" != "$generation" ] || new_generation
    trash=$(mktemp -d "$root/.trash/retired.XXXXXXXX")
    mv -- "$candidate" "$trash/data"
    exec 8>&-
    log "evicting $candidate"
    if rm -rf --one-file-system -- "$trash"; then
      exec 8>>"$namespace/gate"
      flock -x 8
      rm -f -- "$namespace/locks/$old" "$namespace/used/$old"
      exec 8>&-
    else
      rc=1
    fi
    exec 9>&-
  done < <(
    for namespace in "$root"/*; do
      [ -d "$namespace/data" ] && [ ! -L "$namespace" ] || continue
      for candidate in "$namespace"/data/g.*; do
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
        stamp=$(stat -c %Y "$namespace/used/${candidate##*/}" 2>/dev/null || printf 0)
        printf '%s %s\n' "$stamp" "$candidate"
      done
    done | sort -n
  )
  return "$rc"
}

case "${1:-}" in
  run) shift; run_cached "$@" ;;
  gc) shift; collect "$@" ;;
  *) log 'usage: ci-test-cache run api|crm -- command... | gc root free-bytes'; exit 2 ;;
esac
