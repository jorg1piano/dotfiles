-- Extra Neovim options tracked in ~/dotfiles.

-- Make ftplugin/ and syntax/ files stored in ~/dotfiles/nvim available to Neovim.
vim.opt.runtimepath:prepend(vim.fn.expand("~/dotfiles/nvim"))

-- Treat .rules files (j1pstack reviewer rules) as their own format for clearer highlighting.
vim.filetype.add({ extension = { rules = "nudge_rules" } })

-- Hide whitespace markers like tab arrows and trailing-space dots.
vim.opt.list = false
