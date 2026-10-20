-- Send code from Neovim to a Herdr agent pane with a comment attached.
--
-- Visual mode picks up the selected lines, normal mode just references the
-- file. Either way a floating scratch buffer opens for the comment, and the
-- whole thing is submitted with `herdr agent prompt`, which handles bracketed
-- paste so the agent sees one prompt rather than a line-by-line dribble.

local M = {}

-- Pane ids are stable for the life of a pane, so remembering the last target
-- keeps repeat sends to a single keypress. Validated against `agent list`
-- before reuse.
local last_target = nil

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Herdr" })
end

local function herdr(args)
  local result = vim.system(vim.list_extend({ "herdr" }, args), { text = true }):wait()
  if result.code ~= 0 then
    return nil, (result.stderr ~= "" and result.stderr or result.stdout)
  end
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok then
    return nil, "could not parse herdr output: " .. result.stdout
  end
  return decoded, nil
end

-- Agent panes worth offering: same Herdr workspace as this Neovim when we know
-- it (the pane on the left in a split, the agent tab next door), everything
-- otherwise.
local function agents()
  local decoded, err = herdr({ "agent", "list" })
  if not decoded then
    return nil, err
  end

  local workspace = vim.env.HERDR_WORKSPACE_ID
  local all = (decoded.result or {}).agents or {}
  local scoped = {}
  for _, agent in ipairs(all) do
    if not workspace or agent.workspace_id == workspace then
      table.insert(scoped, agent)
    end
  end
  if #scoped == 0 then
    scoped = all
  end
  return scoped, nil
end

local function describe(agent)
  local parts = { agent.pane_id, agent.agent or "agent" }
  local summary = (agent.tokens or {}).summary
  if summary and summary ~= "" then
    table.insert(parts, summary)
  else
    table.insert(parts, vim.fn.fnamemodify(agent.cwd or "", ":t"))
  end
  if agent.agent_status and agent.agent_status ~= "unknown" then
    parts[#parts] = parts[#parts] .. " (" .. agent.agent_status .. ")"
  end
  return table.concat(parts, "  ")
end

-- Resolves the pane to send to, asking only when the choice is ambiguous.
local function pick_target(opts, callback)
  local found, err = agents()
  if not found then
    notify("herdr agent list failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  if #found == 0 then
    notify("no agent panes found", vim.log.levels.WARN)
    return
  end

  if not opts.force then
    if last_target then
      for _, agent in ipairs(found) do
        if agent.pane_id == last_target then
          return callback(agent)
        end
      end
    end
    if #found == 1 then
      last_target = found[1].pane_id
      return callback(found[1])
    end
  end

  vim.ui.select(found, { prompt = "Send to agent:", format_item = describe }, function(choice)
    if not choice then
      return
    end
    last_target = choice.pane_id
    callback(choice)
  end)
end

-- File path as the agent will want to see it: relative to the repo root it is
-- most likely running in, or to cwd outside a repo.
local function display_path(bufnr)
  local absolute = vim.api.nvim_buf_get_name(bufnr)
  if absolute == "" then
    return "[No Name]"
  end
  local dir = vim.fn.fnamemodify(absolute, ":h")
  local root = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
  if vim.v.shell_error == 0 and root and root ~= "" then
    local relative = absolute:sub(#root + 2)
    if relative ~= "" then
      return relative
    end
  end
  return vim.fn.fnamemodify(absolute, ":.")
end

local function selected_range()
  local mode = vim.fn.mode()
  if not mode:match("^[vV\22]") then
    return nil
  end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  -- Leave visual mode so the selection highlight does not linger behind the
  -- comment window.
  vim.cmd([[execute "normal! \<Esc>"]])
  return math.min(a, b), math.max(a, b)
end

local function build_prompt(context, comment)
  local lines = { comment, "", context.reference }
  if context.code then
    vim.list_extend(lines, { "", "```" .. (context.filetype or ""), context.code, "```" })
  end
  return table.concat(lines, "\n")
end

local function send(target, context, comment)
  local text = build_prompt(context, comment)
  vim.system({ "herdr", "agent", "prompt", target.pane_id, text }, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        notify("sent " .. context.reference .. " to " .. target.pane_id)
      else
        local err = result.stderr ~= "" and result.stderr or result.stdout
        notify("send failed: " .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

-- Floating scratch buffer for the comment. <CR> in normal mode or <C-s>
-- anywhere sends; q or <Esc><Esc> in normal mode cancels.
local function prompt_comment(title, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(90, math.max(50, math.floor(vim.o.columns * 0.6)))
  local height = 8
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " <CR> send · q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local comment = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    comment = vim.trim(comment)
    close()
    if comment == "" then
      notify("nothing sent — comment was empty", vim.log.levels.WARN)
      return
    end
    on_submit(comment)
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf })
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.cmd.startinsert()
end

-- opts.force re-asks which agent to send to instead of reusing the last one.
function M.send(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local path = display_path(bufnr)
  local first, last = selected_range()

  local context = { filetype = vim.bo[bufnr].filetype }
  if first then
    context.reference = string.format("%s:%d-%d", path, first, last)
    context.code = table.concat(vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false), "\n")
  else
    context.reference = path
  end

  pick_target(opts, function(target)
    prompt_comment(context.reference .. " → " .. target.pane_id, function(comment)
      send(target, context, comment)
    end)
  end)
end

return M
