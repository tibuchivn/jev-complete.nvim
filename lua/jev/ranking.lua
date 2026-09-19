-- lua/jev/ranking.lua
-- Builds Jev questions, parses answers, and ranks candidates.

local init = require("jev")

local M = {}

-- Score levels for the "score" primitive, ordered least to most relevant.
local SCORE_LEVELS = { "irrelevant", "weak", "moderate", "strong", "perfect" }

-- Assemble the state string: context followed by the candidate list.
-- NOTE: this layout can be adjusted if Jev ranks poorly in practice.
function M.build_state(context, candidates)
  local lines = { context, "", "---", "Candidate list:" }
  for _, candidate in ipairs(candidates) do
    lines[#lines + 1] = "- " .. candidate.word
  end
  return table.concat(lines, "\n")
end

-- Build the questions table for the configured format.
-- Question names use a "cand_" prefix and the lowercased word so they stay
-- valid identifiers and cannot collide.
function M.build_questions(candidates)
  local format = init.config.jev_question_format
  local questions = {}

  if format == "choice" then
    local criteria = {}
    for _, candidate in ipairs(candidates) do
      criteria[candidate.lower] = "Word '" .. candidate.word .. "' as a completion"
    end
    questions.best_candidate = {
      type = "choice",
      criteria = criteria,
      instructions = "Which candidate best fits the current code context?",
    }
    return questions
  end

  for _, candidate in ipairs(candidates) do
    if format == "score" then
      questions["cand_" .. candidate.lower] = {
        type = "score",
        criteria = SCORE_LEVELS,
        instructions = "How relevant is '" .. candidate.word .. "' to the current code context?",
      }
    else
      questions["cand_" .. candidate.lower] = {
        type = "noul",
        instructions = "Does the word '" .. candidate.word
          .. "' fit the current code context better than other candidates?",
      }
    end
  end

  return questions
end

-- Normalize a "score" answer to a 0-1 probability.
local function normalize_score(answer)
  local raw = answer.score
  if raw == nil then
    return 0
  end

  if type(raw) == "number" then
    local index = math.floor(raw)
    local span = #SCORE_LEVELS - 1
    if span <= 0 then
      return 0
    end
    index = math.max(1, math.min(#SCORE_LEVELS, index))
    return (index - 1) / span
  end

  for index, level in ipairs(SCORE_LEVELS) do
    if level == raw then
      return (index - 1) / (#SCORE_LEVELS - 1)
    end
  end

  return 0
end

-- Parse raw Jev answers into a map of lowercased word -> probability.
-- Candidates without a usable answer get probability 0.
function M.parse_response(answers, format, candidates)
  local probabilities = {}
  answers = answers or {}

  if format == "choice" then
    local answer = answers.best_candidate
    local given = answer and answer.probabilities or {}
    for _, candidate in ipairs(candidates) do
      probabilities[candidate.lower] = given[candidate.lower] or 0
    end
    return probabilities
  end

  for _, candidate in ipairs(candidates) do
    local answer = answers["cand_" .. candidate.lower]
    if not answer then
      probabilities[candidate.lower] = 0
    elseif format == "score" then
      probabilities[candidate.lower] = normalize_score(answer)
    else
      probabilities[candidate.lower] = answer.noul or 0
    end
  end

  return probabilities
end

-- Rank candidates by Jev probability, falling back to the fuzzy score when
-- Jev is not confident enough to override. Returns a new list.
function M.rank_candidates(candidates, probabilities)
  probabilities = probabilities or {}

  local ranked = {}
  for _, candidate in ipairs(candidates) do
    local probability = probabilities[candidate.lower]

    local final_score
    if probability and probability >= init.config.confidence_threshold then
      final_score = probability * 10000 + candidate.score
    else
      final_score = candidate.score
    end

    ranked[#ranked + 1] = {
      word = candidate.word,
      lower = candidate.lower,
      score = candidate.score,
      probability = probability,
      final_score = final_score,
    }
  end

  table.sort(ranked, function(a, b)
    return a.final_score > b.final_score
  end)

  return ranked
end

return M
