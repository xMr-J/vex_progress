VexProgressControls = VexProgressControls or {}

function VexProgressControls.StartLockThread(stateAccessor, taskId)
    CreateThread(function()
        while true do
            local state = stateAccessor()

            if state.status ~= 'ACTIVE'
                or state.taskId ~= taskId then
                return
            end

            for _, controlId in ipairs(state.controlsLocked or {}) do
                DisableControlAction(0, controlId, true)
            end

            Wait(0)
        end
    end)
end

function VexProgressControls.IsManualCancelPressed(state)
    if not Config.ManualCancel.enabled then
        return false
    end

    if not state.actionData
        or state.actionData.useControl ~= true then
        return false
    end

    return IsControlJustPressed(
        0,
        Config.ManualCancel.control
    )
end