-- Define hyper
hyper = { "cmd", "alt", "ctrl" }

-- Supress lanugage warning about unknown global variable
hs = hs

-- Reload hotkey
hs.hotkey.bind(hyper, "R", function()
    hs.reload()
end)

-- Print info about the frontmost application
hs.hotkey.bind(hyper, "w", function()
    local app = hs.application.frontmostApplication()
    if app then
        hs.alert.show("App: " .. app:name() .. "\nBundle ID: " .. app:bundleID())
    else
        hs.alert.show("No frontmost application found")
    end
end)

-- Window management
shortcuts = {
    { "j", "Visual Studio Code" },
    { "k", "Ghostty" },
    { "x", "XCode" },
    { "f", "Finder" },
    { "l", "Slack" },
    { "h", "Hammerspoon" },
    { "d", "Docker Desktop" },
    { "'", "Docker Desktop" },
    { "g", "ChatGPT" },
    { "m", "com.apple.mail" },
    { "e", "qemu-system-aarch64" },
    { "p", "1Password" },
    { "s", "Simulator" },
}

for i, shortcut in ipairs(shortcuts) do
    hs.hotkey.bind(hyper, shortcut[1], function()
        hs.application.launchOrFocus(shortcut[2])
    end)
end

-- Screens ordered left-to-right
local function sortedScreens()
    local screens = hs.screen.allScreens()
    table.sort(screens, function(a, b) return a:frame().x < b:frame().x end)
    return screens
end

-- Standard, visible windows belonging to an app, in a stable order.
-- Chrome launched with separate --user-data-dir (one per profile) runs as several
-- processes sharing a bundle ID, and each process only reports its own windows via
-- app:allWindows(). Scanning every window and matching on bundle ID catches them all,
-- which is how the AppWindowSwitcher spoon spans profiles too.
local function visibleStandardWindows(app)
    local bundleID = app:bundleID()
    local appName = app:name()

    local matched = {}
    for _, win in ipairs(hs.window.orderedWindows()) do
        local winApp = win:application()
        if winApp and win:isStandard() and win:isVisible() then
            local matches
            if bundleID then
                matches = winApp:bundleID() == bundleID
            else
                matches = winApp:name() == appName
            end
            if matches then
                table.insert(matched, { win = win, pid = winApp:pid() })
            end
        end
    end

    -- orderedWindows is z-order, which shifts on every focus change. Sort by process
    -- then window ID so repeated presses land the same windows in the same slots.
    table.sort(matched, function(a, b)
        if a.pid ~= b.pid then return a.pid < b.pid end
        return a.win:id() < b.win:id()
    end)

    local windows = {}
    for _, entry in ipairs(matched) do
        table.insert(windows, entry.win)
    end
    return windows
end

-- Store window frames for toggle functionality
local windowFramesU = {}
local lastCycledWindowIndex = {}
local distributionRotation = {}

-- Move focused window to center screen and maximize (with toggle)
hs.hotkey.bind(hyper, "u", function()
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("No focused window")
        return
    end

    local allScreens = hs.screen.allScreens()
    if #allScreens < 2 then
        hs.alert.show("Only one screen detected")
        return
    end

    local winId = win:id()

    -- Check if we have a stored frame for this window
    if windowFramesU[winId] then
        -- Restore previous position
        win:setFrame(windowFramesU[winId])
        windowFramesU[winId] = nil
    else
        -- Store current position and move to center screen and maximize
        windowFramesU[winId] = win:frame()
        local centerScreen = hs.screen.primaryScreen()
        win:moveToScreen(centerScreen)
        win:maximize()
    end
end)

-- Distribute all windows of current app across screens (with rotation)
hs.hotkey.bind(hyper, "n", function()
    local currentWin = hs.window.focusedWindow()
    if not currentWin then
        hs.alert.show("No focused window")
        return
    end

    -- Get all windows of the current application
    local app = currentWin:application()
    local appName = app:name()
    local visibleWindows = visibleStandardWindows(app)

    -- Get all screens
    local allScreens = hs.screen.allScreens()

    -- Get or initialize rotation offset for this app
    local rotationOffset = distributionRotation[appName] or 0

    -- Distribute windows across screens with rotation offset
    for i, win in ipairs(visibleWindows) do
        local screenIndex = ((i - 1 + rotationOffset) % #allScreens) + 1
        win:moveToScreen(allScreens[screenIndex])
        win:maximize()
    end

    -- Increment rotation offset for next time
    distributionRotation[appName] = (rotationOffset + 1) % #allScreens

    hs.alert.show("Distributed " .. #visibleWindows .. " windows across " .. #allScreens .. " screens")
end)

-- Cycle to next window of current app, then move to center screen and maximize
hs.hotkey.bind(hyper, "i", function()
    local currentWin = hs.window.focusedWindow()
    if not currentWin then
        hs.alert.show("No focused window")
        return
    end

    -- Get all windows of the current application
    local app = currentWin:application()
    local appName = app:name()
    local visibleWindows = visibleStandardWindows(app)

    -- If more than one window, cycle to the next one -- Get or initialize the last cycled index for this app
    local lastIndex = lastCycledWindowIndex[appName] or 0
    local nextIndex = (lastIndex % #visibleWindows) + 1

    -- Store the next index
    lastCycledWindowIndex[appName] = nextIndex

    -- Focus the next window
    visibleWindows[nextIndex]:focus()

    -- Move to center screen and maximize
    local win = visibleWindows[nextIndex]
    local allScreens = hs.screen.allScreens()
    if #allScreens >= 2 then
        local centerScreen = hs.screen.primaryScreen()
        win:moveToScreen(centerScreen)
    end
    win:maximize()
end)

hs.loadSpoon("AppWindowSwitcher")
-- :setLogLevel("debug") -- uncomment for console debug log
    :bindHotkeys({
        ["Google Chrome"] = { hyper, ";" },
        ["Code"] = { hyper, "j" },
        ["Ghostty"] = { hyper, "k" },
        ["XCode"] = { hyper, "x" },
        ["Finder"] = { hyper, "f" },
        ["Slack"] = { hyper, "l" },
        ["Hammerspoon"] = { hyper, "h" },
        ["Docker Desktop"] = { hyper, "d" },
        ["ChatGPT"] = { hyper, "g" },
        ["Mail"] = { hyper, "m" },
        ["qemu-system-aarch64"] = { hyper, "e" },
        ["1Password"] = { hyper, "p" },
        ["Simulator"] = { hyper, "s" },
    })

-- Half-screen screenshots: hyper+shift+1..6 captures the matching half to clipboard.
-- Screens sorted left-to-right; each screen contributes two halves (left then right).
-- 1 = screen 1 left, 2 = screen 1 right, 3 = screen 2 left, 4 = screen 2 right, ...
local function captureHalf(index)
    local screens = sortedScreens()
    local screenIdx = math.floor((index - 1) / 2) + 1
    local isRight = (index % 2 == 0)
    local screen = screens[screenIdx]
    if not screen then
        hs.alert.show("No screen at index " .. screenIdx)
        return
    end
    local f = screen:frame()
    local halfW = math.floor(f.w / 2)
    local x = isRight and (f.x + halfW) or f.x
    local rect = string.format("%d,%d,%d,%d", x, f.y, halfW, f.h)
    hs.task.new("/usr/sbin/screencapture", function(exitCode)
        if exitCode == 0 then
            hs.alert.show("Half " .. index .. " → clipboard")
        else
            hs.alert.show("Capture failed (" .. exitCode .. ")")
        end
    end, { "-c", "-x", "-R", rect }):start()
end

for i = 1, 6 do
    hs.hotkey.bind(hyper, tostring(i), function() captureHalf(i) end)
end

-- hyper+7: capture the whole center screen and append it to a collection.
-- The clipboard holds the newline-separated paths of everything collected so far,
-- so repeated presses build up a set of screenshots to paste in one go.
-- hyper+0 clears the collection.
local captureDir = os.getenv("HOME") .. "/Desktop/hs-captures"
local capturedPaths = {}

local function setClipboardToCaptures()
    hs.pasteboard.setContents(table.concat(capturedPaths, "\n"))
end

hs.hotkey.bind(hyper, "7", function()
    local screen = hs.screen.primaryScreen()
    if not screen then
        hs.alert.show("No center screen")
        return
    end

    hs.fs.mkdir(captureDir)
    local f = screen:fullFrame()
    local rect = string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h)
    local path = string.format("%s/capture-%s-%d.png", captureDir, os.date("%Y%m%d-%H%M%S"), #capturedPaths + 1)

    hs.task.new("/usr/sbin/screencapture", function(exitCode)
        if exitCode ~= 0 then
            hs.alert.show("Capture failed (" .. exitCode .. ")")
            return
        end
        table.insert(capturedPaths, path)
        setClipboardToCaptures()
        hs.alert.show(string.format("Captured center screen (%d in array)", #capturedPaths))
    end, { "-x", "-R", rect, path }):start()
end)

hs.hotkey.bind(hyper, "0", function()
    local count = #capturedPaths
    capturedPaths = {}
    setClipboardToCaptures()
    hs.alert.show(string.format("Cleared %d capture%s", count, count == 1 and "" or "s"))
end)

-- hyper+c: arrange Chrome windows in a 3-column split on the leftmost screen.
-- Repeated presses rotate which windows occupy the slots (deterministic).
local chromeRotation = 0
hs.hotkey.bind(hyper, "c", function()
    local chrome = hs.application.get("Google Chrome")
    if not chrome then
        hs.alert.show("Chrome not running")
        return
    end

    local windows = visibleStandardWindows(chrome)
    if #windows == 0 then
        hs.alert.show("No Chrome windows")
        return
    end

    local screen = sortedScreens()[1]
    local f = screen:frame()
    local colW = math.floor(f.w / 3)

    local slots = math.min(3, #windows)
    for slot = 1, slots do
        local idx = ((chromeRotation + slot - 1) % #windows) + 1
        local w = windows[idx]
        w:moveToScreen(screen)
        w:setFrame({
            x = f.x + colW * (slot - 1),
            y = f.y,
            w = (slot == 3) and (f.w - colW * 2) or colW,
            h = f.h,
        })
        w:raise()
    end

    chromeRotation = (chromeRotation + 1) % #windows
    hs.alert.show("Chrome split (rotation " .. chromeRotation .. "/" .. #windows .. ")")
end)

-- hyper+t: tile every window of the frontmost app across screen halves.
-- Halves run left-to-right across screens (screen 1 left, screen 1 right,
-- screen 2 left, ...), same ordering as the hyper+number screenshot bindings.
-- More windows than halves wraps around, stacking the extras.
local function screenHalves()
    local halves = {}
    for _, screen in ipairs(sortedScreens()) do
        local f = screen:frame()
        local halfW = math.floor(f.w / 2)
        table.insert(halves, { screen = screen, frame = { x = f.x, y = f.y, w = halfW, h = f.h } })
        table.insert(halves, { screen = screen, frame = { x = f.x + halfW, y = f.y, w = f.w - halfW, h = f.h } })
    end
    return halves
end

hs.hotkey.bind(hyper, "t", function()
    local focused = hs.window.focusedWindow()
    if not focused then
        hs.alert.show("No focused window")
        return
    end

    local app = focused:application()
    local windows = visibleStandardWindows(app)
    if #windows == 0 then
        hs.alert.show("No windows to tile")
        return
    end

    local halves = screenHalves()
    for i, win in ipairs(windows) do
        local half = halves[((i - 1) % #halves) + 1]
        win:moveToScreen(half.screen)
        win:setFrame(half.frame)
        win:raise()
    end

    hs.alert.show(string.format("Tiled %d %s windows across %d halves", #windows, app:name(), #halves))
end)

hs.alert.show("Config loaded")
