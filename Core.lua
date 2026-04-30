--[[
    AuctionGather - Lightweight Auction Scanner
    Core.lua - Addon namespace and initialization

    Listens to publicly available auction house data via the official WoW API
    and stores it for upload and external processing.
]]

-- Create addon namespace
local ADDON_NAME, AG = ...

-- Version info
AG.VERSION = "0.1.0"
AG.BUILD = 1

-- Debug mode (off by default, toggle with /ag debug)
AG.DEBUG = false

-- Addon state
AG.State = {
    initialized = false,
    auctionHouseOpen = false,
    lastScanTime = 0,
}

-- Default configuration
AG.Defaults = {
    config = {
        autoScan = true,      -- Automatically scan auction house data
        includeOwner = true,  -- Store seller names
        includeBid = true,    -- Store bid information
    },
}

-- Utility: Print to chat (green — info/success)
function AG:Print(...)
    local prefix = "|cFF00FF00[AuctionGather]|r "
    print(prefix, ...)
end

-- Error/warning log: always collected, saved to WTF on logout.
-- Contains Warn() calls and caught exceptions only — stays small.
AG.errorLog = {}
AG.MAX_ERROR_LOG = 200

-- Verbose debug log: only when AG.DEBUG=true, session-only, never saved to WTF.
AG.debugLog = {}
AG.MAX_DEBUG_LOG = 500

-- Utility: Warning — always printed to chat and always written to errorLog.
function AG:Warn(...)
    local args = {...}
    local msg = ""
    for i, v in ipairs(args) do
        if i > 1 then msg = msg .. " " end
        msg = msg .. tostring(v)
    end
    print("|cFFFF9900[AuctionGather]|r " .. msg)

    local entry = date("%H:%M:%S") .. "|" .. msg
    self.errorLog[#self.errorLog + 1] = entry
    if #self.errorLog > self.MAX_ERROR_LOG then
        table.remove(self.errorLog, 1)
    end
end

-- Utility: Verbose debug — only active when AG.DEBUG=true.
-- Session-only: not saved to WTF, resets on logout/reload.
function AG:Debug(...)
    if not self.DEBUG then return end

    local args = {...}
    local message = ""
    for i, v in ipairs(args) do
        if i > 1 then message = message .. " " end
        message = message .. tostring(v)
    end

    local entry = date("%H:%M:%S") .. "|" .. message
    self.debugLog[#self.debugLog + 1] = entry

    local overflow = #self.debugLog - self.MAX_DEBUG_LOG
    if overflow > 0 then
        for i = 1, #self.debugLog - overflow do
            self.debugLog[i] = self.debugLog[i + overflow]
        end
        for i = #self.debugLog - overflow + 1, #self.debugLog do
            self.debugLog[i] = nil
        end
    end

    print("|cFF888888[AG Debug]|r ", ...)
end

-- Load error log from SavedVariables (called on init)
function AG:LoadErrorLog()
    if not AUCTION_GATHER_DEBUG_LOG or AUCTION_GATHER_DEBUG_LOG == "" then return end
    if not self.Encoder then return end

    -- Safety guard: suspiciously large compressed log → likely corrupted, clear it
    if #AUCTION_GATHER_DEBUG_LOG > 200000 then
        self:Print("|cFFFF6600Debug log too large (" .. #AUCTION_GATHER_DEBUG_LOG .. " bytes), clearing.|r")
        AUCTION_GATHER_DEBUG_LOG = ""
        return
    end

    local ok, decompressed = pcall(function()
        return self.Encoder:Decompress(AUCTION_GATHER_DEBUG_LOG)
    end)

    if not ok or not decompressed or decompressed == "" then
        -- Corrupted or unreadable — clear to prevent the same error next session
        self:Print("|cFFFF6600Debug log corrupted, clearing.|r")
        AUCTION_GATHER_DEBUG_LOG = ""
        return
    end

    self.errorLog = {}
    for line in decompressed:gmatch("[^\n]+") do
        self.errorLog[#self.errorLog + 1] = line
    end
end

-- Save error log to SavedVariables (called on logout)
function AG:SaveErrorLog()
    if #self.errorLog > 0 and self.Encoder then
        local logStr = table.concat(self.errorLog, "\n")
        AUCTION_GATHER_DEBUG_LOG = self.Encoder:Compress(logStr)
    else
        AUCTION_GATHER_DEBUG_LOG = ""
    end
end

-- Utility: Get current realm name (localized, for display)
function AG:GetRealmName()
    local realm = GetRealmName()
    return realm or "Unknown"
end

-- Utility: Get normalized realm name (English, no spaces)
-- Used for server-side routing and identification
function AG:GetRealmNameNormalized()
    -- GetNormalizedRealmName returns English name without spaces
    local normalized = GetNormalizedRealmName()
    if normalized and normalized ~= "" then
        return normalized
    end

    -- Fallback: remove spaces from localized name
    local realm = GetRealmName()
    return (realm or "Unknown"):gsub("%s+", "")
end

-- Utility: Get player's region (EU, US, KR, TW, CN)
function AG:GetRegion()
    -- GetCurrentRegion() returns: 1=US, 2=KR, 3=EU, 4=TW, 5=CN
    local regionId = GetCurrentRegion and GetCurrentRegion() or 0
    local regions = {
        [1] = "US",
        [2] = "KR",
        [3] = "EU",
        [4] = "TW",
        [5] = "CN",
    }
    return regions[regionId] or "Unknown"
end

-- Detection uses tocVersion from GetBuildInfo(): expansion * 10000 + minor * 100 + patch.
function AG:GetGameVersion()
    local _, _, _, tocVersion = GetBuildInfo()
    if not tocVersion then return "unknown" end

    local expansion = math.floor(tocVersion / 10000)
    local versions = {
        [1] = "classic",
        [2] = "tbc",
    }
    return versions[expansion] or ("exp" .. expansion)
end

function AG:GetGameBuild()
    local version = GetBuildInfo()
    return version or "unknown"
end

function AG:GetRealmKey()
    local version = self:GetGameVersion()
    local realm = self:GetRealmNameNormalized()
    local faction = UnitFactionGroup("player") or "Unknown"
    return version .. "-" .. realm .. "-" .. faction
end

-- Utility: Get current timestamp
function AG:GetTimestamp()
    return time()
end

-- Utility: Format number with separators
function AG:FormatNumber(num)
    if not num then return "0" end
    local formatted = tostring(num)
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- Utility: Format money (copper to gold/silver/copper)
function AG:FormatMoney(copper)
    if not copper or copper == 0 then return "0c" end

    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    local result = ""
    if gold > 0 then result = result .. gold .. "g " end
    if silver > 0 then result = result .. silver .. "s " end
    if cop > 0 or result == "" then result = result .. cop .. "c" end

    return result:trim()
end

-- Initialize addon (called on ADDON_LOADED)
function AG:Initialize()
    if self.State.initialized then return end

    -- Initialize Storage (loads/creates SavedVariables)
    -- Wrapped in pcall: a corrupted/large SavedVariables file must not prevent
    -- event registration. If Storage fails, the addon still captures new scans.
    if self.Storage then
        local ok, err = pcall(function() self.Storage:Initialize() end)
        if not ok then
            self:Print("|cFFFF6600Storage init failed:|r " .. tostring(err))
            self:Print("SavedVariables may be corrupted. Use /ag clear to reset.")

            -- Ensure AUCTION_GATHER_CONFIG is always usable even if Storage init failed.
            -- Without this, Scanner:OnDataReceived() would silently abort every scan.
            if not AUCTION_GATHER_CONFIG then
                AUCTION_GATHER_CONFIG = {}
            end
            for key, value in pairs(self.Defaults.config) do
                if AUCTION_GATHER_CONFIG[key] == nil then
                    AUCTION_GATHER_CONFIG[key] = value
                end
            end
        end
    end

    -- Initialize Scanner
    if self.Scanner then
        self.Scanner:Initialize()
    end

    -- Initialize Events (always runs, even if Storage failed)
    if self.Events then
        self.Events:Initialize()
    end

    self.State.initialized = true
    self:Print("v" .. self.VERSION .. " loaded. Type /ag for commands.")
end

-- Slash commands
SLASH_AUCTIONGATHER1 = "/ag"
SLASH_AUCTIONGATHER2 = "/auctiongather"

SlashCmdList["AUCTIONGATHER"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "" or cmd == "help" then
        AG:Print("Commands:")
        print("  /ag status - Show addon status")
        print("  /ag version - Show what gv/build/realmKey would be sent to the server")
        print("  /ag realms - Show all stored realm scans")
        print("  /ag last - Show last scan info")
        print("  /ag config - Show configuration")
        print("  /ag debug - Toggle debug mode")
        print("  /ag log - Show debug log info")
        print("  /ag log save - Save log to file now")
        print("  /ag log clear - Clear debug log")
        print("  /ag test - Test encoder")
        print("  /ag clear - Clear all data")
        print("  /ag clear <realm> - Clear specific realm")

    elseif cmd == "version" then
        -- Debug helper: prints exactly the fields that would land in the SavedVariables
        local _, build, _, tocVersion = GetBuildInfo()
        local gv = AG:GetGameVersion()
        local versionColor = (gv == "unknown") and "|cFFFF6600" or "|cFF00FF00"

        AG:Print("Payload preview (next scan would send):")
        print("  gv:       " .. versionColor .. gv .. "|r")
        print("  build:    " .. (build or "?"))
        print("  toc:      " .. tostring(tocVersion or "?"))
        print("  realm:    " .. AG:GetRealmNameNormalized())
        print("  faction:  " .. (UnitFactionGroup("player") or "Unknown"))
        print("  region:   " .. AG:GetRegion())

        if gv == "unknown" then
            print("|cFFFF6600Note:|r Could not detect expansion from tocVersion.")
        end

    elseif cmd == "status" then
        AG:Print("Status:")
        print("  Initialized: " .. tostring(AG.State.initialized))
        print("  AH Open: " .. tostring(AG.State.auctionHouseOpen))
        print("  Current realm: " .. AG:GetRealmKey())
        print("  Region: " .. AG:GetRegion())
        print("  Game version: " .. AG:GetGameVersion() .. " (" .. AG:GetGameBuild() .. ")")
        if AG.Storage then
            print("  Stored realms: " .. AG.Storage:GetRealmCount())
            print("  Total size: " .. AG:FormatNumber(AG.Storage:GetStorageSize()) .. " bytes")
        end

    elseif cmd == "realms" then
        if AG.Storage then
            AG.Storage:PrintStatus()
        end

    elseif cmd == "last" then
        if AG.Storage then
            AG.Storage:PrintLastScan()
        end

    elseif cmd == "config" then
        AG:Print("Configuration:")
        if AUCTION_GATHER_CONFIG then
            for k, v in pairs(AUCTION_GATHER_CONFIG) do
                print("  " .. k .. ": " .. tostring(v))
            end
        end

    elseif cmd == "debug" then
        AG.DEBUG = not AG.DEBUG
        AG:Print("Debug mode: " .. (AG.DEBUG and "|cFF00FF00ON|r (session only, resets on logout)" or "|cFFFF6600OFF|r"))

    elseif cmd == "log" then
        if arg == "clear" then
            AG.errorLog = {}
            AUCTION_GATHER_DEBUG_LOG = ""
            AG:Print("Error log cleared")
        elseif arg == "save" then
            AG:SaveErrorLog()
            AG:Print("Error log saved to file")
        else
            local errCount = #AG.errorLog
            local dbgCount = #AG.debugLog
            local savedSize = AUCTION_GATHER_DEBUG_LOG and #AUCTION_GATHER_DEBUG_LOG or 0
            AG:Print("Error log (saved to file): " .. errCount .. "/" .. AG.MAX_ERROR_LOG .. " entries, " .. savedSize .. " bytes compressed")
            if AG.DEBUG then
                print("  Debug log (session only): " .. dbgCount .. "/" .. AG.MAX_DEBUG_LOG .. " entries")
            end
            if errCount > 0 then
                local show = math.min(5, errCount)
                print("  Last " .. show .. " warning(s):")
                for i = errCount - show + 1, errCount do
                    print("    " .. AG.errorLog[i])
                end
            else
                print("  No warnings recorded.")
            end
            print("  /ag log save — force save now  |  /ag log clear — clear log")
        end

    elseif cmd == "clear" then
        if AG.Storage then
            if arg and arg ~= "" then
                -- Clear specific realm
                AG.Storage:ClearRealm(arg)
            else
                -- Clear all
                AG.Storage:ClearAllData()
            end
        end

    elseif cmd == "test" then
        if AG.Encoder then
            AG.Encoder:Test()
        else
            AG:Print("Encoder not loaded")
        end

    else
        AG:Print("Unknown command: " .. cmd .. ". Type /ag help")
    end
end

-- Export namespace to global (for other addons to access if needed)
AuctionGather = AG
