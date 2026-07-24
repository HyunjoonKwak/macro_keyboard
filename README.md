# CROAD K20 → 맥용 스트림덱

씽크웨이 CROAD K20 매크로 키패드(21키)를 macOS에서 스트림덱처럼 쓰는 프로젝트.
Karabiner-Elements(키 변환)와 Hammerspoon(엔진·UI) 위에서 동작하며,
설정은 GUI로 편집하고 파일(`keymap.json`) 하나로 관리된다.

## 주요 기능

- **레이어**: 키 세트 여러 벌을 `+` 키로 순환, 직행 키·메뉴바·위젯으로도 전환. 레이어별 색상
- **앱 자동 전환 (스마트 프로필)**: 레이어에 앱을 연결하면 그 앱이 앞으로 올 때
  키패드 전체가 자동 전환, 떠나면 복귀. 한 앱에 여러 세트 연결 가능
- **앱 프로필**: 같은 레이어 안에서 특정 앱이 앞에 있을 때만 일부 키를 덮어쓰기
- **액션 10종**: 앱 실행 · URL · 키 조합 · 텍스트 입력 · 셸 명령 · macOS 단축어 ·
  미디어 · 마이크 토글 · 레이어 이동 · 매크로(연속 실행, delay 지원)
- **길게 누르기**: 한 키에 짧게/길게(0.45초) 두 가지 동작
- **아이콘**: 이모지 팔레트, 이미지 파일(jpg/png 등), 앱 실행 키는 실제 앱 아이콘 자동 표시
- **상태 아이콘**: 마이크 키는 음소거 상태에 따라 빨강/초록 + 🎙/🔇 실시간 반영
- **설정 UI**: 실물 배치 그대로의 편집 화면, 프리셋 18종, 키 복사/붙여넣기, 도움말
- **데스크톱 위젯**: 컴팩트/확장 모드, 자유 드래그, 항상 위/데스크톱 고정, 불투명도 조절,
  K20 연결 시 자동 표시·분리 시 자동 숨김
- **레이어 HUD**: 위젯이 꺼져 있으면 레이어 전환 순간 1.5초 미니맵 표시

## 설치 (다른 맥 포함)

터미널에서 한 줄이면 됩니다 — 필요한 앱 설치 유도부터 보안 승인 안내까지 마법사가 진행합니다:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HyunjoonKwak/macro_keyboard/main/install.sh)"
```

또는 저장소를 받아서:

```bash
git clone https://github.com/HyunjoonKwak/macro_keyboard.git && cd macro_keyboard && ./install.sh
```

마법사가 하는 일: Homebrew·Karabiner-Elements·Hammerspoon 확인/설치 → 키 매핑 규칙 설치
(기존 Karabiner 설정은 백업 후 병합) → 설정 연결 → macOS 보안 승인 3종 안내 →
"K20 스트림덱.app" 런처 생성. 재실행해도 안전하다(멱등).

<details>
<summary>수동 설치 (참고용)</summary>

1. `brew install --cask karabiner-elements hammerspoon`
2. K20 연결 후 Karabiner-EventViewer의 Devices 탭에서 Vendor/Product ID 확인
   (기본 규칙은 7276/49160 기준 — CROAD K20이면 그대로 사용)
3. `cp karabiner/k20-rules.json ~/.config/karabiner/assets/complex_modifications/`
   → Karabiner 설정 → Complex Modifications → Add rule로 활성화
4. `cp hammerspoon/keymap.example.json hammerspoon/keymap.json`
5. `ln -sf "$(pwd)/hammerspoon/init.lua" ~/.hammerspoon/init.lua`
6. 시스템 설정에서 승인: 드라이버 확장(Karabiner), 입력 모니터링(karabiner_grabber),
   손쉬운 사용(Hammerspoon)

</details>

## 구성 요소

| 구성 요소 | 역할 |
|---|---|
| K20 스트림덱.app | Launchpad/Dock에서 실행하는 런처 — 설정 창을 연다 |
| 메뉴바 `⌨①` | 현재 레이어 표시, 레이어 점프, 설정 열기, 위젯 제어 |
| 데스크톱 위젯 | 상시 키 배치 표시(스트림덱 LCD 대용), 키 클릭 → 편집 진입 |
| Hammerspoon | 엔진 — 로그인 시 자동 시작, K20 연결/분리 자동 감지 |
| Karabiner-Elements | K20 전용 키 변환 — 메인 키보드에는 영향 없음 |

시스템은 상주형이라 K20을 언제 꽂아도 즉시 동작한다.

## 사용법

- **키 설정**: "K20 스트림덱" 앱(또는 메뉴바 → 설정 열기) → 배치도에서 키 클릭 →
  동작·라벨·아이콘 편집 → 저장하면 **재시작 없이 즉시 반영**
- **레이어 관리**: 상단 탭 `+`로 추가, 활성 탭 `⋯`에서 이름 변경·색상·앱 연결·이동·삭제
- **프리셋**: "프리셋" 버튼 → 18종(Zoom·Xcode·Chrome·Keynote·CapCut·PowerPoint·Excel·
  iMovie·GarageBand·창 배치·캡처 등) → "새 레이어로 추가"하면 색상·앱 자동 연결까지 세팅
- **앱 프로필**: 프로필 드롭다운 → "+ 앱 프로필 추가" → 설치 앱 목록에서 선택
- **매크로 문법**: 한 줄에 하나씩 — `app:이름` `url:주소` `keys:cmd+shift+t` `text:문구`
  `shell:명령` `shortcut:단축어` `media:PLAY` `mic` `layer:이름` `delay:0.5`
- **길게 누르기**: 키 편집의 "길게 누르기 동작"에 같은 문법으로 입력 (여러 개는 `;` 구분)
- **위젯**: 드래그로 이동, `✥` 모서리 순환, `▣` 확장/축소, `⛭` 설정.
  모드·표시 레벨·불투명도는 설정 창 우측 하단 패널에서 조절

## 키 배치표 (실측 기준)

macOS 가상 키코드는 **F20까지만 존재**하므로 F13~F20 × (없음 / Hyper / Shift+Hyper)
조합으로 24슬롯을 만든다. 키 ID는 `f13`~`f20`, `hyper+f13`~, `s-hyper+f13`~ 형식.

물리 배치 (6행×4열 — `+`와 `Enter`는 세로 2칸, `0`은 가로 2칸):

```
[Esc     ] [Tab     ] [⌫       ] [Fn      ]
[Num M+  ] [/  M-   ] [*  MS   ] [-       ]
[7       ] [8       ] [9       ] [+       ]
[4       ] [5       ] [6       ] [ (레이어)]
[1       ] [2       ] [3       ] [Enter   ]
[0 Ins        ]      [.        ] [        ]
```

| 물리 키 | K20이 보내는 코드 (NumLock ON / OFF) | 키 ID |
|---|---|---|
| 7 8 9 | keypad 7/8/9 · home/↑/pgup | `f13` `f14` `f15` |
| 4 5 6 | keypad 4/5/6 · ←/(없음)/→ | `f16` `f17` `f18` |
| 1 2 | keypad 1/2 · end/↓ | `f19` `f20` |
| 3 | keypad 3 · pgdn | `s-hyper+f17` |
| 0 Ins | keypad 0 · insert | `s-hyper+f18` |
| . | keypad . · del⌦ | `s-hyper+f19` |
| Enter (세로) | keypad enter 또는 return | `s-hyper+f20` 또는 `s-hyper+f14` |
| Num / / / * / - | numlock, /, *, - | `hyper+f13`~`f16` |
| **+ (세로)** | keypad + | `hyper+f17` — **레이어 전환 (예약)** |
| Esc, Tab, ⌫ | esc, tab, backspace | `hyper+f19` `hyper+f20` `s-hyper+f13` |
| Fn | (신호 없음 — 펌웨어 전용) | 사용 불가 |
| Num | 마우스 인터페이스로 특수 신호 전송 — Karabiner가 흡수 (무해) | 사용 불가 |

NumLock 상태와 무관하게 같은 물리 키는 같은 키 ID로 수렴하도록 양쪽 코드를 모두 매핑했다.

## 파일 구조

```
install.sh                        설치 마법사 (대화형, 멱등)
karabiner/k20-rules.json          K20 전용 리매핑 규칙 (기기 필터링)
hammerspoon/init.lua              엔진: 디스패치·위젯·HUD·메뉴바·브리지
hammerspoon/ui.html               설정 UI (webview)
hammerspoon/keymap.example.json   예시 키맵 — 복사해서 keymap.json으로 사용
hammerspoon/keymap.json           개인 키맵 (git 제외)
hammerspoon/icons/                이미지 아이콘 저장소 (git 제외, auto/는 앱 아이콘 캐시)
scripts/k20-launcher.applescript  런처 앱 소스
scripts/detect-keypad.sh          기기 ID 탐지 보조
```

## 문제 해결

- **키패드 무반응**: 메뉴바에 `⌨` 아이콘이 있는지 확인 → 없으면 Spotlight에서
  Hammerspoon 실행. 매크로 스위치가 일반 모드(OFF)인지 확인
- **메뉴바 아이콘이 안 보임**: 아이콘이 많으면 macOS가 노치 뒤로 숨긴다 —
  위젯이 같은 기능을 하므로 위젯 사용 권장 (또는 메뉴바 정리 앱 사용)
- **설정 즉시 반영 안 됨**: Hammerspoon 메뉴바(해머 아이콘) → Reload Config
- **CLI 진단**: `hs -c "return #k20Layers"` 로 엔진 상태 확인 가능 (hs.ipc 활성화됨)
