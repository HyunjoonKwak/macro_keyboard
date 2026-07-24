#!/bin/bash
# CROAD K20 → 맥용 스트림덱 설치 마법사
# 사용법:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HyunjoonKwak/macro_keyboard/main/install.sh)"
# 또는 저장소를 클론한 뒤: ./install.sh
set -u

REPO_URL="https://github.com/HyunjoonKwak/macro_keyboard.git"
DEFAULT_REPO_DIR="$HOME/macro_keyboard"
STAMP="$(date +%Y%m%d%H%M%S)"

# ---------- 출력 헬퍼 ----------
if [ -t 1 ]; then
  BOLD="$(tput bold)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"; RESET="$(tput sgr0)"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
step()  { echo; echo "${BOLD}[$1/8] $2${RESET}"; }
ok()    { echo "  ${GREEN}✅ $1${RESET}"; }
warn()  { echo "  ${YELLOW}⚠️  $1${RESET}"; }
fail()  { echo "  ${RED}❌ $1${RESET}"; }

# 터미널이 없으면(파이프 실행 등) 확인 없이 진행 가능한 부분만 진행
TTY_DEV="/dev/tty"
HAS_TTY=0
if [ -r "$TTY_DEV" ] && [ -w "$TTY_DEV" ]; then HAS_TTY=1; fi
ask() { # ask "질문" -> 0(yes)/1(no)
  if [ "$HAS_TTY" = 1 ]; then
    printf "%s [y/N] " "$1" > "$TTY_DEV"
    read -r answer < "$TTY_DEV" || answer=""
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
  return 1
}
pause() { # pause "안내문"
  if [ "$HAS_TTY" = 1 ]; then
    printf "%s (완료했으면 Enter) " "$1" > "$TTY_DEV"
    read -r _ < "$TTY_DEV" || true
  else
    echo "  → $1"
  fi
}

echo "${BOLD}================================================="
echo " CROAD K20 → 맥용 스트림덱 설치 마법사"
echo "=================================================${RESET}"
echo "설치 내용: Homebrew(필요시) · Karabiner-Elements · Hammerspoon"
echo "          키 매핑 규칙 · 설정 UI · 런처 앱(K20 스트림덱.app)"

# ---------- 1. 환경 확인 ----------
step 1 "환경 확인"
if [ "$(uname -s)" != "Darwin" ]; then fail "macOS 전용 스크립트입니다."; exit 1; fi
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then BREW_PREFIX="/opt/homebrew"; else BREW_PREFIX="/usr/local"; fi
ok "macOS ($ARCH), Homebrew 경로: $BREW_PREFIX"

# ---------- 2. Homebrew ----------
step 2 "Homebrew 확인"
BREW="$BREW_PREFIX/bin/brew"
if ! command -v brew >/dev/null 2>&1 && [ ! -x "$BREW" ]; then
  warn "Homebrew가 설치되어 있지 않습니다."
  if ask "지금 Homebrew를 설치할까요? (관리자 암호 필요)"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < "$TTY_DEV" || {
      fail "Homebrew 설치 실패. https://brew.sh 참고 후 다시 실행해 주세요."; exit 1; }
  else
    fail "Homebrew 없이 진행할 수 없습니다. https://brew.sh 에서 설치 후 다시 실행해 주세요."
    exit 1
  fi
fi
command -v brew >/dev/null 2>&1 || eval "$("$BREW" shellenv)"
ok "Homebrew: $(command -v brew)"

# ---------- 3. 앱 설치 ----------
step 3 "Karabiner-Elements · Hammerspoon 설치"
if [ -d "/Applications/Karabiner-Elements.app" ]; then
  ok "Karabiner-Elements 이미 설치됨"
else
  brew install --cask karabiner-elements || { fail "Karabiner 설치 실패"; exit 1; }
  ok "Karabiner-Elements 설치됨"
fi
if [ -d "/Applications/Hammerspoon.app" ]; then
  ok "Hammerspoon 이미 설치됨"
else
  brew install --cask hammerspoon || { fail "Hammerspoon 설치 실패"; exit 1; }
  ok "Hammerspoon 설치됨"
fi

# ---------- 4. 저장소 준비 ----------
step 4 "설정 저장소 준비"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/hammerspoon/keymap.example.json" ]; then
  REPO_DIR="$SCRIPT_DIR"
  ok "현재 저장소 사용: $REPO_DIR"
else
  REPO_DIR="$DEFAULT_REPO_DIR"
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 && ok "기존 저장소 업데이트: $REPO_DIR" \
      || warn "저장소 업데이트 실패(기존 버전 사용): $REPO_DIR"
  else
    git clone "$REPO_URL" "$REPO_DIR" || { fail "저장소 클론 실패"; exit 1; }
    ok "저장소 클론: $REPO_DIR"
  fi
fi
[ -f "$REPO_DIR/hammerspoon/keymap.example.json" ] || { fail "저장소 내용이 올바르지 않습니다."; exit 1; }

# 개인 키맵 생성 (있으면 보존)
if [ -f "$REPO_DIR/hammerspoon/keymap.json" ]; then
  ok "keymap.json 이미 존재 (보존)"
else
  cp "$REPO_DIR/hammerspoon/keymap.example.json" "$REPO_DIR/hammerspoon/keymap.json"
  ok "keymap.json 생성 (예시 복사)"
fi

# ---------- 5. Hammerspoon 연결 ----------
step 5 "Hammerspoon 설정 연결"
mkdir -p "$HOME/.hammerspoon"
HS_INIT="$HOME/.hammerspoon/init.lua"
TARGET="$REPO_DIR/hammerspoon/init.lua"
if [ -e "$HS_INIT" ] && [ "$(readlink "$HS_INIT" 2>/dev/null)" != "$TARGET" ]; then
  if [ ! -L "$HS_INIT" ]; then
    mv "$HS_INIT" "$HS_INIT.backup-$STAMP"
    warn "기존 init.lua를 백업했습니다: init.lua.backup-$STAMP"
  fi
fi
ln -sf "$TARGET" "$HS_INIT"
ok "심링크: ~/.hammerspoon/init.lua → $TARGET"

# ---------- 6. Karabiner 규칙 ----------
step 6 "Karabiner 키 매핑 규칙 설치"
mkdir -p "$HOME/.config/karabiner/assets/complex_modifications"
cp "$REPO_DIR/karabiner/k20-rules.json" "$HOME/.config/karabiner/assets/complex_modifications/"
KARABINER_JSON="$HOME/.config/karabiner/karabiner.json"
[ -f "$KARABINER_JSON" ] && cp "$KARABINER_JSON" "$KARABINER_JSON.backup-$STAMP"
RULES_FILE="$REPO_DIR/karabiner/k20-rules.json" KARABINER_JSON="$KARABINER_JSON" python3 - <<'PYEOF'
import json, os

rules_file = os.environ["RULES_FILE"]
config_path = os.environ["KARABINER_JSON"]
rules = json.load(open(rules_file))["rules"]
device = {
    "identifiers": {"vendor_id": 7276, "product_id": 49160, "is_pointing_device": True},
    "ignore": False,
}

if os.path.exists(config_path):
    config = json.load(open(config_path))
else:
    config = {"profiles": [{
        "name": "Default profile",
        "selected": True,
        "virtual_hid_keyboard": {"keyboard_type_v2": "ansi"},
    }]}

profiles = config.setdefault("profiles", [])
if not profiles:
    profiles.append({"name": "Default profile", "selected": True})
profile = next((p for p in profiles if p.get("selected")), profiles[0])

# 기존 K20 규칙 제거 후 최신 규칙 추가 (다른 규칙은 보존)
cm = profile.setdefault("complex_modifications", {})
existing = cm.setdefault("rules", [])
existing[:] = [r for r in existing if "K20" not in r.get("description", "")]
existing.extend(rules)

devices = profile.setdefault("devices", [])
if not any(
    d.get("identifiers", {}).get("vendor_id") == 7276
    and d.get("identifiers", {}).get("product_id") == 49160
    and d.get("identifiers", {}).get("is_pointing_device")
    for d in devices
):
    devices.append(device)

json.dump(config, open(config_path, "w"), ensure_ascii=False, indent=4)
print("  merged")
PYEOF
ok "규칙 병합 완료 (기존 설정은 karabiner.json.backup-$STAMP 로 백업)"

# ---------- 7. 앱 실행과 보안 승인 ----------
step 7 "앱 실행과 macOS 보안 승인"
open -a "Karabiner-Elements" 2>/dev/null || true
open -a "Hammerspoon" 2>/dev/null || true
sleep 2
echo "  macOS 보안 정책상 아래 3가지는 직접 승인해야 합니다."

echo
echo "  ${BOLD}7-1. Karabiner 드라이버 확장 승인${RESET}"
echo "       열리는 설정 화면에서 '드라이버 확장 프로그램' 항목의"
echo "       Karabiner-DriverKit-VirtualHIDDevice 를 허용하세요."
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension" 2>/dev/null || true
pause "승인"
DRIVER_OK=0
for _ in 1 2 3; do
  if systemextensionsctl list 2>/dev/null | grep -q "activated enabled"; then DRIVER_OK=1; break; fi
  pause "아직 승인이 확인되지 않습니다. 승인 후"
done
[ "$DRIVER_OK" = 1 ] && ok "드라이버 확장 활성화 확인" || warn "드라이버 상태를 확인하지 못했습니다 (나중에 재확인 필요)"

echo
echo "  ${BOLD}7-2. 입력 모니터링 허용${RESET}"
echo "       목록에서 karabiner_grabber 를 켜세요."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
pause "허용"

echo
echo "  ${BOLD}7-3. 손쉬운 사용 허용${RESET}"
echo "       목록에서 Hammerspoon 을 켜세요."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
pause "허용"

pkill -x Hammerspoon 2>/dev/null || true
sleep 1
open -a "Hammerspoon"
sleep 3

# ---------- 8. 런처 앱과 마무리 ----------
step 8 "런처 앱 생성과 최종 확인"
LAUNCHER="/Applications/K20 스트림덱.app"
if ! osacompile -o "$LAUNCHER" "$REPO_DIR/scripts/k20-launcher.applescript" 2>/dev/null; then
  mkdir -p "$HOME/Applications"
  LAUNCHER="$HOME/Applications/K20 스트림덱.app"
  osacompile -o "$LAUNCHER" "$REPO_DIR/scripts/k20-launcher.applescript" || warn "런처 앱 생성 실패"
fi
[ -d "$LAUNCHER" ] && ok "런처 앱: $LAUNCHER"

HS_CLI="$BREW_PREFIX/bin/hs"
if [ -x "$HS_CLI" ] && "$HS_CLI" -c "hs.autoLaunch(true)" >/dev/null 2>&1; then
  ok "Hammerspoon 로그인 시 자동 시작 설정"
else
  warn "자동 시작 설정은 손쉬운 사용 승인 후 다시 실행하면 적용됩니다."
fi

echo
echo "${BOLD}================ 설치 결과 ================${RESET}"
[ -d "/Applications/Karabiner-Elements.app" ] && ok "Karabiner-Elements" || fail "Karabiner-Elements"
[ -d "/Applications/Hammerspoon.app" ] && ok "Hammerspoon" || fail "Hammerspoon"
[ "$(readlink "$HS_INIT" 2>/dev/null)" = "$TARGET" ] && ok "Hammerspoon 설정 연결" || fail "Hammerspoon 설정 연결"
grep -q "CROAD K20" "$KARABINER_JSON" 2>/dev/null && ok "Karabiner 규칙" || fail "Karabiner 규칙"
systemextensionsctl list 2>/dev/null | grep -q "activated enabled" && ok "드라이버 확장" || warn "드라이버 확장 (승인 확인 필요)"
[ -d "$LAUNCHER" ] && ok "K20 스트림덱.app" || warn "런처 앱"

echo
echo "${BOLD}사용법${RESET}"
echo "  · K20 키패드를 USB로 연결하세요 (일반 모드, 매크로 스위치 OFF)"
echo "  · 메뉴바 ⌨ 아이콘 또는 'K20 스트림덱' 앱 → 설정 화면"
echo "  · 키패드의 세로 [+] 키 → 레이어 전환"
echo "  · 문제가 있으면: Hammerspoon 메뉴바 아이콘 → Reload Config"
echo
