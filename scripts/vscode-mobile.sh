#!/usr/bin/env bash
set -e

PORT=6862
HOST=0.0.0.0
URL="http://127.0.0.1:$PORT"
LOG="/tmp/vscode-web.log"

echo "Installing VSCode ⚙️..."

curl -fsSL https://github.com/ahksoft/AiDevSpace-resources/releases/download/Vscode/code -o /bin/code
chmod +x /bin/code


echo "Creating launcher ..."
sleep 3
cat > /bin/vsc << 'EOF'
#!/usr/bin/env bash
set -e

PORT=6862
HOST=0.0.0.0

pkill -f "code serve-web" 2>/dev/null || true

echo "Starting VSCode ⚙️..."

code serve-web \
  --host=$HOST \
  --port=$PORT \
  --without-connection-token \
  "$@"
EOF

chmod +x /bin/vsc


echo "Installing VSCode settings 🛠️..."

mkdir -p ~/.vscode-server/data/User

cat > ~/.vscode-server/data/User/settings.json << 'EOF'
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


echo ""
echo "Installing VSCode Resources..."

pkill -f "code serve-web" 2>/dev/null || true

code serve-web \
  --host=$HOST \
  --port=$PORT \
  --without-connection-token \
  2>&1 | tee "$LOG" &

SERVER_PID=$!


echo "Waiting for Web UI..."

until grep -q "Web UI available" "$LOG"; do
    sleep 0.3
done

echo "Web UI detected."
echo "Trying to Download VSCode dependencies..."

for i in 1 2 3 4 5
do
    curl -s -H "User-Agent: Mozilla/5.0" "$URL" >/dev/null 2>&1 || true
    sleep 1
done


echo "Waiting for server..."

until grep -q "Downloading server" "$LOG"; do
    sleep 2
done

echo "download started."


echo "Please be patient unit Download complete..."

until grep -q "Starting server" "$LOG"; do
    sleep 1.5
done

echo "Download complete."
sleep 3


echo "Setting Environment..."
kill $SERVER_PID 2>/dev/null || true

mkdir -p ~/.vscode/cli
sleep 0.5
cat > ~/.vscode/cli/product.json << 'EOF'
{
  "extensionsGallery": {
    "serviceUrl": "https://open-vsx.org/vscode/gallery",
    "itemUrl": "https://open-vsx.org/vscode/item"
  }
}
EOF


cat > /bin/code-server << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

CODE_BIN="${CODE_BIN:-code}"

case "${1:-}" in
    -v|-V|--version)
        exec "$CODE_BIN" --version
        ;;
    version)
        exec "$CODE_BIN" version "${@:2}"
        ;;
    "")
        exec "$CODE_BIN" serve-web
        ;;
    *)
        exec "$CODE_BIN" serve-web "$@"
        ;;
esac
EOF


echo ""
echo "VSCode install complete ✅"
echo ""
echo "Run VSCode using:"
echo "vsc"
echo ""
echo "Then open:"
echo "http://localhost:6862"


sleep 3

echo "Please Restart Application..."
exit 0 2>/dev/null || kill $$
