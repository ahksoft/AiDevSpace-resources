#!/bin/bash

# --------------------------
# Colors
# --------------------------
C='\e[1;36m'
Y='\e[1;33m'
G='\e[1;32m'
R='\e[1;31m'
W='\e[0m'

banner(){
    clear
    printf "${C} █████╗  ██╗  ██╗██╗  ██╗\n"
    printf "██╔══██╗ ██║  ██║██║ ██╔╝\n"
    printf "███████║ ███████║█████╔╝ \n"
    printf "██╔══██║ ██╔══██║██╔═██╗ \n"
    printf "██║  ██║ ██║  ██║██║  ██╗\n"
    printf "╚═╝  ╚═╝ ╚═╝  ╚═╝╚═╝  ╚═╝\n${W}"
    printf "${Y}                Developed By Abir Hasan AHK\n${W}"
}

# --------------------------
# Add ubuntu user  [ROOT PHASE]
# --------------------------
add_user(){
    echo -e "${G}Adding user 'ubuntu'...${W}"

    if id "ubuntu" &>/dev/null; then
        echo -e "${Y}User 'ubuntu' already exists, updating...${W}"
    else
        useradd -m -s /bin/bash ubuntu
    fi

    echo "ubuntu:1234" | chpasswd
    usermod -aG sudo ubuntu
    echo "ubuntu ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
    chmod 440 /etc/sudoers.d/ubuntu

    echo -e "${G}User 'ubuntu' ready (password: 1234, full sudo).${W}"
    sleep 1
}

# --------------------------
# Install XFCE Desktop  [UBUNTU PHASE]
# --------------------------
install_desktop(){
    echo -e "${G}Installing XFCE Desktop...${W}"

    sudo apt-get update

    # Install udisks2 safely (postinst fails in rootless envs)
    sudo apt-get install -y udisks2
    sudo rm -rf /var/lib/dpkg/info/udisks2.postinst
    sudo sh -c 'echo "" > /var/lib/dpkg/info/udisks2.postinst'
    sudo dpkg --configure -a
    sudo apt-mark hold udisks2

    sudo apt-get install -y xfce4 gnome-terminal nautilus dbus-x11 \
        tigervnc-standalone-server pulseaudio python3-psutil

    # vncstart — runs as ubuntu, VNC on display :5 (port 5905)
    sudo tee /bin/vncstart > /dev/null <<'EOF'
#!/bin/bash
CURRENT_HOST=$(hostname 2>/dev/null || echo "localhost")
grep -q "$CURRENT_HOST" /etc/hosts 2>/dev/null || \
    echo "127.0.0.1 $CURRENT_HOST" | sudo tee -a /etc/hosts
grep -q "127.0.0.1 localhost" /etc/hosts 2>/dev/null || \
    echo "127.0.0.1 localhost" | sudo tee -a /etc/hosts

[ -z "$(pgrep dbus-daemon)" ] && \
    sudo dbus-daemon --system --fork 2>/dev/null || true
echo "Switching to user: ubuntu"
su - ubuntu <<'USEREOF'
vncserver -kill :5 2>/dev/null || true
rm -rf /tmp/.X5-lock /tmp/.X11-unix/X5 2>/dev/null || true
sleep 1
vncserver :5 -geometry 720x1280 -rfbport 5905 -xstartup /usr/bin/startxfce4
USEREOF
EOF

    sudo tee /bin/vncstop > /dev/null <<'EOF'
#!/bin/bash
su - ubuntu <<'USEREOF'
vncserver -kill :5
rm -rf /tmp/.X5-lock /tmp/.X11-unix/X5
USEREOF
EOF

    sudo chmod +x /usr/local/bin/vncstart /usr/local/bin/vncstop

    # vncpasswd runs as ubuntu → stored in ~/.vnc/ (correct)
    printf "123456\n123456\nn\n" | vncpasswd
}

# --------------------------
# Install Chromium Browser  [UBUNTU PHASE]
# --------------------------
install_chromium(){
    echo -e "${G}Installing Chromium Browser...${W}"

    sudo apt-get install -y chromium || \
    sudo apt-get install -y chromium-browser || {
        echo -e "${R}Package manager install failed, trying snap...${W}"
        sudo apt-get install -y snapd && \
        sudo snap install chromium || \
        echo -e "${R}Chromium install failed — check internet connection.${W}"
    }

    # Create a desktop launcher that works inside VNC (no sandbox in proot)
    mkdir -p ~/.local/share/applications
    cat > ~/.local/share/applications/chromium-vnc.desktop <<'EOF'
[Desktop Entry]
Name=Chromium
Comment=Chromium Browser
Exec=chromium --no-sandbox --disable-dev-shm-usage --disable-gpu %U
Icon=chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;
EOF

    # Also create a wrapper so plain 'chromium' works without sandbox flags
    sudo tee /bin/chromium > /dev/null <<'EOF'
#!/bin/bash
exec chromium --no-sandbox --disable-dev-shm-usage --disable-gpu "$@"
EOF
    sudo chmod +x /usr/local/bin/chromium-safe

    echo -e "${G}Chromium installed. Use 'chromium-safe' from terminal or desktop icon.${W}"
}

# --------------------------
# Install Theme  [UBUNTU PHASE]
# --------------------------
install_theme(){
    echo -e "${G}Installing Theme...${W}"
    wget -q https://raw.githubusercontent.com/ahksoft/ahk-modded-distro-ubuntu/main/theme/theme.sh
    bash theme.sh
    rm -f theme.sh
}

# --------------------------
# Sound setup  [UBUNTU PHASE]
# --------------------------
sound_setup(){
    echo -e "${G}Setting up PulseAudio...${W}"
    sudo apt-get install -y pulseaudio

    # ~/.bashrc now correctly targets ubuntu's home
    cat >> ~/.bashrc <<'EOF'

# PulseAudio auto-start
pulseaudio --start \
    --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
    --exit-idle-time=-1 2>/dev/null
EOF
}

# --------------------------
# Install Pi-Apps  [UBUNTU PHASE]
# --------------------------
install_piapps(){
    echo -e "${G}Installing Pi-Apps store...${W}"
    sudo apt-get install -y wget git curl || true
    # Already running as ubuntu — no su needed
    wget -qO- https://raw.githubusercontent.com/Botspot/pi-apps/master/install | bash || \
        echo -e "${R}Pi-Apps install failed — check internet connection.${W}"
}

# --------------------------
# Final Banner
# --------------------------
final_banner(){
    banner
    echo
    echo -e "${G}Installation completed${W}\n"
    echo -e "${Y}Commands:${W}"
    echo -e "  ${C}vncstart${W}       - Start VNC desktop (port 5905)"
    echo -e "  ${C}vncstop${W}        - Stop VNC desktop"
    echo -e "  ${C}chromium-safe${W}  - Launch Chromium browser"
    echo
    touch /root/.desktop_installed
    rm -f ~/install.sh   # removes /home/ubuntu/install.sh
}

# ==========================
# Entry point — two phases
# ==========================
SCRIPT_PATH="$(realpath "$0")"

if [[ "$1" == "--as-ubuntu" ]]; then
    # ── PHASE 2: running as ubuntu ──────────────────────────
    banner
    install_desktop
    install_chromium
    install_theme
    sound_setup
    install_piapps
    final_banner

else
    # ── PHASE 1: running as root ─────────────────────────────
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${R}Run as root!${W}"
        exit 1
    fi

    banner
    add_user

    # Copy script to ubuntu's home so she can read it
    cp "$SCRIPT_PATH" /home/ubuntu/install.sh
    chown ubuntu:ubuntu /home/ubuntu/install.sh
    chmod +x /home/ubuntu/install.sh

    echo -e "${G}Switching to user 'ubuntu'...${W}"
    sleep 1
    # exec replaces this root process entirely — no return to root
    exec su - ubuntu -c "bash /home/ubuntu/install.sh --as-ubuntu"
fi
