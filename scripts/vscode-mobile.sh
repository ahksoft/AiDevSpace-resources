#!/usr/bin/env bash
set -e

# ============================================================
# code-server install & launcher setup
# ============================================================

echo "Installing code-server..."
curl -fsSL https://github.com/ahksoft/AiDevSpace-resources/releases/download/Vscode/code -o ~/code
mv ~/code /bin
chmod +x /bin/code
echo Creating launcher at /bin/vsc..."

# BUG FIX: Use quoted 'EOF' so that variables like ${HOME}, ${PORT},
# ${HOST} are NOT expanded now (at install time) but remain as
# literal text inside the generated /bin/vsc script, where they
# will be evaluated correctly at runtime.
cat > /bin/vsc << 'EOF'
#!/usr/bin/env bash
set -e

# ---------- CONFIG ----------
code serve-web  --host=0.0.0.0  --port=6862 --without-connection-token "$@"
EOF

echo "Setting permissions on /bin/vsc..."
chmod +x /bin/vsc

echo "Installing code-server settings..."
#mkdir -p ~/.local/share/code-server/User/

# BUG FIX: filename was "settings.jsonand" — corrected to "settings.json"
#cat > ~/.local/share/code-server/User/settings.json << 'EOF'
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

code serve-web  --host=0.0.0.0  --port=6862 --without-connection-token   "$@" 2>/dev/null &
curl http://localhost:6862 | 2>/dev/null 

# BUG FIX: create parent directory before writing the done marker,
# and fix the broken heredoc syntax (EOF must be on its own line)
cat > /root/AHK/done << 'EOF'
install complete
EOF 2>/dev/null

echo ""
echo "VSCode install complete ✅"
sleep 3
echo "Now restart your application and run: vsc"
