# CROAD K20 → 맥용 스트림덱

씽크웨이 CROAD K20 매크로 키패드(21키)를 macOS에서 스트림덱처럼 쓰기 위한 설정.

## 배경: K20의 특성

- 전용 "키보드 매니저" 소프트웨어는 **Windows 전용** (맥용 없음).
- 하지만 **일반 모드에서는 평범한 USB 숫자패드**로 동작 → 맥에서 Karabiner로 처리 가능.
- 매크로 모드로 저장한 하드웨어 매크로는 온보드 재생이라 이론상 맥에서도 동작하지만,
  녹화/수정에 Windows가 필요하므로 이 프로젝트는 **일반 모드 + 맥 소프트웨어 조합**을 사용한다.

## 아키텍처

```
K20 (일반 모드, 숫자패드 키 전송)
  → Karabiner-Elements: K20 기기에서 온 입력만 F13~F20 × (Hyper·Shift+Hyper) 조합으로 변환
  → Hammerspoon: 레이어 × 앱별 프로필 → 액션 실행
```

메인 키보드의 숫자키는 영향받지 않는다 (vendor_id/product_id로 기기 필터링).

## 설치 순서

### 1. 도구 설치

```bash
brew install --cask karabiner-elements hammerspoon
```

설치 후 시스템 설정 > 개인정보 보호 및 보안 > 입력 모니터링/손쉬운 사용에서
Karabiner와 Hammerspoon 권한 허용.

### 2. K20 기기 ID 확인

K20을 꽂고 **일반 모드**(매크로 스위치 OFF)로 둔 뒤:

- Karabiner-EventViewer 앱 실행 → Devices 탭에서 K20의 Vendor ID / Product ID 확인
- 또는 `./scripts/detect-keypad.sh` 실행

확인한 값(10진수)으로 `karabiner/k20-rules.json` 안의 `9999` 자리(vendor_id/product_id)를
전부 치환:

```bash
sed -i '' 's/"vendor_id": 9999/"vendor_id": <확인한값>/g; s/"product_id": 9999/"product_id": <확인한값>/g' karabiner/k20-rules.json
```

### 3. Karabiner 규칙 설치

```bash
mkdir -p ~/.config/karabiner/assets/complex_modifications
cp karabiner/k20-rules.json ~/.config/karabiner/assets/complex_modifications/
```

Karabiner-Elements 설정 → Complex Modifications → Add rule → "CROAD K20 → 스트림덱 키" 활성화.

주의: EventViewer에서 실제 키코드가 예상(keypad_0~9 등)과 다르면 json의 `from.key_code`를
실제 값으로 수정. K20의 계산기/더블클릭 같은 특수키는 consumer 키코드일 수 있음.

### 4. Hammerspoon 설정 연결

```bash
cp hammerspoon/keymap.example.json hammerspoon/keymap.json
mkdir -p ~/.hammerspoon && ln -sf "$(pwd)/hammerspoon/init.lua" ~/.hammerspoon/init.lua
```

`keymap.json`은 개인 키 설정 파일이라 git에 올라가지 않는다 (예시는 `keymap.example.json`).
키 배치는 설정 UI(메뉴바 ⌨ 아이콘 → 설정 열기)에서 편집한다 — 저장 즉시 반영.
데스크톱 미니 위젯은 메뉴바 → 위젯 → 컴팩트/확장으로 켠다.

Hammerspoon 실행 → 메뉴바 아이콘 → Reload Config. "K20 스트림덱 로드됨" 알림이 뜨면 성공.

## 키 배치표 (2026-07-24 실측 기준)

macOS 가상 키코드는 **F20까지만 존재**하므로 F21~F24는 쓰지 않고,
F13~F20 × (없음 / Hyper / Shift+Hyper) 조합으로 24슬롯을 만든다.
Hammerspoon에서 쓰는 키 ID는 `f13`~`f20`, `hyper+f13`~, `s-hyper+f13`~ 형식.

물리 배치 (실측, 6행×4열 — `+`와 `Enter`는 세로 2칸, `0`은 가로 2칸):

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
Num 키를 눌러도 (hyper+f13 발동 + 펌웨어 NumLock 토글) 배치는 변하지 않는다.

어느 물리 키가 어떤 ID인지 헷갈리면 그냥 눌러보면 된다 —
미할당 키는 화면에 `① 일반 · s-hyper+f15 (미할당)` 식으로 키 ID가 뜬다.

## 사용법

- 키 배치/액션은 전부 `hammerspoon/init.lua`의 `LAYERS` 테이블에서 수정.
  파일 저장하면 자동 리로드된다.
- `hyper+f17` 키(기본: 키패드 좌상단 쪽) = 레이어 순환 전환.
- 앱별 프로필: `profiles["앱이름"]`에 키를 정의하면 그 앱이 앞에 있을 때 우선 적용,
  없으면 `default`로 폴백.

## 확장 아이디어

- OBS 제어: obs-websocket + `hs.execute` curl 호출로 장면 전환
- 짧게/길게 누르기 구분: `hs.eventtap`으로 keyDown/keyUp 간격 측정
- macOS 단축어 연동: `shortcuts run '단축어이름'` → HomeKit/집중모드까지 제어
- 창 배치: `hs.window` API로 좌/우 절반, 모니터 이동
