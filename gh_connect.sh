#!/usr/bin/env bash
# =============================================================================
# gh_connect.sh
# =============================================================================
# Projekt:      claude-github-connector
# Repó:         https://github.com/dr-watt/claude-github-connector
# Leírás:       Univerzális Claude projekt ↔ GitHub repó összekötő script.
#               Bármely Claude projekthez futtatható – interaktívan kiválasztja
#               a megfelelő GitHub repót, majd beállítja a Git kapcsolatot.
#
# Főbb funkciók:
#   · GitHub CLI (gh) OAuth bejelentkezés böngészőn keresztül
#   · Interaktív repó választó (whiptail TUI menü)
#   · Claude GitHub App ellenőrzése és telepítési útmutató
#   · SSH kulcs generálás + GitHub regisztráció
#   · Lokális Git repó inicializálás és remote beállítás
#   · Projekt-specifikus .gitignore generálás
#   · Első szinkronizálás (fetch → pull → push)
#
# Függőségek:
#   · git          – verziókezelés
#   · gh           – GitHub CLI (automatikusan telepíti a script)
#   · whiptail     – interaktív TUI menü (libnewt)
#   · ssh-keygen   – SSH kulcs generálás
#   · curl, jq     – API lekérések és JSON feldolgozás
#
# Dokumentáció:
#   · GitHub CLI:   https://cli.github.com/manual/
#   · Whiptail:     https://whiptail.readthedocs.io/en/latest/
#   · GitHub Apps:  https://docs.github.com/en/apps
#
# Verzió:       1.0.0
# Dátum:        2026-04-10
# Szerző:       dr-watt
# =============================================================================

set -euo pipefail
# -e  : bármilyen hiba esetén azonnal leáll
# -u  : definiálatlan változó használatakor leáll
# -o pipefail : pipe hibája esetén leáll (nem csak az utolsó parancs hibája számít)

# =============================================================================
# DIAGNOSZTIKAI LOG RENDSZER
# =============================================================================
# Minden kimenet (stdout + stderr) egy időbélyeges log fájlba is kerül.
# A log fájlt add vissza a Claude-nak hibajelentésként.
#
# Log fájl helye: <script indítási könyvtára>/gh_connect_YYYYMMDD_HHMMSS.log
# Crash report:   <script indítási könyvtára>/gh_connect_CRASH_YYYYMMDD_HHMMSS.log
# =============================================================================

# ── Script könyvtárának rögzítése ────────────────────────────────────────────
# FONTOS: ezt a PWD-t az init_local_repo() cd-je előtt kell elmenteni,
# különben a log és crash fájl helye megváltozna a script futása közben.
# $BASH_SOURCE[0] mindig a script saját fájljának elérési útja, még source esetén is.
readonly SCRIPT_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Log fájl inicializálása ───────────────────────────────────────────────────
# Az időbélyeges fájlnév minden futásnál egyedi, nem írja felül a régit.
# A log fájl mindig abba a könyvtárba kerül, ahonnan a scriptet indítottuk.
readonly LOG_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly LOG_FILE="${SCRIPT_RUN_DIR}/gh_connect_${LOG_TIMESTAMP}.log"
readonly CRASH_FILE="${SCRIPT_RUN_DIR}/gh_connect_CRASH_${LOG_TIMESTAMP}.log"

# tee: minden kimenet (stdout + stderr) egyszerre megy a terminálra és a log fájlba
# ANSI színek a terminálra megmaradnak; a log fájlban is látszanak (cat-tel olvasható)
exec > >(tee -a "$LOG_FILE") 2>&1

# ── ERR trap: pontos crash report ────────────────────────────────────────────
# Ha bármelyik parancs hibával tér vissza, ez a handler fut le ELŐSZÖR.
# Megmutatja: fájl neve, sor száma, függvény neve, a hibás parancs szövege,
# és a teljes call stack (melyik függvény hívta a hibásat).
# Dokumentáció: https://www.gnu.org/software/bash/manual/bash.html#index-trap
_diag_crash_handler() {
    local exit_code="$?"       # az elszállt parancs visszatérési kódja
    local line_number="$1"     # sor száma a scriptben
    local failed_command="$2"  # a hibás parancs szövege ($BASH_COMMAND)
    local func_name="${3:-main}" # függvény neve (ha van)

    # ── Crash report fájl összeállítása ──────────────────────────────────────
    {
        echo "=================================================================="
        echo "  CRASH REPORT – gh_connect.sh"
        echo "=================================================================="
        echo "  Időpont:          $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Exit kód:         $exit_code"
        echo "  Hibás sor:        $line_number"
        echo "  Hibás parancs:    $failed_command"
        echo "  Függvény:         $func_name"
        echo ""
        echo "  ── Call stack (hívási lánc) ──────────────────────────────────"
        # FUNCNAME tömbből kihagyjuk az első elemet (_diag_crash_handler)
        local i
        for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
            printf "    #%d  %s() → %s:%d\n" \
                "$i" \
                "${FUNCNAME[$i]}" \
                "${BASH_SOURCE[$i]:-?}" \
                "${BASH_LINENO[$(( i - 1 ))]}"
        done
        echo ""
        echo "  ── Utolsó 30 sor a log fájlból ──────────────────────────────"
        tail -30 "$LOG_FILE" 2>/dev/null || echo "  (log fájl nem olvasható)"
        echo ""
        echo "  ── Rendszer állapot a crash pillanatában ─────────────────────"
        echo "  GH_CLI_AVAILABLE:  ${GH_CLI_AVAILABLE:-?}"
        echo "  GH_AUTHENTICATED:  ${GH_AUTHENTICATED:-?}"
        echo "  GIT_USERNAME:      ${GIT_USERNAME:-?}"
        echo "  SELECTED_REPO:     ${SELECTED_REPO:-?}"
        echo "  PROJECT_DIR:       ${PROJECT_DIR:-?}"
        echo "=================================================================="
    } | tee -a "$CRASH_FILE"

    # Terminálra is kiírjuk a lényeget (a log_error-t nem hívhatjuk, mert az exit-tel zárna)
    echo ""
    echo -e "\033[0;31m[CRASH]\033[0m  A script leállt a(z) ${line_number}. sorban!"
    echo -e "\033[0;31m[CRASH]\033[0m  Hibás parancs: ${failed_command}"
    echo -e "\033[0;33m[LOG]\033[0m    Teljes log:    ${LOG_FILE}"
    echo -e "\033[0;33m[LOG]\033[0m    Crash report:  ${CRASH_FILE}"
    echo ""
    echo -e "\033[1m  ▶ Másold be a Claude-nak a crash report tartalmát:\033[0m"
    echo "    cat ${CRASH_FILE}"
}

# Trap regisztrálása: ERR esetén hívja a crash handlert
# $LINENO és $BASH_COMMAND automatikusan kitöltődnek a bash által
trap '_diag_crash_handler "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' ERR

# ── Script indulás rögzítése ──────────────────────────────────────────────────
echo "=================================================================="
echo "  gh_connect.sh – LOG INDÍTVA"
echo "  Időpont:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Log fájl:  ${LOG_FILE}"
echo "=================================================================="

# =============================================================================
# GLOBÁLIS KONSTANSOK
# =============================================================================

# ── Verzió ───────────────────────────────────────────────────────────────────
readonly VERSION="1.0.0"
readonly SCRIPT_NAME="claude-github-connector"
readonly REPO_URL="https://github.com/dr-watt/claude-github-connector"

# ── Claude GitHub App ─────────────────────────────────────────────────────────
# A Claude alkalmazás GitHub App ID-ja (Anthropic által kiadott)
# Forrás: https://github.com/apps/claude
readonly CLAUDE_APP_URL="https://github.com/apps/claude"
readonly CLAUDE_APP_SETTINGS="https://github.com/settings/installations"

# ── SSH kulcs ─────────────────────────────────────────────────────────────────
readonly SSH_KEY_PATH="$HOME/.ssh/id_ed25519_github"
readonly SSH_CONFIG_PATH="$HOME/.ssh/config"

# ── Whiptail megjelenítési méretek ────────────────────────────────────────────
# Automatikusan a terminál méretéhez igazodik
TERM_HEIGHT=$(tput lines  2>/dev/null || echo 30)
TERM_WIDTH=$(tput cols    2>/dev/null || echo 80)
DIALOG_HEIGHT=$(( TERM_HEIGHT - 6 ))
DIALOG_WIDTH=$(( TERM_WIDTH  - 10 ))
# Menü sorok száma (repó lista)
MENU_HEIGHT=$(( DIALOG_HEIGHT - 8 ))

# ── Szín konstansok ───────────────────────────────────────────────────────────
readonly C_RST="\033[0m"
readonly C_BOLD="\033[1m"
readonly C_RED="\033[0;31m"
readonly C_YLW="\033[0;33m"
readonly C_GRN="\033[0;32m"
readonly C_CYN="\033[0;36m"
readonly C_BLU="\033[0;34m"
readonly C_MGT="\033[0;35m"

# ── Futásidejű állapot változók ───────────────────────────────────────────────
GH_CLI_AVAILABLE=false    # gh CLI elérhető-e
GH_AUTHENTICATED=false    # gh CLI be van-e jelentkezve
SELECTED_REPO=""          # kiválasztott repó (owner/name formátum)
SELECTED_REPO_URL=""      # SSH URL a kiválasztott repóhoz
GIT_USERNAME=""           # GitHub felhasználónév
GIT_EMAIL=""              # GitHub e-mail cím
PROJECT_DIR=""            # Projekt könyvtár teljes elérési útja
REPO_EXISTS=false         # lokális .git könyvtár létezik-e már

# =============================================================================
# NAPLÓZÓ FÜGGVÉNYEK
# =============================================================================

# ── Időbélyeg helper ─────────────────────────────────────────────────────────
# Minden log bejegyzés elé kerül: [HH:MM:SS]
_ts() { date '+%H:%M:%S'; }

# ── Naplózó függvények ────────────────────────────────────────────────────────
# Formátum: [HH:MM:SS] [SZINT]  üzenet
# A kimenet tee-n keresztül egyszerre megy a terminálra és a log fájlba.
log_info()    { echo -e "$(_ts) ${C_CYN}[INFO]${C_RST}  $*"; }
log_ok()      { echo -e "$(_ts) ${C_GRN}[  OK]${C_RST}  $*"; }
log_warn()    { echo -e "$(_ts) ${C_YLW}[WARN]${C_RST}  $*"; }
log_step()    { echo -e "$(_ts) ${C_MGT}[STEP]${C_RST}  $*"; }
log_error()   { echo -e "$(_ts) ${C_RED}[HIBA]${C_RST}  $*" >&2; exit 1; }

# Szekció fejléc: vizuálisan elválasztja a főbb lépéseket a logban
log_section() {
    local title="$*"
    local pad=$(( 56 - ${#title} ))
    [[ "$pad" -lt 0 ]] && pad=0
    echo ""
    echo -e "${C_BLU}${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_BLU}${C_BOLD}║  $(_ts)  ${title}$(printf '%*s' "$pad" '')║${C_RST}"
    echo -e "${C_BLU}${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RST}"
}

# Függvény belépési pont naplózása – a log fájlban mindig látszik, melyik lépésig jutott el
# Használat: log_fn_enter minden public függvény ELEJÉN
log_fn_enter() {
    local fn="${FUNCNAME[1]:-?}"
    echo -e "$(_ts) ${C_MGT}[STEP]${C_RST}  ▶ ${fn}() belépés"
}

# Függvény kilépési pont naplózása – megerősíti, hogy a lépés sikeresen lezárult
# Használat: log_fn_exit minden public függvény VÉGÉN
log_fn_exit() {
    local fn="${FUNCNAME[1]:-?}"
    echo -e "$(_ts) ${C_GRN}[DONE]${C_RST}  ◀ ${fn}() kész"
}

# Figyelmeztető panel (teljes képernyős whiptail msgbox)
show_warning_box() {
    local title="$1"
    local message="$2"
    whiptail --title "$title" \
             --msgbox "$message" \
             "$DIALOG_HEIGHT" "$DIALOG_WIDTH" \
             3>&1 1>&2 2>&3 || true
}

# Igen/Nem kérdés whiptail-lel, visszatérési értéke 0=igen, 1=nem
ask_yesno() {
    local title="$1"
    local message="$2"
    whiptail --title "$title" \
             --yesno "$message" \
             12 "$DIALOG_WIDTH" \
             3>&1 1>&2 2>&3
}

# =============================================================================
# RENDSZERDIAGNOSZTIKA
# =============================================================================
# A script indításakor rögzíti a teljes rendszerkörnyezetet a log fájlba.
# Ha a script elszáll, ebből meg lehet állapítani, mi hiányzott.
# Dokumentáció: https://docs.kernel.org/ | https://zsh.sourceforge.io/Doc/
# =============================================================================

diag_system() {
    log_fn_enter
    log_info "Rendszerdiagnosztika rögzítése..."

    echo ""
    echo "── RENDSZER INFORMÁCIÓK ──────────────────────────────────────────────"
    echo "  Dátum/Idő:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Hostname:         $(hostname -f 2>/dev/null || hostname)"
    echo "  OS:               $(uname -srm)"
    echo "  Distro:           $(lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo 'N/A')"
    echo "  Kernel:           $(uname -r)"
    echo "  Shell:            $SHELL → verziója: $("$SHELL" --version 2>/dev/null | head -1 || echo 'N/A')"
    echo "  Bash verzió:      $BASH_VERSION"
    echo "  Felhasználó:      $(whoami) (UID=$(id -u), GID=$(id -g))"
    echo "  HOME:             $HOME"
    echo "  PWD:              $(pwd)"
    echo "  PATH:             $PATH"
    echo ""
    echo "── TELEPÍTETT ESZKÖZÖK ───────────────────────────────────────────────"
    local tools=("git" "gh" "curl" "jq" "whiptail" "ssh" "ssh-keygen" "tput" "dpkg" "sudo")
    for tool in "${tools[@]}"; do
        local tool_path
        tool_path=$(command -v "$tool" 2>/dev/null || echo "HIÁNYZIK")
        local tool_ver=""
        if [[ "$tool_path" != "HIÁNYZIK" ]]; then
            # Verziót csak a legfontosabbaknál kérjük le
            case "$tool" in
                git)     tool_ver=" → $(git --version 2>/dev/null)" ;;
                gh)      tool_ver=" → $(gh --version 2>/dev/null | head -1)" ;;
                curl)    tool_ver=" → $(curl --version 2>/dev/null | head -1)" ;;
                jq)      tool_ver=" → $(jq --version 2>/dev/null)" ;;
                ssh)     tool_ver=" → $(ssh -V 2>&1)" ;;
            esac
        fi
        printf "  %-15s %s%s\n" "$tool" "$tool_path" "$tool_ver"
    done
    echo ""
    echo "── SSH KÖNYVTÁR ÁLLAPOT ──────────────────────────────────────────────"
    if [[ -d "$HOME/.ssh" ]]; then
        echo "  ~/.ssh/ létezik: igen"
        echo "  ~/.ssh/ jogok:   $(stat -c '%a' "$HOME/.ssh" 2>/dev/null || echo 'N/A')"
        echo "  ~/.ssh fájlok:"
        ls -la "$HOME/.ssh/" 2>/dev/null | sed 's/^/    /' || echo "    (üres)"
    else
        echo "  ~/.ssh/ létezik: NEM (a script létrehozza)"
    fi
    echo ""
    echo "── GIT KONFIGURÁCIÓ ──────────────────────────────────────────────────"
    git config --list --global 2>/dev/null | sed 's/^/  /' || echo "  (nincs git config)"
    echo ""
    echo "── HÁLÓZATI ELÉRHETŐSÉG ──────────────────────────────────────────────"
    local endpoints=("github.com" "cli.github.com" "api.github.com")
    for ep in "${endpoints[@]}"; do
        if curl -sSf --max-time 5 "https://${ep}" -o /dev/null 2>/dev/null; then
            echo "  $ep → ELÉRHETŐ"
        else
            echo "  $ep → NEM ELÉRHETŐ (tűzfal? DNS?)"
        fi
    done
    echo "──────────────────────────────────────────────────────────────────────"
    echo ""

    log_fn_exit
}

# =============================================================================
# 0. ELŐFELTÉTEL: FÜGGŐSÉGEK TELEPÍTÉSE
# =============================================================================

# Ellenőrzi és szükség esetén telepíti a kötelező függőségeket
install_dependencies() {
    log_fn_enter
    log_section "Függőségek ellenőrzése"

    # Kötelező csomagok listája
    local apt_packages=("git" "curl" "jq" "whiptail" "openssh-client")
    local missing=()

    for pkg in "${apt_packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null || command -v "$pkg" &>/dev/null; then
            log_ok "$pkg → telepítve"
        else
            log_warn "$pkg → HIÁNYZIK"
            missing+=("$pkg")
        fi
    done

    # Hiányzó csomagok telepítése
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Hiányzó csomagok telepítése: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
        log_ok "Csomagok telepítve."
    fi

    # GitHub CLI (gh) telepítése – külön folyamat, mert nem apt-ban van alapból
    install_gh_cli
    log_fn_exit
}

# GitHub CLI telepítése a hivatalos apt repóból
# Forrás: https://cli.github.com/manual/installation
install_gh_cli() {
    if command -v gh &>/dev/null; then
        log_ok "GitHub CLI → $(gh --version | head -1)"
        GH_CLI_AVAILABLE=true
        return 0
    fi

    log_info "GitHub CLI telepítése (hivatalos apt repó)..."

    # GPG kulcs és apt forrás hozzáadása
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null

    echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y gh

    log_ok "GitHub CLI telepítve: $(gh --version | head -1)"
    GH_CLI_AVAILABLE=true
}

# =============================================================================
# 1. ELŐFELTÉTEL FIGYELMEZTETÉSEK (whiptail panel)
# =============================================================================

# Megjeleníti az összes szükséges előfeltételt egy TUI panelen,
# mielőtt bármilyen műveletet elvégezne a script.
show_prerequisites_warning() {
    log_fn_enter
    log_section "Előfeltételek ellenőrzése"

    # ── 1. panel: Chromium / GitHub session figyelmeztetés ───────────────────
    show_warning_box \
        "⚠️  ELŐFELTÉTEL 1/3 – Böngésző bejelentkezés" \
"A GitHub CLI (gh) OAuth hitelesítést fog kérni, amely megnyitja
az alapértelmezett böngésződet (Chromium/Firefox).

A SIKERES HITELESÍTÉSHEZ szükséges:
────────────────────────────────────────────────
 ✓  Nyisd meg a böngészőt MOST, ha még nem fut
 ✓  Lépj be a GitHub fiókoddal a böngészőben
    → https://github.com/login

 ℹ  Ha Claude.ai-t is használsz párhuzamosan,
    UGYANABBAN a böngészőben legyél bejelentkezve
    mind a GitHub-ra, mind a Claude.ai-ra.

Folytatás előtt ellenőrizd, hogy a böngészőben
aktív GitHub session van!"

    # ── 2. panel: Claude GitHub App figyelmeztetés ────────────────────────────
    show_warning_box \
        "⚠️  ELŐFELTÉTEL 2/3 – Claude GitHub App" \
"A Claude-nak engedélyt kell adni a GitHub fiókodban,
különben nem tud hozzáférni a repóidhoz.

ELLENŐRIZD MOST a böngészőben:
────────────────────────────────────────────────
 1. Nyisd meg: github.com/settings/installations
 2. Keresd a 'Claude' alkalmazást a listában

 HA NEM LÁTOD → telepítsd:
    github.com/apps/claude
    → [Install] gomb → válaszd ki a fiókod

 HOZZÁFÉRÉS BEÁLLÍTÁSA (telepítéskor vagy utólag):
    ○  'All repositories'   – minden jelenlegi és
                              jövőbeli repóhoz hozzáfér
    ○  'Only select repos'  – CSAK a kiválasztottakhoz
       Ha ezt választod, add hozzá a célrepót:
       → dr-watt/claude-github-connector
         (vagy a project repo nevét)

⚠  E nélkül a Claude nem látja/módosítja a repókat!"

    # ── 3. panel: Összefoglaló – mi fog történni ──────────────────────────────
    show_warning_box \
        "ℹ️  ELŐFELTÉTEL 3/3 – Mit fog csinálni a script?" \
"A script a következő lépéseket hajtja végre:
────────────────────────────────────────────────
 1. GitHub bejelentkezés  → gh auth login (böngésző)
 2. SSH kulcs generálás   → Ed25519, ~/.ssh/id_ed25519_github
 3. SSH kulcs feltöltés   → automatikusan a GitHub fiókba
 4. Repó kiválasztás      → interaktív lista (ÖSSZES repód)
 5. Lokális Git init      → ha még nem létezik .git mappa
 6. Remote origin         → SSH URL beállítása
 7. Szinkronizálás        → fetch → pull → push

FONTOS:
 · A script NEM töröl semmit
 · NEM hoz létre új repót (csak meglévőhöz csatlakozik)
 · Minden lépésnél visszakérdez, ha felülírás szükséges

Folytatáshoz nyomj ENTER-t..."
    log_fn_exit
}

# =============================================================================
# 2. GITHUB CLI HITELESÍTÉS
# =============================================================================

# GitHub CLI OAuth hitelesítés interaktív módban.
# A --web flag SZÁNDÉKOSAN HIÁNYZIK: az automatikus browser-nyitás és
# device code polling megbízhatatlan headless/ZSH környezetben.
# Interaktív módban a gh CLI maga kérdezi meg a hitelesítési módot.
# Dokumentáció: https://cli.github.com/manual/gh_auth_login
authenticate_github_cli() {
    log_fn_enter
    log_section "GitHub CLI hitelesítés"

    # Ellenőrzés: be van-e már lépve
    if gh auth status &>/dev/null; then
        local current_user
        current_user=$(gh api user --jq '.login' 2>/dev/null || echo "ismeretlen")
        log_ok "GitHub CLI már hitelesített: @${current_user}"
        GIT_USERNAME="$current_user"
        GH_AUTHENTICATED=true

        # E-mail lekérése az API-ból – CSAK akkor fogadjuk el, ha valódi email (@-t tartalmaz)
        # A gh api user/emails 404-et adhat ha nincs user:email scope – ekkor JSON jön vissza
        local raw_email_auth
        raw_email_auth=$(gh api user/emails --jq '[.[] | select(.primary==true)] | .[0].email' 2>/dev/null || echo "")
        if [[ "$raw_email_auth" == *"@"* ]]; then
            GIT_EMAIL="$raw_email_auth"
        else
            GIT_EMAIL=""  # sync_git_config fogja bekérni kézzel
        fi

        # Megerősítés kérése: ugyanazt a fiókot használjuk?
        if ! ask_yesno "Fiók megerősítés" \
            "Jelenleg bejelentkezett GitHub fiók: @${current_user}\n\nEzt a fiókot használod a projekt repójához?\n\n(Nem esetén új bejelentkezés indul)"; then
            gh auth logout --hostname github.com 2>/dev/null || true
            GH_AUTHENTICATED=false
        fi
    fi

    # Bejelentkezés, ha szükséges
    if [[ "$GH_AUTHENTICATED" == false ]]; then
        log_info "GitHub bejelentkezés indítása..."
        echo ""
        echo -e "  ${C_YLW}${C_BOLD}▶ FONTOS: a következő lépések a TERMINÁLBAN történnek!${C_RST}"
        echo ""
        echo -e "  ${C_CYN}UTASÍTÁS:${C_RST}"
        echo "  1. A gh CLI megkérdezi a hitelesítési módot"
        echo "     → Válaszd: 'Login with a web browser'"
        echo "  2. Kapsz egy egyszer használatos kódot (pl: ABCD-1234)"
        echo "  3. Nyisd meg böngészőben: https://github.com/login/device"
        echo "  4. Írd be a kódot → Authorize"
        echo "  5. A script AUTOMATIKUSAN FOLYTATÓDIK"
        echo ""
        log_warn "Ha a kód beírása után sem folytatódik: Ctrl+C → újraindítás"
        echo ""

        # Interaktív bejelentkezés – NEM használjuk a --web flaget,
        # mert az automatikus browser-pollozás ZSH terminálban lefagyhat.
        # Az interaktív mód megbízhatóbb: a gh CLI maga kezeli a device flow-t.
        # --git-protocol ssh : minden git művelet SSH-n menjen
        gh auth login \
            --hostname github.com \
            --git-protocol ssh

        # Adatok lekérése a sikeres auth után – email validálással
        GIT_USERNAME=$(gh api user --jq '.login' 2>/dev/null)
        local raw_email_new
        raw_email_new=$(gh api user/emails \
            --jq '[.[] | select(.primary==true)] | .[0].email' 2>/dev/null || echo "")
        if [[ "$raw_email_new" == *"@"* ]]; then
            GIT_EMAIL="$raw_email_new"
        else
            GIT_EMAIL=""  # sync_git_config fogja bekérni kézzel
        fi
        GH_AUTHENTICATED=true
        log_ok "Sikeres bejelentkezés: @${GIT_USERNAME}"
    fi

    # Git globális konfiguráció szinkronizálása a GitHub adatokkal
    sync_git_config
    log_fn_exit
}

# Git globális konfiguráció szinkronizálása a bejelentkezett GitHub adatokkal
sync_git_config() {
    log_info "Git konfiguráció szinkronizálása..."

    # E-mail lekérése az API-ból, validálással
    # A gh api user/emails néha 404-et ad vissza ha nincs user:email scope –
    # ilyenkor a jq kimenet egy JSON hibaüzenet lesz, nem email cím.
    # Az `@` karakter meglétével ellenőrzük, hogy valódi e-mail-t kaptunk-e.
    if [[ -z "$GIT_EMAIL" ]]; then
        local raw_email
        raw_email=$(gh api user/emails \
            --jq '[.[] | select(.primary==true)] | .[0].email' 2>/dev/null || echo "")
        # Csak akkor fogadjuk el, ha valódi e-mail formátum (tartalmaz @-t)
        if [[ "$raw_email" == *"@"* ]]; then
            GIT_EMAIL="$raw_email"
        else
            log_warn "E-mail cím nem volt lekérhetó az API-ból (scope hiány?)."
            GIT_EMAIL=""
        fi
    fi

    # Ha az e-mail még mindig üres, kézzel bekérjük
    if [[ -z "$GIT_EMAIL" ]]; then
        log_info "Add meg a GitHub e-mail címedet (git commit azonosításhoz szükséges):"
        read -rp "  GitHub e-mail cím: " GIT_EMAIL
        # Validáció: @ karaktert tartalmaznia kell
        while [[ "$GIT_EMAIL" != *"@"* ]]; do
            log_warn "Érvénytelen e-mail cím! Próbáld újra:"
            read -rp "  GitHub e-mail cím: " GIT_EMAIL
        done
    fi

    git config --global user.name  "$GIT_USERNAME"
    git config --global user.email "$GIT_EMAIL"

    # Alapvető hasznos beállítások
    git config --global init.defaultBranch   main
    git config --global pull.rebase          false
    git config --global push.default         current
    git config --global core.autocrlf        input
    git config --global color.ui             auto
    git config --global core.editor          nano

    # Praktikus aliasok
    git config --global alias.st   "status -sb"
    git config --global alias.lg   "log --oneline --graph --decorate --all"
    git config --global alias.last "log -1 HEAD --stat"
    git config --global alias.undo "reset --soft HEAD~1"
    git config --global alias.fp   "fetch --prune"

    log_ok "Git konfiguráció kész → user: ${GIT_USERNAME} <${GIT_EMAIL}>"
}

# =============================================================================
# 3. SSH KULCS BEÁLLÍTÁS
# =============================================================================

# Ed25519 SSH kulcs generálása és GitHub-ra feltöltése.
# Ha már létezik kulcs, felajánlja a meglévő használatát.
setup_ssh_key() {
    log_fn_enter
    log_section "SSH kulcs beállítása"

    local pub_path="${SSH_KEY_PATH}.pub"

    # ── Meglévő kulcs kezelése ────────────────────────────────────────────────
    if [[ -f "$SSH_KEY_PATH" ]]; then
        log_ok "SSH kulcs már létezik: $SSH_KEY_PATH"

        if ask_yesno "SSH kulcs" \
            "Létező SSH kulcs találva:\n${SSH_KEY_PATH}\n\nA meglévő kulcsot használod?\n\n(Nem esetén új kulcs generálódik, a régi .bak-ként megmarad)"; then
            log_info "Meglévő kulcs használata."
        else
            # Biztonsági mentés és újragenerálás
            local backup_suffix
            backup_suffix=".bak.$(date +%s)"
            mv "$SSH_KEY_PATH"  "${SSH_KEY_PATH}${backup_suffix}"
            mv "$pub_path"      "${pub_path}${backup_suffix}"
            log_ok "Régi kulcs mentve: ${SSH_KEY_PATH}${backup_suffix}"
            generate_ssh_keypair
        fi
    else
        generate_ssh_keypair
    fi

    # SSH config frissítése
    update_ssh_config

    # Kulcs feltöltése GitHub-ra (gh CLI-vel)
    upload_ssh_key_to_github "${pub_path}"

    # Kapcsolat tesztelése
    test_ssh_connection
    log_fn_exit
}

# Ed25519 SSH kulcspár generálása
generate_ssh_keypair() {
    log_info "Új Ed25519 SSH kulcs generálása..."

    # SSH könyvtár biztosítása
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Passphrase bekérése whiptail password box-szal
    local passphrase
    passphrase=$(whiptail --title "SSH kulcs passphrase" \
        --passwordbox \
        "Add meg az SSH kulcs passphrase-t.\n(Üres = nincs jelszóvédelem, ENTER = kihagyás)" \
        10 "$DIALOG_WIDTH" "" \
        3>&1 1>&2 2>&3) || passphrase=""

    # Kulcs generálás
    ssh-keygen \
        -t ed25519 \
        -C "${GIT_EMAIL:-${GIT_USERNAME}@github}" \
        -f "$SSH_KEY_PATH" \
        -N "$passphrase"

    # Jogosultságok
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"

    log_ok "SSH kulcspár létrehozva: $SSH_KEY_PATH"
}

# ~/.ssh/config frissítése a GitHub bejegyzéssel
update_ssh_config() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$SSH_CONFIG_PATH"
    chmod 600 "$SSH_CONFIG_PATH"

    # Ellenőrzés: van-e már github.com bejegyzés
    if grep -q "Host github.com" "$SSH_CONFIG_PATH" 2>/dev/null; then
        log_ok "~/.ssh/config már tartalmaz github.com bejegyzést."
        return 0
    fi

    # Bejegyzés hozzáfűzése
    cat >> "$SSH_CONFIG_PATH" <<EOF

# ── GitHub SSH – ${SCRIPT_NAME} v${VERSION} ──────────────────────────────────
# Generálva: $(date '+%Y-%m-%d %H:%M:%S')
Host github.com
    HostName         github.com
    User             git
    IdentityFile     ${SSH_KEY_PATH}
    IdentitiesOnly   yes
    AddKeysToAgent   yes
    ServerAliveInterval 60
EOF

    log_ok "~/.ssh/config frissítve."
}

# SSH publikus kulcs feltöltése GitHub-ra a gh CLI segítségével
# FONTOS: set -euo pipefail környezetben a command substitution $(cmd) kilövheti
# a scriptet ha cmd hibával tér vissza. Ezért if-statementet és timeout-ot használunk.
upload_ssh_key_to_github() {
    local pub_path="$1"
    local key_title="${SCRIPT_NAME}-$(hostname -s)-$(date +%Y%m%d)"

    log_info "SSH kulcs feltöltése GitHub-ra: $key_title"

    # ── 1. lépés: Automatikus feltöltési kísérlet ────────────────────────────
    # if-statement: set -e-vel kompatibilis (nem lő ki a scriptet hiba esetén)
    # timeout 15: meggátolja a lefagyást ha a gh cli vár valamire
    if timeout 15 gh ssh-key add "$pub_path" \
        --title "$key_title" \
        --type authentication >/dev/null 2>&1; then
        log_ok "SSH kulcs feltöltve: $key_title"
        return 0
    fi
    log_warn "Automatikus SSH kulcs feltöltés sikertelen (scope hiány vagy már létezik)."

    # ── 2. lépés: SSH kapcsolat tesztelése – ha már működik, kész vagyunk ────
    # Ha az SSH autentikáció sikeres, a kulcs már fent van GitHub-on.
    # Ez a legfontosabb ellenőrzés: meglévő kulcsnál kihagyja a read -r blokkot.
    log_info "SSH kapcsolat tesztelése (timeout: 10s)..."
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" &>/dev/null
    fi
    ssh-add "$SSH_KEY_PATH" 2>/dev/null || true

    local ssh_test
    # timeout + BatchMode=yes: nem kér interaktív inputot, nem fagy le
    ssh_test=$(timeout 10 ssh -T git@github.com \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=8 \
        -o BatchMode=yes \
        2>&1) || true

    if echo "$ssh_test" | grep -q "successfully authenticated"; then
        log_ok "SSH kapcsolat MŰKÖDIK – kulcs már fent van GitHub-on. ✓"
        return 0
    fi
    log_warn "SSH teszt eredménye: ${ssh_test:-timeout}"

    # ── 3. lépés: Fingerprint egyezés ellenőrzése ────────────────────────────
    local pub_fingerprint
    pub_fingerprint=$(ssh-keygen -lf "$pub_path" 2>/dev/null | awk '{print $2}' || echo "")

    if [[ -n "$pub_fingerprint" ]]; then
        local remote_keys
        remote_keys=$(timeout 10 gh ssh-key list 2>/dev/null || echo "")
        if echo "$remote_keys" | grep -q "$pub_fingerprint"; then
            log_ok "SSH kulcs már szerepel a GitHub fiókon (fingerprint egyezik)."
            return 0
        fi
    fi

    # ── 4. lépés: Kézi feltöltés – csak ha az SSH sem működik ───────────────
    log_warn "SSH kulcs nincs fent GitHub-on – kézi feltöltés szükséges!"
    echo ""
    echo -e "  ${C_YLW}${C_BOLD}▶ KÉZI SSH KULCS FELTÖLTÉS SZÜKSÉGES!${C_RST}"
    echo ""
    echo -e "  1. Nyisd meg: ${C_CYN}https://github.com/settings/ssh/new${C_RST}"
    echo "  2. Title:    ${key_title}"
    echo "  3. Key type: Authentication Key"
    echo "  4. Key:      másold be az alábbi publikus kulcsot:"
    echo ""
    echo -e "  ${C_GRN}$(cat "$pub_path")${C_RST}"
    echo ""
    echo "  5. Kattints: 'Add SSH key'"
    echo ""
    log_info "Nyomj ENTER-t ha a kulcsot feltöltötted a GitHub-ra..."
    read -r
    log_ok "Folytatás – SSH kapcsolat tesztelése..."
}

# GitHub SSH kapcsolat tesztelése
test_ssh_connection() {
    log_info "GitHub SSH kapcsolat tesztelése..."

    # ssh-agent aktiválás – csak ha még nem fut
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" &>/dev/null
    fi

    # ssh-add: ha a kulcsnak van passphrase-e, interaktívan kéri.
    # A || true biztosítja, hogy a script ne álljon le ssh-add hiba esetén.
    # Ha a felhasználó megadja a passphrase-t → az agent tárolja a session-re.
    # Ha nem adja meg (Enter) → a kapcsolat teszt úgy is lefut, csak minden
    # SSH műveletnél újra kérni fogja a passphrase-t.
    log_info "SSH kulcs hozzáadása az agent-hez (passphrase esetén most kérni fogja)..."
    ssh-add "$SSH_KEY_PATH" 2>/dev/null || {
        log_warn "ssh-add nem sikerült (passphrase nélkül folytatjuk)."
    }

    # Kapcsolat teszt – StrictHostKeyChecking=accept-new: első kapcsolódáskor
    # automatikusan elfogadja a github.com host kulcsát (ismert fingerprint).
    # Dokumentáció: https://docs.github.com/en/authentication/connecting-to-github-with-ssh
    local ssh_output
    ssh_output=$(ssh -T git@github.com \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        2>&1 || true)

    if echo "$ssh_output" | grep -q "successfully authenticated"; then
        log_ok "SSH kapcsolat: SIKERES → $ssh_output"
    else
        log_warn "SSH teszt eredménye: $ssh_output"
        log_warn "Ha ez hiba, futtasd manuálisan: ssh -T git@github.com"
    fi
}

# =============================================================================
# 4. INTERAKTÍV REPÓ VÁLASZTÓ (whiptail)
# =============================================================================

# Lekéri az összes elérhető GitHub repót és whiptail menüben megmutatja.
# A felhasználó kiválasztja, melyikhez csatlakozzon a projekt.
select_github_repo() {
    log_fn_enter
    log_section "GitHub repó kiválasztása"

    log_info "Repók lekérése a GitHub API-ból (@${GIT_USERNAME})..."

    # ── Repó lista lekérése gh CLI-vel ────────────────────────────────────────
    # Lekérjük: saját + szervezeti repók, mindkét láthatóság
    # Formátum: "owner/name\tleírás\tláthatóság\tutolsó módosítás"
    local repo_data
    repo_data=$(gh repo list \
        --limit 200 \
        --json nameWithOwner,description,visibility,updatedAt \
        --jq '.[] | "\(.nameWithOwner)\t\(.description // "–")\t\(.visibility)\t\(.updatedAt[:10])"' \
        2>/dev/null) || log_error "Repó lista lekérése sikertelen! Ellenőrizd a gh auth státuszt."

    # ── Whiptail menü adatok összeállítása ────────────────────────────────────
    # Formátum: TAG "MEGJELENÍTETT SZÖVEG" státusz (páros sorok)
    local menu_items=()
    local idx=1

    while IFS=$'\t' read -r full_name description visibility updated; do
        # Rövid leírás: max 45 karakter
        local short_desc="${description:0:45}"
        [[ "${#description}" -gt 45 ]] && short_desc="${short_desc}…"

        # Menü sor: "owner/name  [pub/priv] YYYY-MM-DD – leírás"
        local label
        label=$(printf "%-40s [%-7s] %s – %s" \
            "$full_name" "$visibility" "$updated" "$short_desc")

        menu_items+=( "$idx" "$label" )
        idx=$(( idx + 1 ))
    done <<< "$repo_data"

    # Ellenőrzés: van-e egyáltalán repó
    if [[ ${#menu_items[@]} -eq 0 ]]; then
        log_error "Nem találhatók repók a @${GIT_USERNAME} fiókban!\n\
Ellenőrizd a Claude GitHub App engedélyeket:\n${CLAUDE_APP_SETTINGS}"
    fi

    # ── Whiptail menü megjelenítése ───────────────────────────────────────────
    local selected_idx
    selected_idx=$(whiptail \
        --title "GitHub repó kiválasztása (@${GIT_USERNAME})" \
        --menu \
"Válaszd ki a projekthez csatlakoztatni kívánt GitHub repót!

 Összesen ${#menu_items[@]} repó | Navigálás: ↑↓ | Választás: ENTER
 Mégse: ESC vagy Cancel" \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$MENU_HEIGHT" \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || log_error "Repó választás megszakítva."

    # ── Kiválasztott repó adatainak kinyerése ─────────────────────────────────
    # Az indexből visszakeressük az eredeti repó nevet
    local selected_line
    selected_line=$(echo "$repo_data" | sed -n "${selected_idx}p")
    SELECTED_REPO=$(echo "$selected_line" | cut -f1)  # pl: dr-watt/ai-install
    SELECTED_REPO_URL="git@github.com:${SELECTED_REPO}.git"

    # ── Megerősítés ───────────────────────────────────────────────────────────
    local repo_info
    repo_info=$(gh repo view "$SELECTED_REPO" \
        --json name,description,visibility,defaultBranchRef,url \
        --jq '"Név: \(.name)\nURL: \(.url)\nLáthatóság: \(.visibility)\nDefault branch: \(.defaultBranchRef.name)\nLeírás: \(.description // \"–\")"' \
        2>/dev/null || echo "Részletek nem elérhetők")

    if ! ask_yesno "Repó megerősítés" \
        "Kiválasztott repó:\n\n${repo_info}\n\nSSH URL: ${SELECTED_REPO_URL}\n\nEzt a repót csatlakoztatod a projekthez?"; then
        log_info "Választás elvetve, újraindítás..."
        select_github_repo   # rekurzív újrahívás
        return
    fi

    log_ok "Kiválasztott repó: ${SELECTED_REPO}"
    log_ok "SSH URL: ${SELECTED_REPO_URL}"
    log_fn_exit
}

# =============================================================================
# 5. LOKÁLIS GIT REPÓ INICIALIZÁLÁS
# =============================================================================

# Lokális projekt könyvtár meghatározása és Git repó inicializálása.
# Ha már létezik .git mappa, nem inicializálja újra.
init_local_repo() {
    log_fn_enter
    log_section "Lokális projekt könyvtár beállítása"

    # ── Projekt könyvtár bekérése whiptail-lel ────────────────────────────────
    local default_dir
    default_dir=$(pwd)

    PROJECT_DIR=$(whiptail \
        --title "Projekt könyvtár" \
        --inputbox \
"Add meg a projekt könyvtárának TELJES elérési útját.
(Az aktuális könyvtár az alapértelmezett)

Ha a könyvtár nem létezik, a script létrehozza." \
        12 "$DIALOG_WIDTH" "$default_dir" \
        3>&1 1>&2 2>&3) || log_error "Projekt könyvtár megadása megszakítva."

    [[ -z "$PROJECT_DIR" ]] && log_error "Projekt könyvtár nem lehet üres!"

    # Könyvtár létrehozása, ha nem létezik
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    log_ok "Munkakönyvtár: $PROJECT_DIR"

    # ── Git repó inicializálás ────────────────────────────────────────────────
    if [[ -d ".git" ]]; then
        log_ok "Git repó már létezik: $PROJECT_DIR/.git"
        REPO_EXISTS=true
    else
        git init
        log_ok "Git repó inicializálva: $PROJECT_DIR"
        REPO_EXISTS=false
    fi
    log_fn_exit
}

# =============================================================================
# 6. REMOTE ORIGIN BEÁLLÍTÁSA
# =============================================================================

# A kiválasztott GitHub repó SSH URL-jét beállítja origin remote-ként.
setup_remote_origin() {
    log_fn_enter
    log_section "Remote origin beállítása → ${SELECTED_REPO}"

    # ── Meglévő remote kezelése ───────────────────────────────────────────────
    if git remote get-url origin &>/dev/null; then
        local current_url
        current_url=$(git remote get-url origin)

        if [[ "$current_url" == "$SELECTED_REPO_URL" ]]; then
            log_ok "Remote origin már helyesen be van állítva: $current_url"
            return 0
        fi

        log_warn "Eltérő remote origin létezik: $current_url"

        if ! ask_yesno "Remote felülírás" \
            "A jelenlegi remote origin:\n${current_url}\n\nFelülírod ezzel:\n${SELECTED_REPO_URL}"; then
            log_info "Remote felülírás kihagyva."
            return 0
        fi

        git remote remove origin
    fi

    # Remote hozzáadása
    git remote add origin "$SELECTED_REPO_URL"
    log_ok "Remote origin beállítva: $SELECTED_REPO_URL"
    log_fn_exit
}

# =============================================================================
# 7. .GITIGNORE GENERÁLÁS
# =============================================================================

# Interaktívan megkérdezi, milyen típusú projekt, majd annak megfelelő
# .gitignore-t generál. Az alap sablonok mindig benne vannak.
create_gitignore() {
    log_fn_enter
    log_section ".gitignore generálás"

    # Ha már létezik, megkérdezi, felülírja-e
    if [[ -f ".gitignore" ]]; then
        if ! ask_yesno ".gitignore" \
            ".gitignore már létezik.\n\nFelülírod az automatikusan generáltra?\n(Nem = meglévő marad)"; then
            log_info ".gitignore változatlan."
            return 0
        fi
    fi

    # ── Projekt típus kiválasztása whiptail checklisttel ─────────────────────
    local selected_types
    selected_types=$(whiptail \
        --title ".gitignore – Projekt típus" \
        --checklist \
"Jelöld be a projektedhez tartozó technológiákat!
(SPACE = jelölés, ENTER = megerősítés)" \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$MENU_HEIGHT" \
        "python"    "Python / UV / pip / virtualenv"    ON  \
        "cuda"      "CUDA / NVIDIA GPU / PyTorch"       OFF \
        "ollama"    "Ollama / helyi LLM modellek"       OFF \
        "vllm"      "vLLM / quantizált modellek"        OFF \
        "docker"    "Docker / docker-compose"           OFF \
        "node"      "Node.js / npm / yarn"              OFF \
        "rust"      "Rust / Cargo"                      OFF \
        "zsh"       "ZSH / Oh My Zsh"                  OFF \
        "env"       "Környezeti változók (.env fájlok)" ON  \
        "ide"       "IDE fájlok (VSCode, JetBrains)"   ON  \
        3>&1 1>&2 2>&3) || { log_info ".gitignore generálás kihagyva."; return 0; }

    # .gitignore fájl írása
    write_gitignore "$selected_types"
    log_ok ".gitignore fájl létrehozva."
    log_fn_exit
}

# .gitignore fájl tartalmának megírása a kiválasztott típusok alapján
write_gitignore() {
    local types="$1"   # whiptail által visszaadott "python" "cuda" ... string

    cat > .gitignore <<'HEADER'
# =============================================================================
# .gitignore – claude-github-connector által generálva
# Dokumentáció: https://github.com/dr-watt/claude-github-connector
# =============================================================================

# ── Általános rendszerfájlok ──────────────────────────────────────────────────
.DS_Store
Thumbs.db
*.swp
*.swo
*~
.directory
*.bak
*.orig
*.tmp
tmp/
temp/
HEADER

    # Feltételes blokkok a kiválasztott típusok alapján
    if echo "$types" | grep -q "python"; then
        cat >> .gitignore <<'PYTHON'

# ── Python ────────────────────────────────────────────────────────────────────
# Dokumentáció: https://docs.python.org/3.12/
__pycache__/
*.py[cod]
*$py.class
*.so
*.egg
*.egg-info/
dist/
build/
.eggs/
# UV – https://docs.astral.sh/uv/
.venv/
.uv/
uv.lock
# Virtualenv
venv/
env/
ENV/
PYTHON
    fi

    if echo "$types" | grep -q "cuda"; then
        cat >> .gitignore <<'CUDA'

# ── CUDA / PyTorch modellek és checkpointok ──────────────────────────────────
# CUDA dokumentáció: https://docs.nvidia.com/cuda/
# PyTorch dokumentáció: https://docs.pytorch.org/docs/stable/index.html
*.pt
*.pth
*.ckpt
*.safetensors
*.bin
checkpoints/
runs/
wandb/
mlruns/
CUDA
    fi

    if echo "$types" | grep -q "ollama"; then
        cat >> .gitignore <<'OLLAMA'

# ── Ollama – helyi LLM modellek ───────────────────────────────────────────────
# Dokumentáció: https://ollama.readthedocs.io/en/
.ollama/
ollama_models/
*.gguf
*.ggml
OLLAMA
    fi

    if echo "$types" | grep -q "vllm"; then
        cat >> .gitignore <<'VLLM'

# ── vLLM / TurboQuant – quantizált modellek ──────────────────────────────────
# vLLM dokumentáció: https://docs.vllm.ai/en/latest/
# TurboQuant: https://github.com/0xSero/turboquant
vllm_cache/
model_cache/
turboquant_output/
quantized_models/
*.gguf
*.ggml
VLLM
    fi

    if echo "$types" | grep -q "docker"; then
        cat >> .gitignore <<'DOCKER'

# ── Docker ────────────────────────────────────────────────────────────────────
# Dokumentáció: https://docs.docker.com/
.docker/
docker-compose.override.yml
DOCKER
    fi

    if echo "$types" | grep -q "node"; then
        cat >> .gitignore <<'NODE'

# ── Node.js ───────────────────────────────────────────────────────────────────
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.npm
.yarn/cache
dist/
.next/
.nuxt/
NODE
    fi

    if echo "$types" | grep -q "rust"; then
        cat >> .gitignore <<'RUST'

# ── Rust / Cargo ──────────────────────────────────────────────────────────────
target/
Cargo.lock
**/*.rs.bk
RUST
    fi

    if echo "$types" | grep -q "zsh"; then
        cat >> .gitignore <<'ZSH'

# ── ZSH / Oh My Zsh ──────────────────────────────────────────────────────────
# ZSH dokumentáció: https://zsh.sourceforge.io/Doc/
# Oh My Zsh: https://github.com/ohmyzsh/ohmyzsh/wiki
.zsh_history
.zcompdump*
ZSH
    fi

    if echo "$types" | grep -q "env"; then
        cat >> .gitignore <<'ENV'

# ── Környezeti változók és titkok ─────────────────────────────────────────────
.env
.env.*
!.env.example
*.secret
secrets/
*.pem
*.key
*.p12
*.pfx
ENV
    fi

    if echo "$types" | grep -q "ide"; then
        cat >> .gitignore <<'IDE'

# ── IDE és szerkesztők ────────────────────────────────────────────────────────
.idea/
.vscode/
*.code-workspace
.vim/
*.iml
IDE
    fi

    # Naplófájlok – mindig benne van
    cat >> .gitignore <<'LOGS'

# ── Naplófájlok ───────────────────────────────────────────────────────────────
*.log
logs/
*.log.*
LOGS
}

# =============================================================================
# 8. SZINKRONIZÁLÁS (FETCH → PULL → COMMIT → PUSH)
# =============================================================================

# Szinkronizálja a lokális repót a kiválasztott GitHub remote-tal.
# Helyes sorrend: ci.yml → main branch → COMMIT → fetch → pull → push
# FONTOS: a commit-nak ELŐBB kell történnie a pull előtt!
# Ha pull után commitolunk, a pull --rebase "unstaged changes" hibával leáll.
sync_with_remote() {
    log_fn_enter
    log_section "Szinkronizálás → ${SELECTED_REPO}"

    # ── ci.yml áthelyezése .github/workflows/ alá ────────────────────────────
    # GitHub Actions csak a .github/workflows/ mappából olvassa a pipeline-t.
    if [[ -f "ci.yml" && ! -f ".github/workflows/ci.yml" ]]; then
        log_info "ci.yml áthelyezése .github/workflows/ könyvtárba..."
        mkdir -p ".github/workflows"
        mv "ci.yml" ".github/workflows/ci.yml"
        log_ok "CI pipeline áthelyezve: .github/workflows/ci.yml"
    fi

    # ── Main branch biztosítása ───────────────────────────────────────────────
    if ! git rev-parse --verify main &>/dev/null; then
        log_info "Lokális 'main' branch létrehozása..."
        git checkout -b main
    else
        git checkout main 2>/dev/null || true
    fi

    # ── 1. LÉPÉS: Lokális változások commitolása ELŐBB ───────────────────────
    # Pull --rebase csak clean working tree-vel működik.
    # Ezért ELŐSZÖR stage-elünk és commitolunk, UTÁNA pull-olunk.
    local changed
    changed=$(git status --porcelain | wc -l)

    if [[ "$changed" -gt 0 ]]; then
        git add -A
        local commit_msg
        commit_msg="chore: projekt csatlakoztatva GitHub repóhoz

Csatlakoztatott repó: ${SELECTED_REPO}
Felhasználó: @${GIT_USERNAME}
Platform: $(uname -srm)
Dátum: $(date '+%Y-%m-%d %H:%M:%S')
Eszköz: ${SCRIPT_NAME} v${VERSION} (${REPO_URL})"
        git commit -m "$commit_msg"
        log_ok "Lokális commit létrehozva."
    else
        log_info "Nincs helyi változás commitolni."
    fi

    # ── 2. LÉPÉS: Fetch ───────────────────────────────────────────────────────
    log_info "Fetch: remote branch-ek frissítése..."
    git fetch origin 2>/dev/null \
        && log_ok "Fetch kész." \
        || log_warn "Fetch sikertelen (esetleg üres remote, ez normális első futásnál)."

    # ── 3. LÉPÉS: Pull – ha a remote-on van tartalom ─────────────────────────
    # Most már nincs unstaged change (commitoltuk), a pull --rebase működik.
    # Ha mégis ütközne, megpróbálja merge-szel.
    if git ls-remote --exit-code origin main &>/dev/null; then
        log_info "Remote main branch létezik → pull --rebase..."
        if git pull --rebase origin main 2>/dev/null; then
            log_ok "Pull (rebase) kész."
        else
            log_warn "Rebase sikertelen – merge módban próbálom..."
            git rebase --abort 2>/dev/null || true
            if git pull --no-rebase origin main 2>/dev/null; then
                log_ok "Pull (merge) kész."
            else
                log_warn "Pull sikertelen – push --force-with-lease-szel próbálom."
            fi
        fi
    else
        log_info "Remote repó üres – első push lesz."
    fi

    # ── 4. LÉPÉS: Push ───────────────────────────────────────────────────────
    # SSH kulcs agent-hez adása push előtt
    log_info "SSH agent ellenőrzése push előtt..."
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" &>/dev/null
        log_info "ssh-agent elindítva."
    fi
    if ! ssh-add -l 2>/dev/null | grep -q "$(ssh-keygen -lf "${SSH_KEY_PATH}.pub" 2>/dev/null | awk '{print $2}')"; then
        log_info "SSH kulcs hozzáadása agent-hez (passphrase esetén most kéri)..."
        ssh-add "$SSH_KEY_PATH" || log_warn "ssh-add sikertelen – push megpróbálkozik kulcs nélkül is."
    fi

    log_info "Push → origin main..."
    if git push --set-upstream origin main 2>&1; then
        log_ok "Push sikeres! → https://github.com/${SELECTED_REPO}"
    else
        log_warn "Normál push sikertelen – force-with-lease próba (nem törli a remote commitokat)..."
        if git push --force-with-lease origin main 2>&1; then
            log_ok "Push (force-with-lease) sikeres! → https://github.com/${SELECTED_REPO}"
        else
            log_warn "Push sikertelen. Futtasd manuálisan: git push --force origin main"
        fi
    fi
    log_fn_exit
}

# =============================================================================
# 9. ÖSSZEFOGLALÓ
# =============================================================================

# Teljes összefoglaló és útmutatás megjelenítése a script végén
print_summary() {
    log_fn_enter
    log_section "Kész!"

    local repo_web_url="https://github.com/${SELECTED_REPO}"

    # Terminál összefoglaló
    echo ""
    echo -e "  ${C_GRN}${C_BOLD}✓ Projekt sikeresen csatlakoztatva a GitHub repóhoz!${C_RST}"
    echo ""
    echo -e "  ${C_BOLD}Repó:${C_RST}          $repo_web_url"
    echo -e "  ${C_BOLD}SSH URL:${C_RST}        $SELECTED_REPO_URL"
    echo -e "  ${C_BOLD}Felhasználó:${C_RST}    @${GIT_USERNAME}"
    echo -e "  ${C_BOLD}Könyvtár:${C_RST}       $PROJECT_DIR"
    echo ""
    echo -e "  ${C_BOLD}Git aliasok:${C_RST}"
    echo "    git st    → status -sb"
    echo "    git lg    → fa szerkezetű log"
    echo "    git last  → utolsó commit"
    echo "    git undo  → utolsó commit visszavon"
    echo "    git fp    → fetch --prune"
    echo ""
    echo -e "  ${C_BOLD}Claude GitHub App:${C_RST}  ${CLAUDE_APP_SETTINGS}"
    echo ""

    # Whiptail záró panel
    show_warning_box \
        "✅  Sikeres csatlakoztatás!" \
"A projekt sikeresen csatlakoztatva:

  Repó:    https://github.com/${SELECTED_REPO}
  User:    @${GIT_USERNAME}
  Könyv:   ${PROJECT_DIR}

HASZNOS PARANCSOK:
──────────────────────────────────────────
  git st          → változások áttekintése
  git add -A      → minden fájl staging-be
  git commit -m   → commit üzenettel
  git push        → feltöltés GitHub-ra
  git pull        → letöltés GitHub-ról
  git lg          → fa szerkezetű history

CLAUDE GITHUB APP BEÁLLÍTÁS:
  ${CLAUDE_APP_SETTINGS}

Ez az eszköz: ${REPO_URL}"

    # ── Log fájl helye a végén ────────────────────────────────────────────────
    echo ""
    echo -e "  ${C_CYN}[LOG]${C_RST}   Teljes futási napló: ${LOG_FILE}"
    echo ""
    log_fn_exit
}

# =============================================================================
# FŐPROGRAM
# =============================================================================
main() {
    clear
    echo -e "${C_BLU}${C_BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║        claude-github-connector  v${VERSION}              ║"
    echo "  ║        Univerzális Claude Projekt ↔ GitHub Tool          ║"
    echo "  ║        ${REPO_URL}      ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${C_RST}"
    echo -e "  ${C_CYN}[LOG]${C_RST}  Futási napló: ${LOG_FILE}"
    echo -e "  ${C_CYN}[LOG]${C_RST}  Ha a script elszáll, futtasd: cat ${CRASH_FILE}"
    echo ""

    # ── 0. lépés: Rendszerdiagnosztika – MINDIG ELSŐ ──────────────────────────
    # Minden környezeti információ rögzítése a log fájlba,
    # hogy hiba esetén pontosan látsszék, mi okozta a problémát.
    diag_system

    # Futtatási sorrend – minden lépés hibája leállítja a scriptet,
    # az ERR trap rögzíti a crash report-ot a log fájlba.
    install_dependencies        # 0. Függőségek (git, gh, whiptail, jq...)
    show_prerequisites_warning  # 1. Előfeltétel figyelmeztetések (TUI panel)
    authenticate_github_cli     # 2. GitHub CLI OAuth hitelesítés
    setup_ssh_key               # 3. SSH kulcs generálás + GitHub regisztráció
    select_github_repo          # 4. Interaktív repó választó (whiptail menü)
    init_local_repo             # 5. Lokális Git repó inicializálás
    create_gitignore            # 6. .gitignore generálás (interaktív)
    setup_remote_origin         # 7. Remote origin SSH URL beállítása
    sync_with_remote            # 8. Fetch → pull → commit → push
    print_summary               # 9. Összefoglaló
}

# Script csak közvetlen hívás esetén fut le, source-oláskor nem
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
