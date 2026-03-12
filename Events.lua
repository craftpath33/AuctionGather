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

-- Initialize event system (called after ADDON_LOADED)
function Events:Initialize()
    -- Register remaining WoW events
    EventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    EventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    EventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    EventFrame:RegisterEvent("PLAYER_LOGOUT")

    AG:Debug("Events initialized")
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

    -- Pass to Scanner — it handles auctionHouseOpen check and logs the reason if skipped
    if AG.Scanner then
        AG.Scanner:OnDataReceived()
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
function Events:IsAuctionHouseReady()
    return AG.State.auctionHouseOpen and CanSendAuctionQuery()
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
