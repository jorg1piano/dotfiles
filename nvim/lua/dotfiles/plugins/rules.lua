-- Better file-explorer icon for j1pstack .rules files.
-- Filetype detection, syntax, and ftplugin settings live in ~/dotfiles/nvim/options.lua,
-- ~/dotfiles/nvim/syntax/nudge_rules.vim, and ~/dotfiles/nvim/ftplugin/nudge_rules.vim.
return {
  {
    "echasnovski/mini.icons",
    opts = function(_, opts)
      opts.extension = opts.extension or {}
      opts.extension.rules = { glyph = "󰦨", hl = "MiniIconsPurple" }
    end,
  },
}
