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

local function micToggle()
  local dev = hs.audiodevice.defaultInputDevice()
  local muted = not dev:muted()
  dev:setMuted(muted)
  hs.alert.show(muted and "🎙 마이크 OFF" or "🎙 마이크 ON")
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

local function actionFromSpec(spec)
  if spec.type == "app" then return app(spec.arg) end
  if spec.type == "url" then return url(spec.arg) end
  if spec.type == "keys" then return keystroke(spec.mods, spec.key) end
  if spec.type == "text" then return typeText(spec.arg) end
  if spec.type == "shell" then return shell(spec.arg) end
  if spec.type == "shortcut" then return shortcut(spec.arg) end
  if spec.type == "media" then return media(spec.arg) end
  if spec.type == "mic" then return micToggle end
  return nil
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
                actions[id] = actionFromSpec(spec)
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

local function dispatch(id)
  local layer = k20Layers[k20CurrentLayer]
  local frontApp = hs.application.frontmostApplication()
  local appName = frontApp and frontApp:name() or ""
  local appProfile = layer.profiles[appName]
  local action = (appProfile and appProfile[id]) or layer.profiles.default[id]
  if action then
    action()
  else
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
  local defaultSpecs = layer.specs.default or {}

  for _, keyInfo in ipairs(PHYSICAL_KEYS) do
    local colSpan = keyInfo.colSpan or 1
    local rowSpan = keyInfo.rowSpan or 1
    local x = startX + (keyInfo.col - 1) * (cellW + gap)
    local y = startY + (keyInfo.row - 1) * (cellH + gap)
    local w = cellW * colSpan + gap * (colSpan - 1)
    local h = cellH * rowSpan + gap * (rowSpan - 1)
    local label = keyInfo.engraving
    if keyInfo.switch then
      label = frameOpts.switchLabel or "+  레이어 전환"
    elseif keyInfo.disabled then
      label = keyInfo.engraving .. "  —"
    elseif defaultSpecs[keyInfo.id] then
      local spec = defaultSpecs[keyInfo.id]
      label = (spec.icon and spec.icon .. " " or "") .. (spec.label or keyInfo.engraving)
    end

    local target = keyInfo.id and ("key:" .. keyInfo.id) or "drag"
    local interactive = frameOpts.interactive and keyInfo.id ~= nil
    table.insert(elements, {
      type = "rectangle",
      id = interactive and ("key-bg:" .. keyInfo.id) or ("key-bg-" .. keyInfo.row .. "-" .. keyInfo.col),
      action = "fill",
      fillColor = keyInfo.disabled
          and { white = 0.18, alpha = 0.45 }
          or { red = 0.18, green = 0.2, blue = 0.26, alpha = 0.95 },
      roundedRectRadii = { xRadius = radius, yRadius = radius },
      frame = { x = x, y = y, w = w, h = h },
      trackMouseDown = interactive,
      trackMouseUp = interactive,
      trackMouseMove = interactive,
    })
    table.insert(elements, {
      type = "text",
      id = interactive and target or ("key-label-" .. keyInfo.row .. "-" .. keyInfo.col),
      text = label,
      textColor = { white = keyInfo.disabled and 0.55 or 0.95, alpha = 1 },
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
    fillColor = { red = 0.07, green = 0.08, blue = 0.11, alpha = 0.94 },
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
  return 168, 36
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
    textColor = { white = 0.96, alpha = 1 },
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
  elseif message == "mouseMove" and k20WidgetDragState and k20Widget then
    local dx = mouse.x - k20WidgetDragState.startX
    local dy = mouse.y - k20WidgetDragState.startY
    if math.abs(dx) + math.abs(dy) > 4 then k20WidgetDragState.dragged = true end
    if k20WidgetDragState.dragged then
      local frame = k20Widget:frame()
      frame.x = mouse.x - k20WidgetDragState.offsetX
      frame.y = mouse.y - k20WidgetDragState.offsetY
      k20Widget:frame(frame)
    end
  elseif message == "mouseUp" and k20WidgetDragState then
    local state = k20WidgetDragState
    k20WidgetDragState = nil
    if state.dragged and k20Widget then
      local frame = k20Widget:frame()
      hs.settings.set(WIDGET_X_KEY, frame.x)
      hs.settings.set(WIDGET_Y_KEY, frame.y)
      return
    end

    local target = state.target or elementId or ""
    local keyId = target:match("^key:(.+)$") or target:match("^key%-bg:(.+)$")
    if keyId then
      selectWidgetKey(keyId)
    elseif target == "settings" then
      k20OpenSettings()
    elseif target == "toggle" then
      setWidgetMode(k20WidgetMode == "expanded" and "compact" or "expanded")
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

  local baseColor = k20WidgetFlashing
      and { red = 0.19, green = 0.22, blue = 0.36, alpha = 0.98 }
      or { red = 0.07, green = 0.08, blue = 0.11, alpha = 0.94 }
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
  else
    k20Widget:appendElements({
      type = "rectangle",
      id = "header",
      action = "fill",
      fillColor = k20WidgetFlashing
          and { red = 0.27, green = 0.31, blue = 0.5, alpha = 0.92 }
          or { red = 0.12, green = 0.14, blue = 0.2, alpha = 0.92 },
      roundedRectRadii = { xRadius = 14, yRadius = 14 },
      frame = { x = 0, y = 0, w = frame.w, h = 39 },
      trackMouseDown = true,
      trackMouseUp = true,
      trackMouseMove = true,
    })
    k20Widget:appendElements(trackedText(
      "layer",
      (CIRCLED_NUMBERS[k20CurrentLayer] or tostring(k20CurrentLayer)) .. "  " .. layer.name,
      { x = 14, y = 9, w = 270, h = 22 },
      14,
      "left"
    ))
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

setLayer = function(index, announce)
  if not k20Layers[index] then return end
  k20CurrentLayer = index
  if updateMenubar then updateMenubar() end
  if announce then hs.alert.show("레이어: " .. k20Layers[index].name) end
  if k20WidgetMode == "hidden" then showHud() else flashWidget() end
end

local function switchLayer()
  setLayer(k20CurrentLayer % #k20Layers + 1, true)
end

local function handleKey(id)
  if id == k20LayerSwitchId then switchLayer() else dispatch(id) end
end

-- ===========================================================================
-- 설정 UI와 JS ↔ Lua 브리지
-- ===========================================================================
sendKeymapToUI = function()
  if not k20Webview or not k20RawKeymap then return end
  local ok, encoded = pcall(hs.json.encode, k20RawKeymap, true)
  if not ok then warn("UI로 설정을 보낼 수 없음") return end
  k20Webview:evaluateJavaScript("window.k20ReceiveKeymap(" .. encoded .. ");")
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
  k20Webview:allowTextEntry(true)
  k20Webview:closeOnEscape(true)
  k20Webview:deleteOnClose(false)
end

function k20OpenSettings()
  createWebview()
  -- 기존 webview도 파일 URL을 다시 로드해 ui.html 변경을 즉시 반영한다.
  k20Webview:url("file://" .. UI_PATH)
  k20Webview:show()
  k20Webview:bringToFront(true)
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
    table.insert(k20Hotkeys, hs.hotkey.bind(set.mods, key, function() handleKey(id) end))
  end
end

k20Menubar = hs.menubar.new()
updateMenubar()
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
