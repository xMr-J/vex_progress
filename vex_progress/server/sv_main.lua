--[[
    vex_progress :: server/sv_main.lua

    Tamper-resistant progress-action validator.

    THREAT MODEL / DESIGN NOTES (read before wiring this into a reward path):

    1. This module answers exactly one question: "did enough real, server-
       measured wall-clock time elapse between StartAction and
       VerifyActionCompletion for source X?" It uses GetGameTimer() (RedM's
       monotonic wall-clock native), never os.clock() (CPU time — unrelated
       to elapsed real time and unsafe for this purpose) and never any
       client-reported timestamp.

    2. This module does NOT answer "was this player allowed to start this
       action?" StartAction is triggered by the client, so the start
       timestamp is client-*timed* (the client decides when to invoke the
       callback), even though it is server-*recorded*. A modified client can
       call StartAction whenever it wants. It is the responsibility of the
       CALLING GAMEPLAY RESOURCE to gate eligibility (correct item, correct
       zone, cooldown, resource node state, etc.) BEFORE it ever cues the
       client to begin the local vex_progress bar that leads to this call.
       If you need the server itself to be the trust anchor for *when* an
       action starts (stronger guarantee, no client-timing surface at all),
       use a push-based flow instead: have the calling resource invoke
       TriggerClientCallback so the server -- not the client -- originates
       the timing window.

    3. One active progression per `source` at a time, mirroring the client's
       single-slot state machine (IDLE guard). This is a deliberate
       constraint, not an oversight -- concurrent progressions are rejected
       rather than queued.

    4. VerifyActionCompletion is one-shot: the record is consumed on first
       call regardless of outcome, matching the existing correlation-ID
       discipline in sv_trust.lua. A calling resource must NOT retry a
       failed verification to "wait it out" -- COMPLETED_TOO_EARLY is a
       terminal result for that session.
--]]

local RESOURCE = GetCurrentResourceName()

-- ============================================================================
-- Secure action ledger
-- ============================================================================

ActiveProgressions = {}

-- Seed math.random with the best entropy readily available. This is NOT a
-- cryptographic RNG -- stock Lua / FXServer expose no CSPRNG. The token below
-- is defense-in-depth against ID guessing/collision; it is not the security
-- boundary. The security boundary is `source`, taken from the callback's
-- native transport-level invoker, never from the payload.
math.randomseed(GetGameTimer() + (os.time() or 0))

local function debugLog(message, ...)
    if not Config.Debug then
        return
    end

    print(('[vex_progress:server:main] ' .. message):format(...))
end

local function logLifecycle(message, ...)
    if not Config.Logging.lifecycle then
        return
    end

    print(('[vex_progress:server:main] ' .. message):format(...))
end

local function logRejectedStart(source, reason)
    if not Config.Logging.rejectedStarts then
        return
    end

    print((
        '[vex_progress] rejected StartAction source=%s reason=%s'
    ):format(tostring(source), tostring(reason)))
end

local function logRejectedCompletion(source, reason)
    if not Config.Logging.rejectedCompletions then
        return
    end

    print((
        '[vex_progress] rejected VerifyActionCompletion source=%s reason=%s'
    ):format(tostring(source), tostring(reason)))
end

-- High-entropy (not cryptographic) session token. Bound into the record and
-- currently not required back from the client, since `source` binding at
-- the transport level already prevents cross-player interference; kept so
-- a future stricter mode can require it to be echoed back without a schema
-- change.
local function generateToken(source)
    return ('%08x-%08x-%04x'):format(
        GetGameTimer() & 0xFFFFFFFF,
        math.random(0, 0xFFFFFFFF),
        (source or 0) % 0xFFFF
    )
end

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function isValidSource(source)
    return type(source) == 'number' and source > 0
end

local function clampDuration(duration)
    if not VexProgressUtils.IsFiniteNumber(duration) then
        return nil, 'INVALID_DURATION'
    end

    if duration < Config.MinDuration or duration > Config.MaxDuration then
        return nil, 'DURATION_OUT_OF_RANGE'
    end

    return duration
end

local function clearSource(source)
    ActiveProgressions[source] = nil
end

-- ============================================================================
-- StartAction handler
--
-- Registered as a server callback via vex_callback. Per the VEX callback
-- contract (see config.lua Config.Callback), this is invoked BY the client
-- and resolves synchronously (direct return) or via a promise/coroutine --
-- both shapes are supported below. -- VERIFY exact handler signature against
-- the live vex_callback RegisterServerCallback implementation; this assumes
-- handler(source, data) -> table.
-- ============================================================================

local function HandleStartAction(source, data)
    if not isValidSource(source) then
        logRejectedStart(source, 'INVALID_SOURCE')
        return { success = false, reason = 'INVALID_SOURCE' }
    end

    if ActiveProgressions[source] then
        logRejectedStart(source, 'ALREADY_ACTIVE')
        return { success = false, reason = 'ALREADY_ACTIVE' }
    end

    -- Cross-pipeline guard, mirrors the check added to
    -- VexProgressTrust.Create in sv_trust.lua: refuse to open a pull-flow
    -- session while a push-flow session is outstanding for this source, so
    -- the two independent ledgers can never both be ticking for one player.
    if type(VexProgressTrust) == 'table'
        and VexProgressTrust.HasPendingForSource(source) then
        logRejectedStart(source, 'PUSH_FLOW_ACTIVE')
        return { success = false, reason = 'PUSH_FLOW_ACTIVE' }
    end

    if type(data) ~= 'table' then
        logRejectedStart(source, 'INVALID_PAYLOAD')
        return { success = false, reason = 'INVALID_PAYLOAD' }
    end

    local duration, durationErr = clampDuration(data.duration)

    if not duration then
        logRejectedStart(source, durationErr)
        return { success = false, reason = durationErr }
    end

    local issuedAt = GetGameTimer()
    local token = generateToken(source)

    local record = {
        token = token,
        source = source,
        expectedDuration = duration,
        issuedAt = issuedAt,
        expiresAt = issuedAt + duration + Config.PendingTaskGracePeriod,
        consumed = false
    }

    ActiveProgressions[source] = record

    logLifecycle(
        'started source=%d duration=%d token=%s',
        source, duration, token
    )

    return {
        success = true,
        token = token,
        expectedDuration = duration
    }
end

local function RegisterStartActionCallback()
    local callbackResource = Config.Callback.resource
    local registerExport = Config.Callback.registerServerExport
    local actionName = Config.Callback.startActionName

    if type(actionName) ~= 'string' or #actionName == 0 then
        error(
            '[vex_progress] Config.Callback.startActionName is not set. '
            .. 'Add it to config.lua before this resource can start.'
        )
    end

    local ok, err = pcall(function()
        exports[callbackResource][registerExport](
            actionName,
            HandleStartAction
        )
    end)

    if not ok then
        error((
            '[vex_progress] failed to register start-action callback '
            .. '"%s" via %s: %s'
        ):format(actionName, callbackResource, tostring(err)))
    end

    debugLog('registered start-action callback "%s"', actionName)
end

CreateThread(RegisterStartActionCallback)

-- ============================================================================
-- Public server API
-- ============================================================================
--
-- exports['vex_progress']:VerifyActionCompletion(source)
--
-- Call this from a gameplay resource IMMEDIATELY BEFORE granting any reward,
-- item, or cash consequence tied to a progress action. It:
--   1. Requires an active, matching record for `source` (one created via
--      StartAction).
--   2. Consumes the record on first call (one-shot -- cannot be replayed).
--   3. Confirms elapsed server wall-clock time >= expectedDuration minus the
--      configured jitter tolerance.
--   4. Confirms the record has not gone stale past its grace-period expiry.
--
-- Returns:
--   true                      -- timing verified, safe to proceed
--   false, reasonCode (string) -- rejected; do NOT grant the reward
--
-- This function tells you nothing about whether the player was eligible to
-- start the action in the first place -- that is the calling resource's job,
-- enforced before it ever tells the client to begin.
-- ============================================================================

local function VerifyActionCompletion(source)
    if not isValidSource(source) then
        return false, 'INVALID_SOURCE'
    end

    local record = ActiveProgressions[source]

    if not record then
        logRejectedCompletion(source, 'NO_ACTIVE_PROGRESSION')
        return false, 'NO_ACTIVE_PROGRESSION'
    end

    -- One-shot: consume before further validation so this record cannot be
    -- verified twice regardless of the outcome below.
    clearSource(source)

    local nowTick = GetGameTimer()
    local elapsed = nowTick - record.issuedAt

    if elapsed < (record.expectedDuration - Config.EarlyCompletionTolerance) then
        logRejectedCompletion(source, 'COMPLETED_TOO_EARLY')
        return false, 'COMPLETED_TOO_EARLY'
    end

    if nowTick > record.expiresAt then
        logRejectedCompletion(source, 'TASK_EXPIRED')
        return false, 'TASK_EXPIRED'
    end

    logLifecycle(
        'verified source=%d elapsed=%d expected=%d',
        source, elapsed, record.expectedDuration
    )

    return true
end

exports('VerifyActionCompletion', VerifyActionCompletion)

-- Explicit cancel, for calling resources that need to abandon a tracked
-- session without granting anything (e.g. the gameplay precondition became
-- false mid-action). Idempotent.
exports('CancelActionTracking', function(source)
    if not isValidSource(source) then
        return false
    end

    if not ActiveProgressions[source] then
        return false
    end

    clearSource(source)
    logLifecycle('cancelled source=%d', source)

    return true
end)

-- Read-only introspection for debugging/tooling. Deliberately does not
-- expose the token.
exports('IsTrackingSource', function(source)
    return isValidSource(source) and ActiveProgressions[source] ~= nil
end)

-- ============================================================================
-- Automatic disconnect cleanup
-- ============================================================================

AddEventHandler('playerDropped', function()
    local source = source -- luacheck: ignore

    if ActiveProgressions[source] then
        clearSource(source)
        debugLog('cleared session for dropped player %s', tostring(source))
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RESOURCE then
        return
    end

    ActiveProgressions = {}
    debugLog('cleared all sessions on resource stop')
end)

-- ============================================================================
-- Stale-session sweep
--
-- Covers the case where a client called StartAction but never triggered (or
-- was never able to trigger) a corresponding VerifyActionCompletion -- e.g.
-- the calling resource errored, the player alt-F4'd without a clean
-- playerDropped in time, or the client abandoned the action without a
-- cancel path reaching the server. Without this sweep those records would
-- sit in ActiveProgressions forever, permanently blocking that source from
-- starting a new tracked action (see the ALREADY_ACTIVE guard above).
-- ============================================================================

CreateThread(function()
    while true do
        Wait(Config.PendingCleanupInterval)

        local nowTick = GetGameTimer()

        for src, record in pairs(ActiveProgressions) do
            if nowTick > record.expiresAt then
                if Config.Logging.expiredTasks then
                    print((
                        '[vex_progress] expired tracked session '
                        .. 'source=%s token=%s'
                    ):format(tostring(src), tostring(record.token)))
                end

                ActiveProgressions[src] = nil
            end
        end
    end
end)
