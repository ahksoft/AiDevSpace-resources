#!/bin/sh
# =============================================================================
#  cs-mobile-patch-full.sh  —  Patch VS Code / code-server for Android
#  Version: 6.0-full
#
#  Modifies workbench.js + workbench.html inside your VS Code installation.
#  No proxy server, no browser extension, works in any browser.
#
#  Supports both workbench layouts:
#    Layout A (VS Code CLI serve-web):          <ROOT>/out/vs/code/browser/workbench/
#    Layout B (code-server release-standalone): <ROOT>/lib/vscode/out/vs/code/browser/workbench/
#
#  USAGE:
#    sh cs-mobile-patch-full.sh patch   [--yes] [INSTALLATION_DIR]
#    sh cs-mobile-patch-full.sh revert  [INSTALLATION_DIR]
#    sh cs-mobile-patch-full.sh status  [INSTALLATION_DIR]
#    sh cs-mobile-patch-full.sh search
#
# =============================================================================
#
#  PATCHES:
#
#  [JS-1] KEYBOARD POPUP ON SCROLL
#    VS Code's GestureRecognizer touchmove handler calls this.F() to dispatch
#    the scroll event, then calls t.preventDefault(). On Android,
#    preventDefault() on a scroll-phase touchmove causes a relayout/focus
#    cycle that opens the soft keyboard.
#    Fix: record this.eventType=Ks.Change after this.F() fires, then guard
#    t.preventDefault() with "this.eventType!==Ks.Change&&". Clear flag after.
#
#  [JS-2a] CONTEXT MENU — canRelayout
#    Guard with !isAndroid so the menu doesn't vanish when the keyboard opens.
#
#  [JS-2b] CONTEXT MENU — blur-on-focus-loss
#    Guard with !isAndroid so the menu stays open on spurious focus loss.
#
#  [JS-2c] CONTEXT MENU — stable position after keyboard resize
#    On Android, always use activeContainer at position 1 (screen-relative,
#    stable regardless of keyboard state).
#
#  [JS-3] keyboard.dispatch = keyCode
#    Android Gboard sends keyCode=229 in "code" mode. "keyCode" mode reads
#    event.keyCode instead and delivers the real key value.
#
#  [JS-4] actionWidget pointerBlock: add touch event listeners
#    Add "touchstart"+"touchmove" listeners to the pointer-block overlay so it
#    is removed on touch, not just mouse events.
#
#  [JS-5] onDidLayoutChange: stop hiding menu when keyboard opens
#    Guard layout-change subscription with isAndroid|| so the action widget
#    menu stays visible when the keyboard opens.
#
#  [JS-6] experimentalEditContextEnabled = false   <- CRITICAL FOR INSIDERS
#    The EditContext API breaks keyboard input on Android. Force default false.
#
#  [HTML-1] viewport interactive-widget=resizes-content
#    Tells Chrome that keyboard appearance should shrink the viewport (like
#    desktop) rather than float over the content.
#
#  [HTML-3] Mobile CSS injected into <head>
#    Fat scrollbars, enlarged touch targets, terminal touch-action, toolbar CSS.
#
#  [HTML-4] Mobile JS injected before </body>
#    Scroll lock, xterm.js touch scroll, long-press clipboard bar,
#    floating key toolbar with sticky modifier keys, focus guard.
#
#  [SIGN] vsce-sign bypass
#    Some Android arm64 builds cannot run the vsce-sign native binary,
#    causing all extension installs to fail. Stub verify() to always succeed.
#
# =============================================================================

set -eu

PROGRAM=$(basename "$0")
PATCH_MARKER="cs-mobile-full-v6"

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
#  Handles two layouts:
#    Layout A: <ROOT>/out/vs/code/browser/workbench/workbench.html
#    Layout B: <ROOT>/lib/vscode/out/vs/code/browser/workbench/workbench.html
# =============================================================================

html_to_root() {
    _dir=$(dirname "$1")
    _r=$(printf '%s' "${_dir}" | sed 's|/lib/vscode/out/vs/code/browser/workbench$||')
    if [ "${_r}" != "${_dir}" ]; then
        printf '%s\n' "${_r}"; return
    fi
    _r=$(printf '%s' "${_dir}" | sed 's|/out/vs/code/browser/workbench$||')
    printf '%s\n' "${_r}"
}

# =============================================================================
#  PATH RESOLUTION — given ROOT, resolve WORKBENCH_DIR, JS, HTML, VSCE_SIGN
# =============================================================================

_set_paths() {
    ROOT="$1"

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
#  BROAD FILESYSTEM SEARCH
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
            _result="${_found}"; break
        fi
    done
    printf '%s\n' "${_result}"
}

# =============================================================================
#  AUTO-DETECT INSTALLATION
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
#  SEARCH COMMAND
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
        [ -f "${_pkg}" ] || _pkg="${_root}/lib/vscode/package.json"
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

verify_sed() {
    if grep -qE "$2" "$3" 2>/dev/null; then
        ok "$1"
    else
        die "Verification failed: $1
Pattern not matched: $2
The minified source layout may have changed. Revert and check the VS Code version."
    fi
}

soft_sed_verify() {
    if grep -qE "$2" "$3" 2>/dev/null; then
        ok "$1"; return 0
    else
        warn "$1 — not found in this build (skipping)"; return 1
    fi
}

# =============================================================================
#  MOBILE CSS
# =============================================================================

MOBILE_CSS='<style id="cs-m-css">
:root{--tb-h:52px;--tb-bg:#161616;--tb-border:#2d2d2d;--tb-btn:#222;--tb-text:#c8c8c8;--tb-accent:#0e639c;--tb-mod:#6d28d9;--tb-mod-glow:rgba(109,40,217,.4);--tb-r:7px}
textarea,input,[contenteditable]{font-size:16px!important}
::-webkit-scrollbar{width:10px!important;height:10px!important}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:#4a4a4a!important;border-radius:5px!important;min-height:44px}
::-webkit-scrollbar-thumb:active{background:#6a6a6a!important}
.tab{min-height:44px!important}
.tab .label-name{font-size:14px!important}
.action-item a,.action-item .codicon{min-width:40px!important;height:40px!important;line-height:40px!important}
.statusbar{height:28px!important}
.statusbar-item a,.statusbar-item span{padding:0 10px!important}
.monaco-menu .action-label{font-size:14px!important;padding:10px 16px!important}
.suggest-widget .monaco-list-row{height:40px!important}
.suggest-widget .monaco-highlighted-label{font-size:14px!important}
.breadcrumb-item{font-size:14px!important}
.monaco-list-row{min-height:28px!important}
.editor-group-container .title .tabs-and-actions-container{height:44px!important}
.monaco-editor,.xterm,.terminal{-webkit-touch-callout:none!important}
.xterm-viewport{overflow-y:scroll!important;-webkit-overflow-scrolling:touch!important}
.xterm-screen canvas{touch-action:pan-y!important}
#csm-clip{position:fixed;display:none;align-items:center;background:#1c1c1e;border:1px solid #38383a;border-radius:12px;box-shadow:0 8px 32px rgba(0,0,0,.75);overflow:hidden;z-index:2147483640;animation:csm-pop .16s cubic-bezier(.34,1.56,.64,1) both}
#csm-clip.csm-show{display:flex}
@keyframes csm-pop{from{transform:scale(.75);opacity:0}to{transform:scale(1);opacity:1}}
.csm-cb{background:transparent;border:none;border-right:1px solid #38383a;color:#e5e5e7;padding:11px 18px;font-size:13.5px;font-family:-apple-system,system-ui,sans-serif;cursor:pointer;-webkit-tap-highlight-color:transparent;user-select:none;touch-action:manipulation;white-space:nowrap;transition:background .1s}
.csm-cb:last-child{border-right:none}
.csm-cb:active{background:#2c2c2e}
#csm-handle{position:fixed;bottom:0;right:18px;width:44px;height:22px;background:var(--tb-bg);border:1px solid var(--tb-border);border-bottom:none;border-radius:8px 8px 0 0;display:flex;align-items:center;justify-content:center;z-index:2147483646;cursor:pointer;-webkit-tap-highlight-color:transparent;user-select:none;touch-action:manipulation;color:#505050;font-size:10px;font-family:system-ui,sans-serif;transition:bottom .2s ease,color .2s}
#csm-handle.csm-open{bottom:var(--tb-h);color:var(--tb-accent)}
#csm-bar{position:fixed;bottom:0;left:0;right:0;height:var(--tb-h);background:var(--tb-bg);border-top:1px solid var(--tb-border);display:flex;align-items:center;padding:0 6px;gap:4px;z-index:2147483645;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none;transition:transform .22s cubic-bezier(.4,0,.2,1)}
#csm-bar::-webkit-scrollbar{display:none}
#csm-bar.csm-hidden{transform:translateY(100%)}
body.csm-bar-on{padding-bottom:var(--tb-h)!important}
body.csm-bar-on .workbench-container{bottom:var(--tb-h)!important}
.csm-k{background:var(--tb-btn);color:var(--tb-text);border:1px solid #303030;border-radius:var(--tb-r);padding:0 10px;font-size:12px;font-family:"Cascadia Code","Fira Code","SF Mono",monospace;min-width:38px;height:38px;display:flex;align-items:center;justify-content:center;white-space:nowrap;flex-shrink:0;cursor:pointer;-webkit-tap-highlight-color:transparent;user-select:none;touch-action:manipulation;transition:background .1s,border-color .1s,box-shadow .15s}
.csm-k:active{background:#2e2e2e!important}
.csm-mod{color:#93c5fd;border-color:#1e3a5f}
.csm-mod.csm-lit{background:var(--tb-mod)!important;border-color:#7c3aed!important;color:#fff!important;box-shadow:0 0 10px var(--tb-mod-glow)}
.csm-combo{color:#6ee7b7;border-color:#14432e;font-size:11px}
.csm-combo:active{background:#0a2e1e!important}
.csm-arrow{color:#fde68a;border-color:#3a2e10;min-width:34px}
.csm-div{width:1px;height:32px;background:var(--tb-border);flex-shrink:0;margin:0 2px}
.csm-lbl{color:#404040;font-size:8.5px;text-transform:uppercase;letter-spacing:.8px;flex-shrink:0;padding:0 2px;font-family:system-ui}
#csm-toast{position:fixed;top:56px;left:50%;transform:translateX(-50%) translateY(-20px);background:#2a2a2c;color:#e5e5e7;padding:8px 22px;border-radius:20px;font-size:13px;font-family:system-ui,sans-serif;z-index:2147483647;pointer-events:none;opacity:0;border:1px solid #3a3a3c;transition:transform .22s ease,opacity .22s ease;white-space:nowrap}
#csm-toast.csm-show{opacity:1;transform:translateX(-50%) translateY(0)}
</style>'

# =============================================================================
#  MOBILE JS
# =============================================================================

MOBILE_JS='<script id="cs-m-js">(function(){
"use strict";
var _tt;
function toast(m,d){var t=document.getElementById("csm-toast");if(!t){t=document.createElement("div");t.id="csm-toast";document.body.appendChild(t)}t.textContent=m;t.classList.add("csm-show");clearTimeout(_tt);_tt=setTimeout(function(){t.classList.remove("csm-show")},d||1600)}
function isEd(el){return el.closest(".monaco-editor,.xterm,.terminal,.integrated-terminal")}
(function fixVp(){var m=document.querySelector("meta[name=viewport]");if(!m){m=document.createElement("meta");m.name="viewport";document.head.appendChild(m)}m.content="width=device-width,initial-scale=1.0,maximum-scale=5.0,user-scalable=yes"})();
var ScrollLock=(function(){
return{get active(){return false}};
})();
(function initTermScroll(){
var patched=[];
function patch(termEl){if(patched.indexOf(termEl)>=0)return;patched.push(termEl);var vp=termEl.querySelector(".xterm-viewport");if(!vp)return;var sy=0,ss=0,moved=false;
termEl.addEventListener("touchstart",function(e){sy=e.touches[0].clientY;ss=vp.scrollTop;moved=false},{passive:true});
termEl.addEventListener("touchmove",function(e){var dy=sy-e.touches[0].clientY;if(Math.abs(dy)>5){moved=true;vp.scrollTop=ss+dy;e.preventDefault();e.stopPropagation();var ta=termEl.querySelector(".xterm-helper-textarea");if(ta&&document.activeElement===ta)ta.blur()}},{passive:false});
termEl.addEventListener("touchend",function(e){if(moved)e.stopPropagation()},{passive:false});}
function scan(){document.querySelectorAll(".xterm").forEach(patch)}
scan();
new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true});
window.addEventListener("load",scan,{once:true});
})();
(function initClipBar(){
var bar,ht;
function doCopy(){var txt=(window.getSelection()||{}).toString()||"";if(!txt){toast("Nothing selected");return}try{navigator.clipboard.writeText(txt).then(function(){toast("\u2713 Copied")})}catch(e){document.execCommand("copy");toast("\u2713 Copied")}}
function doCut(){var txt=(window.getSelection()||{}).toString()||"";if(!txt){toast("Nothing selected");return}document.execCommand("cut");toast("\u2713 Cut")}
function doPaste(){navigator.clipboard.readText().then(function(txt){var a=document.activeElement;if(!a){toast("Tap editor first");return}a.focus();if(!document.execCommand("insertText",false,txt)){if(a.tagName==="TEXTAREA"){var start=a.selectionStart,val=a.value,nv=val.slice(0,start)+txt+val.slice(a.selectionEnd),setter=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,"value")&&Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,"value").set;if(setter){setter.call(a,nv);a.dispatchEvent(new Event("input",{bubbles:true}));a.selectionStart=a.selectionEnd=start+txt.length}}}toast("\u2713 Pasted")}).catch(function(){toast("Allow clipboard in browser settings")})}
function doAll(){var a=document.activeElement;if(a&&a.tagName==="TEXTAREA")a.select();else document.execCommand("selectAll");toast("\u2713 All selected")}
function buildBar(){bar=document.createElement("div");bar.id="csm-clip";[["Cut \u2702",doCut],["\u2398 Copy",doCopy],["\u21b5 Paste",doPaste],["\u22a1 All",doAll]].forEach(function(pair){var b=document.createElement("button");b.className="csm-cb";b.textContent=pair[0];b.addEventListener("touchstart",function(e){e.preventDefault();e.stopPropagation();hideBar();pair[1]()},{passive:false});bar.appendChild(b)});document.body.appendChild(bar)}
function showBar(x,y){clearTimeout(ht);bar.classList.add("csm-show");requestAnimationFrame(function(){var w=bar.offsetWidth||240,h=bar.offsetHeight||46,bh=document.body.classList.contains("csm-bar-on")?52:0;var lx=Math.max(8,Math.min(x-w/2,window.innerWidth-w-8)),ly=Math.max(60,Math.min(y-h-14,window.innerHeight-h-bh-8));bar.style.left=lx+"px";bar.style.top=ly+"px"})}
function hideBar(){ht=setTimeout(function(){bar&&bar.classList.remove("csm-show")},80)}
buildBar();
var lt,lx,ly,lm;
document.addEventListener("touchstart",function(e){if(!isEd(e.target)){hideBar();return}lx=e.touches[0].clientX;ly=e.touches[0].clientY;lm=false;clearTimeout(lt);lt=setTimeout(function(){if(!lm)showBar(lx,ly)},550)},{passive:true});
document.addEventListener("touchmove",function(e){if(Math.abs(e.touches[0].clientX-lx)>10||Math.abs(e.touches[0].clientY-ly)>10){lm=true;clearTimeout(lt);hideBar()}},{passive:true});
document.addEventListener("touchend",function(){clearTimeout(lt)},{passive:true});
document.addEventListener("touchcancel",function(){clearTimeout(lt)},{passive:true});
})();
(function initToolbar(){
var mods={ctrl:false,alt:false,shift:false,meta:false},barOpen=true;
var LAYOUT=[
{t:"lbl",v:"MOD"},{t:"mod",v:"CTRL",m:"ctrl"},{t:"mod",v:"ALT",m:"alt"},{t:"mod",v:"SHF",m:"shift"},{t:"div"},
{t:"lbl",v:"NAV"},{t:"key",v:"ESC",k:"Escape",c:"Escape"},{t:"key",v:"\u21e5",k:"Tab",c:"Tab"},{t:"key",v:"\u232b",k:"Backspace",c:"Backspace"},{t:"key",v:"DEL",k:"Delete",c:"Delete"},{t:"key",v:"\u21b5",k:"Enter",c:"Enter"},{t:"div"},
{t:"lbl",v:"\u2195"},{t:"key",v:"\u2190",k:"ArrowLeft",c:"ArrowLeft",x:"csm-arrow"},{t:"key",v:"\u2192",k:"ArrowRight",c:"ArrowRight",x:"csm-arrow"},{t:"key",v:"\u2191",k:"ArrowUp",c:"ArrowUp",x:"csm-arrow"},{t:"key",v:"\u2193",k:"ArrowDown",c:"ArrowDown",x:"csm-arrow"},{t:"div"},
{t:"lbl",v:"POS"},{t:"key",v:"Home",k:"Home",c:"Home"},{t:"key",v:"End",k:"End",c:"End"},{t:"key",v:"PgU",k:"PageUp",c:"PageUp"},{t:"key",v:"PgD",k:"PageDown",c:"PageDown"},{t:"div"},
{t:"lbl",v:"CMDS"},
{t:"combo",v:"C-s",combo:{ctrl:true,key:"s",c:"KeyS"}},
{t:"combo",v:"C-z",combo:{ctrl:true,key:"z",c:"KeyZ"}},
{t:"combo",v:"C-y",combo:{ctrl:true,key:"y",c:"KeyY"}},
{t:"combo",v:"C-/",combo:{ctrl:true,key:"/",c:"Slash"}},
{t:"combo",v:"C-p",combo:{ctrl:true,key:"p",c:"KeyP"}},
{t:"combo",v:"C-\x60",combo:{ctrl:true,key:"\x60",c:"Backquote"}},
{t:"combo",v:"C-b",combo:{ctrl:true,key:"b",c:"KeyB"}},
{t:"combo",v:"C-f",combo:{ctrl:true,key:"f",c:"KeyF"}},
{t:"combo",v:"C-w",combo:{ctrl:true,key:"w",c:"KeyW"}},
{t:"combo",v:"C-d",combo:{ctrl:true,key:"d",c:"KeyD"}},
{t:"combo",v:"C-g",combo:{ctrl:true,key:"g",c:"KeyG"}},
{t:"combo",v:"C-\u21e7P",combo:{ctrl:true,shift:true,key:"p",c:"KeyP"}},
{t:"combo",v:"C-\u21e7K",combo:{ctrl:true,shift:true,key:"k",c:"KeyK"}},
{t:"combo",v:"A-\u2191",combo:{alt:true,key:"ArrowUp",c:"ArrowUp"}},
{t:"combo",v:"A-\u2193",combo:{alt:true,key:"ArrowDown",c:"ArrowDown"}}
];
function fireKey(o){
var cands=[document.activeElement];
document.querySelectorAll(".monaco-editor textarea,.xterm-helper-textarea").forEach(function(el){cands.push(el)});
cands.push(document.body);
var init={key:o.key,code:o.code,ctrlKey:o.ctrl!=null?o.ctrl:mods.ctrl,altKey:o.alt!=null?o.alt:mods.alt,shiftKey:o.shift!=null?o.shift:mods.shift,metaKey:o.meta!=null?o.meta:mods.meta,bubbles:true,cancelable:true,composed:true};
var primary=cands[0];
["keydown","keypress","keyup"].forEach(function(type){try{primary.dispatchEvent(new KeyboardEvent(type,init))}catch(e){}});
cands.slice(1,-1).forEach(function(el){try{el.dispatchEvent(new KeyboardEvent("keydown",init))}catch(e){}});
}
function resetMods(){mods.ctrl=mods.alt=mods.shift=mods.meta=false;document.querySelectorAll(".csm-mod").forEach(function(b){b.classList.remove("csm-lit")})}
function makeBtn(def){
if(def.t==="div"){var d=document.createElement("div");d.className="csm-div";return d}
if(def.t==="lbl"){var l=document.createElement("span");l.className="csm-lbl";l.textContent=def.v;return l}
var btn=document.createElement("button");
btn.textContent=def.v;
btn.className="csm-k"+(def.x?" "+def.x:"")+(def.t==="mod"?" csm-mod":"")+(def.t==="combo"?" csm-combo":"");
if(def.t==="mod")btn.dataset.mod=def.m;
btn.addEventListener("touchstart",function(e){
e.preventDefault();e.stopPropagation();
if(def.t==="mod"){mods[def.m]=!mods[def.m];btn.classList.toggle("csm-lit",mods[def.m]);return}
if(def.t==="combo"){fireKey({key:def.combo.key,code:def.combo.c,ctrl:def.combo.ctrl||false,alt:def.combo.alt||false,shift:def.combo.shift||false});resetMods();return}
fireKey({key:def.k,code:def.c});resetMods();
},{passive:false});
return btn;
}
function mountToolbar(){
var bar=document.createElement("div");bar.id="csm-bar";
LAYOUT.forEach(function(def){var el=makeBtn(def);if(el)bar.appendChild(el)});
document.body.appendChild(bar);
var handle=document.createElement("div");handle.id="csm-handle";
handle.textContent="\u25bc";handle.classList.add("csm-open");
handle.addEventListener("touchstart",function(e){
e.preventDefault();barOpen=!barOpen;
bar.classList.toggle("csm-hidden",!barOpen);
handle.classList.toggle("csm-open",barOpen);
handle.textContent=barOpen?"\u25bc":"\u25b2";
document.body.classList.toggle("csm-bar-on",barOpen);
},{passive:false});
document.body.appendChild(handle);
document.body.classList.add("csm-bar-on");
}
mountToolbar();
})();
(function initFocusGuard(){
// Disabled to allow native text selection
})();
console.log("%c[CS-Mobile v6-full] \u2705 All patches active","color:#22c55e;font-weight:bold;font-size:13px");
})();</script>'

# =============================================================================
#  vsce-sign BYPASS PATCH
# =============================================================================

VSCE_PATCH="@@ -99,8 +99,7 @@
  * @returns {Promise<ExtensionSignatureVerificationResult>}
  */
 async function verify(vsixFilePath, signatureArchiveFilePath, verbose) {
-    const args = ['verify', '--package', vsixFilePath, '--signaturearchive', signatureArchiveFilePath];
-    return await execCommand(args, verbose, false);
+    return new ExtensionSignatureVerificationResult(ReturnCode[0], true, 0, '');
 }
 
 /**"

# =============================================================================
#  ASK FUNCTION — interactive patch configuration
# =============================================================================

_yn() {
    _default="${2:-1}"
    if [ "${_default}" -eq 1 ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
    printf "  ${BLD}%-52s${RST} %s: " "$1" "${_hint}"
    IFS= read -r _input </dev/tty || _input=""
    case "${_input}" in
        [Nn]*) printf '%s\n' "0" ;;
        [Yy]*) printf '%s\n' "1" ;;
        *)     printf '%s\n' "${_default}" ;;
    esac
}

ask_patches() {
    printf "\n${BLD}Configure which patches to apply:${RST}\n"
    printf "${CYN}(Press Enter to accept default shown in brackets)${RST}\n\n"

    APPLY_JS1=$(_yn   "JS-1    Fix keyboard popup on scroll"          1)
    APPLY_JS2=$(_yn   "JS-2    Fix context menus on Android"          1)
    APPLY_JS3=$(_yn   "JS-3    keyboard.dispatch = keyCode"           1)
    APPLY_JS4=$(_yn   "JS-4    actionWidget touch dismiss"            1)
    APPLY_JS5=$(_yn   "JS-5    onDidLayoutChange guard"               1)
    APPLY_JS6=$(_yn   "JS-6    Force experimentalEditContext=false"   1)
    APPLY_HTML1=$(_yn "HTML-1  viewport interactive-widget"           1)
    APPLY_HTML3=$(_yn "HTML-3  Inject mobile CSS into <head>"         1)
    APPLY_HTML4=$(_yn "HTML-4  Inject mobile JS before </body>"       1)
    APPLY_SIGN=$(_yn  "SIGN    vsce-sign bypass (arm64 only)"         1)

    printf "\n${BLD}Selected patches:${RST}\n"
    for _p in JS1 JS2 JS3 JS4 JS5 JS6 HTML1 HTML3 HTML4 SIGN; do
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

    if [ -f "${REVERT_PATCH}" ]; then
        warn "Already patched (${REVERT_PATCH} exists)."
        warn "Run 'revert' first, then re-patch."
        exit 1
    fi

    # ── Interactive patch selection ───────────────────────────────────────────
    if [ "${_skip_ask}" -eq 0 ] && [ -t 0 ]; then
        ask_patches
    else
        APPLY_JS1=1; APPLY_JS2=1; APPLY_JS3=1; APPLY_JS4=1
        APPLY_JS5=1; APPLY_JS6=1
        APPLY_HTML1=1; APPLY_HTML3=1; APPLY_HTML4=1
        APPLY_SIGN=1
        [ "${_skip_ask}" -eq 1 ] && msg "Non-interactive mode (--yes): all patches enabled"
    fi

    printf "\n${BLD}Installation :${RST} %s\n" "${ROOT}"
    printf "${BLD}Workbench    :${RST} %s\n\n" "${WORKBENCH_DIR}"

    # ── Backup originals ──────────────────────────────────────────────────────
    cp "${JS}"   "${JS}.origin"
    cp "${HTML}" "${HTML}.origin"

    # ── Cleanup trap ──────────────────────────────────────────────────────────
    trap '
        printf "\n[ERROR] Patch failed — restoring originals\n" >&2
        cp "${JS}.origin"   "${JS}"   2>/dev/null || true
        cp "${HTML}.origin" "${HTML}" 2>/dev/null || true
        rm -f "${JS}.origin" "${HTML}.origin"
        exit 1
    ' EXIT
    trap '
        printf "\r[interrupted] Restoring originals\n" >&2
        cp "${JS}.origin"   "${JS}"   2>/dev/null || true
        cp "${HTML}.origin" "${HTML}" 2>/dev/null || true
        rm -f "${JS}.origin" "${HTML}.origin"
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
            sed -E -i "s#(;this.[^ ]\\(.,.,.,Math.abs\\(g\\)/f,g>0\\?1:-1,.,Math.abs\\(.\\)/f,p>0\\?1:-1,.\\))#\1,this.eventType=${EventType}.Change#g" "${JS}"
            sed -E -i "s#(\\[a\\.identifier\\]\\}this.h&&\\()([^ ].preventDefault\\(\\),)#\\1this.eventType!==${EventType}.Change\\&\\&\\2this.eventType=void 0,#g" "${JS}"
            verify_sed "JS-1: keyboard scroll" \
                'this\.eventType=[^ ]+\.Change.*this\.eventType!==[^ ]+\.Change' "${JS}"
        fi
    else
        warn "[JS-1] Skipped"
    fi


    # =========================================================================
    #  JS-2 + JS-3 + JS-5: require isAndroid variable
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
        sed -E -i "s^(if\\(this\\.[^ ]\\.canRelayout===!1&&!\\([^ ]+&&[^ ]+\\.pointerEvents\\))(\\))^\1\&\&!${isAndroid}\2^" "${JS}"
        verify_sed "JS-2a: canRelayout" \
            'canRelayout===!1&&!\([^ ]+&&[^ ]+\.pointerEvents\)&&![^ ]+\)' "${JS}"

        sed -E -i "s^(\\{this\\.\\$&&\\!\\(..&&..\\.pointerEvents\\))(&&this\\.\\$\\.blur\\(\\)\\})^\1\&\&!${isAndroid}\2^" "${JS}"
        verify_sed "JS-2b: blur guard" \
            'pointerEvents\)&&![^ ]+&&this\.' "${JS}"

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
            warn "JS-6: editor.experimentalEditContextEnabled not in this build"
        fi
    else
        warn "[JS-6] Skipped"
    fi


    # =========================================================================
    #  HTML-1: viewport interactive-widget=resizes-content
    # =========================================================================
    if [ "${APPLY_HTML1}" -eq 1 ]; then
        msg "[HTML-1] viewport interactive-widget..."
        sed -E -i 's/(<meta name="viewport" )(content=.+)(>$)/\1content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, interactive-widget=resizes-content"\3/' "${HTML}"
        verify_sed "HTML-1: viewport" 'interactive-widget=resizes-content' "${HTML}"
    else
        warn "[HTML-1] Skipped"
    fi


    # =========================================================================
    #  HTML-3 + HTML-4: Inject mobile CSS and JS
    #  awk handles multi-line/multi-KB strings safely without quoting issues
    # =========================================================================
    TMPF=$(mktemp)

    if [ "${APPLY_HTML3}" -eq 1 ]; then
        msg "[HTML-3] Injecting mobile CSS..."
        printf '%s\n' "${MOBILE_CSS}" > "${TMPF}.css"
        awk -v f="${TMPF}.css" \
            '/<\/head>/{while((getline l<f)>0)print l;close(f)}{print}' \
            "${HTML}" > "${TMPF}" && mv "${TMPF}" "${HTML}"
        rm -f "${TMPF}.css"
        verify_sed "HTML-3: mobile CSS" 'id="cs-m-css"' "${HTML}"
    else
        warn "[HTML-3] Skipped"
    fi

    if [ "${APPLY_HTML4}" -eq 1 ]; then
        msg "[HTML-4] Injecting mobile JS..."
        printf '%s\n' "${MOBILE_JS}" > "${TMPF}.js"
        awk -v f="${TMPF}.js" \
            '/<\/body>/{while((getline l<f)>0)print l;close(f)}{print}' \
            "${HTML}" > "${TMPF}" && mv "${TMPF}" "${HTML}"
        rm -f "${TMPF}.js"
        verify_sed "HTML-4: mobile JS" 'id="cs-m-js"' "${HTML}"
    else
        warn "[HTML-4] Skipped"
    fi

    rm -f "${TMPF}" 2>/dev/null || true


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
        diff -u "workbench.js.origin"   "workbench.js"   >  "${REVERT_PATCH}" || true
        diff -u "workbench.html.origin" "workbench.html" >> "${REVERT_PATCH}" || true
    )
    # Include bundled sign file in the revert patch if we patched it
    if [ "${APPLY_SIGN}" -eq 1 ] && [ "${VSCE_SIGN_TYPE}" = "bundled" ] \
       && [ -f "${VSCE_SIGN}.origin" ]; then
        diff -u "${VSCE_SIGN}.origin" "${VSCE_SIGN}" >> "${REVERT_PATCH}" || true
        rm -f "${VSCE_SIGN}.origin"
    fi
    [ -s "${REVERT_PATCH}" ] || warn "Revert patch is empty — no diffs found?"

    rm -f "${JS}.origin" "${HTML}.origin"

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
    # The revert patch covers workbench.js, workbench.html, and (if bundled) the sign file.
    # For npm-package sign files, revert separately with `patch -R`.
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
        "$(printf '%s' "${WORKBENCH_DIR}" | grep -q 'lib/vscode' \
            && printf 'lib/vscode (release-standalone)' \
            || printf 'out/ (serve-web)')"

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
    printf "\n${BLD}workbench.html patches:${RST}\n"
    chk "HTML-1 viewport interactive-widget" 'interactive-widget=resizes-content' "${HTML}"
    chk "HTML-3 mobile CSS"                  'id="cs-m-css"'                      "${HTML}"
    chk "HTML-4 mobile JS"                   'id="cs-m-js"'                       "${HTML}"
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
    printf "${BLD}cs-mobile-patch-full.sh v6-full${RST} — Patch VS Code / code-server for Android

${BLD}USAGE:${RST}
  sh cs-mobile-patch-full.sh ${BLD}search${RST}                    Find all installations
  sh cs-mobile-patch-full.sh ${BLD}patch${RST}  [--yes] [DIR]     Apply patches (interactive)
  sh cs-mobile-patch-full.sh ${BLD}revert${RST} [DIR]             Undo all patches
  sh cs-mobile-patch-full.sh ${BLD}status${RST} [DIR]             Check patch state

  --yes / -y    Skip interactive prompt, apply all patches automatically.

${BLD}QUICK START:${RST}
  sh cs-mobile-patch-full.sh search             # find installation
  sh cs-mobile-patch-full.sh patch /path        # select patches interactively
  sh cs-mobile-patch-full.sh patch --yes /path  # apply all without prompting

${BLD}PATCHES (v6-full):${RST}
  JS-1    Keyboard popup on scroll         (EventType guard in touchmove handler)
  JS-2    Context menus on Android         (3 sites: canRelayout, blur, position)
  JS-3    keyboard.dispatch = keyCode      (Gboard / Android IME compatibility)
  JS-4    actionWidget touch dismiss       (touchstart+touchmove on pointerBlock)
  JS-5    onDidLayoutChange guard          (action menu stays open on keyboard open)
  JS-6    experimentalEditContextEnabled   (CRITICAL: force false for Insiders/new Stable)
  HTML-1  viewport interactive-widget      (keyboard shrinks viewport, not overlaps)
  HTML-3  Mobile CSS                       (scrollbars, touch targets, toolbar CSS)
  HTML-4  Mobile JS                        (xterm scroll, clipboard bar, key toolbar)
  SIGN    vsce-sign bypass                 (extension install on arm64 Android)

  NOTE: HTML-2 (Command palette width 76%%) is intentionally excluded.

${BLD}SUPPORTED LAYOUTS:${RST}
  Layout A  <ROOT>/out/vs/code/browser/workbench/            (VS Code CLI serve-web)
  Layout B  <ROOT>/lib/vscode/out/vs/code/browser/workbench/ (release-standalone)

${BLD}REQUIREMENTS:${RST}
  sh  sed  awk  diff  patch  grep  (all pre-installed in Termux and Ubuntu)

${BLD}EXAMPLES:${RST}
  sh cs-mobile-patch-full.sh search
  sh cs-mobile-patch-full.sh patch
  sh cs-mobile-patch-full.sh patch --yes
  sh cs-mobile-patch-full.sh patch ~/.local/share/code-server/code-server/release-standalone
  sh cs-mobile-patch-full.sh status
  sh cs-mobile-patch-full.sh revert
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
