--[[
    AuctionGather - Lightweight Auction Scanner
    Events.lua - WoW event handling

    Listens to WoW auction house events and triggers
    data capture when appropriate.
]]

local ADDON_NAME, AG = ...

AG.Events = {}
local Events = AG.Events

-- Callback registry for internal events
Events.callbacks = {}

-- Create main event frame
local EventFrame = CreateFrame("Frame", "AuctionGatherEventFrame")

-- Register ADDON_LOADED immediately (before Initialize)
-- This is needed to bootstrap the addon
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:SetScript("OnEvent", function(self, event, ...)
    Events:OnEvent(event, ...)
end)

-- Exposed so the legacy getAll watch can check whether a scanning addon
-- (Auctionator) has temporarily stolen our AUCTION_ITEM_LIST_UPDATE registration.
Events.frame = EventFrame

-- Initialize event system (called after ADDON_LOADED)
function Events:Initialize()
    -- Shared events (both backends)
    EventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    EventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    EventFrame:RegisterEvent("PLAYER_LOGOUT")

    -- Register BOTH auction data events and let whichever one the client actually fires
    -- drive capture. This makes capture IMMUNE to AH-client detection mistakes: legacy
    -- clients fire AUCTION_ITEM_LIST_UPDATE, modern clients fire REPLICATE_ITEM_LIST_UPDATE,
    -- and the inactive one simply never fires. Each is registered under pcall because
    -- RegisterEvent throws on an event name the client doesn't know.
    local legacyOk = pcall(EventFrame.RegisterEvent, EventFrame, "AUCTION_ITEM_LIST_UPDATE")
    local modernOk = pcall(EventFrame.RegisterEvent, EventFrame, "REPLICATE_ITEM_LIST_UPDATE")
    AG:Debug("Events initialized — AUCTION_ITEM_LIST_UPDATE registered=" .. tostring(legacyOk)
        .. ", REPLICATE_ITEM_LIST_UPDATE registered=" .. tostring(modernOk))
end

-- Main event handler
function Events:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        self:OnAddonLoaded(...)

    elseif event == "AUCTION_HOUSE_SHOW" then
        self:OnAuctionHouseShow()

    elseif event == "AUCTION_HOUSE_CLOSED" then
        self:OnAuctionHouseClosed()

    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        self:OnAuctionItemListUpdate()

    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        self:OnReplicateItemListUpdate()

    elseif event == "PLAYER_LOGOUT" then
        self:OnPlayerLogout()
    end
end

-- PLAYER_LOGOUT: Flush any in-progress async save before game exits, then save debug log
function Events:OnPlayerLogout()
    -- Complete any async save pipeline that is still running.
    -- This runs synchronously (may be slow for large scans, but acceptable on logout).
    if AG.Scanner then
        AG.Scanner:FlushAsyncSave()
    end
    AG:SaveErrorLog()
end

-- ADDON_LOADED: Initialize when our addon is loaded
function Events:OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then
        return
    end

    -- Unregister - we only need this once
    EventFrame:UnregisterEvent("ADDON_LOADED")

    -- Initialize core addon
    AG:Initialize()
end

-- AUCTION_HOUSE_SHOW: Player opened auction house
function Events:OnAuctionHouseShow()
    AG.State.auctionHouseOpen = true
    AG:Debug("Auction House opened")

    -- Reset per-session scanner state so a new scan can be captured
    if AG.Scanner then
        AG.Scanner:OnAuctionHouseShow()
    end

    -- Fire callback for UI
    self:FireCallback("AH_OPENED")
end

-- AUCTION_HOUSE_CLOSED: Player closed auction house
function Events:OnAuctionHouseClosed()
    AG.State.auctionHouseOpen = false
    AG:Debug("Auction House closed")

    -- Save any accumulated scan data instead of discarding
    if AG.Scanner then
        AG.Scanner:OnAuctionHouseClosed()
    end

    -- Fire callback for UI
    self:FireCallback("AH_CLOSED")
end

-- Throttle for event spam
local lastEventDebugTime = 0
local eventCount = 0

-- AUCTION_ITEM_LIST_UPDATE: Auction data received from server
-- This is the KEY event we're listening to!
function Events:OnAuctionItemListUpdate()
    -- Throttle debug output (max once per second)
    local now = GetTime()
    eventCount = eventCount + 1

    if now - lastEventDebugTime >= 1 then
        AG:Debug("EVENT: AUCTION_ITEM_LIST_UPDATE (x" .. eventCount .. ")")
        lastEventDebugTime = now
        eventCount = 0
    end

    -- Route straight to the legacy reader (the event itself is the signal that the
    -- legacy AH is active). The reader has its own capability + auctionHouseOpen guards.
    if AG.Scanner and AG.Scanner.legacy then
        AG.Scanner.legacy:OnDataReceived()
    end
end

-- REPLICATE_ITEM_LIST_UPDATE: full replicate buffer ready (modern AH).
-- Fires for our own ReplicateItems() call OR any other addon's (Auctionator/TSM) —
-- this is how passive capture works on modern clients. Unlike AUCTION_ITEM_LIST_UPDATE
-- it fires once per scan, so no throttling is needed.
function Events:OnReplicateItemListUpdate()
    AG:Debug("EVENT: REPLICATE_ITEM_LIST_UPDATE")

    -- Route straight to the modern reader (the event is the signal that the modern AH
    -- is active). The reader has its own capability + auctionHouseOpen guards.
    if AG.Scanner and AG.Scanner.modern then
        AG.Scanner.modern:OnReplicateUpdate()
    end
end

-- Register a callback for internal events
function Events:RegisterCallback(event, callback)
    if not self.callbacks[event] then
        self.callbacks[event] = {}
    end
    table.insert(self.callbacks[event], callback)
end

-- Fire callbacks for an internal event
function Events:FireCallback(event, ...)
    if not self.callbacks[event] then
        return
    end

    for _, callback in ipairs(self.callbacks[event]) do
        pcall(callback, ...)
    end
end

-- Utility: Check if auction house is currently usable
-- CanSendAuctionQuery is a legacy-only API (absent on modern C_AuctionHouse clients),
-- so guard it to avoid a nil-call on MoP/Cata/Retail.
function Events:IsAuctionHouseReady()
    return AG.State.auctionHouseOpen and (not CanSendAuctionQuery or CanSendAuctionQuery())
end

-- Utility: Get time until next full scan is available
function Events:GetFullScanCooldown()
    -- GetAll has a 15-minute cooldown
    -- Note: This is approximate, WoW doesn't expose exact cooldown
    if AG.State.lastScanTime == 0 then
        return 0
    end

    local elapsed = AG:GetTimestamp() - AG.State.lastScanTime
    local cooldown = 15 * 60 -- 15 minutes

    if elapsed >= cooldown then
        return 0
    end

    return cooldown - elapsed
end
