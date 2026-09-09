# vex_progress

A secure progress action and task-locking system for RedM.

`vex_progress` provides a centralized way for VEX resources to run timed player actions with progress UI, cancellation, animations, props, control locking, and server-side completion validation.

## Features

* Circular Western-themed progress UI
* Server-authoritative completion validation
* Speed-hack protection
* Manual action cancellation
* Animation support
* Attached prop support
* Player movement/distance validation
* Vehicle state interruption
* Damage and death interruption
* Control locking during actions
* Automatic resource cleanup
* Client-only cosmetic actions
* Secure server-backed actions
* Lightweight while idle

## Dependencies

* `vex_core`
* `vex_callback`

## Installation

Place `vex_progress` in your resources directory and ensure it after its dependencies:

```cfg
ensure vex_core
ensure vex_callback
ensure vex_progress
```

## Client Usage

```lua
exports['vex_progress']:StartProgressAction({
    duration = 5000,
    label = 'Gathering herbs...',
    requiresServerAck = false,
    useControl = true,
    maxDistance = 2.0
}, function(result)
    print('Action completed')
end, function(reason)
    print('Action cancelled:', reason)
end)
```

Client-side progress actions should only be used when completion has no authoritative server consequence.

## Secure Server Usage

```lua
local success, result = exports['vex_progress']:StartSecureProgress(source, {
    duration = 5000,
    label = 'Gathering herbs...',
    requiresServerAck = true,
    useControl = true,
    maxDistance = 2.0
})

if success then
    -- Grant rewards or continue authoritative logic here.
end
```

For actions involving items, money, XP, crafting, harvesting, quests, or other server-side consequences, always use the secure server flow.

## Exports

### Client

```lua
StartProgressAction(actionData, onComplete, onCancel)
CancelProgressAction(reason)
IsProgressActive()
GetActiveTaskId()
```

### Server

```lua
StartSecureProgress(source, actionData)
CancelSecureProgress(source, taskId)
```

## VEX

Part of the VEX RedM resource ecosystem.
