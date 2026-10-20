-- Render Markdown in the buffer; reveal the source around the cursor for editing.
return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-mini/mini.icons" },
    opts = {
      heading = { sign = false },
      code = { sign = false, width = "block", right_pad = 1 },
      checkbox = { enabled = true },
    },
    config = function(_, opts)
      local markdown = require("render-markdown")
      markdown.setup(opts)
      Snacks.toggle({
        name = "Render Markdown",
        get = markdown.get,
        set = markdown.set,
      }):map("<leader>um")
    end,
  },
}
