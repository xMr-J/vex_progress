VexProgressAnimation = VexProgressAnimation or {}

local function debugLog(message, ...)
    if not Config.Debug then
        return
    end

    print(('[vex_progress:client:animation] ' .. message):format(...))
end

local function waitForCondition(predicate, timeout)
    local deadline = GetGameTimer() + timeout

    while GetGameTimer() < deadline do
        if predicate() then
            return true
        end

        Wait(10)
    end

    return predicate()
end

function VexProgressAnimation.LoadAnimation(dict)
    if type(dict) ~= 'string' or #dict == 0 then
        return false
    end

    RequestAnimDict(dict)

    local loaded = waitForCondition(function()
        return HasAnimDictLoaded(dict)
    end, Config.AssetLoadTimeout)

    if not loaded then
        debugLog('animation dictionary timed out: %s', dict)
    end

    return loaded
end

function VexProgressAnimation.LoadModel(model)
    local hash = model

    if type(hash) == 'string' then
        hash = GetHashKey(hash)
    end

    if type(hash) ~= 'number' then
        return false, nil
    end

    RequestModel(hash)

    local loaded = waitForCondition(function()
        return HasModelLoaded(hash)
    end, Config.AssetLoadTimeout)

    if not loaded then
        debugLog('model timed out: %s', tostring(model))
        return false, nil
    end

    return true, hash
end

function VexProgressAnimation.ResolveFlags(animation)
    local requested = animation.flags or {}
    local flags = 0

    -- Only mappings explicitly verified/configured by the resource are applied.
    -- Additional RDR3-specific semantic flags can be added to Config.Animation.
    if requested.loop == true and Config.Animation.flags.loop then
        flags = flags | Config.Animation.flags.loop
    end

    return flags
end

function VexProgressAnimation.Play(ped, animation, duration)
    if not animation then
        return true, nil
    end

    if not VexProgressAnimation.LoadAnimation(animation.dict) then
        return false, 'ANIM_LOAD_TIMEOUT'
    end

    local flags = VexProgressAnimation.ResolveFlags(animation)

    TaskPlayAnim(
        ped,
        animation.dict,
        animation.name,
        animation.blendIn or Config.Animation.blendIn,
        animation.blendOut or Config.Animation.blendOut,
        duration,
        flags,
        0.0,
        false,
        false,
        false,
        '',
        false
    )

    return true, {
        dict = animation.dict,
        name = animation.name
    }
end

function VexProgressAnimation.CreateProp(ped, propData)
    if not propData then
        return true, nil
    end

    local loaded, modelHash = VexProgressAnimation.LoadModel(propData.model)

    if not loaded then
        return false, 'PROP_LOAD_TIMEOUT'
    end

    local coords = GetEntityCoords(ped)

    local prop = CreateObject(
        modelHash,
        coords.x,
        coords.y,
        coords.z,
        Config.Props.networked,
        Config.Props.networked,
        false,
        false,
        false
    )

    if not prop or prop == 0 or not DoesEntityExist(prop) then
        SetModelAsNoLongerNeeded(modelHash)
        return false, 'PROP_CREATE_FAILED'
    end

    local boneIndex = GetEntityBoneIndexByName(ped, propData.bone)

    if not boneIndex or boneIndex == -1 then
        DeleteEntity(prop)
        SetModelAsNoLongerNeeded(modelHash)
        return false, 'PROP_BONE_NOT_FOUND'
    end

    local offset = VexProgressUtils.NormalizeVectorTable(propData.offset)
    local rotation = VexProgressUtils.NormalizeVectorTable(propData.rotation)

    AttachEntityToEntity(
        prop,
        ped,
        boneIndex,
        offset.x,
        offset.y,
        offset.z,
        rotation.x,
        rotation.y,
        rotation.z,
        false,
        false,
        Config.Props.collision,
        false,
        2,
        true,
        false,
        false
    )

    SetModelAsNoLongerNeeded(modelHash)

    return true, prop
end

function VexProgressAnimation.Cleanup(ped, animHandle, propHandle)
    if propHandle
        and propHandle ~= 0
        and DoesEntityExist(propHandle)
        and Config.Props.deleteOnCleanup then

        DetachEntity(propHandle, true, true)
        DeleteEntity(propHandle)
    end

    if animHandle and animHandle.dict then
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            ClearPedTasksImmediately(ped)
        end

        if HasAnimDictLoaded(animHandle.dict) then
            RemoveAnimDict(animHandle.dict)
        end
    end
end