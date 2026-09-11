#!/bin/bash
set -e

# Works with both:  bash <(curl ...)  and  curl ... | bash
ask() { read -rp "$1" "$2" </dev/tty; }

DAYS=7

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

hr()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
bold(){ echo -e "  ${YEL}$*${NC}"; }
ok()  { echo -e "  ${GRN}✔${NC}  $*"; }
del() { echo -e "  ${RED}✗${NC}  $*"; }
dim() { echo -e "  ${DIM}$*${NC}"; }

bytes_to_human() {
  local b="$1"
  if [[ $b -ge 1073741824 ]]; then printf "%.1f GB" "$(echo "$b 1073741824" | awk '{printf "%.1f", $1/$2}')";
  elif [[ $b -ge 1048576 ]]; then printf "%.1f MB" "$(echo "$b 1048576" | awk '{printf "%.1f", $1/$2}')";
  elif [[ $b -ge 1024 ]]; then printf "%.1f KB" "$(echo "$b 1024" | awk '{printf "%.1f", $1/$2}')";
  else printf "%d B" "$b"; fi
}

echo ""
hr
echo "  VPS Cleanup — Dynamic Preview"
echo "  Will scan: stopped containers (>${DAYS}d), images, volumes,"
echo "             build cache, apt cache, journal logs, /tmp"
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
TOTAL_BYTES=0

# ━━━━━━━━━━━━━━━━━━━━ DOCKER ━━━━━━━━━━━━━━━━━━━━━━
DOCKER_OK=false
if command -v docker &>/dev/null && sudo docker info &>/dev/null 2>&1; then
  DOCKER_OK=true
fi

STALE_IDS=()
STALE_LABELS=()
CONTAINER_BYTES=0

DANGLING_IDS=()
IMAGE_BYTES=0

VOLUME_NAMES=()
VOLUME_BYTES=0

BUILD_BYTES=0

if $DOCKER_OK; then
  # Stale stopped containers
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    NAME=$(sudo docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')
    FINISHED=$(sudo docker inspect --format '{{.State.FinishedAt}}' "$id" 2>/dev/null | cut -c1-19 | tr 'T' ' ')
    if [[ -z "$FINISHED" || "$FINISHED" == "0001-01-01"* ]]; then continue; fi
    TS=$(date -d "$FINISHED" +%s 2>/dev/null || echo 0)
    if [[ "$TS" -lt "$CUTOFF_EPOCH" ]]; then
      SIZE_RAW=$(sudo docker inspect --format '{{.SizeRootFs}}' "$id" 2>/dev/null || echo 0)
      STALE_IDS+=("$id")
      AGE_DAYS=$(( ($(date +%s) - TS) / 86400 ))
      STALE_LABELS+=("$NAME  [stopped ${AGE_DAYS}d ago]  $(bytes_to_human ${SIZE_RAW:-0})")
      CONTAINER_BYTES=$(( CONTAINER_BYTES + ${SIZE_RAW:-0} ))
    fi
  done < <(sudo docker ps -a --filter status=exited --filter status=created -q 2>/dev/null)

  # Dangling images
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    SIZE_RAW=$(sudo docker image inspect --format '{{.Size}}' "$id" 2>/dev/null || echo 0)
    DANGLING_IDS+=("$id")
    IMAGE_BYTES=$(( IMAGE_BYTES + ${SIZE_RAW:-0} ))
  done < <(sudo docker images -f "dangling=true" -q 2>/dev/null)

  # Unused volumes
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    MOUNTPOINT=$(sudo docker volume inspect --format '{{.Mountpoint}}' "$vol" 2>/dev/null)
    SIZE_RAW=$(sudo du -sb "$MOUNTPOINT" 2>/dev/null | awk '{print $1}' || echo 0)
    VOLUME_NAMES+=("$vol  $(bytes_to_human ${SIZE_RAW:-0})")
    VOLUME_BYTES=$(( VOLUME_BYTES + ${SIZE_RAW:-0} ))
  done < <(sudo docker volume ls -qf dangling=true 2>/dev/null)

  # Build cache
  BUILD_CACHE_RAW=$(sudo docker system df --format '{{json .}}' 2>/dev/null \
    | grep -i '"Type":"Build Cache"' \
    | grep -oP '"Size":"\K[^"]+' || echo "0B")
  # Try numeric from docker system df
  BUILD_LINE=$(sudo docker system df 2>/dev/null | grep -i "Build Cache" || true)
  BUILD_BYTES_RAW=$(echo "$BUILD_LINE" | awk '{print $4}' | sed 's/B$//' | \
    awk '{
      if ($1 ~ /GB/) { sub(/GB/,"",$1); printf "%d", $1*1073741824 }
      else if ($1 ~ /MB/) { sub(/MB/,"",$1); printf "%d", $1*1048576 }
      else if ($1 ~ /kB/) { sub(/kB/,"",$1); printf "%d", $1*1024 }
      else printf "%d", $1
    }' 2>/dev/null || echo 0)
  BUILD_BYTES=${BUILD_BYTES_RAW:-0}
fi

# ━━━━━━━━━━━━━━━━━━━━ SYSTEM ━━━━━━━━━━━━━━━━━━━━━━
# Apt cache
APT_BYTES=$(sudo du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
APT_LIST_BYTES=$(sudo du -sb /var/cache/apt/lists/ 2>/dev/null | awk '{print $1}' || echo 0)
APT_TOTAL=$(( APT_BYTES + APT_LIST_BYTES ))

# Journal logs (total; we vacuum to 7d)
JOURNAL_BYTES=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d]+(?= bytes)' | head -1 || echo 0)

# /tmp old files
TMP_FILES=()
TMP_BYTES=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  SIZE_RAW=$(sudo du -sb "$f" 2>/dev/null | awk '{print $1}' || echo 0)
  TMP_FILES+=("$f")
  TMP_BYTES=$(( TMP_BYTES + ${SIZE_RAW:-0} ))
done < <(sudo find /tmp -maxdepth 2 -mtime +${DAYS} 2>/dev/null)

# Page cache (always available, size = cached in /proc/meminfo)
PAGE_CACHE_KB=$(awk '/^Cached:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
PAGE_CACHE_BYTES=$(( PAGE_CACHE_KB * 1024 ))

# ━━━━━━━━━━━━━━━━━━━━ GRAND TOTAL ━━━━━━━━━━━━━━━━━
TOTAL_BYTES=$(( CONTAINER_BYTES + IMAGE_BYTES + VOLUME_BYTES + BUILD_BYTES + APT_TOTAL + JOURNAL_BYTES + TMP_BYTES + PAGE_CACHE_BYTES ))

# ━━━━━━━━━━━━━━━━━━━━ PRINT PREVIEW ━━━━━━━━━━━━━━
hr
echo -e "  ${YEL}DOCKER${NC}"
hr

if $DOCKER_OK; then
  # Containers
  if [[ ${#STALE_IDS[@]} -gt 0 ]]; then
    echo "  Stopped containers  >  ${DAYS}d old:"
    for label in "${STALE_LABELS[@]}"; do del "$label"; done
    echo -e "  ${DIM}Subtotal: $(bytes_to_human $CONTAINER_BYTES)${NC}"
  else
    ok "No stale containers found"
  fi
  echo ""

  # Images
  if [[ ${#DANGLING_IDS[@]} -gt 0 ]]; then
    echo "  Dangling images: ${#DANGLING_IDS[@]}"
    for id in "${DANGLING_IDS[@]}"; do
      TAG=$(sudo docker image inspect --format '{{index .RepoTags 0}}' "$id" 2>/dev/null || echo "<none>")
      del "$id  $TAG"
    done
    echo -e "  ${DIM}Subtotal: $(bytes_to_human $IMAGE_BYTES)${NC}"
  else
    ok "No dangling images"
  fi
  echo ""

  # Volumes
  if [[ ${#VOLUME_NAMES[@]} -gt 0 ]]; then
    echo "  Unused volumes: ${#VOLUME_NAMES[@]}"
    for v in "${VOLUME_NAMES[@]}"; do del "$v"; done
    echo -e "  ${DIM}Subtotal: $(bytes_to_human $VOLUME_BYTES)${NC}"
  else
    ok "No unused volumes"
  fi
  echo ""

  # Build cache
  if [[ "$BUILD_BYTES" -gt 0 ]]; then
    del "Docker build cache  →  $(bytes_to_human $BUILD_BYTES)"
  else
    ok "Build cache is empty"
  fi
else
  dim "Docker not available / not running — skipped"
fi

echo ""
hr
echo -e "  ${YEL}SYSTEM${NC}"
hr

# Apt
if [[ "$APT_TOTAL" -gt 0 ]]; then
  del "APT package cache  →  $(bytes_to_human $APT_TOTAL)"
else
  ok "APT cache already clean"
fi

# Journal
if [[ "$JOURNAL_BYTES" -gt 0 ]]; then
  del "Journal logs (total, keep last ${DAYS}d)  →  $(bytes_to_human $JOURNAL_BYTES)"
else
  ok "Journal empty"
fi

# /tmp
if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
  del "/tmp files older than ${DAYS}d  →  ${#TMP_FILES[@]} items  ($(bytes_to_human $TMP_BYTES))"
else
  ok "No old /tmp files"
fi

# Page cache
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
  if [[ ${#STALE_IDS[@]} -gt 0 ]]; then
    echo "🗑️  Removing stale containers..."
    for id in "${STALE_IDS[@]}"; do
      sudo docker rm "$id" &>/dev/null && echo "  Removed $id" || true
    done
  fi

  if [[ ${#DANGLING_IDS[@]} -gt 0 ]]; then
    echo "🗑️  Removing dangling images..."
    sudo docker image prune -f &>/dev/null
  fi

  if [[ ${#VOLUME_NAMES[@]} -gt 0 ]]; then
    echo "🗑️  Removing unused volumes..."
    sudo docker volume prune -f &>/dev/null
  fi

  echo "🗑️  Pruning Docker build cache (>${DAYS}d)..."
  sudo docker builder prune -f &>/dev/null || true

  echo "🗑️  Removing unused Docker networks..."
  sudo docker network prune -f &>/dev/null || true
fi

echo "🗑️  Cleaning APT cache..."
sudo apt-get clean -y &>/dev/null || true
sudo apt-get autoclean -y &>/dev/null || true
sudo apt-get autoremove -y --purge &>/dev/null || true

echo "🗑️  Vacuuming journal logs (keeping last ${DAYS}d)..."
sudo journalctl --vacuum-time=${DAYS}d &>/dev/null || true

if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
  echo "🗑️  Removing old /tmp files..."
  sudo find /tmp -maxdepth 2 -mtime +${DAYS} -delete 2>/dev/null || true
fi

echo "🗑️  Dropping system page cache..."
sudo sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

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
  sudo docker system df 2>/dev/null | awk 'NR>1 {printf "    %-22s  size: %-10s  reclaimable: %s\n", $1, $3, $4}' || true
  echo ""
fi
