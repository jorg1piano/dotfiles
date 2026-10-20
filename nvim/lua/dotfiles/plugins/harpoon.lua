-- Shifted digits on the ABC (US) layout. Norwegian layout: !"#¤%&/()
local slot_keys = "!@#$%^&*("

local function pin_current_file_keys()
  local keys = {}
  for slot = 1, #slot_keys do
    table.insert(keys, {
      "<leader>" .. slot_keys:sub(slot, slot),
      function()
        require("harpoon"):list():replace_at(slot)
        vim.notify(("Harpoon slot %d: %s"):format(slot, vim.fn.expand("%:t")))
      end,
      desc = "Harpoon Pin to Slot " .. slot,
    })
  end
  return keys
end

return {
  { import = "lazyvim.plugins.extras.editor.harpoon2" },
  {
    "ThePrimeagen/harpoon",
    keys = pin_current_file_keys(),
  },
}
