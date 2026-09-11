#!/bin/bash
set -e

# Works with both:  bash <(curl ...)  and  curl ... | bash
ask() { read -rp "$1" "$2" </dev/tty; }

DAYS=7
HOURS=$(( DAYS * 24 ))

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

hr()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
ok()  { echo -e "  ${GRN}✔${NC}  $*"; }
del() { echo -e "  ${RED}✗${NC}  $*"; }
dim() { echo -e "  ${DIM}$*${NC}"; }

bytes_to_human() {
  local raw="${1:-0}"
  # Sanitize: strip anything non-numeric (handles <nil>, empty, etc.)
  local b
  b=$(echo "$raw" | grep -oP '^\d+' || echo 0)
  b="${b:-0}"
  if [[ "$b" -ge 1073741824 ]]; then
    awk "BEGIN{printf \"%.1f GB\", $b/1073741824}"
  elif [[ "$b" -ge 1048576 ]]; then
    awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
  elif [[ "$b" -ge 1024 ]]; then
    awk "BEGIN{printf \"%.1f KB\", $b/1024}"
  else
    echo "${b} B"
  fi
}

echo ""
hr
echo "  VPS Cleanup — Dynamic Preview"
echo "  Scans: containers (all stopped), unused images (>${DAYS}d),"
echo "         volumes, build cache, apt cache, journal logs, /tmp"
hr
echo ""

if [[ "$(uname -s)" != "Linux" ]]; then
  echo -e "${RED}❌ This script is for Linux VPS only.${NC}"
  exit 1
fi

echo "  Requesting admin access..."
sudo -v </dev/tty
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

echo ""
echo -e "${BLU}  Scanning — please wait...${NC}"
echo ""

CUTOFF_EPOCH=$(date -d "-${DAYS} days" +%s 2>/dev/null)

# ━━━━━━━━━━━━━━━━━━━━ DOCKER ━━━━━━━━━━━━━━━━━━━━━
DOCKER_OK=false
if command -v docker &>/dev/null && sudo docker info &>/dev/null 2>&1; then
  DOCKER_OK=true
fi

STALE_IDS=()
STALE_LABELS=()
CONTAINER_BYTES=0

UNUSED_IMAGE_IDS=()
UNUSED_IMAGE_LABELS=()
IMAGE_BYTES=0

VOLUME_NAMES=()
VOLUME_BYTES=0

BUILD_BYTES=0

if $DOCKER_OK; then
  # ── All stopped containers (any age) ──────────────
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    NAME=$(sudo docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')
    FINISHED=$(sudo docker inspect --format '{{.State.FinishedAt}}' "$id" 2>/dev/null | cut -c1-19 | tr 'T' ' ')
    if [[ -z "$FINISHED" || "$FINISHED" == "0001-01-01"* ]]; then continue; fi
    TS=$(date -d "$FINISHED" +%s 2>/dev/null || echo 0)
    SIZE_RAW=$(sudo docker inspect --format '{{.SizeRootFs}}' "$id" 2>/dev/null | grep -oP '^\d+' || echo 0)
    SIZE_RAW=${SIZE_RAW:-0}
    STALE_IDS+=("$id")
    AGE_DAYS=$(( ($(date +%s) - TS) / 86400 ))
    STALE_LABELS+=("$NAME  [stopped ${AGE_DAYS}d ago]  $(bytes_to_human $SIZE_RAW)")
    CONTAINER_BYTES=$(( CONTAINER_BYTES + SIZE_RAW ))
  done < <(sudo docker ps -a --filter status=exited --filter status=created --filter status=dead -q 2>/dev/null)

  # ── Unused images older than DAYS ─────────────────
  # Images not used by any container (running or stopped), older than DAYS
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    REPO=$(sudo docker image inspect --format '{{index .RepoTags 0}}' "$id" 2>/dev/null || echo "<none>")
    SIZE_RAW=$(sudo docker image inspect --format '{{.Size}}' "$id" 2>/dev/null || echo 0)
    SIZE_RAW=${SIZE_RAW:-0}
    CREATED=$(sudo docker image inspect --format '{{.Created}}' "$id" 2>/dev/null | cut -c1-19 | tr 'T' ' ')
    CTS=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)
    if [[ "$CTS" -lt "$CUTOFF_EPOCH" ]]; then
      UNUSED_IMAGE_IDS+=("$id")
      UNUSED_IMAGE_LABELS+=("$REPO  $(bytes_to_human $SIZE_RAW)")
      IMAGE_BYTES=$(( IMAGE_BYTES + SIZE_RAW ))
    fi
  done < <(sudo docker images --filter "dangling=false" -q 2>/dev/null | sort -u)
  # Also add dangling images
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    # Skip if already in list
    for existing in "${UNUSED_IMAGE_IDS[@]:-}"; do [[ "$existing" == "$id" ]] && continue 2; done
    SIZE_RAW=$(sudo docker image inspect --format '{{.Size}}' "$id" 2>/dev/null || echo 0)
    SIZE_RAW=${SIZE_RAW:-0}
    UNUSED_IMAGE_IDS+=("$id")
    UNUSED_IMAGE_LABELS+=("<none>  $(bytes_to_human $SIZE_RAW)")
    IMAGE_BYTES=$(( IMAGE_BYTES + SIZE_RAW ))
  done < <(sudo docker images -f "dangling=true" -q 2>/dev/null)

  # Filter out images actually used by a container (running or stopped)
  USED_IDS=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && USED_IDS+=("$id")
  done < <(sudo docker ps -a --format '{{.Image}}' 2>/dev/null | xargs -I{} sudo docker inspect --format '{{.Id}}' {} 2>/dev/null || true)

  FILTERED_IMAGE_IDS=()
  FILTERED_IMAGE_LABELS=()
  IMAGE_BYTES=0
  for i in "${!UNUSED_IMAGE_IDS[@]}"; do
    ID="${UNUSED_IMAGE_IDS[$i]}"
    USED=false
    for uid in "${USED_IDS[@]:-}"; do
      if [[ "$uid" == "$ID"* ]] || [[ "$ID" == "$uid"* ]]; then USED=true; break; fi
    done
    if ! $USED; then
      FILTERED_IMAGE_IDS+=("$ID")
      FILTERED_IMAGE_LABELS+=("${UNUSED_IMAGE_LABELS[$i]}")
      SIZE_RAW=$(sudo docker image inspect --format '{{.Size}}' "$ID" 2>/dev/null || echo 0)
      IMAGE_BYTES=$(( IMAGE_BYTES + ${SIZE_RAW:-0} ))
    fi
  done
  UNUSED_IMAGE_IDS=("${FILTERED_IMAGE_IDS[@]:-}")
  UNUSED_IMAGE_LABELS=("${FILTERED_IMAGE_LABELS[@]:-}")

  # ── Unused volumes ─────────────────────────────────
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    MOUNTPOINT=$(sudo docker volume inspect --format '{{.Mountpoint}}' "$vol" 2>/dev/null)
    SIZE_RAW=$(sudo du -sb "$MOUNTPOINT" 2>/dev/null | awk '{print $1}' || echo 0)
    SIZE_RAW=${SIZE_RAW:-0}
    VOLUME_NAMES+=("$vol  $(bytes_to_human $SIZE_RAW)")
    VOLUME_BYTES=$(( VOLUME_BYTES + SIZE_RAW ))
  done < <(sudo docker volume ls -qf dangling=true 2>/dev/null)

  # ── Build cache size ───────────────────────────────
  BUILD_LINE=$(sudo docker system df 2>/dev/null | awk '/Build Cache/{print $4}')
  BUILD_BYTES=$(echo "${BUILD_LINE:-0}" | awk '{
    v=$1
    if (v ~ /GB/) { sub(/GB/,"",v); printf "%d", v*1073741824 }
    else if (v ~ /MB/) { sub(/MB/,"",v); printf "%d", v*1048576 }
    else if (v ~ /kB/) { sub(/kB/,"",v); printf "%d", v*1024 }
    else { gsub(/[^0-9]/,"",v); printf "%d", v+0 }
  }' 2>/dev/null || echo 0)
fi

# ━━━━━━━━━━━━━━━━━━━━ SYSTEM ━━━━━━━━━━━━━━━━━━━━━
APT_BYTES=$(sudo du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
APT_LIST_BYTES=$(sudo du -sb /var/cache/apt/lists/ 2>/dev/null | awk '{print $1}' || echo 0)
APT_TOTAL=$(( ${APT_BYTES:-0} + ${APT_LIST_BYTES:-0} ))

JOURNAL_BYTES=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d]+(?= bytes)' | head -1 || echo 0)

TMP_FILES=()
TMP_BYTES=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  SIZE_RAW=$(sudo du -sb "$f" 2>/dev/null | awk '{print $1}' || echo 0)
  TMP_FILES+=("$f")
  TMP_BYTES=$(( TMP_BYTES + ${SIZE_RAW:-0} ))
done < <(sudo find /tmp -maxdepth 2 -mtime +${DAYS} 2>/dev/null)

PAGE_CACHE_KB=$(awk '/^Cached:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
PAGE_CACHE_BYTES=$(( ${PAGE_CACHE_KB:-0} * 1024 ))

TOTAL_BYTES=$(( CONTAINER_BYTES + IMAGE_BYTES + VOLUME_BYTES + BUILD_BYTES + APT_TOTAL + ${JOURNAL_BYTES:-0} + TMP_BYTES + PAGE_CACHE_BYTES ))

# ━━━━━━━━━━━━━━━━━━━━ PRINT PREVIEW ━━━━━━━━━━━━━━
hr
echo -e "  ${YEL}DOCKER${NC}"
hr

if $DOCKER_OK; then
  # Containers
  if [[ ${#STALE_IDS[@]} -gt 0 ]]; then
    echo "  All stopped containers (${#STALE_IDS[@]}):"
    for label in "${STALE_LABELS[@]}"; do del "$label"; done
    echo -e "  ${DIM}Subtotal: $(bytes_to_human $CONTAINER_BYTES)${NC}"
  else
    ok "No stopped containers"
  fi
  echo ""

  # Images
  if [[ ${#UNUSED_IMAGE_IDS[@]} -gt 0 ]]; then
    echo "  Unused images older than ${DAYS}d (${#UNUSED_IMAGE_IDS[@]}):"
    for label in "${UNUSED_IMAGE_LABELS[@]}"; do del "$label"; done
    echo -e "  ${DIM}Subtotal: $(bytes_to_human $IMAGE_BYTES)${NC}"
  else
    ok "No unused images older than ${DAYS}d"
  fi
  echo ""

  # Volumes
  if [[ ${#VOLUME_NAMES[@]} -gt 0 ]]; then
    echo "  Unused volumes (${#VOLUME_NAMES[@]}):"
    for v in "${VOLUME_NAMES[@]}"; do del "$v"; done
    echo -e "  ${DIM}Subtotal: $(bytes_to_human $VOLUME_BYTES)${NC}"
  else
    ok "No unused volumes"
  fi
  echo ""

  if [[ "${BUILD_BYTES:-0}" -gt 0 ]]; then
    del "Docker build cache  →  $(bytes_to_human $BUILD_BYTES)"
  else
    ok "Build cache is empty"
  fi
else
  dim "Docker not available — skipped"
fi

echo ""
hr
echo -e "  ${YEL}SYSTEM${NC}"
hr

[[ "${APT_TOTAL:-0}" -gt 0 ]] && del "APT package cache  →  $(bytes_to_human $APT_TOTAL)" || ok "APT cache clean"
[[ "${JOURNAL_BYTES:-0}" -gt 0 ]] && del "Journal logs (keep last ${DAYS}d)  →  $(bytes_to_human $JOURNAL_BYTES)" || ok "Journal empty"
[[ ${#TMP_FILES[@]} -gt 0 ]] && del "/tmp files older than ${DAYS}d  →  ${#TMP_FILES[@]} items  ($(bytes_to_human $TMP_BYTES))" || ok "No old /tmp files"
del "System page cache (RAM, reclaimable)  →  $(bytes_to_human $PAGE_CACHE_BYTES)"

echo ""
hr
echo -e "  ${GRN}  Estimated space to be freed: $(bytes_to_human $TOTAL_BYTES)${NC}"
hr
echo ""

ask "  Delete everything listed above? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "  Aborted — nothing deleted."
  exit 0
fi

echo ""
hr
echo "  Running cleanup..."
hr
echo ""

if $DOCKER_OK; then
  # All stopped containers
  echo "🗑️  Removing stopped containers..."
  sudo docker container prune -f &>/dev/null
  echo "  Done."

  # All unused images older than DAYS
  echo "🗑️  Removing unused images (>${DAYS}d)..."
  sudo docker image prune -a -f --filter "until=${HOURS}h" &>/dev/null || sudo docker image prune -a -f &>/dev/null || true
  echo "  Done."

  # Volumes — delete explicitly by name (docker volume prune can silently skip
  # volumes that Swarm/Dokploy still references internally)
  echo "🗑️  Removing unused volumes..."
  VOLS_REMOVED=0
  VOLS_FAILED=()
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    if sudo docker volume rm "$vol" &>/dev/null; then
      VOLS_REMOVED=$(( VOLS_REMOVED + 1 ))
    else
      VOLS_FAILED+=("$vol")
    fi
  done < <(sudo docker volume ls -qf dangling=true 2>/dev/null)
  echo "  Removed: $VOLS_REMOVED volumes"
  if [[ ${#VOLS_FAILED[@]} -gt 0 ]]; then
    echo "  ⚠️  Skipped (still in use by a service):"
    for v in "${VOLS_FAILED[@]}"; do echo "    - $v"; done
  fi

  echo "🗑️  Pruning Docker build cache..."
  sudo docker builder prune -a -f &>/dev/null || true
  echo "  Done."

  echo "🗑️  Removing unused Docker networks..."
  sudo docker network prune -f &>/dev/null || true
  echo "  Done."
fi

echo "🗑️  Cleaning APT cache..."
sudo apt-get clean -y &>/dev/null || true
sudo apt-get autoclean -y &>/dev/null || true
sudo apt-get autoremove -y --purge &>/dev/null || true
echo "  Done."

echo "🗑️  Vacuuming journal logs (keeping last ${DAYS}d)..."
sudo journalctl --vacuum-time=${DAYS}d &>/dev/null || true
echo "  Done."

if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
  echo "🗑️  Removing old /tmp files..."
  sudo find /tmp -maxdepth 2 -mtime +${DAYS} -delete 2>/dev/null || true
  echo "  Done."
fi

echo "🗑️  Dropping system page cache..."
sudo sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
echo "  Done."

echo ""
hr
echo -e "  ${GRN}✅ Done!${NC}"
hr
echo ""

echo "  Disk usage now:"
df -h / | awk 'NR>1 {printf "    %-20s  used: %-8s  free: %-8s  (%s full)\n", $1, $3, $4, $5}'
echo ""

if $DOCKER_OK; then
  echo "  Docker summary:"
  sudo docker system df 2>/dev/null | awk '
    NR==1 { next }
    {
      type=$1; size=$4; reclaim=$5
      # Handle "Local Volumes" which spans two words
      if ($1=="Local") { type="Local Volumes"; size=$5; reclaim=$6 }
      printf "    %-22s  size: %-12s  reclaimable: %s\n", type, size, reclaim
    }
  ' || true
  echo ""
fi
