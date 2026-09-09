--[[
    vex_progress :: client/cl_main.lua

    Orchestrates local progress-action execution for both transport flows:

      PUSH  (server-initiated, trust-authoritative)
        server: StartSecureProgress -> TriggerClientCallback(secureActionName)
        client: RegisterClientCallback(secureActionName, HandleSecureProgressAction)
        The handler call BLOCKS (yields via Wait) until the action finishes
        or is interrupted, then returns {success, taskId, reason} -- that
        return value IS the coroutine response the server is awaiting.
        Do not wrap this path in its own CreateThread; the yield needs to
        propagate back through vex_callback's machinery.

      PULL  (client-initiated, convenience)
        exports['vex_progress']:StartProgress(actionData, onComplete, onCancel)
        Validates and (if actionData.requiresServerAck) registers the timing
        window with the server BEFORE any visuals start, then runs the
        action in its OWN thread so the calling script's coroutine is not
        blocked for the full duration. Completion/interruption is delivered
        asynchronously via onComplete/onCancel, matching the original
        synchronous-accept/async-complete export contract.

    Both flows share one core runner (RunProgressAction) and one canonical
    cleanup path (FinishProgressAction), so there is exactly one place that
    ever touches anim/prop teardown or resets state to IDLE.

    This file does not implement animation, prop, or control-disable natives
    directly -- see cl_animation.lua and cl_controls.lua. It orchestrates.
--]]

-- ============================================================================
-- Canonical state (single active progression at a time)
-- ============================================================================

local VexProgressState = {
    status         = 'IDLE',   -- IDLE | ACTIVE | INTERRUPTING
    runId          = nil,      -- local thread-safety token (always set)
    taskId         = nil,      -- protocol id: server-issued for push flow,
                                -- locally generated otherwise
    pendingReason  = nil,
    startTick      = nil,
    originCoords   = nil,
    healthSnapshot = nil,
    vehicleSnapshot = nil,
    animHandle     = nil,
    propHandle     = nil,
    controlsLocked = {},
    actionData     = nil,
    callbacks      = { onComplete = nil, onCancel = nil }
}

local runGeneration = 0

local function GetState()
    return VexProgressState
end

local function debugLog(message, ...)
    if not Config.Debug then
        return
    end

    print(('[vex_progress:client:main] ' .. message):format(...))
end

-- ============================================================================
-- Snapshots
-- ============================================================================

local function CaptureVehicleSnapshot(ped)
    -- RDR3 horses/mounts use the vehicle native family, so this also covers
    -- "dismounted/remounted" as a vehicle-state change.
    local inVehicle = IsPedInAnyVehicle(ped, false)

    return {
        inVehicle = inVehicle,
        vehicle = inVehicle and GetVehiclePedIsIn(ped, false) or 0
    }
end

-- ============================================================================
-- vex_core speed-multiplier integration (cosmetic/local only -- see notes)
-- ============================================================================

local function GetSpeedMultiplier()
    local coreResource = Config.Core.resource
    local exportName = Config.Core.playerExport

    -- -- VERIFY: exact client-side GetPlayer() signature/return shape from
    -- vex_core. Assumed here: no-arg export returning a table with the
    -- configured progressSpeedField.
    local ok, player = pcall(function()
        return exports[coreResource][exportName]()
    end)

    if not ok or type(player) ~= 'table' then
        return 1.0
    end

    local raw = player[Config.Core.progressSpeedField]

    if not VexProgressUtils.IsFiniteNumber(raw) then
        return 1.0
    end

    return VexProgressUtils.Clamp(
        raw,
        Config.Core.minSpeedMultiplier,
        Config.Core.maxSpeedMultiplier
    )
end

local function ComputeLocalDuration(rawDuration)
    -- Cosmetic only: affects the local animation/NUI bar length. Never
    -- affects the duration used for server-side trust validation (that
    -- always uses the caller's raw actionData.duration), so a speed buff
    -- can't be used to shrink the server's verification window and a
    -- legitimately buffed player can't get flagged as COMPLETED_TOO_EARLY.
    local multiplier = GetSpeedMultiplier()

    return math.max(1, math.floor(rawDuration * multiplier))
end

-- ============================================================================
-- Interruption
-- ============================================================================

local function RequestInterrupt(reason)
    if VexProgressState.status ~= 'ACTIVE' then
        return
    end

    VexProgressState.status = 'INTERRUPTING'
    VexProgressState.pendingReason = reason
end

-- ============================================================================
-- Per-frame threads (control lock + manual cancel)
-- ============================================================================

local function StartCancelThread(runId)
    CreateThread(function()
        while true do
            local state = VexProgressState

            if state.status ~= 'ACTIVE' or state.runId ~= runId then
                return
            end

            if VexProgressControls.IsManualCancelPressed(state) then
                RequestInterrupt('MANUAL_CANCEL')
                return
            end

            Wait(0)
        end
    end)
end

-- ============================================================================
-- 250ms integrity thread (distance / vehicle / ragdoll / death)
--
-- Deliberately separate from the per-frame threads above: none of these
-- checks need per-frame resolution, and running them at Config
-- .IntegrityPollInterval instead of Wait(0) keeps idle cost down during
-- long-duration actions.
-- ============================================================================

local function StartIntegrityThread(runId)
    CreateThread(function()
        while true do
            local state = VexProgressState

            if state.status ~= 'ACTIVE' or state.runId ~= runId then
                return
            end

            local ped = PlayerPedId()

            if Config.InterruptOnDeath and IsEntityDead(ped) then
                RequestInterrupt('PLAYER_DIED')
                return
            end

            -- -- VERIFY: correct RDR3 ragdoll-state native/flag. IsPedRagdoll
            -- is assumed to exist with GTA-equivalent semantics; confirm
            -- against a live RDR3 build before enabling in production.
            if Config.InterruptOnRagdoll and IsPedRagdoll(ped) then
                RequestInterrupt('RAGDOLL')
                return
            end

            if Config.InterruptOnDistance and state.originCoords then
                local maxDistance =
                    (state.actionData and state.actionData.maxDistance)
                    or Config.DefaultMaxDistance

                local distance = #(GetEntityCoords(ped) - state.originCoords)

                if distance > maxDistance then
                    RequestInterrupt('DISTANCE_EXCEEDED')
                    return
                end
            end

            if Config.InterruptOnVehicleChange and state.vehicleSnapshot then
                local nowInVehicle = IsPedInAnyVehicle(ped, false)

                if nowInVehicle ~= state.vehicleSnapshot.inVehicle then
                    RequestInterrupt('VEHICLE_STATE_CHANGED')
                    return
                elseif nowInVehicle then
                    local currentVehicle = GetVehiclePedIsIn(ped, false)

                    if currentVehicle ~= state.vehicleSnapshot.vehicle then
                        RequestInterrupt('VEHICLE_STATE_CHANGED')
                        return
                    end
                end
            end

            Wait(Config.IntegrityPollInterval)
        end
    end)
end

-- ============================================================================
-- Damage interruption (event-driven, registered once)
--
-- -- VERIFY: CEventDamageEntity's exact arg shape on the live RDR3 build.
-- The victim-entity argument index below is an assumption and must be
-- confirmed before InterruptOnDamage is relied on in production; until
-- verified, treat this handler as best-effort.
-- ============================================================================

AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventDamageEntity' then
        return
    end

    if not Config.InterruptOnDamage or VexProgressState.status ~= 'ACTIVE' then
        return
    end

    local victim = args and args[1]

    if victim == PlayerPedId() then
        RequestInterrupt('DAMAGE_TAKEN')
    end
end)

-- ============================================================================
-- Canonical cleanup (single exit path for every ending: complete,
-- interrupt, or pre-empted by a newer run)
-- ============================================================================

local function FinishProgressAction(success, reason)
    local state = VexProgressState
    local ped = PlayerPedId()

    VexProgressAnimation.Cleanup(ped, state.animHandle, state.propHandle)

    local taskId = state.taskId
    local callbacks = state.callbacks

    local ok = pcall(function()
        SendNUIMessage({
            action = success and 'complete' or 'cancel',
            taskId = taskId
        })
    end)

    if not ok then
        debugLog('SendNUIMessage failed during cleanup for task %s', tostring(taskId))
    end

    state.status = 'IDLE'
    state.runId = nil
    state.taskId = nil
    state.pendingReason = nil
    state.startTick = nil
    state.originCoords = nil
    state.healthSnapshot = nil
    state.vehicleSnapshot = nil
    state.animHandle = nil
    state.propHandle = nil
    state.controlsLocked = {}
    state.actionData = nil
    state.callbacks = { onComplete = nil, onCancel = nil }

    if success then
        if callbacks and callbacks.onComplete then
            callbacks.onComplete()
        end
    else
        if callbacks and callbacks.onCancel then
            callbacks.onCancel(reason)
        end
    end

    return {
        success = success,
        taskId = taskId,
        reason = (not success) and reason or nil
    }
end

-- ============================================================================
-- Core runner -- shared by both flows. BLOCKS the calling coroutine until
-- the action finishes or is interrupted; callers that must not block
-- (the pull-flow export) wrap this in their own CreateThread.
-- ============================================================================

local function RunProgressAction(actionData, callbacks)
    local valid, validationReason = VexProgressUtils.ValidateActionData(actionData)

    if not valid then
        return { success = false, reason = validationReason }
    end

    if VexProgressState.status ~= 'IDLE' then
        return { success = false, reason = 'ALREADY_ACTIVE' }
    end

    runGeneration = runGeneration + 1

    local runId = ('%d:%d'):format(GetGameTimer(), runGeneration)
    local taskId = actionData.taskId or ('vp:local:%s'):format(runId)
    local ped = PlayerPedId()

    local state = VexProgressState
    state.status = 'ACTIVE'
    state.runId = runId
    state.taskId = taskId
    state.pendingReason = nil
    state.startTick = GetGameTimer()
    state.originCoords = GetEntityCoords(ped)
    state.healthSnapshot = GetEntityHealth(ped)
    state.vehicleSnapshot = CaptureVehicleSnapshot(ped)
    state.animHandle = nil
    state.propHandle = nil
    state.actionData = actionData
    state.callbacks = callbacks or {}
    state.controlsLocked = VexProgressUtils.CopyArray(
        actionData.disableControls or Config.DefaultDisabledControls
    )

    local localDuration = ComputeLocalDuration(actionData.duration)

    local animOk, animResult = VexProgressAnimation.Play(
        ped, actionData.animation, localDuration
    )

    if not animOk then
        return FinishProgressAction(false, animResult)
    end

    state.animHandle = animResult

    local propOk, propResult = VexProgressAnimation.CreateProp(ped, actionData.prop)

    if not propOk then
        return FinishProgressAction(false, propResult)
    end

    state.propHandle = propResult

    local sendOk = pcall(function()
        SendNUIMessage({
            action = 'start',
            taskId = taskId,
            duration = localDuration,
            label = actionData.label,
            useControl = actionData.useControl == true,
            layout = Config.UI.layout,
            style = {
                ring = Config.UI.ring,
                bar = Config.UI.bar,
                typography = Config.UI.typography
            }
        })
    end)

    if not sendOk then
        debugLog('SendNUIMessage failed on start for task %s', tostring(taskId))
    end

    VexProgressControls.StartLockThread(GetState, runId)
    StartCancelThread(runId)
    StartIntegrityThread(runId)

    while true do
        if VexProgressState.runId ~= runId then
            -- Superseded by a newer run before we could finish naturally --
            -- should not happen given the ALREADY_ACTIVE guard, but fail
            -- closed rather than silently returning a false success.
            return { success = false, taskId = taskId, reason = 'SUPERSEDED' }
        end

        if VexProgressState.status == 'INTERRUPTING' then
            local reason = VexProgressState.pendingReason
            return FinishProgressAction(false, reason)
        end

        if GetGameTimer() - VexProgressState.startTick >= localDuration then
            return FinishProgressAction(true, nil)
        end

        Wait(50)
    end
end

-- ============================================================================
-- PUSH flow: server-initiated, trust-authoritative
-- ============================================================================

local function HandleSecureProgressAction(data)
    if type(data) ~= 'table' then
        return { success = false, reason = 'INVALID_PAYLOAD' }
    end

    -- Runs synchronously (blocking/yielding) on purpose -- this return
    -- value is the coroutine response vex_callback delivers back to
    -- sv_main.lua's StartSecureProgress.
    return RunProgressAction(data, { onComplete = nil, onCancel = nil })
end

CreateThread(function()
    local callbackResource = Config.Callback.resource
    local registerExport = Config.Callback.registerClientExport
    local actionName = Config.Callback.secureActionName

    if type(actionName) ~= 'string' or #actionName == 0 then
        error('[vex_progress] Config.Callback.secureActionName is not set.')
    end

    local ok, err = pcall(function()
        exports[callbackResource][registerExport](
            actionName,
            HandleSecureProgressAction
        )
    end)

    if not ok then
        error((
            '[vex_progress] failed to register push-flow callback "%s" via %s: %s'
        ):format(actionName, callbackResource, tostring(err)))
    end

    debugLog('registered push-flow callback "%s"', actionName)
end)

-- ============================================================================
-- PULL flow: client-initiated convenience export
--
-- exports['vex_progress']:StartProgress(actionData, onComplete, onCancel)
--
-- Synchronous accept/reject, asynchronous completion -- does NOT block the
-- caller for the full duration (unlike the push-flow handler above, which
-- must block). Returns true if the action was accepted and is now running,
-- false if it was rejected outright (onCancel is still invoked with the
-- reason in the reject case, so callers only need one code path).
-- ============================================================================

local function StartProgress(actionData, onComplete, onCancel)
    if type(actionData) ~= 'table' then
        if onCancel then onCancel('INVALID_ACTION_DATA') end
        return false
    end

    if VexProgressState.status ~= 'IDLE' then
        if onCancel then onCancel('ALREADY_ACTIVE') end
        return false
    end

    local valid, validationReason = VexProgressUtils.ValidateActionData(actionData)

    if not valid then
        if onCancel then onCancel(validationReason) end
        return false
    end

    CreateThread(function()
        local remoteTaskId = nil

        if actionData.requiresServerAck == true then
            local callbackResource = Config.Callback.resource
            local triggerExport = Config.Callback.triggerServerExport
            local actionName = Config.Callback.startActionName

            if type(triggerExport) ~= 'string' or #triggerExport == 0 then
                if onCancel then onCancel('TRIGGER_SERVER_EXPORT_NOT_CONFIGURED') end
                return
            end

            -- Raw, caller-specified duration only -- see the file-level
            -- notes on why buff-adjusted duration never reaches the server.
            local ok, response = pcall(function()
                return exports[callbackResource][triggerExport](
                    actionName,
                    { duration = actionData.duration }
                )
            end)

            if not ok then
                if onCancel then onCancel('CALLBACK_TRANSPORT_FAILED') end
                return
            end

            if type(response) == 'table' and type(response.next) == 'function' then
                response = Citizen.Await(response)
            end

            if type(response) ~= 'table' or response.success ~= true then
                local rejectReason =
                    (type(response) == 'table' and response.reason)
                    or 'SERVER_START_REJECTED'

                if onCancel then onCancel(rejectReason) end
                return
            end

            remoteTaskId = response.token
        end

        local runActionData = VexProgressUtils.DeepCopy(actionData)
        runActionData.taskId = remoteTaskId

        RunProgressAction(runActionData, {
            onComplete = onComplete,
            onCancel = onCancel
        })
        -- Result already delivered via onComplete/onCancel inside
        -- FinishProgressAction; nothing further to do here.
    end)

    return true
end

exports('StartProgress', StartProgress)

-- ============================================================================
-- Additional exports (symmetry with the original modular export schema)
-- ============================================================================

exports('CancelProgressAction', function(reason)
    RequestInterrupt(VexProgressUtils.SanitizeReason(reason, 'MANUAL_CANCEL'))
    return true
end)

exports('IsProgressActive', function()
    return VexProgressState.status == 'ACTIVE'
end)

exports('GetActiveTaskId', function()
    return VexProgressState.taskId
end)

-- ============================================================================
-- Resource stop safety
-- ============================================================================

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    if VexProgressState.status == 'ACTIVE' then
        RequestInterrupt('RESOURCE_STOP')
    end
end)
