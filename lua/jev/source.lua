-- lua/jev/source.lua
-- Buffer word extraction and candidate filtering.

local init = require("jev")

local M = {}

-- A word is valid when it is at least min_word_length characters long and is
-- not made up entirely of digits. Digit-leading words such as "2nd" are kept.
function M.is_valid_word(word)
  if type(word) ~= "string" or #word < init.config.min_word_length then
    return false
  end
  if word:match("^%d+$") then
    return false
  end
  return true
end

-- Return the unique words of the current buffer.
-- Each entry is { word = "original_case", lower = "lowercase" }.
-- Deduplication is case-insensitive and keeps the first-seen original case.
-- min_word_length and max_extract_words are applied.
function M.get_buffer_words()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local seen = {}
  local words = {}

  for _, line in ipairs(lines) do
    for token in line:gmatch("[%w_]+") do
      if M.is_valid_word(token) then
        local lower = token:lower()
        if not seen[lower] then
          seen[lower] = true
          words[#words + 1] = { word = token, lower = lower }
          if #words >= init.config.max_extract_words then
            return words
          end
        end
      end
    end
  end

  return words
end

-- True when every character of `needle` appears in `haystack` in order.
function M.is_subsequence(needle, haystack)
  local n = #needle
  if n == 0 then
    return true
  end

  local i = 1
  for j = 1, #haystack do
    if haystack:sub(j, j) == needle:sub(i, i) then
      i = i + 1
      if i > n then
        return true
      end
    end
  end

  return false
end

-- Filter and rank buffer words against a prefix.
-- Returns entries sorted by score descending, capped at max_candidates.
-- Each entry is { word = "original_case", score = <number> }.
-- Prefix matches score 1000 - #word; subsequence matches score 500 - #word.
function M.filter_candidates(prefix, words)
  if not prefix or prefix == "" then
    return {}
  end

  local needle = prefix:lower()
  local needle_len = #needle
  local results = {}

  for _, entry in ipairs(words) do
    local lower = entry.lower
    local score

    if lower:sub(1, needle_len) == needle then
      score = 1000 - #lower
    elseif M.is_subsequence(needle, lower) then
      score = 500 - #lower
    end

    if score then
      results[#results + 1] = { word = entry.word, score = score }
    end
  end

  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  local limit = math.min(#results, init.config.max_candidates)
  local candidates = {}
  for i = 1, limit do
    candidates[i] = results[i]
  end

  return candidates
end

return M
