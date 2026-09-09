VexProgressTrust = VexProgressTrust or {}

local pending = {}
local generation = 0

local function now()
    return GetGameTimer()
end

local function debugLog(message, ...)
    if not Config.Debug then
        return
    end

    print(('[vex_progress:server:trust] ' .. message):format(...))
end

local function makeKey(source, taskId)
    return ('%d:%s'):format(source, taskId)
end

local function createTaskId(source)
    generation = generation + 1

    return ('vp:%d:%d:%d'):format(
        source,
        os.time(),
        generation
    )
end

function VexProgressTrust.Create(source, expectedDuration)
    if type(source) ~= 'number' or source <= 0 then
        return false, 'INVALID_SOURCE'
    end

    if type(expectedDuration) ~= 'number'
        or expectedDuration < Config.MinDuration
        or expectedDuration > Config.MaxDuration then
        return false, 'INVALID_DURATION'
    end

    -- Cross-pipeline guard: sv_main.lua's pull-flow ledger (ActiveProgressions)
    -- is a separate global set up by server/sv_main.lua. It won't exist yet
    -- at file-load time (sv_trust.lua loads first per fxmanifest.lua), but
    -- by the time this function is actually CALLED (well after resource
    -- start) it will -- global lookups in Lua resolve at call time, not
    -- load time, so this is safe without reordering the manifest.
    if type(ActiveProgressions) == 'table' and ActiveProgressions[source] then
        debugLog('rejected push-flow create for %d: pull flow active', source)
        return false, 'PULL_FLOW_ACTIVE'
    end

    local taskId = createTaskId(source)
    local issuedAt = now()

    local record = {
        taskId = taskId,
        source = source,
        expectedDuration = expectedDuration,
        issuedAt = issuedAt,
        expiresAt =
            issuedAt
            + expectedDuration
            + Config.PendingTaskGracePeriod
    }

    pending[makeKey(source, taskId)] = record

    debugLog(
        'created pending task %s for %d',
        taskId,
        source
    )

    return taskId, record
end

function VexProgressTrust.Consume(source, taskId)
    if type(source) ~= 'number'
        or type(taskId) ~= 'string' then
        return false, 'INVALID_COMPLETION'
    end

    local key = makeKey(source, taskId)
    local record = pending[key]

    if not record then
        return false, 'UNKNOWN_TASK'
    end

    -- One-shot semantics:
    -- consume before further validation so the same correlation ID cannot be
    -- replayed regardless of whether this attempt succeeds.
    pending[key] = nil

    if record.source ~= source then
        return false, 'SOURCE_MISMATCH'
    end

    local elapsed = now() - record.issuedAt

    if elapsed <
        (record.expectedDuration - Config.EarlyCompletionTolerance) then

        return false, 'COMPLETED_TOO_EARLY'
    end

    if now() > record.expiresAt then
        return false, 'TASK_EXPIRED'
    end

    return true, {
        taskId = taskId,
        elapsed = elapsed,
        expectedDuration = record.expectedDuration
    }
end

function VexProgressTrust.Cancel(source, taskId)
    if type(source) ~= 'number'
        or type(taskId) ~= 'string' then
        return false
    end

    local key = makeKey(source, taskId)

    if not pending[key] then
        return false
    end

    pending[key] = nil

    return true
end

function VexProgressTrust.ClearPlayer(source)
    local prefix = ('%d:'):format(source)

    for key in pairs(pending) do
        if key:sub(1, #prefix) == prefix then
            pending[key] = nil
        end
    end
end

function VexProgressTrust.ClearAll()
    pending = {}
end

-- Used by sv_main.lua's pull-flow HandleStartAction to enforce the same
-- guard in the other direction (reject StartAction while a push-flow
-- session is outstanding for that source).
function VexProgressTrust.HasPendingForSource(source)
    if type(source) ~= 'number' then
        return false
    end

    local prefix = ('%d:'):format(source)

    for key in pairs(pending) do
        if key:sub(1, #prefix) == prefix then
            return true
        end
    end

    return false
end

CreateThread(function()
    while true do
        Wait(Config.PendingCleanupInterval)

        local tick = now()

        for key, record in pairs(pending) do
            if tick > record.expiresAt then
                if Config.Logging.expiredTasks then
                    print((
                        '[vex_progress] expired pending task %s for source %d'
                    ):format(
                        record.taskId,
                        record.source
                    ))
                end

                pending[key] = nil
            end
        end
    end
end)