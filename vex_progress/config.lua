Config = Config or {}

-- ============================================================================
-- General
-- ============================================================================

Config.Debug = false

Config.ResourceName = 'vex_progress'

-- Consequential actions should explicitly require server acknowledgement.
-- Client-only actions are intended for cosmetic/non-authoritative use only.
Config.RequireExplicitServerAckFlag = true

-- Hard-fail when an animation dictionary or prop model cannot be loaded.
Config.HardFailAssetLoading = true

-- ============================================================================
-- Timing
-- ============================================================================

Config.DefaultDuration = 5000

Config.MinDuration = 250
Config.MaxDuration = 300000

-- Integrity checks that do not require per-frame polling.
Config.IntegrityPollInterval = 250

-- Hard loading budget for animation dictionaries/models.
Config.AssetLoadTimeout = 3000

-- Server timing tolerance.
--
-- A response is considered too early when:
--
-- elapsed < expectedDuration - EarlyCompletionTolerance
--
-- 200ms is intentionally conservative and primarily absorbs frame/network
-- scheduling variance. It does NOT make the client timer authoritative.
Config.EarlyCompletionTolerance = 200

-- How long a server-side pending task may remain alive past its expected finish.
Config.PendingTaskGracePeriod = 15000

-- Server cleanup cadence.
Config.PendingCleanupInterval = 5000

-- ============================================================================
-- Distance / interruption
-- ============================================================================

Config.DefaultMaxDistance = 2.0

Config.InterruptOnDamage = true
Config.InterruptOnDistance = true
Config.InterruptOnVehicleChange = true
Config.InterruptOnRagdoll = true
Config.InterruptOnDeath = true

-- Animation interruption checking can be enabled after the specific RDR3 task
-- index/native behavior used by your animation catalog has been live-verified.
Config.InterruptOnAnimationLoss = false

-- ============================================================================
-- Manual cancellation
-- ============================================================================

Config.ManualCancel = {
    enabled = true,

    -- RDR3 INPUT_FRONTEND_CANCEL.
    -- Common keyboard bindings include Backspace / Escape.
    control = 0x156F7119,

    label = 'Cancel'
}

-- ============================================================================
-- Controls
-- ============================================================================
--
-- Keep this list intentionally empty until the exact RDR3 INPUT_* hashes used
-- by the server are verified against the live RedM build.
--
-- Calling resources may provide actionData.disableControls.
--
-- This avoids accidentally importing FiveM/GTA V integer controls into RedM.
-- ============================================================================

Config.DefaultDisabledControls = {}

-- ============================================================================
-- Animation
-- ============================================================================

Config.Animation = {
    blendIn = 1.0,
    blendOut = 1.0,

    -- Do not expose GTA V animation flag constants as part of the public API.
    -- The caller should use semantic booleans under actionData.animation.flags.
    --
    -- Actual RDR3 animation bit combinations should be verified against the
    -- target server build before expanding this mapping.
    flags = {
        loop = 1
    }
}

-- ============================================================================
-- Prop behavior
-- ============================================================================

Config.Props = {
    -- Blueprint default: cosmetic props stay local/non-networked.
    networked = false,

    collision = false,

    -- Delete on every canonical cleanup path.
    deleteOnCleanup = true
}

-- ============================================================================
-- UI
-- ============================================================================

Config.UI = {
    layout = 'ring', -- ring | bar

    position = 'bottom-center',

    showLabel = true,
    showTimer = false,

    ring = {
        size = 112,
        strokeWidth = 7,

        trackColor = 'rgba(33, 25, 18, 0.72)',
        progressColor = '#c6a36a',
        glowColor = 'rgba(198, 163, 106, 0.30)'
    },

    bar = {
        width = 360,
        height = 8,

        trackColor = 'rgba(33, 25, 18, 0.72)',
        progressColor = '#c6a36a'
    },

    typography = {
        primary = 'Georgia, "Times New Roman", serif',
        secondary = 'Arial, Helvetica, sans-serif'
    }
}

-- ============================================================================
-- vex_core integration
-- ============================================================================

Config.Core = {
    resource = 'vex_core',

    -- Optional client export expected to return the local VEX player mirror.
    playerExport = 'GetPlayer',

    -- Optional field used when applying an action-speed modifier.
    --
    -- Example:
    -- player.progressSpeedMultiplier = 0.90
    --
    -- Effective duration is snapshotted once at action start.
    progressSpeedField = 'progressSpeedMultiplier',

    minSpeedMultiplier = 0.25,
    maxSpeedMultiplier = 4.0
}

-- ============================================================================
-- vex_callback integration
-- ============================================================================
--
-- These names follow the VEX callback architecture. Keeping them centralized
-- makes the transport adapter replaceable without changing progress logic.
-- ============================================================================

Config.Callback = {
    resource = 'vex_callback',

    registerServerExport = 'RegisterServerCallback',
    registerClientExport = 'RegisterClientCallback',
    triggerClientExport = 'TriggerClientCallback',

    secureActionName = 'vex_progress:secureAction'
}

-- ============================================================================
-- Logging
-- ============================================================================

Config.Logging = {
    rejectedStarts = true,
    rejectedCompletions = true,
    expiredTasks = Config.Debug,
    lifecycle = Config.Debug
}