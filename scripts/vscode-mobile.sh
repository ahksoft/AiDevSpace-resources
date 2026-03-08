curl -fsSL https://code-server.dev/install.sh | sh

echo "code louncher. Installing..."
cat > /bin/vsc << EOF 
#!/usr/bin/env bash
set -e
#pkill -f code-server
# ---------- CONFIG ----------
PORT=${PORT:-6862}                                                                 HOST="0.0.0.0"
DATA_DIR="${HOME}/.local/share/code-server"
CONFIG_DIR="${HOME}/.config/code-server"

# ---------- PERFORMANCE ----------
#export NODE_OPTIONS="--dns-result-order=ipv4first --max-old-space-size=512"
#export ELECTRON_RUN_AS_NODE=1
#export UV_THREADPOOL_SIZE=4

# Reduce telemetry & background tasks
#export VSCODE_DISABLE_TELEMETRY=1                                                 #export VSCODE_DISABLE_CRASH_REPORTER=1
#export VSCODE_SKIP_UPDATE_CHECK=1

# ---------- PROOT FIX ----------                                                  # Fix network interface crash
#export NODE_NO_WARNINGS=1

# ---------- CLEAN BROKEN MODULES ----------
#if [ ! -d "/usr/lib/code-server/lib/vscode/node_modules/vsda" ]; then
#    echo "Fixing missing vsda module..."
#    mkdir -p /usr/lib/code-server/lib/vscode/node_modules/vsda
#fi

# ---------- DIRECTORIES ----------
mkdir -p "$DATA_DIR"
mkdir -p "$CONFIG_DIR"

# ---------- START SERVER ----------
echo "Starting optimized code-server..."

exec code-server \
  --bind-addr ${HOST}:${PORT} \
  --auth none \
  --disable-telemetry \
  --disable-update-check \
  --disable-workspace-trust \
  --disable-getting-started-override \
  --disable-file-downloads \
  --user-data-dir "$DATA_DIR" \
  --config "$CONFIG_DIR/config.yaml"
EOF 
echo "setting permission"
sleep 3
chmod +x /bin/vsc
sleep 4
echo "code settings. Installing..."
mkdir -p ~/.local/share/code-server/User/
cat > ~/.local/share/code-server/User/settings.jsonand << EOF 
{
  "chat.enabled": false,
  "workbench.panel.chat.enabled": false,
  "chat.commandCenter.enabled": false,
  "github.copilot.enable": false,

  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "workbench.panel.alignment": "justify",

  "update.mode": "none",
  "telemetry.telemetryLevel": "off",

  "workbench.startupEditor": "none",
  "workbench.tips.enabled": false,
  "workbench.welcomePage.walkthroughs.openOnInstall": false
}
EOF
echo "VSCode install complete ✅"
sleep 3
echo "Now Restart Your Application"
cat > /root/AHK/done<< EOF install complete 
EOF
