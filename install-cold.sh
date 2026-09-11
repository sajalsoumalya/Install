#!/bin/bash
set -e

MINIO_PORT=9000
MINIO_CONSOLE_PORT=9001
MINIO_USER="coldadmin"
MINIO_PASS="coldpass123"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   MinIO Cold Storage Setup — soumalya.in"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

OS="$(uname -s)"
ARCH="$(uname -m)"

# ── Pick Machine Name ─────────────────────────────────
pick_machine_name() {
  echo "  Each machine gets its own unique subdomain as a Tier."
  echo "  Examples: laptop, pc, nas, office-pc, home-server"
  echo ""
  read -rp "  Enter a name for this machine [default: laptop]: " MACHINE_NAME
  MACHINE_NAME="${MACHINE_NAME:-laptop}"
  # lowercase, replace spaces with hyphens, strip special chars
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

# ── Detect OS nicely ──────────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
  OS_NAME="macOS"
elif [[ "$OS" == "Linux" ]]; then
  OS_NAME="Linux"
else
  echo "❌ Windows detected. Please run this in WSL2 (Windows Subsystem for Linux)."
  echo "   Install WSL2: https://learn.microsoft.com/en-us/windows/wsl/install"
  exit 1
fi

echo "  Detected OS : $OS_NAME ($ARCH)"
echo ""

# ── Install Docker ────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    echo "✅ Docker already installed"
    return
  fi

  echo "📦 Docker not found. Installing..."
  echo ""

  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      echo "   Installing via Homebrew..."
      brew install --cask docker
      echo "   ⚠️  Please open Docker Desktop from Applications once, then press Enter to continue."
      read -r
    else
      echo "   ⚠️  Please install Docker Desktop manually:"
      echo "   https://www.docker.com/products/docker-desktop/"
      echo "   Then press Enter to continue."
      read -r
    fi
  elif [[ "$OS" == "Linux" ]]; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    sudo systemctl enable docker
    sudo systemctl start docker
    echo "✅ Docker installed"
    echo "   ⚠️  You may need to log out and back in for Docker group permissions."
    echo "   For now, using sudo docker. Press Enter to continue."
    read -r
    DOCKER_CMD="sudo docker"
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
  echo "  Enter the mount path where cold storage data should be saved."
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
  echo "  How many GB should MinIO cold storage use?"
  echo "  (A soft quota — data beyond this will be rejected)"
  echo ""
  read -rp "  Storage quota in GB [default: 50]: " QUOTA_GB
  QUOTA_GB="${QUOTA_GB:-50}"
  QUOTA_BYTES=$(( QUOTA_GB * 1024 * 1024 * 1024 ))
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
    echo "✅ MinIO cold container already exists, restarting with new config..."
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

  # Create bucket and apply quota
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
  echo "  Machine name     : $MACHINE_NAME"
  echo "  Storage path     : $MINIO_DATA"
  echo "  Storage quota    : ${QUOTA_GB} GB"
  echo "  Permanent URL    : https://$TUNNEL_DOMAIN"
  echo "  Local Console    : http://localhost:$MINIO_CONSOLE_PORT"
  echo ""
  echo "  ┌─ Add this Tier in AIStor (minio.soumalya.in) ──────────────┐"
  echo "  │  Administrator → Tiers → Add Tier → MinIO                  │"
  echo "  │                                                             │"
  echo "  │  Tier Name  → $TIER_NAME"
  echo "  │  Endpoint   → https://$TUNNEL_DOMAIN"
  echo "  │  Access Key → $MINIO_USER"
  echo "  │  Secret Key → $MINIO_PASS"
  echo "  │  Bucket     → $BUCKET_NAME"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Run this script on each machine with a different name."
  echo "  Each gets its own permanent Cloudflare URL and Tier."
  echo ""
}

# ── Run ───────────────────────────────────────────────
install_docker
pick_machine_name
pick_drive
pick_size
install_cloudflared
start_minio
setup_tunnel
