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
    local task = hs.task.new("/Users/jorgen/.local/bin/copy-latest-screenshot.sh",
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                hs.alert.show("Screenshot copy failed")
            end
        end
    )
    task:start()
end)

hs.loadSpoon("AppWindowSwitcher")
-- :setLogLevel("debug") -- uncomment for console debug log
    :bindHotkeys({
        ["Google Chrome"] = { hyper, ";" },
    })

hs.alert.show("Config loaded")
