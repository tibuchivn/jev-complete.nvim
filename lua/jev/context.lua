-- lua/jev/context.lua
-- Builds the context string sent to Jev, keeping it within a token budget.

local init = require("jev")

local M = {}

-- Rough token estimate: about four characters per token, rounded up.
function M.estimate_tokens(text)
  if not text or text == "" then
    return 0
  end
  return math.ceil(#text / 4)
end

-- Slice of the buffer to send, plus the cursor position inside that slice.
local function select_lines(lines, cursor_line)
  local full = table.concat(lines, "\n")

  if M.estimate_tokens(full) <= init.config.max_context_tokens then
    return lines, cursor_line
  end

  local half = math.floor(init.config.context_fallback_lines / 2)
  local first = math.max(1, cursor_line - half)
  local last = math.min(#lines, cursor_line + half)

  local window = {}
  for i = first, last do
    window[#window + 1] = lines[i]
  end

  return window, cursor_line - first + 1
end

-- Build the context string for the current buffer.
-- Small buffers are sent whole; larger ones fall back to a window around the
-- cursor. A "-- <CURSOR> --" marker is inserted after the cursor line so Jev
-- can tell where the completion would be inserted.
function M.build_context()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if #lines == 0 then
    return "-- <CURSOR> --"
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local selected, cursor_index = select_lines(lines, cursor_line)

  local out = {}
  for i, line in ipairs(selected) do
    out[#out + 1] = line
    if i == cursor_index then
      out[#out + 1] = "-- <CURSOR> --"
    end
  end

  return table.concat(out, "\n")
end

return M
