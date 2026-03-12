#!/bin/sh
# =============================================================================
#  cs-mobile-patch.sh  —  Patch VS Code / code-server for Android
#  Version: 6.0
#
#  Directly modifies workbench.js inside your VS Code installation.
#  No proxy server, no browser extension, works in any browser.
#
#  Supports both workbench layouts:
#    Layout A (VS Code CLI serve-web):       <ROOT>/out/vs/code/browser/workbench/
#    Layout B (code-server release-standalone): <ROOT>/lib/vscode/out/vs/code/browser/workbench/
#
#  USAGE:
#    sh cs-mobile-patch.sh patch   [--yes] [INSTALLATION_DIR]
#    sh cs-mobile-patch.sh revert  [INSTALLATION_DIR]
#    sh cs-mobile-patch.sh status  [INSTALLATION_DIR]
#    sh cs-mobile-patch.sh search
#
# =============================================================================
#
#  HOW EACH PATCH WORKS (full mechanism):
#
#  [JS-1] KEYBOARD POPUP ON SCROLL
#    VS Code's GestureRecognizer touchmove handler calls this.F() to dispatch
#    the scroll event, then calls t.preventDefault(). On Android,
#    preventDefault() on a scroll-phase touchmove causes a relayout/focus
#    cycle that opens the soft keyboard.
#    Fix: record this.eventType=Ks.Change after this.F() fires, then guard
#    t.preventDefault() with "this.eventType!==Ks.Change&&". Clear flag after.
#    Ks (EventType) is minified per-build and auto-detected from the source.
#
#  [JS-2a] CONTEXT MENU — canRelayout
#    VS Code hides the context menu when the window resizes (keyboard open/close
#    triggers this via canRelayout===!1 check). Guard with !isAndroid.
#
#  [JS-2b] CONTEXT MENU — blur-on-focus-loss
#    VS Code blurs the menu's root element when it loses focus. On Android
#    this happens spuriously when touch events cause focus shifts. Guard with
#    !isAndroid so the menu stays open.
#
#  [JS-2c] CONTEXT MENU — stable position after keyboard resize
#    showContextView() positions the menu relative to the triggering element.
#    When the Android keyboard opens, all element positions shift, making the
#    menu jump. Fix: on Android, always use activeContainer at position 1
#    (screen-relative, stable regardless of keyboard state).
#
#  [JS-3] keyboard.dispatch = keyCode
#    Android Gboard sends keyCode=229 (composition event) for almost every
#    key in "code" dispatch mode because event.code is empty during composition.
#    VS Code sees nothing. "keyCode" mode reads event.keyCode instead, which
#    contains the real value. Set default to keyCode on Android.
#
#  [JS-4] actionWidget pointerBlock: add touch event listeners
#    VS Code creates a .context-view-pointerBlock transparent overlay to catch
#    clicks outside a menu. It only listens to POINTER_MOVE and MOUSE_DOWN.
#    On Android, touch events don't always synthesize mouse events, leaving the
#    overlay stuck and blocking all taps. Add "touchstart"+"touchmove" listeners
#    that also remove the overlay.
#
#  [JS-5] onDidLayoutChange: stop hiding menu when keyboard opens
#    The action widget (quick-fix lightbulb) subscribes to layout changes to
#    hide. On Android, keyboard open = layout change = menu vanishes before
#    you can tap any suggestion. Guard subscription with isAndroid||.
#
#  [JS-6] experimentalEditContextEnabled = false   <- CRITICAL FOR INSIDERS
#    VS Code Insiders (and newer Stable) enable the EditContext browser API
#    by default. On Android it makes the keyboard appear but characters never
#    reach the editor — completely broken. Force default to false.
#    Ref: https://github.com/microsoft/vscode/commit/3ff1dceedf606ee5cc60ffab6c1132b91ce67228
#
#  [SIGN] vsce-sign bypass
#    Some Android arm64 builds cannot run the vsce-sign native binary,
#    causing all extension installs to fail. Stub verify() to always succeed.
#
# =============================================================================

set -eu

PROGRAM=$(basename "$0")
PATCH_MARKER="cs-mobile-v6"

# ── ANSI colours (stderr only, auto-disabled when not a tty) ─────────────────
if [ -t 2 ]; then
    GRN='\033[0;32m' YLW='\033[0;33m' RED='\033[0;31m'
    CYN='\033[0;36m' BLD='\033[1m'    RST='\033[0m'
else
    GRN='' YLW='' RED='' CYN='' BLD='' RST=''
fi

msg()  { printf "${CYN}[patch]${RST} %s\n" "$*" >&2; }
ok()   { printf "${GRN}[  ok ]${RST} %s\n" "$*" >&2; }
warn() { printf "${YLW}[ warn]${RST} %s\n" "$*" >&2; }
die()  { printf "${RED}[ERROR]${RST} %s\n" "$*" >&2; exit 1; }

# =============================================================================
#  WORKBENCH ROOT — given a path to workbench.html, strip the known suffix
#  to recover the installation ROOT.
#
#  Handles two layouts:
#    Layout A: <ROOT>/out/vs/code/browser/workbench/workbench.html
#    Layout B: <ROOT>/lib/vscode/out/vs/code/browser/workbench/workbench.html
# =============================================================================

html_to_root() {
    # $1 = full path to workbench.html
    _dir=$(dirname "$1")
    # Try lib/vscode/out layout first (longer suffix)
    _r=$(printf '%s' "${_dir}" | sed 's|/lib/vscode/out/vs/code/browser/workbench$||')
    if [ "${_r}" != "${_dir}" ]; then
        printf '%s\n' "${_r}"; return
    fi
    # Fall back to plain out/ layout
    _r=$(printf '%s' "${_dir}" | sed 's|/out/vs/code/browser/workbench$||')
    printf '%s\n' "${_r}"
}

# =============================================================================
#  PATH RESOLUTION — given a candidate ROOT, resolve WORKBENCH_DIR, JS, and
#  VSCE_SIGN by probing both supported layouts.
# =============================================================================

_set_paths() {
    # $1 = ROOT
    ROOT="$1"

    # Detect workbench layout
    if [ -d "${ROOT}/lib/vscode/out/vs/code/browser/workbench" ]; then
        WORKBENCH_DIR="${ROOT}/lib/vscode/out/vs/code/browser/workbench"
    elif [ -d "${ROOT}/out/vs/code/browser/workbench" ]; then
        WORKBENCH_DIR="${ROOT}/out/vs/code/browser/workbench"
    else
        WORKBENCH_DIR="${ROOT}/out/vs/code/browser/workbench"   # validated later
    fi

    JS="${WORKBENCH_DIR}/workbench.js"
    HTML="${WORKBENCH_DIR}/workbench.html"
    REVERT_PATCH="${WORKBENCH_DIR}/.${PATCH_MARKER}.patch"

    # Probe vsce-sign in order of preference.
    # "npm"     = dedicated package file, patched with unified diff
    # "bundled" = sign logic inlined into a large bundled JS, patched with sed
    VSCE_SIGN=""
    VSCE_SIGN_TYPE=""
    for _candidate_type_pair in \
        "npm:${ROOT}/lib/vscode/node_modules/@vscode/vsce-sign/src/main.js" \
        "npm:${ROOT}/node_modules/@vscode/vsce-sign/src/main.js" \
        "bundled:${ROOT}/lib/vscode/out/server-main.js" \
        "bundled:${ROOT}/out/node/main.js"
    do
        _t="${_candidate_type_pair%%:*}"
        _f="${_candidate_type_pair#*:}"
        if [ -f "${_f}" ]; then
            VSCE_SIGN="${_f}"
            VSCE_SIGN_TYPE="${_t}"
            break
        fi
    done
}

# =============================================================================
#  BROAD FILESYSTEM SEARCH — used by both auto-detect and the `search` command
# =============================================================================

search_filesystem() {
    _result=""
    for _root in \
        "${HOME}" \
        "/data/data/com.termux/files/home" \
        "/data/user/0/com.termux/files/home" \
        "/storage/emulated/0" \
        "/sdcard" \
        "/usr" \
        "/opt" \
        "/usr/local"
    do
        [ -d "${_root}" ] || continue
        _found=$(find "${_root}" \
            -maxdepth 12 \
            -name "workbench.html" \
            -path "*/vs/code/browser/workbench/workbench.html" \
            2>/dev/null | head -5 || true)
        if [ -n "${_found}" ]; then
            _result="${_found}"
            break
        fi
    done
    printf '%s\n' "${_result}"
}

# =============================================================================
#  AUTO-DETECT INSTALLATION
#
#  Tries in order:
#   1. Explicit path argument
#   2. code/code-insiders --version → commit-id → known path
#   3. Static well-known paths (including Termux-specific and release-standalone)
#   4. Glob ~/.vscode/cli/serve-web/* and ~/.config/code-server/*
#   5. code-server binary → adjacent lib dir
#   6. Broad find across home + common roots
# =============================================================================

find_workbench() {
    ROOT=""

    # ── 1. Explicit path ──────────────────────────────────────────────────────
    if [ $# -gt 0 ]; then
        if [ -d "$1" ]; then
            ROOT=$(realpath "$1")
            msg "Using provided path: ${ROOT}"
        else
            die "Path does not exist: $1"
        fi
    fi

    # ── 2. code/code-insiders --version → commit hash ─────────────────────────
    if [ -z "${ROOT}" ]; then
        for _bin in code code-insiders; do
            if command -v "${_bin}" >/dev/null 2>&1; then
                _commit=$( "${_bin}" --version 2>/dev/null \
                    | grep -Eo '[0-9a-f]{40}' | head -1 || true )
                if [ -n "${_commit}" ]; then
                    case "${_bin}" in
                        *insiders*) _base="${HOME}/.vscode-insiders/cli/serve-web" ;;
                        *)          _base="${HOME}/.vscode/cli/serve-web" ;;
                    esac
                    for _suf in "/server" ""; do
                        _c="${_base}/${_commit}${_suf}"
                        for _wb_rel in \
                            "lib/vscode/out/vs/code/browser/workbench/workbench.html" \
                            "out/vs/code/browser/workbench/workbench.html"
                        do
                            if [ -f "${_c}/${_wb_rel}" ]; then
                                ROOT="${_c}"; break 3
                            fi
                        done
                    done
                fi
            fi
        done
        [ -n "${ROOT}" ] && msg "Found via 'code --version'"
    fi

    # ── 3. Static well-known paths ─────────────────────────────────────────────
    if [ -z "${ROOT}" ]; then
        for _c in \
            "${HOME}/.local/share/code-server/code-server/release-standalone" \
            "${HOME}/.local/share/code-server" \
            "${HOME}/.config/code-server" \
            "${HOME}/.vscode-server" \
            "${HOME}/.vscode-server-insiders" \
            "/usr/lib/code-server" \
            "/usr/local/lib/code-server" \
            "/opt/code-server" \
            "/data/data/com.termux/files/usr/lib/code-server" \
            "/data/data/com.termux/files/home/.local/share/code-server"
        do
            for _wb_rel in \
                "lib/vscode/out/vs/code/browser/workbench/workbench.html" \
                "out/vs/code/browser/workbench/workbench.html"
            do
                if [ -f "${_c}/${_wb_rel}" ]; then
                    ROOT="${_c}"; break 2
                fi
            done
        done
        [ -n "${ROOT}" ] && msg "Found at static path: ${ROOT}"
    fi

    # ── 4. Glob serve-web and code-server config dirs ─────────────────────────
    if [ -z "${ROOT}" ]; then
        for _base in \
            "${HOME}/.vscode/cli/serve-web" \
            "${HOME}/.vscode-insiders/cli/serve-web" \
            "${HOME}/.config/code-server/versions"
        do
            [ -d "${_base}" ] || continue
            _found=$(find "${_base}" -maxdepth 7 \
                -name "workbench.html" \
                -path "*/vs/code/browser/workbench/*" \
                2>/dev/null | sort -r | head -1 || true)
            if [ -n "${_found}" ]; then
                ROOT=$(html_to_root "${_found}")
                msg "Found via glob in ${_base}"
                break
            fi
        done
    fi

    # ── 5. code-server binary → lib dir ───────────────────────────────────────
    if [ -z "${ROOT}" ]; then
        if command -v code-server >/dev/null 2>&1; then
            _bin_dir=$(dirname "$(command -v code-server)")
            for _c in \
                "$(dirname "${_bin_dir}")" \
                "${_bin_dir}/../lib/code-server" \
                "${_bin_dir}/../../lib/node_modules/code-server"
            do
                _c=$(realpath "${_c}" 2>/dev/null || true)
                for _wb_rel in \
                    "lib/vscode/out/vs/code/browser/workbench/workbench.html" \
                    "out/vs/code/browser/workbench/workbench.html"
                do
                    if [ -f "${_c}/${_wb_rel}" ]; then
                        ROOT="${_c}"; break 2
                    fi
                done
            done
            [ -n "${ROOT}" ] && msg "Found via code-server binary"
        fi
    fi

    # ── 6. Broad filesystem search ─────────────────────────────────────────────
    if [ -z "${ROOT}" ]; then
        msg "Auto-detect failed — running broad filesystem search (may take a moment)..."
        _found=$(search_filesystem)
        if [ -n "${_found}" ]; then
            _first=$(printf '%s\n' "${_found}" | head -1)
            ROOT=$(html_to_root "${_first}")
            msg "Found via filesystem search: ${ROOT}"
        fi
    fi

    # ── Give up ────────────────────────────────────────────────────────────────
    if [ -z "${ROOT}" ]; then
        die "Cannot find VS Code / code-server installation.

Run the search command to find it:
  sh ${PROGRAM} search

Then pass the path explicitly:
  sh ${PROGRAM} patch /path/to/installation"
    fi

    _set_paths "${ROOT}"

    [ -f "${JS}"   ] || die "workbench.js not found in ${WORKBENCH_DIR}"
    [ -f "${HTML}" ] || die "workbench.html not found in ${WORKBENCH_DIR}"
}

# =============================================================================
#  SEARCH COMMAND — finds all VS Code installations and prints the patch command
# =============================================================================

cmd_search() {
    printf "\n${BLD}Searching for VS Code / code-server installations...${RST}\n\n" >&2

    _found=0

    _show() {
        _html="$1"
        _root=$(html_to_root "${_html}")
        _js=$(dirname "${_html}")/workbench.js
        [ -f "${_js}" ] || return
        printf "${GRN}Found:${RST} %s\n" "${_root}"
        printf "  Workbench: %s\n" "$(dirname "${_html}")"
        _pkg="${_root}/package.json"
        if [ ! -f "${_pkg}" ]; then
            _pkg="${_root}/lib/vscode/package.json"
        fi
        if [ -f "${_pkg}" ]; then
            _ver=$(grep -m1 '"version"' "${_pkg}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || true)
            [ -n "${_ver}" ] && printf "  Version:   %s\n" "${_ver}"
        fi
        printf "  ${BLD}Patch with:${RST}  sh %s patch %s\n\n" "${PROGRAM}" "${_root}"
        _found=$((_found + 1))
    }

    for _search_root in \
        "${HOME}" \
        "/data/data/com.termux/files/home" \
        "/data/user/0/com.termux/files/home" \
        "/usr" \
        "/opt" \
        "/usr/local"
    do
        [ -d "${_search_root}" ] || continue
        find "${_search_root}" \
            -maxdepth 14 \
            -name "workbench.html" \
            -path "*/vs/code/browser/workbench/workbench.html" \
            2>/dev/null | while IFS= read -r _html; do
            _show "${_html}"
        done
    done

    if [ "${_found}" -eq 0 ]; then
        printf "${YLW}No installations found.${RST}\n\n"
        printf "Is code-server or VS Code CLI ('code serve-web') installed?\n"
        printf "If installed in an unusual location, pass the path directly:\n"
        printf "  sh %s patch /path/to/installation\n\n" "${PROGRAM}"
    fi
}

# =============================================================================
#  HELPERS
# =============================================================================

# Hard fail if pattern not found after sed
verify_sed() {
    if grep -qE "$2" "$3" 2>/dev/null; then
        ok "$1"
    else
        die "Verification failed: $1
Pattern not matched: $2
The minified source layout may have changed. Revert and check the VS Code version."
    fi
}

# Soft fail — warn and continue if pattern not found (version-dependent patches)
soft_sed_verify() {
    if grep -qE "$2" "$3" 2>/dev/null; then
        ok "$1"
        return 0
    else
        warn "$1 — not found in this build (skipping)"
        return 1
    fi
}

# =============================================================================
#  ASK FUNCTION — interactive patch configuration
#
#  Prompts the user with a Y/n question.
#  Usage:   _yn "description" DEFAULT_FLAG_VAR
#  Returns: sets the named variable to 1 (yes) or 0 (no)
# =============================================================================

_yn() {
    # $1 = label   $2 = default (1=yes, 0=no)
    _default="${2:-1}"
    if [ "${_default}" -eq 1 ]; then
        _hint="[Y/n]"
    else
        _hint="[y/N]"
    fi
    printf "  ${BLD}%-52s${RST} %s: " "$1" "${_hint}"
    IFS= read -r _input </dev/tty || _input=""
    case "${_input}" in
        [Nn]*)  printf '%s\n' "0" ;;
        [Yy]*)  printf '%s\n' "1" ;;
        "")     printf '%s\n' "${_default}" ;;
        *)      printf '%s\n' "${_default}" ;;
    esac
}

ask_patches() {
    printf "\n${BLD}Configure which patches to apply:${RST}\n"
    printf "${CYN}(Press Enter to accept default shown in brackets)${RST}\n\n"

    APPLY_JS1=$(_yn "JS-1  Fix keyboard popup on scroll"       1)
    APPLY_JS2=$(_yn "JS-2  Fix context menus on Android"       1)
    APPLY_JS3=$(_yn "JS-3  keyboard.dispatch = keyCode"        1)
    APPLY_JS4=$(_yn "JS-4  actionWidget touch dismiss"         1)
    APPLY_JS5=$(_yn "JS-5  onDidLayoutChange guard"            1)
    APPLY_JS6=$(_yn "JS-6  Force experimentalEditContext=false" 1)
    APPLY_SIGN=$(_yn "SIGN  vsce-sign bypass (arm64 only)"     1)

    printf "\n${BLD}Selected patches:${RST}\n"
    for _p in JS1 JS2 JS3 JS4 JS5 JS6 SIGN; do
        eval "_v=\${APPLY_${_p}}"
        if [ "${_v}" -eq 1 ]; then
            printf "  ${GRN}[+]${RST} %s\n" "${_p}"
        else
            printf "  ${YLW}[-]${RST} %s  (skipped)\n" "${_p}"
        fi
    done
    printf "\n"
}

# =============================================================================
#  PATCH COMMAND
# =============================================================================

cmd_patch() {
    # ── Parse flags ───────────────────────────────────────────────────────────
    _skip_ask=0
    _args=""
    for _a in "$@"; do
        case "${_a}" in
            --yes|-y|-Y) _skip_ask=1 ;;
            *) _args="${_args} ${_a}" ;;
        esac
    done
    # shellcheck disable=SC2086
    set -- ${_args}
    find_workbench "$@"

    # ── Already patched? ──────────────────────────────────────────────────────
    if [ -f "${REVERT_PATCH}" ]; then
        warn "Already patched (${REVERT_PATCH} exists)."
        warn "Run 'revert' first, then re-patch."
        exit 1
    fi

    # ── Interactive patch selection (skip if --yes or non-tty) ───────────────
    if [ "${_skip_ask}" -eq 0 ] && [ -t 0 ]; then
        ask_patches
    else
        APPLY_JS1=1; APPLY_JS2=1; APPLY_JS3=1; APPLY_JS4=1
        APPLY_JS5=1; APPLY_JS6=1; APPLY_SIGN=1
        [ "${_skip_ask}" -eq 1 ] && msg "Non-interactive mode (--yes): all patches enabled"
    fi

    printf "\n${BLD}Installation :${RST} %s\n" "${ROOT}"
    printf "${BLD}Workbench JS :${RST} %s\n\n" "${JS}"

    # ── Make backups ──────────────────────────────────────────────────────────
    cp "${JS}" "${JS}.origin"

    # ── Cleanup trap ──────────────────────────────────────────────────────────
    trap '
        printf "\n[ERROR] Patch failed — restoring original\n" >&2
        cp "${JS}.origin" "${JS}" 2>/dev/null || true
        rm -f "${JS}.origin"
        exit 1
    ' EXIT
    trap '
        printf "\r[interrupted] Restoring original\n" >&2
        cp "${JS}.origin" "${JS}" 2>/dev/null || true
        rm -f "${JS}.origin"
        exit 1
    ' HUP INT TERM


    # =========================================================================
    #  JS-1: Fix keyboard popup on scroll
    # =========================================================================
    if [ "${APPLY_JS1}" -eq 1 ]; then
        msg "[JS-1] Keyboard popup on scroll..."
        EventType=$(grep -Eo '\([^ ]\.type===[^ ]+\.Change\|\|[^ ]\.type===[^ ]+\.Contextmenu\)' "${JS}" \
            | grep -Eo '[^ =]+\.Contextmenu' | cut -d'.' -f1 || true)
        if [ -z "${EventType}" ]; then
            warn "      EventType variable not detected — skipping JS-1"
        else
            # Step A: tag scroll events
            sed -E -i "s#(;this.[^ ]\\(.,.,.,Math.abs\\(g\\)/f,g>0\\?1:-1,.,Math.abs\\(.\\)/f,p>0\\?1:-1,.\\))#\1,this.eventType=${EventType}.Change#g" "${JS}"
            # Step B: guard preventDefault, clear flag
            sed -E -i "s#(\\[a\\.identifier\\]\\}this.h&&\\()([^ ].preventDefault\\(\\),)#\\1this.eventType!==${EventType}.Change\\&\\&\\2this.eventType=void 0,#g" "${JS}"
            verify_sed "JS-1: keyboard scroll" \
                'this\.eventType=[^ ]+\.Change.*this\.eventType!==[^ ]+\.Change' "${JS}"
        fi
    else
        warn "[JS-1] Skipped"
    fi


    # =========================================================================
    #  JS-2 + JS-3 + JS-5: Context menus, keyboard.dispatch, layout guard
    #  (all require the isAndroid minified variable name)
    # =========================================================================
    if [ "${APPLY_JS2}" -eq 1 ] || [ "${APPLY_JS3}" -eq 1 ] || [ "${APPLY_JS5}" -eq 1 ]; then
        msg "[JS-2/3/5] Detecting isAndroid variable..."
        isAndroid=$(grep -Eo ',[^ ]{1,3}=!!\([^ ]{1,3}&&[^ ]{1,3}\.indexOf\("Android"\)>=0\),' "${JS}" \
            | cut -d= -f1 | sed 's/,//' || true)
        if [ -z "${isAndroid}" ]; then
            warn "      isAndroid variable not detected — skipping JS-2, JS-3, JS-5"
            APPLY_JS2=0; APPLY_JS3=0; APPLY_JS5=0
        else
            msg "      isAndroid = ${isAndroid}"
        fi
    fi

    if [ "${APPLY_JS2}" -eq 1 ]; then
        msg "[JS-2] Context menus..."

        # JS-2a: Don't hide context menu on window resize on Android
        sed -E -i "s^(if\\(this\\.[^ ]\\.canRelayout===!1&&!\\([^ ]+&&[^ ]+\\.pointerEvents\\))(\\))^\1\&\&!${isAndroid}\2^" "${JS}"
        verify_sed "JS-2a: canRelayout" \
            'canRelayout===!1&&!\([^ ]+&&[^ ]+\.pointerEvents\)&&![^ ]+\)' "${JS}"

        # JS-2b: Don't blur context menu on focus loss on Android
        sed -E -i "s^(\\{this\\.\\$&&\\!\\(..&&..\\.pointerEvents\\))(&&this\\.\\$\\.blur\\(\\)\\})^\1\&\&!${isAndroid}\2^" "${JS}"
        verify_sed "JS-2b: blur guard" \
            'pointerEvents\)&&![^ ]+&&this\.' "${JS}"

        # JS-2c: Lock context menu to screen-relative position on Android
        sed -E -i "s/(showContextView\\([^ ],[^ ],[^ ]\\)\\{let [^ ];)(.+)(,this.b.show\\([^ ]\\))/\1${isAndroid}?this.b.setContainer(this.c.activeContainer,1):(\2)\3/" "${JS}"
        verify_sed "JS-2c: context menu position" \
            'activeContainer,1\):\(' "${JS}"
    else
        warn "[JS-2] Skipped"
    fi

    if [ "${APPLY_JS3}" -eq 1 ]; then
        msg "[JS-3] keyboard.dispatch = keyCode on Android..."
        sed -E -i "s^(,properties:\\{\"keyboard\\.dispatch\":\\{scope:1,type:\"string\",enum:\\[\"code\",\"keyCode\"\\],default:)(\"code\")^\1${isAndroid}?\"keyCode\":\"code\"^" "${JS}"
        verify_sed "JS-3: keyboard.dispatch" \
            '"keyCode"\],default:[^ ]+\?"keyCode":"code"' "${JS}"
    else
        warn "[JS-3] Skipped"
    fi

    if [ "${APPLY_JS5}" -eq 1 ]; then
        msg "[JS-5] onDidLayoutChange guard..."
        sed -E -i "s^(,)(this\\.\\w\\(this\\.a\\.onDidLayoutChange\\(\\(\\)=>this\\.\\w\\.hide\\(\\)\\)\\)\\})^\1${isAndroid}||\2^g" "${JS}"
        verify_sed "JS-5: onDidLayoutChange guard" \
            '\|\|this\.[^ ]\(this\.a\.onDidLayoutChange' "${JS}"
    else
        warn "[JS-5] Skipped"
    fi


    # =========================================================================
    #  JS-4: actionWidget pointerBlock — add touchstart/touchmove
    # =========================================================================
    if [ "${APPLY_JS4}" -eq 1 ]; then
        msg "[JS-4] actionWidget touch events..."
        sed -E -i 's^(,.\.add\(\w\(\w,)(..\.MOUSE_DOWN)(,\(\)=>.\.remove\(\)\)\))(;)^\1\2\3\1"touchstart"\3\1"touchmove"\3\4^g' "${JS}"
        verify_sed "JS-4: actionWidget touch" \
            '"touchstart".*"touchmove"' "${JS}"
    else
        warn "[JS-4] Skipped"
    fi


    # =========================================================================
    #  JS-6: experimentalEditContextEnabled = false
    # =========================================================================
    if [ "${APPLY_JS6}" -eq 1 ]; then
        msg "[JS-6] experimentalEditContextEnabled=false..."
        if grep -qF '"editor.experimentalEditContextEnabled"' "${JS}" 2>/dev/null; then
            sed -E -i 's/("editor\.experimentalEditContextEnabled"[^}]*"default"\s*:\s*)(!0|true)/\1!1/g' "${JS}"
            sed -E -i 's/("editor\.experimentalEditContextEnabled"\s*:\s*\{[^}]*default\s*:\s*)(!0|true)/\1!1/g' "${JS}"
            verify_sed "JS-6: editContextEnabled=false" \
                '"editor\.experimentalEditContextEnabled"' "${JS}"
            ok "JS-6: experimentalEditContextEnabled forced to false"
        else
            warn "JS-6: editor.experimentalEditContextEnabled not in this build (too old or already removed)"
        fi
    else
        warn "[JS-6] Skipped"
    fi


    # =========================================================================
    #  SIGN: vsce-sign bypass (optional)
    #
    #  Two strategies depending on what was found:
    #    npm     — dedicated src/main.js, apply unified diff with `patch`
    #    bundled — logic inlined into server-main.js / out/node/main.js,
    #              use python3 regex substitution (minified single-line)
    # =========================================================================
    if [ "${APPLY_SIGN}" -eq 1 ]; then
        if [ -z "${VSCE_SIGN}" ]; then
            warn "SIGN: no sign file found under ${ROOT} — skipping"
        elif [ "${VSCE_SIGN_TYPE}" = "npm" ]; then
            msg "[SIGN] vsce-sign bypass (npm package: $(basename "${VSCE_SIGN}"))..."
            if printf '%s\n' "${VSCE_PATCH}" | patch -u "${VSCE_SIGN}" 2>/dev/null; then
                ok "SIGN: vsce-sign patched"
            else
                warn "SIGN: patch failed (already patched or version mismatch) — skipping"
            fi
        else
            # bundled: verify() is a class method minified into server-main.js.
            # Shape (from server-main.js inspection):
            #   async verify(t,s,i,n,r){let o;try{o=await this.d()}catch...
            # Strategy: inject an early return right after the opening brace.
            # We do NOT try to replace the whole body — too fragile in minified JS.
            # The injected return short-circuits everything; dead code is left in place.
            msg "[SIGN] vsce-sign bypass (bundled: ${VSCE_SIGN})..."
            if grep -qE "vsce-sign|ExtensionSignatureVerif|signaturearchive" "${VSCE_SIGN}" 2>/dev/null; then
                cp "${VSCE_SIGN}" "${VSCE_SIGN}.origin"
                python3 - "${VSCE_SIGN}" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='replace').read()

STUB = 'return{code:void 0,didExecute:!1,output:""};'

# Already patched?
if STUB in src:
    sys.exit(0)

# Pattern: async verify(<5 short params>){  followed by  let <x>;try{
# The lookahead anchors us to the real method without consuming content we'd lose.
patched = re.sub(
    r'(async verify\(\w[\w$]*,\w[\w$]*,\w[\w$]*,\w[\w$]*,\w[\w$]*\)\{)(?=let \w)',
    r'\1' + STUB,
    src
)

# Fallback A: 3-param variant (older/different build shape)
if patched == src:
    patched = re.sub(
        r'(async verify\(\w[\w$]*,\w[\w$]*,\w[\w$]*\)\{)(?=let \w)',
        r'\1' + STUB,
        src
    )

# Fallback B: any param count, anchored by the dynamic-import load pattern
if patched == src:
    patched = re.sub(
        r'(async verify\([^)]{0,40}\)\{)(?=\w[\w$]*;try\{\w[\w$]*=await this\.\w[\w$]*\(\))',
        r'\1' + STUB,
        src
    )

open(path, 'w', encoding='utf-8').write(patched)
PYEOF
                if grep -qF 'return{code:void 0,didExecute:!1,output:""};' "${VSCE_SIGN}" 2>/dev/null; then
                    ok "SIGN: bundled vsce-sign patched"
                else
                    warn "SIGN: python substitution found no match — restoring original"
                    cp "${VSCE_SIGN}.origin" "${VSCE_SIGN}"
                fi
            else
                warn "SIGN: sign pattern not found in ${VSCE_SIGN} — skipping"
            fi
        fi
    else
        warn "[SIGN] Skipped"
    fi


    # ── Generate revert patch ─────────────────────────────────────────────────
    msg "Generating revert patch..."
    (
        cd "${WORKBENCH_DIR}"
        diff -u "workbench.js.origin" "workbench.js" > "${REVERT_PATCH}" || true
    )
    # Include bundled sign file in the revert patch if we patched it
    if [ "${APPLY_SIGN}" -eq 1 ] && [ "${VSCE_SIGN_TYPE}" = "bundled" ] \
       && [ -f "${VSCE_SIGN}.origin" ]; then
        diff -u "${VSCE_SIGN}.origin" "${VSCE_SIGN}" >> "${REVERT_PATCH}" || true
        rm -f "${VSCE_SIGN}.origin"
    fi
    [ -s "${REVERT_PATCH}" ] || warn "Revert patch is empty — no diffs found?"

    rm -f "${JS}.origin"

    trap - EXIT HUP INT TERM

    printf "\n${GRN}${BLD}Done! All selected patches applied.${RST}\n\n"
    printf "  Restart code-server / 'code serve-web', then refresh Chrome.\n\n"
    printf "  Revert:  sh %s revert %s\n\n" "${PROGRAM}" "${ROOT}"
}

# =============================================================================
#  REVERT COMMAND
# =============================================================================

cmd_revert() {
    find_workbench "$@"

    if [ ! -f "${REVERT_PATCH}" ]; then
        warn "No revert patch found in ${WORKBENCH_DIR}"
        exit 0
    fi

    msg "Reverting patches..."
    # The revert patch covers workbench.js and (if bundled) the sign file.
    # For npm-package sign files, revert with `patch -R` on the original hunk.
    ( cd "${WORKBENCH_DIR}" && patch -up0 -R < "${REVERT_PATCH}" )

    if [ "${VSCE_SIGN_TYPE}" = "npm" ] && [ -f "${VSCE_SIGN}" ]; then
        printf '%s\n' "${VSCE_PATCH}" | patch -uR "${VSCE_SIGN}" 2>/dev/null \
            || warn "vsce-sign revert failed (may not have been patched)"
    fi
    # bundled sign revert is handled by the unified diff already applied above.

    rm -f "${REVERT_PATCH}"
    ok "Reverted. Restart code-server and refresh browser."
}

# =============================================================================
#  STATUS COMMAND
# =============================================================================

cmd_status() {
    find_workbench "$@"

    printf "\n${BLD}Installation :${RST} %s\n" "${ROOT}"
    printf "${BLD}Workbench    :${RST} %s\n" "${WORKBENCH_DIR}"
    printf "${BLD}Layout       :${RST} %s\n\n" \
        "$(printf '%s' "${WORKBENCH_DIR}" | grep -q 'lib/vscode' && printf 'lib/vscode (release-standalone)' || printf 'out/ (serve-web)')"

    if [ -f "${REVERT_PATCH}" ]; then
        printf "${GRN}${BLD}Status: PATCHED${RST}\n\n"
    else
        printf "${YLW}${BLD}Status: NOT PATCHED${RST}\n\n"
    fi

    chk() {
        if grep -qE "$2" "$3" 2>/dev/null; then
            printf "  ${GRN}[+]${RST} %s\n" "$1"
        else
            printf "  ${YLW}[-]${RST} %s\n" "$1"
        fi
    }

    printf "${BLD}workbench.js patches:${RST}\n"
    chk "JS-1  keyboard scroll fix"         'this\.eventType=[^ ]+\.Change'                         "${JS}"
    chk "JS-2a context menu canRelayout"    'canRelayout===!1&&!\([^ ]+&&[^ ]+\.pointerEvents\)&&!' "${JS}"
    chk "JS-2b context menu blur guard"     'pointerEvents\)&&![^ ]+&&this\.'                       "${JS}"
    chk "JS-2c context menu stable pos"     'activeContainer,1\):\('                                "${JS}"
    chk "JS-3  keyboard.dispatch=keyCode"   '"keyCode"\],default:[^ ]+\?"keyCode":"code"'           "${JS}"
    chk "JS-4  actionWidget touch dismiss"  '"touchstart".*"touchmove"'                             "${JS}"
    chk "JS-5  onDidLayoutChange guard"     '\|\|this\.[^ ]\(this\.a\.onDidLayoutChange'            "${JS}"
    chk "JS-6  editContextEnabled=false"    'experimentalEditContextEnabled'                        "${JS}"

    if [ -n "${VSCE_SIGN}" ]; then
        printf "\n${BLD}optional (%s):${RST}\n" "${VSCE_SIGN_TYPE}"
        chk "SIGN  vsce-sign bypass" 'return\{code:void 0,didExecute:!1\|ExtensionSignatureVerificationResult\(ReturnCode' "${VSCE_SIGN}"
        printf "       %s\n" "${VSCE_SIGN}"
    else
        printf "\n${YLW}[ -- ]${RST} SIGN: no sign file found under %s\n" "${ROOT}"
    fi
    printf "\n"
}

# =============================================================================
#  HELP
# =============================================================================

cmd_help() {
    printf "${BLD}cs-mobile-patch.sh v6${RST} — Patch VS Code / code-server for Android

${BLD}USAGE:${RST}
  sh cs-mobile-patch.sh ${BLD}search${RST}                    Find all installations
  sh cs-mobile-patch.sh ${BLD}patch${RST}  [--yes] [DIR]     Apply patches (interactive)
  sh cs-mobile-patch.sh ${BLD}revert${RST} [DIR]             Undo all patches
  sh cs-mobile-patch.sh ${BLD}status${RST} [DIR]             Check patch state

  --yes / -y    Skip interactive prompt, apply all patches automatically.
  If auto-detect fails, run 'search' first — it prints the exact command.

${BLD}QUICK START:${RST}
  sh cs-mobile-patch.sh search             # find installation
  sh cs-mobile-patch.sh patch /path        # select patches interactively
  sh cs-mobile-patch.sh patch --yes /path  # apply all without prompting

${BLD}PATCHES (v6 — JS only):${RST}
  JS-1   Keyboard popup on scroll         (EventType guard in touchmove handler)
  JS-2   Context menus on Android         (3 sites: canRelayout, blur, position)
  JS-3   keyboard.dispatch = keyCode      (Gboard / Android IME compatibility)
  JS-4   actionWidget touch dismiss       (touchstart+touchmove on pointerBlock)
  JS-5   onDidLayoutChange guard          (action menu stays open on keyboard open)
  JS-6   experimentalEditContextEnabled   (CRITICAL: force false for Insiders/new Stable)
  SIGN   vsce-sign bypass                 (extension install on arm64 Android)

${BLD}SUPPORTED LAYOUTS:${RST}
  Layout A  <ROOT>/out/vs/code/browser/workbench/       (VS Code CLI serve-web)
  Layout B  <ROOT>/lib/vscode/out/vs/code/browser/workbench/  (release-standalone)

${BLD}KNOWN PATHS (auto-detected):${RST}
  ~/.local/share/code-server/code-server/release-standalone
  ~/.local/share/code-server
  ~/.config/code-server
  ~/.vscode/cli/serve-web/<commit>/
  /usr/lib/code-server  |  /usr/local/lib/code-server  |  /opt/code-server
  /data/data/com.termux/files/usr/lib/code-server

${BLD}NEW IN v6 vs v5:${RST}
  + Interactive ask function — select patches before applying
  + Dual layout support (lib/vscode/out/ + out/) auto-detected
  + Added release-standalone path to known paths
  + HTML patches removed (HTML-1 viewport, HTML-2 palette, HTML-3 CSS, HTML-4 JS)
  + Only workbench.js is modified; revert patch covers JS only
  + --yes/-y flag for fully non-interactive use

${BLD}REQUIREMENTS:${RST}
  sh  sed  awk  diff  patch  grep  (all pre-installed in Termux and Ubuntu)

${BLD}EXAMPLES:${RST}
  sh cs-mobile-patch.sh search
  sh cs-mobile-patch.sh patch
  sh cs-mobile-patch.sh patch --yes
  sh cs-mobile-patch.sh patch ~/.local/share/code-server/code-server/release-standalone
  sh cs-mobile-patch.sh status
  sh cs-mobile-patch.sh revert
"
}

# =============================================================================
#  ENTRY POINT
# =============================================================================

case "${1:-help}" in
    patch)          shift; cmd_patch  "$@" ;;
    revert)         shift; cmd_revert "$@" ;;
    status)         shift; cmd_status "$@" ;;
    search|find)    cmd_search ;;
    help|-h|--help) cmd_help ;;
    *) printf "Unknown command: %s\nRun: sh %s help\n" "$1" "${PROGRAM}" >&2; exit 1 ;;
esac
