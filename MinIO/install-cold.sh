#!/bin/bash
set -e

MINIO_PORT=9000
MINIO_CONSOLE_PORT=9001

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   MinIO Cold Storage Node Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

OS="$(uname -s)"
ARCH="$(uname -m)"

# ── Request sudo upfront ──────────────────────────────
echo "  This script needs admin (sudo) access to install software."
echo "  Please enter your system password when prompted."
echo ""
sudo -v
# Keep sudo alive throughout the script
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# ── Detect OS ─────────────────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
  OS_NAME="macOS"
elif [[ "$OS" == "Linux" ]]; then
  OS_NAME="Linux"
else
  echo "❌ Windows detected. Please run this in WSL2."
  echo "   https://learn.microsoft.com/en-us/windows/wsl/install"
  exit 1
fi
echo "  Detected OS : $OS_NAME ($ARCH)"
echo ""

# ── Ask credentials & endpoint ────────────────────────
echo "  Configure your cold storage node."
echo ""

while true; do
  read -rp "  Access Key / Username (min 3 chars): " MINIO_USER
  [[ ${#MINIO_USER} -ge 3 ]] && break
  echo "  ❌ Username must be at least 3 characters."
done

while true; do
  read -rsp "  Secret Key / Password (min 8 chars): " MINIO_PASS
  echo ""
  [[ ${#MINIO_PASS} -ge 8 ]] && break
  echo "  ❌ Password must be at least 8 characters."
done

echo ""
while true; do
  read -rp "  Your AIStor/MinIO server URL (e.g. https://minio.yourdomain.com): " AISTOR_URL
  [[ -n "$AISTOR_URL" ]] && break
  echo "  ❌ Endpoint cannot be empty."
done
echo ""

# ── Pick Machine Name ─────────────────────────────────
pick_machine_name() {
  echo "  Each machine gets its own unique Tier in AIStor."
  echo "  Examples: laptop, pc, nas, office-pc, home-server"
  echo ""
  read -rp "  Enter a name for this machine [default: laptop]: " MACHINE_NAME
  MACHINE_NAME="${MACHINE_NAME:-laptop}"
  MACHINE_NAME=$(echo "$MACHINE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
  TUNNEL_NAME="cold-$MACHINE_NAME"
  BUCKET_NAME="cold-$MACHINE_NAME"
  TIER_NAME="COLD-$(echo "$MACHINE_NAME" | tr '[:lower:]' '[:upper:]')"
  echo ""
  echo "  ✅ Tunnel name : $TUNNEL_NAME"
  echo "  ✅ Bucket name : $BUCKET_NAME"
  echo "  ✅ Tier name   : $TIER_NAME"
  echo ""
}

# ── Install Docker ────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    echo "✅ Docker already installed"
    return
  fi
  echo "📦 Docker not found. Installing..."
  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install --cask docker
      echo "   ⚠️  Open Docker Desktop from Applications, then press Enter."
      read -r
    else
      echo "   ⚠️  Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
      echo "   Then press Enter to continue."
      read -r
    fi
  elif [[ "$OS" == "Linux" ]]; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    sudo systemctl enable docker
    sudo systemctl start docker
    DOCKER_CMD="sudo docker"
    echo "✅ Docker installed"
    return
  fi
  echo "✅ Docker ready"
}

DOCKER_CMD="docker"

# ── Pick Storage Drive ────────────────────────────────
pick_drive() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Available Drives / Disks:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  df -h | grep -E "^/|^Filesystem" | awk '{printf "  %-30s %-10s %-10s %-10s %s\n", $1, $2, $3, $4, $6}'
  echo ""
  echo "  Enter the path where cold storage data should be saved."
  echo "  Example: /  or  /Volumes/MyDrive  or  /mnt/data"
  echo ""
  read -rp "  Storage path [default: $HOME/minio-cold]: " CUSTOM_PATH
  MINIO_DATA="${CUSTOM_PATH:-$HOME/minio-cold}"
  echo ""
  echo "  ✅ Data will be stored at: $MINIO_DATA"
}

# ── Pick Storage Size ─────────────────────────────────
pick_size() {
  echo ""
  AVAILABLE=$(df -h "$MINIO_DATA" 2>/dev/null | awk 'NR==2{print $4}')
  echo "  Available space at $MINIO_DATA: $AVAILABLE"
  echo ""
  echo "  How many GB should this cold storage node use?"
  echo ""
  read -rp "  Storage quota in GB [default: 50]: " QUOTA_GB
  QUOTA_GB="${QUOTA_GB:-50}"
  echo ""
  echo "  ✅ Quota set to: ${QUOTA_GB}GB"
}

# ── Install cloudflared ───────────────────────────────
install_cloudflared() {
  if command -v cloudflared &>/dev/null; then
    echo "✅ cloudflared already installed"
    return
  fi
  echo "📦 Installing cloudflared..."
  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install cloudflare/cloudflare/cloudflared
    else
      curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz" -o /tmp/cloudflared.tgz
      tar -xzf /tmp/cloudflared.tgz -C /tmp
      sudo mv /tmp/cloudflared /usr/local/bin/
    fi
  elif [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "x86_64" ]]; then
      curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o /tmp/cloudflared
    else
      curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" -o /tmp/cloudflared
    fi
    chmod +x /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/
  fi
  echo "✅ cloudflared installed"
}

# ── Start MinIO ───────────────────────────────────────
start_minio() {
  mkdir -p "$MINIO_DATA"
  if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q "^minio-cold$"; then
    echo "♻️  Removing existing minio-cold container..."
    $DOCKER_CMD rm -f minio-cold
  fi
  echo "🚀 Starting MinIO cold storage container..."
  $DOCKER_CMD run -d \
    --name minio-cold \
    --restart unless-stopped \
    -p $MINIO_PORT:9000 \
    -p $MINIO_CONSOLE_PORT:9001 \
    -e MINIO_ROOT_USER="$MINIO_USER" \
    -e MINIO_ROOT_PASSWORD="$MINIO_PASS" \
    -v "$MINIO_DATA:/data" \
    quay.io/minio/minio server /data --console-address ":9001"
  echo "⏳ Waiting for MinIO to start..."
  sleep 6
  $DOCKER_CMD exec minio-cold sh -c "
    mc alias set local http://localhost:9000 $MINIO_USER $MINIO_PASS --quiet 2>/dev/null &&
    mc mb --ignore-existing local/$BUCKET_NAME &&
    mc quota set local/$BUCKET_NAME --size ${QUOTA_GB}GiB
  " && echo "✅ Bucket '$BUCKET_NAME' created with ${QUOTA_GB}GB quota" \
    || echo "⚠️  Bucket setup had issues — check http://localhost:$MINIO_CONSOLE_PORT"
}

# ── Setup Cloudflare Tunnel ───────────────────────────
setup_tunnel() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Cloudflare Tunnel Setup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Your browser will open for Cloudflare login."
  echo "  Sign in and click Authorize."
  echo ""
  cloudflared tunnel login

  echo ""
  echo "🚇 Creating tunnel: $TUNNEL_NAME"
  cloudflared tunnel create "$TUNNEL_NAME" 2>/dev/null || echo "  Tunnel already exists, continuing..."

  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
  TUNNEL_DOMAIN="${TUNNEL_ID}.cfargotunnel.com"

  CONFIG_DIR="$HOME/.cloudflared"
  mkdir -p "$CONFIG_DIR"

  cat > "$CONFIG_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CONFIG_DIR/$TUNNEL_ID.json

ingress:
  - hostname: $TUNNEL_DOMAIN
    service: http://localhost:$MINIO_PORT
  - service: http_status:404
EOF

  echo "⚙️  Installing tunnel as a system service (auto-starts on reboot)..."
  sudo cloudflared service install

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅ Cold Storage Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Machine      : $MACHINE_NAME"
  echo "  Storage path : $MINIO_DATA"
  echo "  Quota        : ${QUOTA_GB} GB"
  echo "  Public URL   : https://$TUNNEL_DOMAIN"
  echo "  Local UI     : http://localhost:$MINIO_CONSOLE_PORT"
  echo ""
  echo "  ┌─ Add Tier in AIStor ($AISTOR_URL) ─────────┐"
  echo "  │  Administrator → Tiers → Add Tier → MinIO  │"
  echo "  │                                             │"
  echo "  │  Tier Name  → $TIER_NAME"
  echo "  │  Endpoint   → https://$TUNNEL_DOMAIN"
  echo "  │  Access Key → $MINIO_USER"
  echo "  │  Secret Key → (your password)"
  echo "  │  Bucket     → $BUCKET_NAME"
  echo "  └─────────────────────────────────────────────┘"
  echo ""
  echo "  Run this script on each machine with a different name."
  echo ""
}

# ── Run ───────────────────────────────────────────────
pick_machine_name
install_docker
pick_drive
pick_size
install_cloudflared
start_minio
setup_tunnel
