-- Extra Neovim keymaps on top of LazyVim's defaults.
-- Loaded from ~/.config/nvim/lua/config/keymaps.lua via dofile.

-- Fuzzy find files from any directory, not just the project root or cwd.
-- Prompts for a path (tab-completes directories), then opens the Snacks
-- file picker rooted there. Hidden files are included; press <a-i> inside
-- the picker to also include gitignored files.
vim.keymap.set("n", "<leader>fa", function()
  vim.ui.input({ prompt = "Search from: ", default = "~/", completion = "dir" }, function(dir)
    if dir and dir ~= "" then
      Snacks.picker.files({ cwd = vim.fn.expand(dir), hidden = true })
    end
  end)
end, { desc = "Find files (any path)" })

vim.keymap.set("n", "<leader>fo", function()
  vim.fn.jobstart({ "open", vim.fn.expand("%:p:h") }, { detach = true })
end, { desc = "Open file directory" })

-- Send code to a Herdr agent pane with a comment attached: select a block (or
-- stay in normal mode to send just the file reference), write the context in
-- the popup, <CR> to submit.
vim.keymap.set({ "n", "v" }, "<leader>ah", function()
  require("dotfiles.herdr").send()
end, { desc = "Herdr: send to agent" })

vim.keymap.set({ "n", "v" }, "<leader>aH", function()
  require("dotfiles.herdr").send({ force = true })
end, { desc = "Herdr: send to agent (pick pane)" })

-- Collapse every comment in the buffer, leaving the code expanded. Toggling
-- back restores whatever folds the window had before.
vim.keymap.set("n", "<leader>zc", function()
  require("dotfiles.comment_folds").toggle()
end, { desc = "Toggle comment folds" })

-- Delete every line that starts with a # (leading whitespace allowed).
vim.api.nvim_create_user_command("DeleteComments", "g/^\\s*#/d", {})

-- Copy the current file's absolute path to the clipboard.
vim.api.nvim_create_user_command("CopyFilePath", function()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("Current buffer has no file path", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", path)
end, {})
