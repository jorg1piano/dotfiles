-- Fold every comment in the buffer and nothing else.
--
-- Neovim's folding is level-based, so neither foldmethod=syntax nor the
-- treesitter foldexpr can single out comments. This walks the treesitter tree
-- for comment nodes and folds exactly the lines they cover. The window's own
-- fold settings are put back on toggle off, so LazyVim's structural folds
-- return untouched.

local M = {}

-- Grammars disagree on what a comment node is called, and a query naming a
-- node type the grammar lacks fails to parse as a whole, so each candidate is
-- compiled on its own and the ones that survive are unioned.
local comment_node_types = { "comment", "line_comment", "block_comment", "doc_comment" }

local lines_by_buf = {}
local saved_by_win = {}

local function comment_queries(lang)
  local queries = {}
  for _, node_type in ipairs(comment_node_types) do
    local ok, query = pcall(vim.treesitter.query.parse, lang, "(" .. node_type .. ") @comment")
    if ok then
      table.insert(queries, query)
    end
  end
  return queries
end

local function indent_width(buf, row)
  local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  return #text:match("^%s*")
end

local function collect(buf, query, root, lines)
  for _, node in query:iter_captures(root, buf) do
    local start_row, start_col, end_row, end_col = node:range()
    -- A node ending at column 0 stops on the line break above it.
    if end_col == 0 then
      end_row = end_row - 1
    end
    -- A comment trailing code shares its line with that code, which has to
    -- stay visible.
    if start_col > indent_width(buf, start_row) then
      start_row = start_row + 1
    end
    for line = start_row + 1, end_row + 1 do
      lines[line] = true
    end
  end
end

local function comment_lines(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end

  local queries = comment_queries(parser:lang())
  if #queries == 0 then
    return nil
  end

  local lines = {}
  for _, tree in ipairs(parser:parse()) do
    for _, query in ipairs(queries) do
      collect(buf, query, tree:root(), lines)
    end
  end
  return lines
end

function M.foldexpr()
  local buf = vim.api.nvim_get_current_buf()
  local lines = lines_by_buf[buf]
  if not lines then
    lines = comment_lines(buf) or {}
    lines_by_buf[buf] = lines
  end
  return lines[vim.v.lnum] and 1 or 0
end

local function restore(win)
  local saved = saved_by_win[win]
  saved_by_win[win] = nil
  vim.wo[win].foldexpr = saved.foldexpr
  vim.wo[win].foldmethod = saved.foldmethod
  vim.wo[win].foldenable = saved.foldenable
  vim.wo[win].foldlevel = saved.foldlevel
end

function M.toggle()
  local win = vim.api.nvim_get_current_win()
  if saved_by_win[win] then
    return restore(win)
  end

  local buf = vim.api.nvim_get_current_buf()
  local lines = comment_lines(buf)
  if not lines then
    vim.notify("No treesitter comments for " .. vim.bo[buf].filetype, vim.log.levels.WARN, {
      title = "Comment folds",
    })
    return
  end
  lines_by_buf[buf] = lines

  saved_by_win[win] = {
    foldexpr = vim.wo.foldexpr,
    foldmethod = vim.wo.foldmethod,
    foldenable = vim.wo.foldenable,
    foldlevel = vim.wo.foldlevel,
  }

  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'dotfiles.comment_folds'.foldexpr()"
  vim.wo.foldenable = true
  vim.wo.foldlevel = 0
end

local group = vim.api.nvim_create_augroup("dotfiles_comment_folds", { clear = true })

vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = group,
  callback = function(args)
    lines_by_buf[args.buf] = nil
  end,
})

vim.api.nvim_create_autocmd("BufUnload", {
  group = group,
  callback = function(args)
    lines_by_buf[args.buf] = nil
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    saved_by_win[tonumber(args.match)] = nil
  end,
})

return M
