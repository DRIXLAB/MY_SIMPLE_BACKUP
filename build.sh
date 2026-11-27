#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  build.sh  —  Compile l'application native « MY SIMPLE BACKUP » (SwiftUI)
#
#  Usage :
#    bash build.sh [options]
#
#  Options :
#    --debug          Configuration debug (release par défaut)
#    --skip-tests     Ne pas lancer les tests du moteur (swift test)
#    --install        Copier l'app dans /Applications après le build
#    --open           Lancer l'app après le build
#    -h, --help       Afficher cette aide
#
#  Seul Xcode 15+ est requis (Swift Package Manager), aucun outil tiers.
#  Signature : un certificat « Developer ID Application » ou « Apple Development »
#  du trousseau est utilisé automatiquement s'il existe (sinon signature ad hoc),
#  ou imposé avec : SIGN_IDENTITY="Apple Development: Nom (ID)" bash build.sh
# ──────────────────────────────────────────────────────────────────────────────

set -o pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
BLD='\033[1m'
RST='\033[0m'

ok()   { echo -e "  ${GRN}✓${RST}  $*"; }
info() { echo -e "  ${BLU}→${RST}  $*"; }
warn() { echo -e "  ${YLW}⚠${RST}  $*"; }
err()  { echo -e "  ${RED}✗${RST}  $*"; }
step() { echo -e "\n${BLD}── $* ──${RST}"; }
hr()   { echo -e "${BLD}────────────────────────────────────────────${RST}"; }

usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed -E 's/^#( {1,2}|$)//'; }

CONFIG="release"
RUN_TESTS=1
INSTALL=0
OPEN_APP=0
for arg in "$@"; do
    case "$arg" in
        --debug)      CONFIG="debug" ;;
        --skip-tests) RUN_TESTS=0 ;;
        --install)    INSTALL=1 ;;
        --open)       OPEN_APP=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            err "Option inconnue : $arg"; usage; exit 1 ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="MY SIMPLE BACKUP.app"
PRODUCT="SauvegardeMac"
APP_PATH="$DIST_DIR/$APP_NAME"

echo
hr
echo -e "${BLD}      Build — MY SIMPLE BACKUP (SwiftUI, $CONFIG)${RST}"
hr

# ── 1. Xcode ──────────────────────────────────────────────────────────────────
step "1/5  Xcode"

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "Ce script doit être lancé sur macOS."
    exit 1
fi

# xcode-select peut pointer vers les Command Line Tools seules (sans XCTest) :
# on utilise alors Xcode.app directement.
if ! xcodebuild -version &>/dev/null; then
    XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)"
    if [[ -n "$XCODE_APP" ]]; then
        export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
        info "xcode-select pointe vers $(xcode-select -p 2>/dev/null) — utilisation de $XCODE_APP"
        info "(pour corriger durablement : sudo xcode-select -s \"$DEVELOPER_DIR\")"
    fi
fi

if ! XCODE_VERSION="$(xcodebuild -version 2>&1 | head -1)" || [[ "$XCODE_VERSION" != Xcode* ]]; then
    err "xcodebuild ne fonctionne pas :"
    xcodebuild -version 2>&1 | sed 's/^/       /'
    err "Si la licence n'est pas acceptée : sudo xcodebuild -license accept"
    err "Si c'est le premier lancement d'Xcode : xcodebuild -runFirstLaunch"
    exit 1
fi

XCODE_MAJOR="$(echo "$XCODE_VERSION" | grep -oE '[0-9]+' | head -1)"
if [[ "$XCODE_MAJOR" -lt 15 ]]; then
    err "$XCODE_VERSION détecté — Xcode 15 minimum requis (Swift 5.9)."
    exit 1
fi
ok "$XCODE_VERSION — $(swift --version 2>/dev/null | grep -oE 'Swift version [0-9.]+' | head -1)"

mkdir -p "$LOG_DIR"
cd "$PROJECT_DIR" || exit 1

# Affiche les erreurs de compilation d'un journal, sans doublons.
show_errors() {
    echo
    grep -E '(error|fatal error):' "$1" | sort -u | head -40 | sed 's/^/    /'
    echo
    err "Journal complet : $1"
}

# ── 2. Tests du moteur ────────────────────────────────────────────────────────
step "2/5  Tests du moteur de copie"

if [[ $RUN_TESTS -eq 1 ]]; then
    TEST_LOG="$LOG_DIR/swift-test.log"
    info "swift test… (compile aussi l'application)"
    if swift test >"$TEST_LOG" 2>&1; then
        ok "$(grep -E 'Executed [0-9]+ tests?' "$TEST_LOG" | tail -1 | sed 's/^[[:space:]]*//')"
    else
        if grep -qE 'Executed [0-9]+ tests?' "$TEST_LOG"; then
            err "Des tests échouent — build interrompu (le moteur copie et supprime des fichiers)."
            grep -E 'error|failed' "$TEST_LOG" | head -30 | sed 's/^/       /'
            err "Journal complet : $TEST_LOG"
        else
            err "La compilation a échoué. Erreurs :"
            show_errors "$TEST_LOG"
        fi
        exit 1
    fi
else
    warn "Tests ignorés (--skip-tests)"
fi

# ── 3. Compilation ────────────────────────────────────────────────────────────
step "3/5  Compilation"

BUILD_LOG="$LOG_DIR/swift-build.log"
info "swift build -c ${CONFIG}… 1 à 3 minutes au premier build"
if ! swift build -c "$CONFIG" --product "$PRODUCT" >"$BUILD_LOG" 2>&1; then
    err "La compilation a échoué. Erreurs :"
    show_errors "$BUILD_LOG"
    exit 1
fi
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null)"
if [[ ! -x "$BIN_DIR/$PRODUCT" ]]; then
    err "Exécutable introuvable : $BIN_DIR/$PRODUCT"
    exit 1
fi
WARNINGS="$(grep -E ': warning:' "$BUILD_LOG" | sort -u | wc -l | tr -d ' ')"
ok "Compilation réussie ($WARNINGS avertissement(s), détails dans build/swift-build.log)"

# ── 4. Bundle .app et signature ───────────────────────────────────────────────
step "4/5  Assemblage de $APP_NAME"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP_PATH/Contents/MacOS/$PRODUCT"
cp "$PROJECT_DIR/Bundle/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Bundle/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
# Langues déclarées (menus macOS et demandes d'autorisation traduits)
cp -R "$PROJECT_DIR/Bundle/fr.lproj" "$PROJECT_DIR/Bundle/en.lproj" "$APP_PATH/Contents/Resources/"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
if ! plutil -lint -s "$APP_PATH/Contents/Info.plist" "$APP_PATH"/Contents/Resources/*.lproj/InfoPlist.strings; then
    err "Bundle/Info.plist ou un fichier InfoPlist.strings est invalide."
    exit 1
fi
# Le Finder met les icônes en cache : on signale la mise à jour du bundle.
touch "$APP_PATH"
ok "Bundle assemblé"

# Identité de signature : imposée, sinon Developer ID, sinon Apple Development, sinon ad hoc.
IDENTITY="$SIGN_IDENTITY"
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
    for kind in "Developer ID Application" "Apple Development"; do
        IDENTITY="$(echo "$IDENTITIES" | grep -F "\"$kind:" | head -1 | sed -E 's/.*"(.*)"/\1/')"
        [[ -n "$IDENTITY" ]] && break
    done
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"

if ! codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_PATH" 2>"$LOG_DIR/codesign.log"; then
    err "Échec de la signature avec « $IDENTITY » :"
    sed 's/^/       /' "$LOG_DIR/codesign.log"
    exit 1
fi
codesign --verify --strict "$APP_PATH" 2>/dev/null || warn "Vérification de la signature en échec."

if [[ "$IDENTITY" == "-" ]]; then
    warn "Signature ad hoc : l'accès complet au disque sera à redonner après chaque build."
    warn "Pour une signature stable : Xcode › Réglages › Comptes › ajouter votre Apple ID,"
    warn "puis « Gérer les certificats… » › + › Apple Development. Relancez ensuite build.sh."
else
    ok "Signée : $IDENTITY"
fi
ok "dist/$APP_NAME ($(du -sh "$APP_PATH" | cut -f1))"

# ── 5. Installation ───────────────────────────────────────────────────────────
step "5/5  Installation"

FINAL_APP="$APP_PATH"
if [[ $INSTALL -eq 1 ]]; then
    if pgrep -xq "$PRODUCT"; then
        err "MY SIMPLE BACKUP est ouverte : quittez-la puis relancez avec --install."
        exit 1
    fi
    rm -rf "/Applications/$APP_NAME"
    # Ancienne version installée sous l'ancien nom (même identifiant) : on la retire pour éviter
    # deux applications identiques dans le Launchpad. Vérifiée par son identifiant avant suppression.
    OLD_APP="/Applications/Sauvegarde Mac.app"
    if [[ -d "$OLD_APP" ]] && [[ "$(defaults read "$OLD_APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" == "com.cepe.sauvegarde-mac" ]]; then
        rm -rf "$OLD_APP" && ok "Ancienne version « Sauvegarde Mac.app » retirée de /Applications"
    fi
    ditto "$APP_PATH" "/Applications/$APP_NAME" || { err "Copie vers /Applications impossible."; exit 1; }
    FINAL_APP="/Applications/$APP_NAME"
    ok "Installée dans /Applications"
else
    info "Non installée (ajoutez --install pour copier dans /Applications)"
fi

echo
echo -e "${BLD}Application :${RST}  $FINAL_APP"
echo
echo -e "${BLD}${YLW}Accès complet au disque :${RST}"
echo "  Réglages Système › Confidentialité et sécurité › Accès complet au disque"
echo "  → ajouter « $FINAL_APP »"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'"

if [[ $OPEN_APP -eq 1 ]]; then
    open "$FINAL_APP"
    echo
    ok "Application lancée"
fi

echo
echo -e "  ${GRN}Build terminé !${RST}"
echo
