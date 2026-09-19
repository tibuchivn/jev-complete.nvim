-- tests/test_phase1.lua
-- Manual test suite for Phase 1 (candidate collection).
-- Run:
--   nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/test_phase1.lua" -c "qa!"
-- Exit code 0 when every case passes, 1 when any case fails.

local failures = 0
local passes = 0

local function ok(cond, label, detail)
  if cond then
    passes = passes + 1
    print("PASS: " .. label)
  else
    failures = failures + 1
    print("FAIL: " .. label .. (detail and (" -- " .. detail) or ""))
  end
end

local function eq(actual, expected, label)
  ok(
    actual == expected,
    label,
    "expected=" .. vim.inspect(expected) .. " actual=" .. vim.inspect(actual)
  )
end

local function set_lines(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local function index_by_lower(list)
  local idx = {}
  for _, entry in ipairs(list) do
    idx[entry.lower] = entry
  end
  return idx
end

local init = require("jev")
local source = require("jev.source")
local cache = require("jev.cache")

-- ---------------------------------------------------------------------------
-- Group 0: module interfaces
-- ---------------------------------------------------------------------------
print("== Group 0: interfaces ==")
eq(type(source.get_buffer_words), "function", "source.get_buffer_words is a function")
eq(type(source.is_valid_word), "function", "source.is_valid_word is a function")
eq(type(source.is_subsequence), "function", "source.is_subsequence is a function")
eq(type(source.filter_candidates), "function", "source.filter_candidates is a function")
eq(type(cache.get_words), "function", "cache.get_words is a function")
eq(type(cache.clear), "function", "cache.clear is a function")
eq(type(cache.stats), "function", "cache.stats is a function")

-- ---------------------------------------------------------------------------
-- Group 1: is_valid_word
-- ---------------------------------------------------------------------------
print("== Group 1: is_valid_word ==")
eq(source.is_valid_word("abc"), true, "3-letter word is valid")
eq(source.is_valid_word("ab"), false, "2-letter word is invalid (min_word_length=3)")
eq(source.is_valid_word("a"), false, "1-letter word is invalid")
eq(source.is_valid_word("123"), false, "all-digit word is invalid")
eq(source.is_valid_word("2nd"), true, "word starting with digit is valid")
eq(source.is_valid_word("my_var"), true, "underscore word is valid")

-- ---------------------------------------------------------------------------
-- Group 2: get_buffer_words
-- ---------------------------------------------------------------------------
print("== Group 2: get_buffer_words ==")
set_lines({
  "local hello = 1",
  "local help = 2",
  "local held = 3",
  'local world = "shell"',
  "local Foo = 4",
  "local foo = 5",
  "local my_var = 6",
  "local ab = 7",
  "local a = 8",
  "local 123 = 9",
  "local 2nd = 10",
  "local helicopter = 11",
})

local words = source.get_buffer_words()
local idx = index_by_lower(words)

eq(#words, 10, "sample buffer yields 10 unique words")
ok(idx["foo"] ~= nil, "keeps first-seen case 'Foo' (lower='foo')")
eq(idx["foo"] and idx["foo"].word, "Foo", "original case preserved on dedupe")
eq(idx["ab"], nil, "2-letter word filtered out")
eq(idx["a"], nil, "1-letter word filtered out")
eq(idx["123"], nil, "all-digit word filtered out")
ok(idx["2nd"] ~= nil, "digit-leading word kept")
ok(idx["my_var"] ~= nil, "underscore word kept")
ok(idx["local"] ~= nil, "repeated word deduped to one entry")
ok(idx["local"] and idx["local"].lower == "local", "lower field is lowercased")

-- ---------------------------------------------------------------------------
-- Group 3: cache hit
-- ---------------------------------------------------------------------------
print("== Group 3: cache hit ==")
cache.clear()
set_lines({ "alpha beta gamma", "delta epsilon zeta" })

local first = cache.get_words()
eq(#first, 6, "cache returns extracted words")
local after_first = cache.stats()
eq(after_first.misses, 1, "first call is a miss")
eq(after_first.hits, 0, "first call records no hit")

local second = cache.get_words()
local after_second = cache.stats()
eq(after_second.hits, 1, "second call is a hit")
eq(after_second.misses, 1, "second call does not add a miss")
eq(after_second.size, 1, "cache holds a single entry")
eq(#second, #first, "cached result matches original")

-- ---------------------------------------------------------------------------
-- Group 4: cache invalidation on buffer change
-- ---------------------------------------------------------------------------
print("== Group 4: cache invalidation ==")
cache.clear()
set_lines({ "first content here" })
local before = cache.get_words()
set_lines({ "second content changed" })
local after = cache.get_words()
local invalidation_stats = cache.stats()

eq(invalidation_stats.misses, 2, "buffer edit forces a second miss")
ok(#before == #after, "both extractions have same word count")
ok(index_by_lower(before)["first"] ~= nil, "before-change words present")
ok(index_by_lower(after)["second"] ~= nil, "after-change words present")
ok(index_by_lower(after)["first"] == nil, "stale words absent after edit")

-- ---------------------------------------------------------------------------
-- Group 5: filter_candidates
-- ---------------------------------------------------------------------------
print("== Group 5: filter_candidates ==")
local sample = { "hello", "help", "held", "world", "shell", "helicopter" }
local sample_words = {}
for _, w in ipairs(sample) do
  sample_words[#sample_words + 1] = { word = w, lower = w }
end

local filtered = source.filter_candidates("hel", sample_words)
eq(#filtered, 5, "drops non-matching 'world'")
eq(filtered[1].score, 996, "shortest prefix match ranked first (help/held)")
eq(filtered[2].score, 996, "tie at prefix score 996")
eq(filtered[3].score, 995, "hello at prefix score 995")
eq(filtered[4].score, 990, "helicopter at prefix score 990")
eq(filtered[5].score, 495, "subsequence match 'shell' ranked last")

local matched_words = {}
for _, entry in ipairs(filtered) do
  matched_words[entry.word] = true
end
eq(matched_words["world"], nil, "non-matching word excluded")

eq(#source.filter_candidates("", sample_words), 0, "empty prefix yields no candidates")

local none = source.filter_candidates("zzz", sample_words)
eq(#none, 0, "unmatched prefix yields no candidates")

eq(#source.filter_candidates("hello", sample_words), 1, "prefix equal to word matches")
eq(source.filter_candidates("hello", sample_words)[1].word, "hello", "exact word returned")

local long_prefix = source.filter_candidates("helpp", sample_words)
eq(#long_prefix, 0, "prefix longer than word does not match")

local many = {}
for i = 1, 40 do
  local w = "hel" .. i
  many[#many + 1] = { word = w, lower = w }
end
eq(#source.filter_candidates("hel", many), init.config.max_candidates, "result capped at max_candidates")

-- ---------------------------------------------------------------------------
-- Group 6: empty buffer
-- ---------------------------------------------------------------------------
print("== Group 6: empty buffer ==")
set_lines({})
eq(#source.get_buffer_words(), 0, "empty buffer yields no words")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print("")
print(string.format("TOTAL: %d passed, %d failed", passes, failures))

if failures > 0 then
  vim.cmd("cquit 1")
end
