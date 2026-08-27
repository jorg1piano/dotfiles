-- Sidekick CLI chat with Claude, on <leader>ac.
return {
  { import = "lazyvim.plugins.extras.ai.sidekick" },
  {
    "folke/sidekick.nvim",
    opts = {
      -- NES (inline next-edit suggestions) needs a GitHub Copilot subscription,
      -- which isn't set up here — disable it and use only the CLI chat.
      nes = { enabled = false },
      cli = {
        mux = { enabled = false },
        tools = {
          claude = { cmd = { "claude" } },
        },
      },
    },
    keys = {
      {
        "<leader>ac",
        function()
          require("sidekick.cli").toggle({ name = "claude", focus = true })
        end,
        desc = "Sidekick Toggle Claude",
        mode = { "n", "v" },
      },
    },
  },
}
