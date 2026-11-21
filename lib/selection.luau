--!nonstrict
-- Intelligent, non-repeating fact selection.
--
-- Scoring favours subjects, kinds and difficulty levels that have not appeared
-- recently, while still allowing every fact to surface eventually. Preferences
-- are soft: a filter never permanently hides part of the library.

local M = {}

local function hash(text)
  local h = 5381
  for i = 1, #text do
    h = ((h * 33) + text:byte(i)) % 2147483647
  end
  return h
end

function M.pick(facts, ctx)
  if #facts == 0 then return nil end

  local timeline = ctx.timeline or {}
  local byId = {}
  for _, fact in ipairs(facts) do byId[fact.id] = fact end

  -- Recent facts are strongly penalised, with a gradient so the oldest of the
  -- recent set can return before the newest one.
  local recentRank = {}
  local firstRecent = math.max(1, #timeline - 11)
  for i = firstRecent, #timeline do
    recentRank[timeline[i]] = (#timeline - i)
  end

  local recentSubjects, recentKinds = {}, {}
  for i = math.max(1, #timeline - 4), #timeline do
    local fact = byId[timeline[i]]
    if fact then recentSubjects[fact.subject] = true end
  end
  for i = math.max(1, #timeline - 6), #timeline do
    local fact = byId[timeline[i]]
    if fact then recentKinds[fact.kind] = true end
  end

  local current = byId[ctx.currentId]
  local preferred = ctx.difficulty or "any"
  local topics = ctx.topics or {}
  local hasTopics = #topics > 0
  local topicSet = {}
  for _, topic in ipairs(topics) do topicSet[topic:lower()] = true end

  local best, bestScore = nil, -math.huge
  local nowBucket = math.floor((ctx.nowMs or 0) / 1000)

  for _, fact in ipairs(facts) do
    if fact.id ~= ctx.currentId then
      local score = 100

      if recentRank[fact.id] then
        score = score - 55 - (12 - recentRank[fact.id]) * 3
      end
      if recentSubjects[fact.subject] then score = score - 14 end
      if not recentKinds[fact.kind] then score = score + 7 end
      if current and fact.difficulty ~= current.difficulty then score = score + 8 end

      if preferred ~= "any" then
        if fact.difficulty == preferred then score = score + 30 else score = score - 22 end
      end
      if hasTopics then
        if topicSet[fact.subject:lower()] then score = score + 22 else score = score - 10 end
      end

      -- A stable, time-bucketed tie-breaker: variety across sessions without
      -- making selection depend on a random seed that is lost on restart.
      score = score + ((hash(fact.id .. ":" .. tostring(nowBucket)) % 23) / 10)

      if score > bestScore then
        best, bestScore = fact, score
      end
    end
  end

  return best
end

return M
