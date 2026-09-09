VexProgressUtils = VexProgressUtils or {}

local function isFinite(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function VexProgressUtils.IsFiniteNumber(value)
    return isFinite(value)
end

function VexProgressUtils.Clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

function VexProgressUtils.CopyArray(input)
    local output = {}

    if type(input) ~= 'table' then
        return output
    end

    for i = 1, #input do
        output[i] = input[i]
    end

    return output
end

function VexProgressUtils.DeepCopy(value, seen)
    if type(value) ~= 'table' then
        return value
    end

    seen = seen or {}

    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy

    for key, child in pairs(value) do
        copy[VexProgressUtils.DeepCopy(key, seen)] =
            VexProgressUtils.DeepCopy(child, seen)
    end

    return copy
end

function VexProgressUtils.SanitizeReason(reason, fallback)
    if type(reason) ~= 'string' then
        return fallback or 'UNKNOWN'
    end

    reason = reason:upper():gsub('[^A-Z0-9_%-]', '_')

    if #reason == 0 then
        return fallback or 'UNKNOWN'
    end

    return reason:sub(1, 64)
end

function VexProgressUtils.ValidateVectorTable(value)
    if type(value) ~= 'table' then
        return false
    end

    return isFinite(value.x or value[1])
        and isFinite(value.y or value[2])
        and isFinite(value.z or value[3])
end

function VexProgressUtils.NormalizeVectorTable(value)
    if not VexProgressUtils.ValidateVectorTable(value) then
        return nil
    end

    return {
        x = value.x or value[1],
        y = value.y or value[2],
        z = value.z or value[3]
    }
end

function VexProgressUtils.ValidateActionData(actionData)
    if type(actionData) ~= 'table' then
        return false, 'INVALID_ACTION_DATA'
    end

    if not isFinite(actionData.duration) then
        return false, 'INVALID_DURATION'
    end

    if actionData.duration < Config.MinDuration
        or actionData.duration > Config.MaxDuration then
        return false, 'DURATION_OUT_OF_RANGE'
    end

    if type(actionData.label) ~= 'string'
        or #actionData.label == 0
        or #actionData.label > 128 then
        return false, 'INVALID_LABEL'
    end

    if actionData.useControl ~= nil
        and type(actionData.useControl) ~= 'boolean' then
        return false, 'INVALID_USE_CONTROL'
    end

    if Config.RequireExplicitServerAckFlag
        and type(actionData.requiresServerAck) ~= 'boolean' then
        return false, 'SERVER_ACK_FLAG_REQUIRED'
    end

    if actionData.maxDistance ~= nil then
        if not isFinite(actionData.maxDistance)
            or actionData.maxDistance < 0.0 then
            return false, 'INVALID_MAX_DISTANCE'
        end
    end

    if actionData.disableControls ~= nil then
        if type(actionData.disableControls) ~= 'table' then
            return false, 'INVALID_CONTROL_LIST'
        end

        for _, control in ipairs(actionData.disableControls) do
            if type(control) ~= 'number' then
                return false, 'INVALID_CONTROL'
            end
        end
    end

    if actionData.animation ~= nil then
        local animation = actionData.animation

        if type(animation) ~= 'table'
            or type(animation.dict) ~= 'string'
            or #animation.dict == 0
            or type(animation.name) ~= 'string'
            or #animation.name == 0 then
            return false, 'INVALID_ANIMATION'
        end

        if animation.flags ~= nil
            and type(animation.flags) ~= 'table' then
            return false, 'INVALID_ANIMATION_FLAGS'
        end
    end

    if actionData.prop ~= nil then
        local prop = actionData.prop

        if type(prop) ~= 'table' then
            return false, 'INVALID_PROP'
        end

        if type(prop.model) ~= 'string'
            and type(prop.model) ~= 'number' then
            return false, 'INVALID_PROP_MODEL'
        end

        if type(prop.bone) ~= 'string' or #prop.bone == 0 then
            return false, 'INVALID_PROP_BONE'
        end

        if not VexProgressUtils.ValidateVectorTable(prop.offset) then
            return false, 'INVALID_PROP_OFFSET'
        end

        if not VexProgressUtils.ValidateVectorTable(prop.rotation) then
            return false, 'INVALID_PROP_ROTATION'
        end
    end

    return true
end