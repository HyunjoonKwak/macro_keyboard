-- CROAD K20 스트림덱 엔진
-- Karabiner가 K20 키를 F13~F20 (+Hyper / +Shift+Hyper)로 변환해서 보내면,
-- keymap.json의 앱별 프로필/레이어에 따라 액션을 실행한다.

local HYPER = { "cmd", "alt", "ctrl" }
local SHYPER = { "cmd", "alt", "ctrl", "shift" }

-- ~/.hammerspoon/init.lua 심링크의 실제 위치에서 설정 폴더를 찾는다 (맥마다 경로가 달라도 동작).
-- 심링크가 아니면(파일을 직접 복사한 경우) ~/.hammerspoon 자체를 사용.
local function resolveConfigDir()
  local link = hs.configdir .. "/init.lua"
  local pipe = io.popen("readlink " .. string.format("%q", link) .. " 2>/dev/null")
  local target = pipe and pipe:read("*l") or nil
  if pipe then pipe:close() end
  if target and #target > 0 then
    if not target:match("^/") then
      target = hs.configdir .. "/" .. target
    end
    local dir = target:match("^(.*)/[^/]+$")
    if dir then return dir .. "/" end
  end
  return hs.configdir .. "/"
end
local CONFIG_DIR = resolveConfigDir()
local KEYMAP_PATH = CONFIG_DIR .. "keymap.json"
local UI_PATH = CONFIG_DIR .. "ui.html"

-- hs 객체는 Lua GC로 사라지지 않도록 모두 전역에 보관한다.
k20ConfigWatcher = nil
k20Webview = nil
k20UserContentController = nil
k20Menubar = nil
k20HudCanvas = nil
k20HudTimer = nil
k20Widget = nil
k20WidgetFlashTimer = nil
k20WidgetSelectTimer = nil
k20WidgetMode = nil
k20WidgetLevel = nil
k20WidgetFlashing = false
k20WidgetDragState = nil
k20WidgetDragTap = nil
k20Hotkeys = {}
k20RawKeymap = nil
k20Layers = nil
k20LayerSwitchId = "hyper+f17"
k20CurrentLayer = 1

-- ===========================================================================
-- 액션 헬퍼
-- ===========================================================================
local function app(name)
  return function()
    if not hs.application.launchOrFocus(name) then
      hs.alert.show("⚠️ 앱을 찾을 수 없음: " .. name)
    end
  end
end

local function keystroke(mods, key)
  return function() hs.eventtap.keyStroke(mods, key) end
end

local function typeText(text)
  return function() hs.eventtap.keyStrokes(text) end
end

local function shell(cmd)
  return function() hs.execute(cmd, true) end
end

local function url(link)
  return function() hs.urlevent.openURL(link) end
end

local function shortcut(name)
  return function() hs.execute("shortcuts run " .. string.format("%q", name), true) end
end

local function media(key)
  return function()
    hs.eventtap.event.newSystemKeyEvent(key, true):post()
    hs.eventtap.event.newSystemKeyEvent(key, false):post()
  end
end

k20MicMuted = k20MicMuted or false

local function micToggle()
  local dev = hs.audiodevice.defaultInputDevice()
  local muted = not dev:muted()
  dev:setMuted(muted)
  k20MicMuted = muted
  hs.alert.show(muted and "🔇 마이크 OFF" or "🎙 마이크 ON")
  if k20RefreshViews then k20RefreshViews() end -- 위젯의 마이크 상태 아이콘 갱신
end

-- ===========================================================================
-- 설정 읽기와 검증
-- ===========================================================================
local MEDIA_KEYS = {
  PLAY = true,
  PREVIOUS = true,
  NEXT = true,
  SOUND_UP = true,
  SOUND_DOWN = true,
  MUTE = true,
}

local VALID_MODS = { cmd = true, alt = true, ctrl = true, shift = true }

local function warn(message)
  hs.alert.show("⚠️ K20 설정: " .. message)
end

local function isKeyId(id)
  if type(id) ~= "string" then return false end
  local base = id:match("^f(%d+)$")
      or id:match("^hyper%+f(%d+)$")
      or id:match("^s%-hyper%+f(%d+)$")
  local number = tonumber(base)
  return number ~= nil and number >= 13 and number <= 20
end

local function validateActionSpec(spec)
  if type(spec) ~= "table" or type(spec.type) ~= "string" then
    return false, "액션 객체 또는 type이 없음"
  end
  if spec.label ~= nil and type(spec.label) ~= "string" then
    return false, "label은 문자열이어야 함"
  end
  if spec.icon ~= nil and type(spec.icon) ~= "string" then
    return false, "icon은 문자열이어야 함"
  end
  if spec.image ~= nil then
    if type(spec.image) ~= "string" or spec.image == "" or spec.image:match("%.%.") then
      return false, "image는 icons/ 아래 상대 경로여야 함"
    end
  end
  if spec.hold ~= nil then
    if type(spec.hold) ~= "table" then return false, "hold 형식 오류" end
    if spec.hold.hold ~= nil then return false, "hold 안에 hold는 넣을 수 없음" end
    if spec.hold.type == "delay" then return false, "hold는 지연만으로는 안 됨" end
    local valid, reason = validateActionSpec(spec.hold)
    if not valid then return false, "길게 누르기: " .. reason end
  end

  if spec.type == "multi" then
    if type(spec.steps) ~= "table" or #spec.steps == 0 then
      return false, "매크로에는 1개 이상의 step이 필요함"
    end
    if #spec.steps > 50 then return false, "매크로 step은 50개 이하" end
    for index, step in ipairs(spec.steps) do
      if type(step) ~= "table" then return false, "step " .. index .. " 형식 오류" end
      if step.hold ~= nil then return false, "step " .. index .. ": 매크로 단계에는 hold 불가" end
      if step.type == "delay" then
        if type(step.seconds) ~= "number" or step.seconds < 0 or step.seconds > 60 then
          return false, "step " .. index .. ": 지연은 0~60초"
        end
      elseif step.type == "multi" then
        return false, "매크로 안에 매크로는 넣을 수 없음"
      else
        local valid, reason = validateActionSpec(step)
        if not valid then return false, "step " .. index .. ": " .. reason end
      end
    end
    return true
  end

  if spec.type == "mic" then
    if spec.arg ~= nil then return false, "mic에는 arg를 지정하지 않음" end
    return true
  elseif spec.type == "media" then
    if type(spec.arg) == "string" and MEDIA_KEYS[spec.arg] then return true end
    return false, "지원하지 않는 미디어 키"
  elseif spec.type == "keys" then
    if type(spec.mods) ~= "table" or type(spec.key) ~= "string" or spec.key == "" then
      return false, "keys에는 mods 배열과 key가 필요함"
    end
    local modCount = #spec.mods
    for index, mod in pairs(spec.mods) do
      if type(index) ~= "number" or index < 1 or index > modCount or index % 1 ~= 0 then
        return false, "mods는 배열이어야 함"
      end
      if not VALID_MODS[mod] then return false, "지원하지 않는 modifier" end
    end
    return true
  elseif spec.type == "app" or spec.type == "url" or spec.type == "text"
      or spec.type == "shell" or spec.type == "shortcut" then
    if type(spec.arg) == "string" and spec.arg ~= "" then return true end
    return false, spec.type .. "에는 arg 문자열이 필요함"
  end

  return false, "알 수 없는 액션 타입: " .. tostring(spec.type)
end

local runSteps

local function actionFromSpec(spec)
  if spec.type == "app" then return app(spec.arg) end
  if spec.type == "url" then return url(spec.arg) end
  if spec.type == "keys" then return keystroke(spec.mods, spec.key) end
  if spec.type == "text" then return typeText(spec.arg) end
  if spec.type == "shell" then return shell(spec.arg) end
  if spec.type == "shortcut" then return shortcut(spec.arg) end
  if spec.type == "media" then return media(spec.arg) end
  if spec.type == "mic" then return micToggle end
  if spec.type == "multi" then
    return function() runSteps(spec.steps, 1) end
  end
  return nil
end

-- 매크로(multi): step을 순서대로 실행. 타이머는 GC 방지를 위해 전역 목록에 보관.
k20MultiTimers = k20MultiTimers or {}

local function keepTimer(timer)
  for i = #k20MultiTimers, 1, -1 do
    if not k20MultiTimers[i]:running() then table.remove(k20MultiTimers, i) end
  end
  table.insert(k20MultiTimers, timer)
end

runSteps = function(steps, index)
  local step = steps[index]
  if not step then return end
  local delay = 0.05 -- step 사이 기본 간격 (연속 키 입력 안정화)
  if step.type == "delay" then
    delay = step.seconds
  else
    local action = actionFromSpec(step)
    if action then action() end
  end
  if steps[index + 1] then
    keepTimer(hs.timer.doAfter(delay, function() runSteps(steps, index + 1) end))
  end
end

local function validateKeymapForSave(keymap)
  if type(keymap) ~= "table" then return false, "최상위 설정이 객체가 아님" end
  if not isKeyId(keymap.layerSwitchKey) then return false, "layerSwitchKey가 올바르지 않음" end
  if type(keymap.layers) ~= "table" or #keymap.layers == 0 then
    return false, "layers 배열이 비어 있음"
  end
  for layerIndex, layer in ipairs(keymap.layers) do
    if type(layer) ~= "table" or type(layer.name) ~= "string" or layer.name == "" then
      return false, "레이어 " .. layerIndex .. "의 name이 올바르지 않음"
    end
    if layer.color ~= nil
        and not (type(layer.color) == "string" and layer.color:match("^#%x%x%x%x%x%x$")) then
      return false, layer.name .. "의 color는 #RRGGBB 형식이어야 함"
    end
    if layer.appTrigger ~= nil
        and not (type(layer.appTrigger) == "string" and layer.appTrigger ~= "") then
      return false, layer.name .. "의 appTrigger는 앱 이름 문자열이어야 함"
    end
    if type(layer.profiles) ~= "table" then
      return false, layer.name .. "의 profiles가 객체가 아님"
    end
    for profileName, profile in pairs(layer.profiles) do
      if type(profileName) ~= "string" or type(profile) ~= "table" then
        return false, layer.name .. "의 프로필 형식이 올바르지 않음"
      end
      for id, spec in pairs(profile) do
        if not isKeyId(id) then return false, "올바르지 않은 키 ID: " .. tostring(id) end
        local valid, reason = validateActionSpec(spec)
        if not valid then
          return false, layer.name .. "/" .. profileName .. "/" .. id .. ": " .. reason
        end
      end
    end
  end
  return true
end

local function readKeymap()
  local ok, result = pcall(hs.json.read, KEYMAP_PATH)
  if not ok or type(result) ~= "table" then
    warn("keymap.json을 읽을 수 없음")
    return nil
  end
  return result
end

local function compileKeymap(raw)
  if type(raw) ~= "table" or type(raw.layers) ~= "table" then
    warn("layers 배열이 없음")
    return nil
  end

  local switchId = raw.layerSwitchKey
  if not isKeyId(switchId) then
    warn("layerSwitchKey가 잘못되어 hyper+f17 사용")
    switchId = "hyper+f17"
  end

  local layers = {}
  for layerIndex, layerSpec in ipairs(raw.layers) do
    if type(layerSpec) ~= "table" or type(layerSpec.name) ~= "string" or layerSpec.name == ""
        or type(layerSpec.profiles) ~= "table" then
      warn("레이어 " .. layerIndex .. " 형식이 잘못되어 건너뜀")
    else
      local layer = { name = layerSpec.name, profiles = {}, specs = {} }
      if type(layerSpec.color) == "string" and layerSpec.color:match("^#%x%x%x%x%x%x$") then
        layer.color = layerSpec.color
      end
      if type(layerSpec.appTrigger) == "string" and layerSpec.appTrigger ~= "" then
        layer.appTrigger = layerSpec.appTrigger
      end
      for profileName, profileSpec in pairs(layerSpec.profiles) do
        if type(profileName) ~= "string" or profileName == "" or type(profileSpec) ~= "table" then
          warn(layerSpec.name .. "의 잘못된 프로필을 건너뜀")
        else
          local actions = {}
          local specs = {}
          for id, spec in pairs(profileSpec) do
            if not isKeyId(id) then
              warn(layerSpec.name .. "/" .. profileName .. ": 잘못된 키 ID " .. tostring(id))
            else
              local valid, reason = validateActionSpec(spec)
              if valid then
                local entry = { run = actionFromSpec(spec) }
                if spec.hold then entry.hold = actionFromSpec(spec.hold) end
                actions[id] = entry
                specs[id] = spec
              else
                warn(layerSpec.name .. "/" .. profileName .. "/" .. id .. ": " .. reason)
              end
            end
          end
          layer.profiles[profileName] = actions
          layer.specs[profileName] = specs
        end
      end
      layer.profiles.default = layer.profiles.default or {}
      layer.specs.default = layer.specs.default or {}
      table.insert(layers, layer)
    end
  end

  if #layers == 0 then
    warn("사용 가능한 레이어가 없음")
    return nil
  end
  return layers, switchId
end

local updateMenubar
local sendKeymapToUI
local renderWidget

function k20Rebuild()
  local raw = readKeymap()
  if not raw then return false end
  local layers, switchId = compileKeymap(raw)
  if not layers then return false end

  local previousName = k20Layers and k20Layers[k20CurrentLayer]
      and k20Layers[k20CurrentLayer].name or nil
  local nextIndex = math.min(k20CurrentLayer or 1, #layers)
  if previousName then
    for index, layer in ipairs(layers) do
      if layer.name == previousName then
        nextIndex = index
        break
      end
    end
  end

  k20RawKeymap = raw
  k20Layers = layers
  k20LayerSwitchId = switchId
  k20CurrentLayer = math.min(nextIndex, #layers)
  if updateMenubar then updateMenubar() end
  if renderWidget then renderWidget() end
  return true
end

-- ===========================================================================
-- 디스패치, 메뉴바, 레이어 HUD와 데스크톱 위젯
-- ===========================================================================
local PHYSICAL_KEYS = {
  { engraving = "Esc", id = "hyper+f19", row = 1, col = 1 },
  { engraving = "Tab", id = "hyper+f20", row = 1, col = 2 },
  { engraving = "⌫", id = "s-hyper+f13", row = 1, col = 3 },
  { engraving = "Fn", disabled = true, row = 1, col = 4 },
  { engraving = "Num", disabled = true, row = 2, col = 1 },
  { engraving = "/", id = "hyper+f14", row = 2, col = 2 },
  { engraving = "*", id = "hyper+f15", row = 2, col = 3 },
  { engraving = "-", id = "hyper+f16", row = 2, col = 4 },
  { engraving = "7", id = "f13", row = 3, col = 1 },
  { engraving = "8", id = "f14", row = 3, col = 2 },
  { engraving = "9", id = "f15", row = 3, col = 3 },
  { engraving = "+", switch = true, row = 3, col = 4, rowSpan = 2 },
  { engraving = "4", id = "f16", row = 4, col = 1 },
  { engraving = "5", id = "f17", row = 4, col = 2 },
  { engraving = "6", id = "f18", row = 4, col = 3 },
  { engraving = "1", id = "f19", row = 5, col = 1 },
  { engraving = "2", id = "f20", row = 5, col = 2 },
  { engraving = "3", id = "s-hyper+f17", row = 5, col = 3 },
  { engraving = "Enter", id = "s-hyper+f20", row = 5, col = 4, rowSpan = 2 },
  { engraving = "0", id = "s-hyper+f18", row = 6, col = 1, colSpan = 2 },
  { engraving = ".", id = "s-hyper+f19", row = 6, col = 3 },
}

local CIRCLED_NUMBERS = { "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩" }
local WIDGET_ALPHA_KEY = "k20.widget.alpha"

local function widgetAlpha()
  local alpha = tonumber(hs.settings.get(WIDGET_ALPHA_KEY))
  if not alpha then return 0.94 end
  return math.max(0.2, math.min(1, alpha))
end

-- "#RRGGBB" → hs 색상 테이블 (brighten: 1보다 크면 밝게)
local function hexToColor(hex, alpha, brighten)
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then return nil end
  local factor = brighten or 1
  local function channel(v)
    return math.min(1, (tonumber(v, 16) / 255) * factor)
  end
  return { red = channel(r), green = channel(g), blue = channel(b), alpha = alpha or 1 }
end

-- 이미지 아이콘 캐시 (경로 → hs.image, 실패 시 false 기록해 재시도 방지)
k20ImageCache = k20ImageCache or {}
local function iconImage(relPath)
  if type(relPath) ~= "string" or relPath == "" then return nil end
  local cached = k20ImageCache[relPath]
  if cached ~= nil then return cached or nil end
  local image = hs.image.imageFromPath(CONFIG_DIR .. relPath)
  k20ImageCache[relPath] = image or false
  return image
end

-- 앱 실행 액션: 설치된 앱의 실제 아이콘을 자동 추출해 사용
local APP_DIRS = {
  "/Applications/", "/System/Applications/",
  "/Applications/Utilities/", "/System/Applications/Utilities/",
}

local function appIconImage(appName)
  if type(appName) ~= "string" or appName == "" then return nil end
  local key = "app:" .. appName
  local cached = k20ImageCache[key]
  if cached ~= nil then return cached or nil end
  local image = nil
  for _, dir in ipairs(APP_DIRS) do
    local path = dir .. appName .. ".app"
    if hs.fs.attributes(path) then
      image = hs.image.iconForFile(path)
      break
    end
  end
  if not image then
    local running = hs.application.get(appName)
    local bundleID = running and running:bundleID() or nil
    if bundleID then image = hs.image.imageFromAppBundle(bundleID) end
  end
  k20ImageCache[key] = image or false
  return image
end

-- 설정 UI(웹뷰)용: 앱 아이콘을 icons/auto/에 PNG로 내보내고 상대 경로 반환
local function ensureAppIconFile(appName)
  local rel = "icons/auto/" .. appName:gsub("[^%w가-힣%-_%.]", "_") .. ".png"
  if hs.fs.attributes(CONFIG_DIR .. rel) then return rel end
  local image = appIconImage(appName)
  if not image then return nil end
  hs.execute(string.format("mkdir -p %q", CONFIG_DIR .. "icons/auto"), false)
  local small = image:setSize({ w = 128, h = 128 })
  if not (small and small:saveToFile(CONFIG_DIR .. rel, "png")) then return nil end
  return rel
end

local WIDGET_MODE_KEY = "k20.widget.mode"
local WIDGET_X_KEY = "k20.widget.x"
local WIDGET_Y_KEY = "k20.widget.y"
local WIDGET_LEVEL_KEY = "k20.widget.level"
local VALID_WIDGET_MODES = { hidden = true, compact = true, expanded = true }
local VALID_WIDGET_LEVELS = { top = true, desktop = true }

k20WidgetMode = hs.settings.get(WIDGET_MODE_KEY)
if not VALID_WIDGET_MODES[k20WidgetMode] then k20WidgetMode = "hidden" end
k20WidgetLevel = hs.settings.get(WIDGET_LEVEL_KEY)
if not VALID_WIDGET_LEVELS[k20WidgetLevel] then k20WidgetLevel = "top" end

local function resolveEntry(id)
  local layer = k20Layers[k20CurrentLayer]
  local frontApp = hs.application.frontmostApplication()
  local appName = frontApp and frontApp:name() or ""
  local appProfile = layer.profiles[appName]
  return (appProfile and appProfile[id]) or layer.profiles.default[id], layer
end

local function dispatch(id)
  local entry, layer = resolveEntry(id)
  if entry and entry.run then
    entry.run()
  elseif not entry and k20Webview and k20Webview:hswindow() then
    -- 설정 창이 열려 있을 때만 안내 (키 찾기 용도). 평소에는 조용히 무시.
    hs.alert.show(layer.name .. " · " .. id .. " (미할당)")
  end
end

local function hideHud()
  if k20HudCanvas then
    k20HudCanvas:hide()
    k20HudCanvas:delete()
    k20HudCanvas = nil
  end
  k20HudTimer = nil
end

local function buildKeypadElements(layer, frameOpts)
  local elements = {}
  local gap = frameOpts.gap or 5
  local cellW = frameOpts.cellW or 120
  local cellH = frameOpts.cellH or 21
  local startX = frameOpts.startX or 22
  local startY = frameOpts.startY or 45
  local fontSize = frameOpts.fontSize or 10
  local radius = frameOpts.radius or 5
  local alphaScale = frameOpts.alpha or 1 -- 위젯 불투명도에 맞춰 키 칸도 함께 조절
  local defaultSpecs = layer.specs.default or {}

  for _, keyInfo in ipairs(PHYSICAL_KEYS) do
    local colSpan = keyInfo.colSpan or 1
    local rowSpan = keyInfo.rowSpan or 1
    local x = startX + (keyInfo.col - 1) * (cellW + gap)
    local y = startY + (keyInfo.row - 1) * (cellH + gap)
    local w = cellW * colSpan + gap * (colSpan - 1)
    local h = cellH * rowSpan + gap * (rowSpan - 1)
    -- 할당된 키만 라벨 표시. 미할당/비활성 키는 빈 칸으로 (시각적 소음 제거)
    local label = ""
    local cellImage = nil
    local micCell = false
    if keyInfo.switch then
      label = frameOpts.switchLabel or "+  레이어 전환"
    elseif not keyInfo.disabled and defaultSpecs[keyInfo.id] then
      local spec = defaultSpecs[keyInfo.id]
      micCell = spec.type == "mic"
      cellImage = spec.image and iconImage(spec.image) or nil
      if not cellImage and spec.type == "app" and not spec.icon then
        cellImage = appIconImage(spec.arg) -- 앱 실제 아이콘 자동 사용
      end
      if cellImage then
        label = spec.label or ""
      else
        local icon = spec.icon
        if micCell and not icon then
          icon = k20MicMuted and "🔇" or "🎙" -- 상태 반영 아이콘
        end
        label = (icon and icon .. " " or "") .. (spec.label or keyInfo.engraving)
      end
    end

    local target = keyInfo.id and ("key:" .. keyInfo.id) or "drag"
    local interactive = frameOpts.interactive and keyInfo.id ~= nil
    table.insert(elements, {
      type = "rectangle",
      id = interactive and ("key-bg:" .. keyInfo.id) or ("key-bg-" .. keyInfo.row .. "-" .. keyInfo.col),
      action = "fill",
      fillColor = keyInfo.disabled
          and { white = 0.18, alpha = 0.45 * alphaScale }
          or (micCell and (k20MicMuted
            and { red = 0.48, green = 0.16, blue = 0.16, alpha = 0.95 * alphaScale }
            or { red = 0.15, green = 0.36, blue = 0.22, alpha = 0.95 * alphaScale }))
          or { red = 0.18, green = 0.2, blue = 0.26, alpha = 0.95 * alphaScale },
      roundedRectRadii = { xRadius = radius, yRadius = radius },
      frame = { x = x, y = y, w = w, h = h },
      trackMouseDown = interactive,
      trackMouseUp = interactive,
      trackMouseMove = interactive,
    })
    if cellImage then
      local size = math.min(h - 6, 22)
      local imgX = (label == "") and (x + (w - size) / 2) or (x + 5)
      table.insert(elements, {
        type = "image",
        id = interactive and ("key-img:" .. keyInfo.id) or ("key-img-" .. keyInfo.row .. "-" .. keyInfo.col),
        image = cellImage,
        imageScaling = "scaleProportionally",
        imageAlpha = alphaScale,
        frame = { x = imgX, y = y + (h - size) / 2, w = size, h = size },
        trackMouseDown = interactive,
        trackMouseUp = interactive,
        trackMouseMove = interactive,
      })
    end
    table.insert(elements, {
      type = "text",
      id = interactive and target or ("key-label-" .. keyInfo.row .. "-" .. keyInfo.col),
      text = label,
      textColor = { white = keyInfo.disabled and 0.55 or 0.95, alpha = alphaScale },
      textFont = ".AppleSystemUIFont",
      textSize = fontSize,
      textAlignment = "center",
      frame = frameOpts.centerText
          and { x = x + 3, y = y + math.max(1, (h - fontSize - 3) / 2), w = w - 6, h = fontSize + 5 }
          or { x = x + 3, y = y + 3, w = w - 6, h = h - 4 },
      trackMouseDown = interactive,
      trackMouseUp = interactive,
      trackMouseMove = interactive,
    })
  end
  return elements
end

local function showHud()
  if k20HudTimer then
    k20HudTimer:stop()
    k20HudTimer = nil
  end
  hideHud()

  local layer = k20Layers[k20CurrentLayer]
  local screen = hs.screen.mainScreen()
  if not layer or not screen then return end
  local screenFrame = screen:frame()
  local width, height = 540, 210
  local frame = {
    x = screenFrame.x + (screenFrame.w - width) / 2,
    y = screenFrame.y + screenFrame.h - height - 54,
    w = width,
    h = height,
  }
  k20HudCanvas = hs.canvas.new(frame)
  k20HudCanvas:level(hs.canvas.windowLevels.overlay)
  k20HudCanvas:behavior({ "canJoinAllSpaces", "stationary" })
  k20HudCanvas:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = (layer.color and hexToColor(layer.color, 0.94))
        or { red = 0.07, green = 0.08, blue = 0.11, alpha = 0.94 },
    roundedRectRadii = { xRadius = 18, yRadius = 18 },
    frame = { x = 0, y = 0, w = width, h = height },
  })
  k20HudCanvas:appendElements({
    type = "text",
    text = layer.name,
    textColor = { white = 1, alpha = 1 },
    textFont = ".AppleSystemUIFontBold",
    textSize = 20,
    textAlignment = "center",
    frame = { x = 16, y = 10, w = width - 32, h = 28 },
  })
  for _, element in ipairs(buildKeypadElements(layer, {
    gap = 5,
    cellW = 120,
    cellH = 21,
    startX = 22,
    startY = 45,
    fontSize = 10,
    radius = 5,
    switchLabel = "+  레이어 전환",
  })) do
    k20HudCanvas:appendElements(element)
  end
  k20HudCanvas:show()
  k20HudTimer = hs.timer.doAfter(1.5, hideHud)
end

local function deleteWidget()
  if k20Widget then
    k20Widget:hide()
    k20Widget:delete()
    k20Widget = nil
  end
end

local function widgetDimensions()
  if k20WidgetMode == "expanded" then return 360, 230 end
  return 190, 36
end

-- 드래그 대신: ✥ 클릭 시 네 모서리(우상→우하→좌하→좌상)를 순환 이동
local WIDGET_CORNER_KEY = "k20.widget.corner"
local function cycleWidgetPosition()
  local width, height = widgetDimensions()
  local sf = hs.screen.mainScreen():frame()
  local corner = ((hs.settings.get(WIDGET_CORNER_KEY) or 1) % 4) + 1
  hs.settings.set(WIDGET_CORNER_KEY, corner)
  local m = 24
  local pos = ({
    { x = sf.x + sf.w - width - m, y = sf.y + m },
    { x = sf.x + sf.w - width - m, y = sf.y + sf.h - height - m },
    { x = sf.x + m, y = sf.y + sf.h - height - m },
    { x = sf.x + m, y = sf.y + m },
  })[corner]
  hs.settings.set(WIDGET_X_KEY, pos.x)
  hs.settings.set(WIDGET_Y_KEY, pos.y)
  renderWidget()
end

local function widgetFrame()
  local width, height = widgetDimensions()
  local savedX = hs.settings.get(WIDGET_X_KEY)
  local savedY = hs.settings.get(WIDGET_Y_KEY)
  if type(savedX) == "number" and type(savedY) == "number" then
    return { x = savedX, y = savedY, w = width, h = height }
  end
  local screen = hs.screen.mainScreen()
  local frame = screen and screen:frame() or { x = 0, y = 0, w = 1440, h = 900 }
  return {
    x = frame.x + frame.w - width - 24,
    y = frame.y + 64,
    w = width,
    h = height,
  }
end

local function trackedText(id, text, frame, size, alignment)
  return {
    type = "text",
    id = id,
    text = text,
    -- 불투명도를 따라가되 글자는 최소 가독성 유지
    textColor = { white = 0.96, alpha = math.max(0.55, widgetAlpha()) },
    textFont = ".AppleSystemUIFontBold",
    textSize = size,
    textAlignment = alignment or "center",
    frame = frame,
    trackMouseDown = true,
    trackMouseUp = true,
    trackMouseMove = true,
  }
end

local setWidgetMode
local setWidgetLevel
local resetWidgetPosition
local setLayer

local function selectWidgetKey(keyId)
  k20OpenSettings()
  if k20WidgetSelectTimer then k20WidgetSelectTimer:stop() end
  k20WidgetSelectTimer = hs.timer.doAfter(0.4, function()
    k20WidgetSelectTimer = nil
    if k20Webview then
      k20Webview:evaluateJavaScript(
        "window.k20SelectKey && window.k20SelectKey('" .. keyId .. "')"
      )
    end
  end)
end

-- 드래그는 캔버스 자체 mouseMove가 불안정해서, 누른 순간부터 전역 eventtap으로
-- 마우스를 추적한다 (커서가 위젯 밖으로 나가도 계속 따라옴).
local function stopWidgetDragTap()
  if k20WidgetDragTap then
    k20WidgetDragTap:stop()
    k20WidgetDragTap = nil
  end
end

local function startWidgetDragTap()
  stopWidgetDragTap()
  local types = hs.eventtap.event.types
  k20WidgetDragTap = hs.eventtap.new({ types.leftMouseDragged }, function()
    local state = k20WidgetDragState
    if not state or not k20Widget then return false end
    local mouse = hs.mouse.absolutePosition()
    local dx = mouse.x - state.startX
    local dy = mouse.y - state.startY
    if math.abs(dx) + math.abs(dy) > 4 then state.dragged = true end
    if state.dragged then
      local frame = k20Widget:frame()
      frame.x = mouse.x - state.offsetX
      frame.y = mouse.y - state.offsetY
      k20Widget:frame(frame)
    end
    return false
  end)
  k20WidgetDragTap:start()
end

local function widgetMouseCallback(_, message, elementId)
  local mouse = hs.mouse.absolutePosition()
  if message == "mouseDown" then
    local frame = k20Widget and k20Widget:frame() or nil
    if not frame then return end
    k20WidgetDragState = {
      target = elementId,
      offsetX = mouse.x - frame.x,
      offsetY = mouse.y - frame.y,
      startX = mouse.x,
      startY = mouse.y,
      dragged = false,
    }
    startWidgetDragTap()
  elseif message == "mouseUp" and k20WidgetDragState then
    local state = k20WidgetDragState
    k20WidgetDragState = nil
    stopWidgetDragTap()
    if state.dragged and k20Widget then
      local frame = k20Widget:frame()
      hs.settings.set(WIDGET_X_KEY, frame.x)
      hs.settings.set(WIDGET_Y_KEY, frame.y)
      return
    end

    local target = state.target or elementId or ""
    local keyId = target:match("^key:(.+)$") or target:match("^key%-bg:(.+)$")
        or target:match("^key%-img:(.+)$")
    if keyId then
      selectWidgetKey(keyId)
    elseif target == "settings" then
      k20OpenSettings()
    elseif target == "toggle" then
      setWidgetMode(k20WidgetMode == "expanded" and "compact" or "expanded")
    elseif target == "move" then
      cycleWidgetPosition()
    elseif target == "layer" or target == "layer-number" then
      setLayer(k20CurrentLayer % #k20Layers + 1, true)
    end
  end
end

renderWidget = function()
  deleteWidget()
  if k20WidgetMode == "hidden" or not k20Layers then return end
  local layer = k20Layers[k20CurrentLayer]
  if not layer then return end
  local frame = widgetFrame()
  k20Widget = hs.canvas.new(frame)
  k20Widget:level(k20WidgetLevel == "desktop"
      and hs.canvas.windowLevels.desktopIcon or hs.canvas.windowLevels.floating)
  k20Widget:behavior({ "canJoinAllSpaces", "stationary" })
  k20Widget:canvasMouseEvents(true, true, false, true)
  k20Widget:mouseCallback(widgetMouseCallback)

  local alpha = widgetAlpha()
  local layerColor = layer.color and hexToColor(layer.color, alpha) or nil
  local baseColor
  if k20WidgetFlashing then
    baseColor = (layer.color and hexToColor(layer.color, math.min(1, alpha + 0.04), 1.6))
        or { red = 0.19, green = 0.22, blue = 0.36, alpha = math.min(1, alpha + 0.04) }
  else
    baseColor = layerColor or { red = 0.07, green = 0.08, blue = 0.11, alpha = alpha }
  end
  k20Widget:appendElements({
    type = "rectangle",
    id = "background",
    action = "fill",
    fillColor = baseColor,
    roundedRectRadii = {
      xRadius = k20WidgetMode == "compact" and 18 or 14,
      yRadius = k20WidgetMode == "compact" and 18 or 14,
    },
    frame = { x = 0, y = 0, w = frame.w, h = frame.h },
    trackMouseDown = true,
    trackMouseUp = true,
    trackMouseMove = true,
  })

  if k20WidgetMode == "compact" then
    k20Widget:appendElements(trackedText(
      "layer-number",
      CIRCLED_NUMBERS[k20CurrentLayer] or ("(" .. k20CurrentLayer .. ")"),
      { x = 10, y = 7, w = 25, h = 22 },
      15
    ))
    k20Widget:appendElements(trackedText(
      "layer",
      layer.name,
      { x = 35, y = 8, w = 82, h = 20 },
      12,
      "left"
    ))
    k20Widget:appendElements(trackedText("toggle", "▣", { x = 118, y = 8, w = 20, h = 20 }, 12))
    k20Widget:appendElements(trackedText("settings", "⛭", { x = 139, y = 7, w = 20, h = 22 }, 15))
    k20Widget:appendElements(trackedText("move", "✥", { x = 160, y = 8, w = 20, h = 20 }, 13))
  else
    k20Widget:appendElements({
      type = "rectangle",
      id = "header",
      action = "fill",
      fillColor = k20WidgetFlashing
          and ((layer.color and hexToColor(layer.color, 0.92, 1.9))
            or { red = 0.27, green = 0.31, blue = 0.5, alpha = 0.92 })
          or ((layer.color and hexToColor(layer.color, 0.92, 1.35))
            or { red = 0.12, green = 0.14, blue = 0.2, alpha = 0.92 }),
      roundedRectRadii = { xRadius = 14, yRadius = 14 },
      frame = { x = 0, y = 0, w = frame.w, h = 39 },
      trackMouseDown = true,
      trackMouseUp = true,
      trackMouseMove = true,
    })
    k20Widget:appendElements(trackedText(
      "layer",
      (CIRCLED_NUMBERS[k20CurrentLayer] or tostring(k20CurrentLayer)) .. "  " .. layer.name,
      { x = 14, y = 9, w = 252, h = 22 },
      14,
      "left"
    ))
    k20Widget:appendElements(trackedText("move", "✥", { x = 272, y = 8, w = 22, h = 23 }, 14))
    k20Widget:appendElements(trackedText("settings", "⛭", { x = 300, y = 8, w = 24, h = 23 }, 16))
    k20Widget:appendElements(trackedText("toggle", "▁", { x = 329, y = 7, w = 20, h = 22 }, 16))
    for _, element in ipairs(buildKeypadElements(layer, {
      gap = 5,
      cellW = 80,
      cellH = 25,
      startX = 13,
      startY = 47,
      fontSize = 8,
      radius = 5,
      switchLabel = "+ 레이어",
      interactive = true,
      centerText = true,
      alpha = alpha,
    })) do
      k20Widget:appendElements(element)
    end
  end
  k20Widget:show()
end

local function flashWidget()
  if k20WidgetMode == "hidden" then return end
  if k20WidgetFlashTimer then k20WidgetFlashTimer:stop() end
  k20WidgetFlashing = true
  renderWidget()
  k20WidgetFlashTimer = hs.timer.doAfter(0.6, function()
    k20WidgetFlashTimer = nil
    k20WidgetFlashing = false
    renderWidget()
  end)
end

setWidgetMode = function(mode)
  if not VALID_WIDGET_MODES[mode] then return end
  if k20WidgetFlashTimer then
    k20WidgetFlashTimer:stop()
    k20WidgetFlashTimer = nil
  end
  k20WidgetMode = mode
  hs.settings.set(WIDGET_MODE_KEY, mode)
  k20WidgetFlashing = false
  if mode ~= "hidden" then hideHud() end
  renderWidget()
  if updateMenubar then updateMenubar() end
end

setWidgetLevel = function(level)
  if not VALID_WIDGET_LEVELS[level] then return end
  k20WidgetLevel = level
  hs.settings.set(WIDGET_LEVEL_KEY, level)
  renderWidget()
  if updateMenubar then updateMenubar() end
end

resetWidgetPosition = function()
  hs.settings.clear(WIDGET_X_KEY)
  hs.settings.clear(WIDGET_Y_KEY)
  renderWidget()
end

-- 설정 UI에서 위젯 모드/레벨/투명도를 변경할 때 호출됨
function k20ApplyWidgetConfig(config)
  if type(config) ~= "table" then return end
  local alpha = tonumber(config.alpha)
  if alpha then
    hs.settings.set(WIDGET_ALPHA_KEY, math.max(0.2, math.min(1, alpha)))
  end
  if config.mode and VALID_WIDGET_MODES[config.mode] and config.mode ~= k20WidgetMode then
    setWidgetMode(config.mode)
  end
  if config.level and VALID_WIDGET_LEVELS[config.level] and config.level ~= k20WidgetLevel then
    setWidgetLevel(config.level)
  end
  renderWidget()
end

setLayer = function(index, announce)
  if not k20Layers[index] then return end
  k20CurrentLayer = index
  if updateMenubar then updateMenubar() end
  if announce then hs.alert.show("레이어: " .. k20Layers[index].name) end
  if k20WidgetMode == "hidden" then showHud() else flashWidget() end
end

local function switchLayer()
  k20AutoLayerActive = false -- 수동 전환 시 자동 복귀 모드 해제 (사용자 제어 우선)
  setLayer(k20CurrentLayer % #k20Layers + 1, true)
end

-- ===========================================================================
-- 앱 연결 레이어: 특정 앱이 앞으로 오면 그 앱의 레이어로 자동 전환,
-- 떠나면 원래 레이어로 복귀 (스트림덱의 스마트 프로필)
-- ===========================================================================
k20AutoLayerActive = k20AutoLayerActive or false
k20ReturnLayer = k20ReturnLayer or nil

local function onAppActivated(appName)
  if not k20Layers then return end
  local current = k20Layers[k20CurrentLayer]
  -- 이미 이 앱에 연결된 레이어에 있으면 유지 (한 앱의 2번째 세트 사용 중 등)
  if current and current.appTrigger == appName then
    k20AutoLayerActive = true
    return
  end
  local target = nil
  for index, layer in ipairs(k20Layers) do
    if layer.appTrigger == appName then
      target = index
      break
    end
  end
  if target then
    if not k20AutoLayerActive and current and not current.appTrigger then
      k20ReturnLayer = k20CurrentLayer
    end
    k20AutoLayerActive = true
    setLayer(target, false)
  elseif k20AutoLayerActive then
    -- 연결 앱을 떠남 → 원래 레이어로 복귀
    k20AutoLayerActive = false
    local back = k20ReturnLayer
    if back and k20Layers[back] and not k20Layers[back].appTrigger then
      setLayer(back, false)
    else
      setLayer(1, false)
    end
  end
end

k20AppWatcher = hs.application.watcher.new(function(appName, eventType)
  if eventType == hs.application.watcher.activated and appName then
    onAppActivated(appName)
  end
end)
k20AppWatcher:start()

-- 길게 누르기: hold 동작이 있는 키는 눌림/뗌을 구분해 처리한다.
-- hold가 없는 키는 기존처럼 누르는 즉시 실행 (지연 없음).
local HOLD_SECONDS = 0.45
k20HoldPending = k20HoldPending or {}

local function keyPressed(id)
  if id == k20LayerSwitchId then
    switchLayer()
    return
  end
  local entry = resolveEntry(id)
  if not entry or not entry.hold then
    dispatch(id)
    return
  end
  local pending = { done = false, entry = entry }
  pending.timer = hs.timer.doAfter(HOLD_SECONDS, function()
    pending.done = true
    if entry.hold then entry.hold() end
  end)
  k20HoldPending[id] = pending
end

local function keyReleased(id)
  local pending = k20HoldPending[id]
  if not pending then return end
  k20HoldPending[id] = nil
  if pending.timer then pending.timer:stop() end
  if not pending.done and pending.entry.run then pending.entry.run() end
end

-- ===========================================================================
-- 설정 UI와 JS ↔ Lua 브리지
-- ===========================================================================
sendKeymapToUI = function()
  if not k20Webview or not k20RawKeymap then return end
  local ok, encoded = pcall(hs.json.encode, k20RawKeymap, true)
  if not ok then warn("UI로 설정을 보낼 수 없음") return end
  k20Webview:evaluateJavaScript("window.k20ReceiveKeymap(" .. encoded .. ");")
  local cfgOk, cfg = pcall(hs.json.encode, {
    mode = k20WidgetMode, level = k20WidgetLevel, alpha = widgetAlpha(),
  })
  if cfgOk then
    k20Webview:evaluateJavaScript(
      "window.k20ReceiveWidgetConfig && window.k20ReceiveWidgetConfig(" .. cfg .. ");")
  end
  -- 앱 액션들의 자동 아이콘(PNG 추출본) 경로를 UI로 전달
  local appIcons = {}
  for _, layer in ipairs(k20RawKeymap.layers or {}) do
    for _, profile in pairs(layer.profiles or {}) do
      if type(profile) == "table" then
        for _, spec in pairs(profile) do
          if type(spec) == "table" and spec.type == "app" and type(spec.arg) == "string"
              and not spec.image and not spec.icon and appIcons[spec.arg] == nil then
            appIcons[spec.arg] = ensureAppIconFile(spec.arg) or false
          end
        end
      end
    end
  end
  local cleaned = {}
  for name, rel in pairs(appIcons) do
    if rel then cleaned[name] = rel end
  end
  local iconsOk, iconsJson = pcall(hs.json.encode, cleaned)
  if iconsOk then
    k20Webview:evaluateJavaScript(
      "window.k20ReceiveAppIcons && window.k20ReceiveAppIcons(" .. iconsJson .. ");")
  end
end

local function saveKeymap(keymap)
  local valid, reason = validateKeymapForSave(keymap)
  if not valid then warn("저장 거부: " .. reason) return end
  local ok, encoded = pcall(hs.json.encode, keymap, true)
  if not ok then warn("JSON 인코딩 실패") return end

  local tempPath = KEYMAP_PATH .. ".tmp"
  local file, openError = io.open(tempPath, "w")
  if not file then warn("임시 파일 열기 실패: " .. tostring(openError)) return end
  local writeOk = file:write(encoded .. "\n")
  file:close()
  if not writeOk then
    os.remove(tempPath)
    warn("keymap.json 쓰기 실패")
    return
  end
  local renamed, renameError = os.rename(tempPath, KEYMAP_PATH)
  if not renamed then
    os.remove(tempPath)
    warn("keymap.json 교체 실패: " .. tostring(renameError))
    return
  end
  if k20Rebuild() then
    hs.alert.show("저장됨")
    sendKeymapToUI()
  end
end

-- 이미지 아이콘 선택: 네이티브 파일 선택창 → icons/ 폴더로 복사 → UI에 상대 경로 전달
local function pickIconImage()
  local result = hs.dialog.chooseFileOrFolder(
    "아이콘으로 쓸 이미지를 선택하세요", "~", true, false, false,
    { "png", "jpg", "jpeg", "gif", "icns", "tiff", "heic", "webp" }, true)
  if type(result) ~= "table" or not result["1"] then return end
  local path = tostring(result["1"])
      :gsub("^file://", "")
      :gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  local base = (path:match("([^/]+)$") or "icon"):gsub("[^%w%.%-_가-힣]", "_")
  local destRel = "icons/" .. os.time() .. "-" .. base
  hs.execute(string.format("mkdir -p %q && cp %q %q",
    CONFIG_DIR .. "icons", path, CONFIG_DIR .. destRel), false)
  if not hs.fs.attributes(CONFIG_DIR .. destRel) then
    warn("이미지 복사 실패")
    return
  end
  k20ImageCache[destRel] = nil
  if k20Webview then
    local ok, encoded = pcall(hs.json.encode, destRel)
    if ok then
      k20Webview:evaluateJavaScript(
        "window.k20ReceiveIcon && window.k20ReceiveIcon(" .. encoded .. ");")
    end
  end
end

local function handleUIMessage(message)
  -- WKScriptMessage는 보통 body에 게시 객체를 담지만, 직접 변환되는 버전도 허용한다.
  local body = type(message) == "table" and message.body or nil
  if type(body) ~= "table" and type(message) == "table" and message.action then
    body = message
  end
  if type(body) ~= "table" then warn("UI 메시지 형식이 잘못됨") return end
  if body.action == "load" then
    sendKeymapToUI()
  elseif body.action == "save" then
    saveKeymap(body.keymap)
  elseif body.action == "widget" then
    k20ApplyWidgetConfig(body.config)
  elseif body.action == "pickImage" then
    pickIconImage()
  else
    warn("알 수 없는 UI 요청")
  end
end

local function createWebview()
  if k20Webview then return end
  k20UserContentController = hs.webview.usercontent.new("k20")
  k20UserContentController:setCallback(handleUIMessage)
  local screenFrame = hs.screen.mainScreen():frame()
  local frame = {
    x = screenFrame.x + (screenFrame.w - 900) / 2,
    y = screenFrame.y + (screenFrame.h - 640) / 2,
    w = 900,
    h = 640,
  }
  k20Webview = hs.webview.new(frame, {
    developerExtrasEnabled = false,
  }, k20UserContentController)
  k20Webview:windowTitle("K20 스트림덱 설정")
  k20Webview:windowStyle({ "titled", "closable", "miniaturizable", "resizable" })
  k20Webview:level(hs.drawing.windowLevels.normal) -- 일반 창처럼: 다른 창 뒤로 갈 수 있게
  k20Webview:allowTextEntry(true)
  k20Webview:closeOnEscape(true)
  k20Webview:deleteOnClose(false)
end

function k20OpenSettings()
  createWebview()
  -- 기존 webview도 파일 URL을 다시 로드해 ui.html 변경을 즉시 반영한다.
  k20Webview:url("file://" .. UI_PATH)
  k20Webview:show()
  -- bringToFront는 창을 항상-위 레벨로 바꿔버리므로 쓰지 않는다.
  -- 일반 창 레벨을 유지한 채 포커스만 가져온다.
  k20Webview:level(hs.drawing.windowLevels.normal)
  local win = k20Webview:hswindow()
  if win then win:focus() end
end

updateMenubar = function()
  if not k20Menubar or not k20Layers then return end
  k20Menubar:setTitle("⌨" .. (CIRCLED_NUMBERS[k20CurrentLayer] or tostring(k20CurrentLayer)))
  k20Menubar:setMenu(function()
    local menu = {
      { title = "설정 열기", fn = k20OpenSettings },
      {
        title = "위젯",
        menu = {
          { title = "숨김", checked = k20WidgetMode == "hidden", fn = function() setWidgetMode("hidden") end },
          { title = "컴팩트", checked = k20WidgetMode == "compact", fn = function() setWidgetMode("compact") end },
          { title = "확장", checked = k20WidgetMode == "expanded", fn = function() setWidgetMode("expanded") end },
          { title = "-" },
          { title = "항상 위", checked = k20WidgetLevel == "top", fn = function() setWidgetLevel("top") end },
          {
            title = "데스크톱 고정",
            checked = k20WidgetLevel == "desktop",
            fn = function() setWidgetLevel("desktop") end,
          },
          { title = "위젯 위치 초기화", fn = resetWidgetPosition },
        },
      },
      { title = "-" },
    }
    for index, layer in ipairs(k20Layers) do
      local layerIndex = index
      table.insert(menu, {
        title = layer.name,
        checked = layerIndex == k20CurrentLayer,
        fn = function() setLayer(layerIndex, true) end,
      })
    end
    table.insert(menu, { title = "-" })
    table.insert(menu, { title = "재시작", fn = function() hs.reload() end })
    return menu
  end)
end

-- ===========================================================================
-- 시작: 설정 로드, 모든 F13~F20 조합 바인드, 메뉴와 watcher 생성
-- ===========================================================================
if not k20Rebuild() then
  k20RawKeymap = {
    layerSwitchKey = "hyper+f17",
    layers = { { name = "설정 오류", profiles = { default = {} } } },
  }
  k20Layers = {
    { name = "설정 오류", profiles = { default = {} }, specs = { default = {} } },
  }
end

for f = 13, 20 do
  local key = "f" .. f
  for _, set in ipairs({
    { mods = {}, id = key },
    { mods = HYPER, id = "hyper+" .. key },
    { mods = SHYPER, id = "s-hyper+" .. key },
  }) do
    local id = set.id
    table.insert(k20Hotkeys, hs.hotkey.bind(set.mods, key,
      function() keyPressed(id) end,
      function() keyReleased(id) end))
  end
end

k20Menubar = hs.menubar.new()
updateMenubar()

-- 마이크 상태 추적: 즉시(k20RefreshViews) + 외부 변경 폴링(5초)
function k20RefreshViews()
  if renderWidget then renderWidget() end
end

local function syncMicState()
  local dev = hs.audiodevice.defaultInputDevice()
  local muted = dev and dev:muted() or false
  if muted ~= k20MicMuted then
    k20MicMuted = muted
    k20RefreshViews()
  end
end
syncMicState()
k20MicPollTimer = hs.timer.doEvery(5, syncMicState)
renderWidget()

local function reloadOnLuaChange(files)
  for _, file in ipairs(files) do
    if file:sub(-4) == ".lua" then
      hs.reload()
      return
    end
  end
end
k20ConfigWatcher = hs.pathwatcher.new(CONFIG_DIR, reloadOnLuaChange):start()

-- CLI(hs 명령)로 상태 점검/제어 가능하게 (검증 자동화용)
require("hs.ipc")
pcall(hs.ipc.cliInstall, "/opt/homebrew")

hs.alert.show("⌨️ K20 스트림덱 로드됨 · " .. k20Layers[k20CurrentLayer].name)
