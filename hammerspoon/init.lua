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
}

for i, shortcut in ipairs(shortcuts) do
    hs.hotkey.bind(hyper, shortcut[1], function()
        hs.application.launchOrFocus(shortcut[2])
    end)
end

hs.hotkey.bind(hyper, "4", function()
    local task = hs.task.new("~/.local/bin/copy-latest-screenshot.sh",
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                hs.alert.show("Screenshot copy failed")
            end
        end
    )
    task:start()
end)

-- Store window frames for toggle functionality
local windowFramesU = {}
local lastCycledWindowIndex = {}

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
    local appWindows = app:allWindows()

    -- Filter to only standard windows (exclude minimized, hidden, etc)
    local visibleWindows = {}
    for _, win in ipairs(appWindows) do
        if win:isStandard() and win:isVisible() then
            table.insert(visibleWindows, win)
        end
    end

    -- Sort windows by ID to ensure consistent order
    table.sort(visibleWindows, function(a, b) return a:id() < b:id() end)

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
    })

hs.alert.show("Config loaded")
