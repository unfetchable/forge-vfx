local types = require("@root/types")
local logger = require("@mod/logger")
local utility = require("@mod/utility")
local emitters = require("@root/emitters")

local Promise = require("@pkg/Promise")

local EffectSelectors = table.concat({
  "Beam",
  "Trail",
  "ParticleEmitter",

  -- Beziers
  `.{utility.BEZIER_TAG}`,

  -- Lightning bolts
  `.{utility.LIGHTNING_TAG}`,

  -- Spin models
  "Model",

  -- Camera shakes
  "RayValue",

  -- Screen effects
  "BasePart[$Enabled=true]",

  -- Shockwave effects
  "#Rings > Part",
  "#Lines > Part",
  "#Debris > Part",
}, ",")

local effects = {}

local api_ref: types.Api?

function effects.init(api: types.Api)
  api_ref = api
end

function effects.deinit()
  api_ref = nil
end

-- Emits nested effects from a list of instances
-- This is the function that effects should use for emitting nested effects
function effects.emit(depth: number, ...: Instance): types.EmitEnv
  if not api_ref or not api_ref.setup then
    logger.error("effects service not initialized")
    return { Finished = Promise.resolve() }
  end

  local sharedUncMap: { [Instance]: number } = {}
  local sharedRefMap: { [Instance]: Instance } = {}

  local legacyScale = 1

  local list = { ... }
  local rootPromises = {}

  local function queryAndEmitDescendants(obj: Instance, baseDepth: number): { any }
    local allDescendants = obj:QueryDescendants(EffectSelectors)
    local total = #allDescendants

    if total == 0 then
      return {}
    end

    local nestedEffectHandlers = {}

    for index = 1, total do
      local desc = allDescendants[index]

      if utility.shouldSkipNested(desc) then
        nestedEffectHandlers[desc] = true
      end
    end

    -- filter and emit valid effects
    local promises = table.create(total)
    local promiseCount = 0
    local skipCache = { [obj] = false }
    local depthCache = { [obj] = baseDepth }

    local function shouldSkip(instance: Instance): boolean
      local cached = skipCache[instance]

      if cached ~= nil then
        return cached
      end

      local current = instance
      local skip = false
      local visited = {}

      while current and current ~= obj do
        visited[current] = true
        skip = nestedEffectHandlers[current] == true

        if skip then
          break
        end

        local cachedParentSkip = skipCache[current]

        if cachedParentSkip ~= nil then
          skip = cachedParentSkip
          break
        end

        current = current.Parent
      end

      for inst in visited do
        skipCache[inst] = skip
      end

      return skip
    end

    local function getDepth(instance: Instance): number
      local cached = depthCache[instance]

      if cached then
        return cached
      end

      local current = instance
      local stack = {}

      while current do
        local cachedDepth = depthCache[current]

        if cachedDepth then
          break
        end

        table.insert(stack, current)

        local parent = current.Parent

        if parent and parent ~= obj then
          current = parent
        else
          depthCache[current] = baseDepth + 1
          break
        end
      end

      for i = #stack, 1, -1 do
        local child = stack[i]
        depthCache[child] = depthCache[child.Parent] + 1
      end

      return depthCache[instance]
    end

    for index = 1, total do
      local desc = allDescendants[index]

      if shouldSkip(desc) then
        continue
      end

      promiseCount += 1

      promises[promiseCount] = utility.createEmitPromise(effects, desc, getDepth(desc), function(scope)
        emitters.dispatch(desc, scope, sharedUncMap, sharedRefMap, api_ref.caches.shared_part, legacyScale)
      end)
    end

    return promises
  end

  for _, obj in list do
    -- screen effects
    if
      obj:IsA("BasePart")
      and obj:GetAttribute("Enabled")
      and not utility.findFirstClassWithTag(obj, "Attachment", utility.SHOCKWAVE_TAG)
    then
      if utility.lock(obj) then
        continue
      end

      local anc = obj:FindFirstAncestorOfClass("Model")

      if anc and not utility.isSpinModelStatic(anc) then
        continue
      end

      local lockThread = coroutine.running()

      local scope = {}
      scope.depth = depth
      scope.effects = effects

      local await = emitters.screen(obj, scope)

      if await then
        local innerPromises = queryAndEmitDescendants(obj, depth + 1)

        if #innerPromises > 0 then
          table.insert(
            rootPromises,
            Promise.all(innerPromises):finally(function()
              utility.unlock(obj, lockThread)
              utility.cleanupScope(scope)
            end)
          )
        else
          utility.unlock(obj, lockThread)
          utility.cleanupScope(scope)
        end
      end
    -- other effects
    else
      table.insert(
        rootPromises,
        utility.createEmitPromise(effects, obj, depth, function(scope)
          emitters.dispatch(obj, scope, sharedUncMap, sharedRefMap, api_ref.caches.shared_part, legacyScale)
        end)
      )

      if not utility.shouldSkipNested(obj) then
        local descendantPromises = queryAndEmitDescendants(obj, depth + 1)

        for _, promise in descendantPromises do
          table.insert(rootPromises, promise)
        end
      end
    end
  end

  local env = {
    Finished = Promise.all(rootPromises),
  }

  return env
end

-- Helper function to prepare EmitOnFinish folder
-- Call this when setting up an effect to extract the EmitOnFinish folder
-- Returns the EmitOnFinish folder or nil
function effects.prepareEmitOnFinish(obj: Instance, scope: types.scope): Folder?
  local emitOnFinish = obj:FindFirstChild("EmitOnFinish")

  if emitOnFinish and emitOnFinish:IsA("Folder") then
    emitOnFinish.Parent = nil
    table.insert(scope, emitOnFinish)
    return emitOnFinish
  end

  return nil
end

-- Helper function to emit nested effects during the effect
-- Call this to emit effects that are children of the cloned part
-- Returns an env with Finished promise that resolves when all nested effects finish
function effects.emitNested(part: Instance, depth: number): types.EmitEnv
  if not api_ref or not api_ref.setup then
    return { Finished = Promise.resolve() }
  end

  local children = part:GetChildren()

  if #children == 0 then
    return { Finished = Promise.resolve() }
  end

  return effects.emit(depth, table.unpack(children))
end

-- Helper function to emit EmitOnFinish effects at the end of an effect
-- Call this when the effect finishes to emit the EmitOnFinish children
-- The children will be parented to the targetParent before emitting
-- Returns an env with Finished promise that resolves when all EmitOnFinish effects finish
function effects.emitOnFinish(emitOnFinish: Folder?, targetParent: Instance, depth: number): types.EmitEnv
  if not emitOnFinish then
    return { Finished = Promise.resolve() }
  end

  local children = emitOnFinish:GetChildren()

  if #children == 0 then
    return { Finished = Promise.resolve() }
  end

  for _, child in children do
    child.Parent = targetParent
  end

  return effects.emit(depth, table.unpack(children))
end

return effects
