#!/bin/zsh
# CROAD K20 키패드의 vendor_id / product_id를 찾는 스크립트.
# 키패드를 USB에 꽂은 뒤 실행하세요.
#
# 사용법: ./scripts/detect-keypad.sh

echo "== 연결된 HID 키보드 장치 목록 =="
hidutil list --matching '{"DeviceUsagePage":1,"DeviceUsage":6}' 2>/dev/null \
  | awk 'NR==1 || tolower($0) ~ /keyboard|keypad|usb/'

echo ""
echo "== ioreg 기준 USB 장치 =="
ioreg -p IOUSB -l 2>/dev/null \
  | grep -E '"USB Product Name"|"idVendor"|"idProduct"' \
  | paste - - - 2>/dev/null

echo ""
echo "위 목록에서 K20으로 보이는 장치의 VendorID / ProductID (10진수)를"
echo "karabiner/k20-rules.json 안의 vendor_id / product_id 값에 넣으세요."
echo "장치를 못 찾겠으면: Karabiner-EventViewer 앱 > Devices 탭이 가장 확실합니다."
