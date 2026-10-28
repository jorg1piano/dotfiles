-- Define hyper
hyper = { "cmd", "alt", "ctrl" }

-- Supress lanugage warning about unknown global variable
hs = hs

-- Cap every Accessibility call at 200 ms. An app that stops answering (a hung VLC once
-- held each hotkey for 1.5 s) then costs at most that per call.
hs.window.timeout(0.2)

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

-- Screens ordered left-to-right
local function sortedScreens()
    local screens = hs.screen.allScreens()
    table.sort(screens, function(a, b) return a:frame().x < b:frame().x end)
    return screens
end

-- Every running process of an app. Chrome launched with separate --user-data-dir (one
-- per profile) runs as several processes sharing a bundle ID, and each process only
-- reports its own windows via app:allWindows().
local function appProcesses(app)
    local bundleID = app:bundleID()
    if not bundleID then return { app } end
    return hs.application.applicationsForBundleID(bundleID)
end

local function isSameApp(a, b)
    if a:bundleID() then return a:bundleID() == b:bundleID() end
    return a:pid() == b:pid()
end

-- Standard, visible windows belonging to an app, in a stable order. Only the app's own
-- processes are asked for windows. hs.window.orderedWindows() asks every running app,
-- which costs ~25 ms per app and stalls on any app that has stopped answering.
local function visibleStandardWindows(app)
    local matched = {}
    for _, proc in ipairs(appProcesses(app)) do
        for _, win in ipairs(proc:allWindows()) do
            if win:isStandard() and win:isVisible() then
                table.insert(matched, { win = win, pid = proc:pid() })
            end
        end
    end

    -- Sort by process then window ID so repeated presses land the same windows in the
    -- same slots.
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

-- Hyper+key app switching. When the app isn't frontmost, activate it: one call to the
-- app, no window enumeration, and macOS brings its last-used window forward. When it is
-- frontmost, raise its backmost window, so repeated presses cycle through all of them.
local function focusApp(name, launchName)
    local app = hs.application.get(name)
    if not app then
        hs.application.launchOrFocus(launchName or name)
        return
    end

    local front = hs.application.frontmostApplication()
    if not (front and isSameApp(front, app)) then
        app:activate()
        return
    end

    local byId = {}
    for _, win in ipairs(visibleStandardWindows(app)) do
        byId[win:id()] = win
    end
    -- Front-to-back window IDs straight from the window server, no Accessibility calls.
    local ids = hs.window._orderedwinids()
    for i = #ids, 1, -1 do
        local win = byId[ids[i]]
        if win then
            win:raise():focus()
            return
        end
    end
end

-- { key, running app name, name to launch with when it differs }
local appHotkeys = {
    { ";", "Google Chrome" },
    { "j", "Code", "Visual Studio Code" },
    { "k", "Ghostty" },
    { "f", "Finder" },
    { "l", "Slack" },
    { "h", "Hammerspoon" },
    { "d", "Docker Desktop" },
    { "'", "Docker Desktop" },
    { "g", "ChatGPT" },
    { "x", "ChatGPT" },
    { "m", "Mail" },
    { "e", "qemu-system-aarch64" },
    { "s", "Simulator" },
}

for _, entry in ipairs(appHotkeys) do
    hs.hotkey.bind(hyper, entry[1], function() focusApp(entry[2], entry[3]) end)
end

-- Draw a red border around a captured region for a second so it's obvious what was shot.
-- Called after screencapture exits, so the border never lands in the image.
local function flashRect(rect)
    local c = hs.canvas.new(rect)
    c:level(hs.canvas.windowLevels.overlay)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:appendElements({
        type = "rectangle",
        action = "stroke",
        strokeColor = { red = 1, green = 0, blue = 0, alpha = 1 },
        strokeWidth = 8,
    })
    c:show()
    hs.timer.doAfter(1, function()
        c:hide(0.2)
        hs.timer.doAfter(0.25, function() c:delete() end)
    end)
end

-- Screenshot collection: the clipboard holds newline-separated paths of everything
-- collected so far, so a single paste hands over every capture in order.
-- hyper+9 starts a group (clears the collection); hyper+1..6 then save to files and
-- append instead of copying an image. hyper+9 again stops the group. hyper+7 appends
-- the center screen at any time. hyper+0 clears.
local captureDir = os.getenv("HOME") .. "/Desktop/hs-captures"
local capturedPaths = {}
local groupActive = false

local function setClipboardToCaptures()
    hs.pasteboard.setContents(table.concat(capturedPaths, "\n"))
end

local function nextCapturePath()
    hs.fs.mkdir(captureDir)
    return string.format("%s/capture-%s-%d.png", captureDir, os.date("%Y%m%d-%H%M%S"), #capturedPaths + 1)
end

local function captureRectToCollection(frame, label)
    local rect = string.format("%d,%d,%d,%d", frame.x, frame.y, frame.w, frame.h)
    local path = nextCapturePath()
    hs.task.new("/usr/sbin/screencapture", function(exitCode)
        if exitCode ~= 0 then
            hs.alert.show("Capture failed (" .. exitCode .. ")")
            return
        end
        table.insert(capturedPaths, path)
        setClipboardToCaptures()
        flashRect(frame)
        hs.alert.show(string.format("%s (%d in group)", label, #capturedPaths))
    end, { "-x", "-R", rect, path }):start()
end

-- Half-screen screenshots: hyper+1..6 captures the matching half to clipboard, or into
-- the group when hyper+9 has started one.
-- Screens sorted left-to-right; each screen contributes two halves (left then right).
-- 1 = screen 1 left, 2 = screen 1 right, 3 = screen 2 left, 4 = screen 2 right, ...
-- Digits pressed within chordWindow seconds of each other combine: consecutive halves merge into one
-- rect (1,2 = all of screen 1), gaps give separate shots (1,2,5,6 = screens 1 and 3).
-- Non-contiguous halves are shot separately and stitched side by side into one image.
local function halfFrame(index)
    local screens = sortedScreens()
    local screenIdx = math.floor((index - 1) / 2) + 1
    local isRight = (index % 2 == 0)
    local screen = screens[screenIdx]
    if not screen then return nil end
    local f = screen:frame()
    local halfW = math.floor(f.w / 2)
    local x = isRight and (f.x + halfW) or f.x
    return { x = x, y = f.y, w = halfW, h = f.h }
end

local function unionFrame(a, b)
    local x1, y1 = math.min(a.x, b.x), math.min(a.y, b.y)
    local x2, y2 = math.max(a.x + a.w, b.x + b.w), math.max(a.y + a.h, b.y + b.h)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Turn a set of half indices into one frame per run of consecutive indices.
local function chordFrames(indices)
    table.sort(indices)
    local runs = {}
    local run
    for _, i in ipairs(indices) do
        local f = halfFrame(i)
        if not f then
            hs.alert.show("No screen for half " .. i)
        elseif run and i == run.last then
            -- same digit pressed twice; ignore
        elseif run and i == run.last + 1 then
            run.frame = unionFrame(run.frame, f)
            run.last = i
            run.label = run.label .. "," .. i
        else
            run = { frame = f, last = i, label = tostring(i) }
            table.insert(runs, run)
        end
    end
    return runs
end

-- Stitch several PNGs side by side into one image.
local function stitchImages(paths)
    local images, totalW, maxH = {}, 0, 0
    for _, path in ipairs(paths) do
        local img = hs.image.imageFromPath(path)
        if not img then return nil end
        local sz = img:size()
        table.insert(images, { img = img, w = sz.w, h = sz.h })
        totalW = totalW + sz.w
        maxH = math.max(maxH, sz.h)
    end
    local c = hs.canvas.new({ x = 0, y = 0, w = totalW, h = maxH })
    local xOff = 0
    for _, e in ipairs(images) do
        c:appendElements({
            type = "image",
            image = e.img,
            imageScaling = "none",
            frame = { x = xOff, y = 0, w = e.w, h = e.h },
        })
        xOff = xOff + e.w
    end
    local out = c:imageFromCanvas()
    c:delete()
    return out
end

-- Capture each run to a temp file in order, then hand all paths to done().
local function captureRunsToFiles(runs, done)
    local paths = {}
    local function step(i)
        local r = runs[i]
        if not r then return done(paths) end
        local f = r.frame
        local rect = string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h)
        local path = string.format("%s/part-%s-%d.png", captureDir, os.date("%Y%m%d-%H%M%S"), i)
        hs.task.new("/usr/sbin/screencapture", function(exitCode)
            if exitCode ~= 0 then
                hs.alert.show("Capture failed (" .. exitCode .. ")")
                return
            end
            flashRect(f)
            table.insert(paths, path)
            step(i + 1)
        end, { "-x", "-R", rect, path }):start()
    end
    hs.fs.mkdir(captureDir)
    step(1)
end

local function captureChord(indices)
    local runs = chordFrames(indices)
    if #runs == 0 then return end
    local labels = {}
    for _, r in ipairs(runs) do table.insert(labels, r.label) end
    local label = "Halves " .. table.concat(labels, "+")

    if #runs == 1 and groupActive then
        captureRectToCollection(runs[1].frame, label)
        return
    end

    if #runs == 1 then
        local f = runs[1].frame
        local rect = string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h)
        hs.task.new("/usr/sbin/screencapture", function(exitCode)
            if exitCode == 0 then
                flashRect(f)
                hs.alert.show(label .. " → clipboard")
            else
                hs.alert.show("Capture failed (" .. exitCode .. ")")
            end
        end, { "-c", "-x", "-R", rect }):start()
        return
    end

    -- Non-contiguous halves: shoot each run, stitch into one image.
    captureRunsToFiles(runs, function(paths)
        local img = stitchImages(paths)
        for _, p in ipairs(paths) do os.remove(p) end
        if not img then
            hs.alert.show("Stitch failed")
            return
        end
        if groupActive then
            local path = nextCapturePath()
            img:saveToFile(path)
            table.insert(capturedPaths, path)
            setClipboardToCaptures()
            hs.alert.show(string.format("%s (%d in group)", label, #capturedPaths))
        else
            hs.pasteboard.writeObjects(img)
            hs.alert.show(label .. " → clipboard")
        end
    end)
end

local chordWindow = 0.8
local pendingHalves = {}
local chordTimer

local function pressHalf(index)
    table.insert(pendingHalves, index)
    if chordTimer then chordTimer:stop() end
    chordTimer = hs.timer.doAfter(chordWindow, function()
        local indices = pendingHalves
        pendingHalves = {}
        chordTimer = nil
        captureChord(indices)
    end)
end

for i = 1, 6 do
    hs.hotkey.bind(hyper, tostring(i), function() pressHalf(i) end)
end

-- Half-screen recordings: hyper+shift+1..6 toggles a video recording of the
-- matching half, same layout as the hyper+1..6 screenshots. First press starts,
-- second press stops, saves the .mov to ~/Desktop and copies its path. Clicks are
-- drawn into the video (-k).
local hyperShift = { "cmd", "alt", "ctrl", "shift" }
local recordings = {}

-- While any half recording runs, shift+drag draws a red rectangle on screen so viewers
-- can see what's being pointed at. The drag is swallowed, so apps don't see shift-clicks
-- until recording stops. Each rectangle fades out a few seconds after release.
local annotation = { start = nil, canvas = nil }

local function annotationFrame(a, b)
    return {
        x = math.min(a.x, b.x), y = math.min(a.y, b.y),
        w = math.max(math.abs(a.x - b.x), 1), h = math.max(math.abs(a.y - b.y), 1),
    }
end

local annotationTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp,
}, function(event)
    local kind = event:getType()
    local types = hs.eventtap.event.types
    local pos = event:location()

    if kind == types.leftMouseDown then
        if not event:getFlags().shift then return false end
        annotation.start = pos
        local c = hs.canvas.new(annotationFrame(pos, pos))
        c:level(hs.canvas.windowLevels.overlay)
        c:behavior({ "canJoinAllSpaces", "stationary" })
        c:clickActivating(false)
        c:appendElements({
            type = "rectangle",
            action = "stroke",
            strokeColor = { red = 1, green = 0, blue = 0, alpha = 1 },
            strokeWidth = 4,
        })
        c:show()
        annotation.canvas = c
        return true
    end

    if not annotation.start then return false end

    if kind == types.leftMouseDragged then
        annotation.canvas:frame(annotationFrame(annotation.start, pos))
    else
        local c = annotation.canvas
        annotation.start, annotation.canvas = nil, nil
        hs.timer.doAfter(3, function()
            c:hide(0.4)
            hs.timer.doAfter(0.5, function() c:delete() end)
        end)
    end
    return true
end)

local function updateAnnotationTap()
    if next(recordings) then annotationTap:start() else annotationTap:stop() end
end

local function toggleRecordHalf(index)
    local active = recordings[index]
    if active then
        -- screencapture finalizes the movie on SIGINT; the exit callback reports it.
        active:interrupt()
        return
    end

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
    local path = string.format("%s/Desktop/recording-half%d-%s.mov",
        os.getenv("HOME"), index, os.date("%Y%m%d-%H%M%S"))

    recordings[index] = hs.task.new("/usr/sbin/screencapture", function(exitCode)
        recordings[index] = nil
        updateAnnotationTap()
        if exitCode == 0 then
            hs.pasteboard.setContents(path)
            hs.alert.show("Half " .. index .. " recording saved (path copied)")
        else
            hs.alert.show("Recording failed (" .. exitCode .. ")")
        end
    end, { "-v", "-k", "-R", rect, path }):start()
    updateAnnotationTap()
    hs.alert.show("Recording half " .. index .. "… shift+drag to highlight, press again to stop")
end

for i = 1, 6 do
    hs.hotkey.bind(hyperShift, tostring(i), function() toggleRecordHalf(i) end)
end

hs.hotkey.bind(hyper, "9", function()
    if groupActive then
        groupActive = false
        setClipboardToCaptures()
        hs.alert.show(string.format("Group done: %d capture%s on clipboard", #capturedPaths, #capturedPaths == 1 and "" or "s"))
    else
        groupActive = true
        capturedPaths = {}
        setClipboardToCaptures()
        hs.alert.show("Group started: hyper+1..6 to capture, hyper+9 to stop")
    end
end)

hs.hotkey.bind(hyper, "7", function()
    local screen = hs.screen.primaryScreen()
    if not screen then
        hs.alert.show("No center screen")
        return
    end
    captureRectToCollection(screen:fullFrame(), "Captured center screen")
end)

hs.hotkey.bind(hyper, "0", function()
    local count = #capturedPaths
    capturedPaths = {}
    groupActive = false
    setClipboardToCaptures()
    hs.alert.show(string.format("Cleared %d capture%s", count, count == 1 and "" or "s"))
end)

-- hyper+c: open the Sectioned overlay to pick a region to screenshot or record; c again
-- inside the overlay repeats the last action on the last region. The URL launches Sectioned
-- first if it isn't running; pressing again closes the overlay or stops a recording.
hs.hotkey.bind(hyper, "c", function()
    hs.urlevent.openURL("sectioned://capture")
end)

-- hyper+§: arrange Chrome windows in a 3-column split on the leftmost screen.
-- Repeated presses rotate which windows occupy the slots (deterministic).
-- § is the ISO section key, bound by keycode (10).
local chromeRotation = 0
hs.hotkey.bind(hyper, 10, function()
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

-- hyper+o: tile every window of the frontmost app on the screen it already lives on.
-- Up to three windows go side by side as columns; four or more fall into the squarest
-- grid that fits them, filled left-to-right then top-to-bottom. Nothing moves between
-- screens, so this is the single-screen counterpart to hyper+t.
local function gridShape(count)
    if count <= 3 then
        return count, 1
    end
    local cols = math.ceil(math.sqrt(count))
    return cols, math.ceil(count / cols)
end

hs.hotkey.bind(hyper, "o", function()
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

    -- The focused window's screen, not the primary one: tile where the eyes already are.
    local screen = focused:screen()
    local f = screen:frame()
    local cols, rows = gridShape(#windows)
    local cellW = math.floor(f.w / cols)
    local cellH = math.floor(f.h / rows)

    for i, win in ipairs(windows) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        -- Windows parked on another screen get pulled in first; setFrame alone is
        -- unreliable across a screen boundary.
        win:moveToScreen(screen)
        -- The right column and bottom row absorb the rounding remainder so the
        -- tiling covers the full frame instead of leaving a sliver of desktop.
        win:setFrame({
            x = f.x + cellW * col,
            y = f.y + cellH * row,
            w = (col == cols - 1) and (f.w - cellW * col) or cellW,
            h = (row == rows - 1) and (f.h - cellH * row) or cellH,
        })
        win:raise()
    end

    hs.alert.show(string.format("Tiled %d %s windows in %dx%d", #windows, app:name(), cols, rows))
end)

-- hyper+p: PromptBox, a floating editor for writing prompts to terminal agents.
-- Remembers the window that was focused, opens PromptBox on that window's screen, and gives
-- focus back when PromptBox hides. ⌘↩ in PromptBox puts the prompt on the clipboard and
-- sends promptbox-paste, which pastes it into that window. Press hyper+p again to hide.
local promptBoxBundleID = "no.devda.PromptBox"
local promptBoxTarget = nil

hs.hotkey.bind(hyper, "p", function()
    local front = hs.application.frontmostApplication()
    if front and front:bundleID() == promptBoxBundleID then
        hs.urlevent.openURL("promptbox://hide")
        return
    end
    promptBoxTarget = hs.window.focusedWindow()
    local url = "promptbox://show"
    if promptBoxTarget then
        local f = promptBoxTarget:frame()
        url = string.format("%s?x=%d&y=%d", url, f.x + f.w / 2, f.y + f.h / 2)
    end
    hs.urlevent.openURL(url)
end)

local function refocusPromptBoxTarget()
    if not promptBoxTarget then return false end
    return pcall(function() promptBoxTarget:focus() end)
end

hs.urlevent.bind("promptbox-closed", function()
    refocusPromptBoxTarget()
end)

hs.urlevent.bind("promptbox-paste", function()
    if refocusPromptBoxTarget() then
        hs.timer.doAfter(0.15, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
    end
end)

-- Replace the selected text with the output of a stdin→stdout script.
-- Copies the selection, runs it through the script, pastes the result over the
-- selection, then puts the original clipboard back.
-- opts: { working = "...", unchanged = "...", done = "...", name = "..." }
local function replaceSelectionVia(script, opts)
    local savedClipboard = hs.pasteboard.getContents()
    local changeCount = hs.pasteboard.changeCount()

    hs.eventtap.keyStroke({ "cmd" }, "c", 0)

    -- Give the app a moment to put the selection on the clipboard.
    hs.timer.doAfter(0.2, function()
        local text = hs.pasteboard.getContents()
        if hs.pasteboard.changeCount() == changeCount or not text or text == "" then
            hs.alert.show("No text selected")
            return
        end

        hs.alert.show(opts.working)
        local stdout = {}
        local task = hs.task.new("/bin/zsh", function(exitCode, _, stderr)
            local result = table.concat(stdout)
            if exitCode ~= 0 or result == "" then
                hs.alert.show(opts.name .. " failed (" .. exitCode .. ")")
                print(opts.name .. " stderr: " .. tostring(stderr))
                hs.pasteboard.setContents(savedClipboard)
                return
            end
            -- Model output ends with a newline the selection didn't have.
            result = result:gsub("\n$", "")
            if result == text then
                hs.alert.show(opts.unchanged)
                hs.pasteboard.setContents(savedClipboard)
                return
            end
            hs.pasteboard.setContents(result)
            hs.eventtap.keyStroke({ "cmd" }, "v", 0)
            hs.alert.show(opts.done)
            hs.timer.doAfter(0.3, function()
                if savedClipboard then hs.pasteboard.setContents(savedClipboard) end
            end)
        end, function(_, out)
            table.insert(stdout, out)
            return true
        end, { "-lc", "exec " .. script })
        task:setInput(text)
        task:start()
        task:closeInput()
    end)
end

-- hyper+y: fix typos in the selected text via scripts/fix-typos
-- (claude -p with a fix-typos-only system prompt).
hs.hotkey.bind(hyper, "y", function()
    replaceSelectionVia(os.getenv("HOME") .. "/dotfiles/scripts/fix-typos", {
        name = "fix-typos",
        working = "Fixing typos…",
        unchanged = "No typos found",
        done = "Typos fixed",
    })
end)

-- hyper+shift+y: translate the selected English text to Norwegian via
-- scripts/translate-no.
hs.hotkey.bind(hyperShift, "y", function()
    replaceSelectionVia(os.getenv("HOME") .. "/dotfiles/scripts/translate-no", {
        name = "translate-no",
        working = "Translating to Norwegian…",
        unchanged = "Already Norwegian",
        done = "Translated",
    })
end)

hs.alert.show("Config loaded")
