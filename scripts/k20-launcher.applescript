do shell script "open -ga Hammerspoon"
set settingsOpened to false
repeat 20 times
	try
		do shell script "HS=/opt/homebrew/bin/hs; [ -x $HS ] || HS=/usr/local/bin/hs; $HS -c 'k20OpenSettings()'"
		set settingsOpened to true
		exit repeat
	on error
		delay 0.5
	end try
end repeat
if not settingsOpened then
	display dialog "Hammerspoon을 시작하지 못했습니다. Hammerspoon 앱을 직접 실행해 주세요." buttons {"확인"} default button 1
end if
