#!/bin/bash
# VS Code VNC Setup Script

set -e

echo -e "\e[35;1m[*] \e[0mInstalling VS Code environment...\e[0m"


echo "=== VSCode + VNC + Openbox Setup Script ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Update package list
print_status "Updating package list..."
apt-get update -qq

# Install dependencies (including manually installed packages)
print_status "Installing dependencies..."
apt-get install -y -qq \
    wget \
    curl \
    openbox \
    python3-xdg \
    xterm \
    xdotool \
    x11-utils \
    tigervnc-standalone-server \
    tigervnc-viewer \
    tigervnc-tools \
    xfonts-base \
    x11-xserver-utils \
    libasound2t64 \
    libatk-bridge2.0-0t64 \
    libatk1.0-0t64 \
    libatspi2.0-0t64 \
    libcairo2 \
    libgbm1 \
    libgtk-3-0t64 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xdg-utils \
    2>&1 | grep -v "^Selecting" | grep -v "^Preparing" | grep -v "^Unpacking" | grep -v "^Setting up" | grep -v "^Processing" || true

# Detect architecture
ARCH=$(dpkg --print-architecture)
print_status "Detected architecture: $ARCH"

# Download and install VSCode
print_status "Downloading VSCode..."
if [ "$ARCH" = "arm64" ]; then
    VSCODE_URL="https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-arm64"
elif [ "$ARCH" = "amd64" ]; then
    VSCODE_URL="https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"
else
    print_error "Unsupported architecture: $ARCH"
    exit 1
fi

wget -q --show-progress -O /tmp/vscode.deb "$VSCODE_URL"

print_status "Installing VSCode..."
dpkg -i /tmp/vscode.deb 2>/dev/null || apt-get install -f -y -qq
rm -f /tmp/vscode.deb

# Get the user who ran sudo (or use root if not sudo)
if [ -n "$SUDO_USER" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME="$(eval echo ~$SUDO_USER)"
else
    TARGET_USER="root"
    TARGET_HOME="/root"
fi

print_status "Configuring for user: $TARGET_USER"

# Create necessary directories
print_status "Creating configuration directories..."
mkdir -p "$TARGET_HOME/.vnc"
mkdir -p "$TARGET_HOME/.config/tigervnc"
mkdir -p "$TARGET_HOME/.config/openbox"
mkdir -p "$TARGET_HOME/.vscode-vnc"

# Set VNC password
print_status "Setting VNC password..."
if [ ! -f "$TARGET_HOME/.vnc/passwd" ]; then
    # Create .vnc directory if it doesn't exist
    mkdir -p "$TARGET_HOME/.vnc"
    # Set password using vncpasswd
    echo -e "123456\n123456\nn" | vncpasswd 2>/dev/null || true
    # Copy password file to correct location if created elsewhere
    if [ -f "$TARGET_HOME/.config/tigervnc/passwd" ] && [ ! -f "$TARGET_HOME/.vnc/passwd" ]; then
        cp "$TARGET_HOME/.config/tigervnc/passwd" "$TARGET_HOME/.vnc/passwd"
    fi
    # Set proper permissions
    if [ -f "$TARGET_HOME/.vnc/passwd" ]; then
        chmod 600 "$TARGET_HOME/.vnc/passwd"
        print_status "VNC password set to: 123456"
        print_warning "Please change the VNC password using: vncpasswd"
    else
        print_error "Failed to create VNC password file"
    fi
fi

# Create Openbox configuration with VSCode window rules
print_status "Creating Openbox configuration..."

# Create rc.xml with window rules for VSCode
cat > "$TARGET_HOME/.config/openbox/rc.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance>
    <strength>10</strength>
    <screen_edge_strength>20</screen_edge_strength>
  </resistance>
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
    <focusLast>yes</focusLast>
    <underMouse>no</underMouse>
    <focusDelay>200</focusDelay>
    <raiseOnFocus>no</raiseOnFocus>
  </focus>
  <placement>
    <policy>Smart</policy>
    <center>yes</center>
    <monitor>Any</monitor>
    <primaryMonitor>1</primaryMonitor>
  </placement>
  <theme>
    <name>Clearlooks</name>
    <titleLayout>NLIMC</titleLayout>
    <keepBorder>yes</keepBorder>
    <animateIconify>yes</animateIconify>
    <font place="ActiveWindow">
      <name>sans</name>
      <size>8</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
    <font place="InactiveWindow">
      <name>sans</name>
      <size>8</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
  </theme>
  <desktops>
    <number>1</number>
    <firstdesk>1</firstdesk>
  </desktops>
  <resize>
    <drawContents>yes</drawContents>
  </resize>
  <margins>
    <top>0</top>
    <bottom>0</bottom>
    <left>0</left>
    <right>0</right>
  </margins>
  <keyboard>
    <keybind key="A-F4">
      <action name="Execute">
        <command>true</command>
      </action>
    </keybind>
    <keybind key="A-Escape">
      <action name="Execute">
        <command>true</command>
      </action>
    </keybind>
  </keyboard>
  <applications>
    <!-- VSCode: window rules - fullscreen, no minimize, no close -->
    <application class="code">
      <decor>no</decor>
      <maximized>yes</maximized>
      <fullscreen>yes</fullscreen>
      <minimize>no</minimize>
      <maximize>no</maximize>
      <close>no</close>
      <layer>normal</layer>
      <skip_taskbar>yes</skip_taskbar>
    </application>
    <application name="Code">
      <decor>no</decor>
      <maximized>yes</maximized>
      <fullscreen>yes</fullscreen>
      <minimize>no</minimize>
      <maximize>no</maximize>
      <close>no</close>
      <layer>normal</layer>
      <skip_taskbar>yes</skip_taskbar>
    </application>
    <application class="code-oss">
      <decor>no</decor>
      <maximized>yes</maximized>
      <fullscreen>yes</fullscreen>
      <minimize>no</minimize>
      <maximize>no</maximize>
      <close>no</close>
      <layer>normal</layer>
      <skip_taskbar>yes</skip_taskbar>
    </application>
  </applications>
</openbox_config>
EOF

# Create xstartup script - simple and working version
print_status "Creating VNC xstartup script..."
cat > "$TARGET_HOME/.config/tigervnc/xstartup" << 'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec openbox
EOF
chmod +x "$TARGET_HOME/.config/tigervnc/xstartup"

# Create the main vscode start script
print_status "Creating vscode start script..."
START_SCRIPT="/home/vscode"
cat > "$START_SCRIPT" << 'EOF'
#!/bin/bash

# VSCode + VNC + Openbox Starter Script

# Configuration
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_RESOLUTION="${VNC_RESOLUTION:-720x1280}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5905}"

# Strip : from display number for grep commands
VNC_NUM="${VNC_DISPLAY#:}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=================================${NC}"
echo -e "${BLUE}  VSCode + VNC + Openbox Starter${NC}"
echo -e "${BLUE}=================================${NC}"
echo ""

# Function to cleanup
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down...${NC}"
    tigervncserver -kill "$VNC_DISPLAY" 2>/dev/null || true
    exit 0
}

# Set trap for cleanup
trap cleanup INT TERM EXIT

# Check if VNC server is already running
if tigervncserver -list 2>/dev/null | grep -q "^$VNC_NUM"; then
    echo -e "${YELLOW}VNC server already running on display $VNC_DISPLAY${NC}"
    echo -e "${YELLOW}Stopping existing server...${NC}"
    tigervncserver -kill "$VNC_DISPLAY" 2>/dev/null || true
    sleep 2
fi

# Clean up any stale lock files
rm -f "/tmp/.X${VNC_NUM}-lock" "/tmp/.X11-unix/X${VNC_NUM}" 2>/dev/null || true

# Ensure xstartup script exists
mkdir -p ~/.config/tigervnc
if [ ! -f ~/.config/tigervnc/xstartup ]; then
cat > ~/.config/tigervnc/xstartup << 'XEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec openbox
XEOF
chmod +x ~/.config/tigervnc/xstartup
fi

echo -e "${GREEN}Starting VNC server...${NC}"
echo "  Display: $VNC_DISPLAY"
echo "  Port: $VNC_PORT"
echo "  Resolution: $VNC_RESOLUTION"
echo ""

# Start VNC server
tigervncserver -geometry "$VNC_RESOLUTION" \
               -depth "$VNC_DEPTH" \
               -rfbport "$VNC_PORT" \
               "$VNC_DISPLAY" 2>&1 | head -5

# Check if VNC started successfully
sleep 3
if ! tigervncserver -list 2>/dev/null | grep -q "^$VNC_NUM"; then
    echo -e "${RED}ERROR: VNC server failed to start!${NC}"
    echo -e "${YELLOW}Check logs: ~/.config/tigervnc/localhost.localdomain:$VNC_DISPLAY.log${NC}"
    exit 1
fi

echo -e "${GREEN}VNC server started!${NC}"
echo ""
echo "========================================"
echo "Connect to VNC:"
echo "  Host: <your-host>:$VNC_PORT"
echo "  Password: (set during setup - default: 123456)"
echo ""
echo "To stop: Press Ctrl+C"
echo "========================================"
echo ""

# Set background color
echo -e "${GREEN}Setting desktop background...${NC}"
DISPLAY="$VNC_DISPLAY" xsetroot -solid "#2e3440" 2>/dev/null || true

# Start VSCode
echo -e "${GREEN}Starting VSCode...${NC}"
DISPLAY="$VNC_DISPLAY" code --no-sandbox --user-data-dir=$HOME/.vscode-vnc &

# Give VSCode time to initialize
sleep 5

# Maximize VSCode window using xdotool if available
if command -v xdotool &> /dev/null; then
    echo -e "${GREEN}Maximizing VSCode window...${NC}"
    sleep 2
    # Try to find and maximize the VSCode window
    DISPLAY="$VNC_DISPLAY" xdotool search --class "Code" windowactivate windowmaximize 2>/dev/null || true
    DISPLAY="$VNC_DISPLAY" xdotool search --class "code" windowactivate windowmaximize 2>/dev/null || true
fi

# Verify everything is running
if ps aux | grep -v grep | grep -q "openbox"; then
    echo -e "${GREEN}✓ Openbox is running${NC}"
else
    echo -e "${YELLOW}! Warning: Openbox not detected${NC}"
fi

if ps aux | grep -v grep | grep -q "code.*user-data-dir"; then
    echo -e "${GREEN}✓ VSCode is running${NC}"
else
    echo -e "${YELLOW}! Warning: VSCode not detected${NC}"
fi

echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop the server${NC}"
echo ""

# Keep script running and monitor VNC
while true; do
    sleep 3
    if ! tigervncserver -list 2>/dev/null | grep -q "^$VNC_NUM"; then
        echo -e "${YELLOW}VNC server has stopped${NC}"
        break
    fi
done
EOF

# Ensure the starter script has proper permissions
chmod 755 "$START_SCRIPT"
# Set ownership for the target user
if [ "$TARGET_USER" != "root" ]; then
    chown "$TARGET_USER:$TARGET_USER" "$START_SCRIPT"
fi

# Create desktop entry (if desktop environment exists)
if [ -d "/usr/share/applications" ]; then
    cat > /usr/share/applications/vnc-vscode.desktop << EOF
[Desktop Entry]
Name=VSCode VNC Server
Comment=Start VSCode with VNC and Openbox
Exec=$START_SCRIPT
Type=Application
Terminal=true
Icon=code
Categories=Development;
EOF
fi

# Fix ownership for the target user
if [ "$TARGET_USER" != "root" ]; then
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.vnc"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.vscode-vnc"
    chown "$TARGET_USER:$TARGET_USER" "$START_SCRIPT"
fi

# Download additional vscode script from external source
print_status "Downloading additional vscode script..."
if curl -f -s https://raw.githubusercontent.com/ahksoft/AiDevSpace-resources/refs/heads/main/scripts/vscode -o ~/vscode; then
    chmod +x ~/vscode
    mv ~/vscode /usr/bin
    curl -f -s https://raw.githubusercontent.com/ahksoft/AiDevSpacresourcese-/refs/heads/main/scripts/settings.json -o ~/settings.json
    mv ~/settings.json /.vscode-vnc/User/settings.json
    print_status "Additional vscode script installed"
else
    print_warning "Failed to download additional vscode script (continuing without it)"
fi

# Mark setup as complete
touch /root/.vscode_setup_done
sudo bash -c 'echo "127.0.0.1 localhost" >> /etc/hosts'

echo -e "\e[32;1m[ ^|^s] \e[0mVS Code VNC setup completed!\e[0m"


echo ""
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}  Setup Complete!${NC}"
echo -e "${GREEN}===============================================${NC}"
echo ""
echo "To start VSCode + VNC + Openbox, run:"
echo ""
echo "  /home/vscode"
echo ""
echo "Default configuration:"
echo "  VNC Port: 5905"
echo "  Display: :1"
echo "  Resolution: 720x1280"
echo "  Password: 123456"
echo ""
echo "Connect with any VNC viewer to:"
echo "  <hostname>:5905"
echo ""
echo "To change VNC password:"
echo "  vncpasswd"
echo ""
echo "To customize settings, edit:"
echo "  ~/.config/tigervnc/xstartup"
echo ""
