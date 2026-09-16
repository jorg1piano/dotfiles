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

-- Collapse every comment in the buffer, leaving the code expanded. Toggling
-- back restores whatever folds the window had before.
vim.keymap.set("n", "<leader>zc", function()
  require("dotfiles.comment_folds").toggle()
end, { desc = "Toggle comment folds" })
