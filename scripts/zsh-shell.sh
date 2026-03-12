#!/usr/bin/env bash
# Linux Zsh + Zinit + Powerlevel10k full setup
# Author: AHK Soft

set -e

echo "📦 Updating system packages..."

# ---------------------------
# Detect package manager
# ---------------------------
if command -v apt >/dev/null 2>&1; then
    PKG_UPDATE="sudo apt update -y && sudo apt upgrade -y"
    PMGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_UPDATE="sudo dnf upgrade -y"
    PMGR="dnf"
elif command -v pacman >/dev/null 2>&1; then
    PKG_UPDATE="sudo pacman -Syu --noconfirm"
    PMGR="pacman"
else
    echo "[ERROR] Unsupported Linux distribution. Install packages manually."
    exit 1
fi

eval $PKG_UPDATE

# ---------------------------
# Safe package install
# ---------------------------
pkg_install() {
    pkg_name="$1"
    if [ "$PMGR" = "apt" ]; then
        if apt-cache show "$pkg_name" >/dev/null 2>&1; then
            sudo apt install -y "$pkg_name"
        else
            echo "[INFO] Package '$pkg_name' not found. Skipping."
        fi
    elif [ "$PMGR" = "dnf" ]; then
        if dnf list "$pkg_name" >/dev/null 2>&1; then
            sudo dnf install -y "$pkg_name"
        else
            echo "[INFO] Package '$pkg_name' not found. Skipping."
        fi
    elif [ "$PMGR" = "pacman" ]; then
        if pacman -Si "$pkg_name" >/dev/null 2>&1; then
            sudo pacman -S --noconfirm "$pkg_name"
        else
            echo "[INFO] Package '$pkg_name' not found. Skipping."
        fi
    fi
}

# ---------------------------
# Essential packages
# ---------------------------
echo "💡 Installing essential packages..."
for pkg in zsh git curl wget unzip nano fzf fd-find bat eza jq zoxide fontconfig; do
    pkg_install "$pkg"
done
# prover9 skipped

# ---------------------------
# Oh-My-Zsh
# ---------------------------
echo "💡 Installing Oh-My-Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# ---------------------------
# .aliases
# ---------------------------
echo "📥 Downloading .aliases..."
curl -fsSL https://raw.githubusercontent.com/ahksoft/ahk-termux-desktop/f7c1e118e70bdd5d89f6aba0979aed97d2727ada/other/.aliases -o ~/.aliases

# ---------------------------
# Zinit
# ---------------------------
ZINIT_HOME="$HOME/.local/share/zinit"
mkdir -p "$ZINIT_HOME"
if [ ! -d "$ZINIT_HOME/zinit.git" ]; then
  git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME/zinit.git"
fi

# ---------------------------
# MesloLGS NF Nerd Font
# ---------------------------
echo "💡 Installing MesloLGS NF Nerd Font..."
mkdir -p ~/.local/share/fonts
cd ~/.local/share/fonts

for style in "Regular" "Bold" "Italic" "Bold Italic"; do
    fname="MesloLGS NF ${style}.ttf"
    url="https://github.com/romkatv/powerlevel10k-media/raw/master/${fname// /%20}"
    echo "📥 Downloading $fname"
    wget -q "$url" -O "$fname"
done

fc-cache -fv >/dev/null
echo "✅ MesloLGS NF installed. Set your terminal font to 'MesloLGS NF'."

read -p "Press ENTER after setting your terminal font to MesloLGS NF..."

# ---------------------------
# .zshrc
# ---------------------------
echo "⚙️ Writing .zshrc..."
cat > ~/.zshrc << 'EOF'
#!/usr/bin/env zsh

export EDITOR="nvim"
export VISUAL="nvim"
export BAT_PAGER="less"
setopt AUTO_CD
setopt nonomatch

# Load aliases
[ -f "$HOME/.aliases" ] && source "$HOME/.aliases"

# ---------------------
# ZINIT
# ---------------------
typeset -gAH ZINIT
ZINIT[HOME_DIR]="$HOME/.local/share/zinit"
ZINIT[BIN_DIR]="$ZINIT[HOME_DIR]/zinit.git"
ZINIT[COMPLETIONS_DIR]="$ZINIT[HOME_DIR]/completions"
ZINIT[SNIPPETS_DIR]="$ZINIT[HOME_DIR]/snippets"
ZINIT[ZCOMPDUMP_PATH]="$ZINIT[HOME_DIR]/zcompdump"
ZINIT[PLUGINS_DIR]="$ZINIT[HOME_DIR]/plugins"
ZINIT[OPTIMIZE_OUT_DISK_ACCESSES]=1

[ -f "$ZINIT[BIN_DIR]/zinit.zsh" ] && source "$ZINIT[BIN_DIR]/zinit.zsh"

# ---------------------
# Plugins
# ---------------------
zi light zsh-users/zsh-completions
zi ice atload'_zsh_autosuggest_start' atinit'ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=50; bindkey "^_" autosuggest-execute; bindkey "^ " autosuggest-accept'
zi light zsh-users/zsh-autosuggestions
zi light zdharma-continuum/fast-syntax-highlighting
zi light joshskidmore/zsh-fzf-history-search
zi ice atload'bindkey "^I" menu-select; bindkey -M menuselect "$terminfo[kcbt]" reverse-menu-complete'
zi light marlonrichert/zsh-autocomplete

# ---------------------
# Powerlevel10k (official)
# ---------------------
zi ice atclone"git submodule update --init --recursive" \
       atpull"%atclone" \
       depth=1 lucid
zi light romkatv/powerlevel10k

[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

if [[ ! -f ~/.p10k.zsh ]]; then
    echo "💡 Powerlevel10k config not found. Running wizard..."
    autoload -Uz promptinit
    promptinit
    if [[ $- == *i* ]]; then
        p10k configure
    fi
fi

function set_10k_theme() {
    rm -f ~/.p10k.zsh
    echo "✅ Powerlevel10k theme reset. Restart Zsh to configure again."
}

# ---------------------
# Completion
# ---------------------
autoload -Uz compinit
compinit

# Smart cd + ./ completion
zstyle ':completion:*:*:cd:*' tag-order directories
function _local_execs() {
  compadd $(find . -maxdepth 1 -type f -executable 2>/dev/null)
}
compdef _local_execs ./
bindkey '^I' expand-or-complete

# ---------------------
# Auto-suggestions from all commands
# ---------------------
_all_cmds_file="$HOME/.all_commands"
compgen -c | sort -u > $_all_cmds_file
[ -f "$HOME/.aliases" ] && alias | awk -F'[ =]' '{print $2}' >> $_all_cmds_file
autoload -U add-zsh-hook
function zsh_suggest_all_commands() {
    local cur="${BUFFER}"
    BUFFER=$(compgen -W "$(cat $_all_cmds_file)" -- "$cur")
}
add-zsh-hook preexec zsh_suggest_all_commands

function command_not_found_handler() {
    echo "[INFO] Command '$1' not found. Install manually."
}
EOF

# ---------------------------
# Default shell
# ---------------------------
echo "🔄 Changing default shell to zsh..."
chsh -s $(which zsh)

echo "✅ Linux setup finished!"
echo "💡 First Zsh launch will run Powerlevel10k wizard. Ensure 'MesloLGS NF' is selected as terminal font."
echo "👉 You ready to go restart terminal or run "zsh" manually for complete instaltion!"
rm ~/linux-super-shell.sh
