-- Snacks explorer: show dotfiles in the sidebar.
return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        sources = {
          files = {
            -- Include files under hidden dirs such as .agents/skills.
            hidden = true,
            exclude = { ".git" },
            -- Keep gitignored build/cache output hidden unless toggled in picker.
            ignored = false,
          },
          grep = {
            hidden = true,
            exclude = { ".git" },
            ignored = false,
          },
          explorer = {
            -- Dotfiles (.claude, .github, .env…) are the ones worth opening;
            -- .git itself is noise, so it stays hidden.
            hidden = true,
            exclude = { ".git" },
            -- Gitignored files stay out; press I in the explorer to see them,
            -- H to hide dotfiles again.
            ignored = false,
          },
        },
      },
    },
  },
}
