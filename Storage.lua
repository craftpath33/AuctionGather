--[[
    AuctionGather - Lightweight Auction Scanner
    Storage.lua - SavedVariables management

    Stores scan data per realm+faction with light obfuscation.
    Metadata is readable, payload is encoded (Base64 + reverse).
]]

local ADDON_NAME, AG = ...

AG.Storage = {}
local Storage = AG.Storage

-- Data structure version (for migrations)
-- v2: realm key includes game version prefix (Version-Realm-Faction) and each scan
--     stores gv/build fields. Old v1 keys (Realm-Faction) are wiped on migration.
local DATA_VERSION = 2

-- Minimum thresholds to save (filter out partial searches and single-item queries)
local MIN_AUCTIONS = 500
local MIN_UNIQUE_ITEMS = 50

-- Runtime cache for last scan info (not saved, just for display)
Storage.lastScanInfo = nil

-- Initialize storage and SavedVariables
function Storage:Initialize()
    -- Initialize global data storage
    if not AUCTION_GATHER_DATA then
        AUCTION_GATHER_DATA = {
            v = DATA_VERSION,
            realms = {},  -- realm-faction keyed data
        }
    end

    -- Migrate if needed
    if not AUCTION_GATHER_DATA.v or AUCTION_GATHER_DATA.v < DATA_VERSION then
        self:MigrateData()
    end

    -- Initialize config
    if not AUCTION_GATHER_CONFIG then
        AUCTION_GATHER_CONFIG = {}
    end

    -- Apply defaults for missing config values
    for key, value in pairs(AG.Defaults.config) do
        if AUCTION_GATHER_CONFIG[key] == nil then
            AUCTION_GATHER_CONFIG[key] = value
        end
    end

    -- Remove legacy key (debug is now a session-only runtime flag, not saved to config)
    AUCTION_GATHER_CONFIG.debugPrint = nil

    -- Initialize per-character data
    if not AUCTION_GATHER_CHARACTER then
        AUCTION_GATHER_CHARACTER = {
            lastScanTime = 0,
            scanCount = 0,
        }
    end

    -- Initialize debug log (compressed string in SavedVariables)
    if not AUCTION_GATHER_DEBUG_LOG then
        AUCTION_GATHER_DEBUG_LOG = ""
    end

    -- Load previous debug log from compressed format
    AG:LoadErrorLog()

    AG:Debug("Storage initialized (v" .. DATA_VERSION .. ")")
end

-- Migrate data from older versions
function Storage:MigrateData()
    AG:Debug("Migrating data to version " .. DATA_VERSION)

    -- Clear old format (incompatible structure)
    AG:Debug("Migrating to realm-based format, clearing old data")
    AUCTION_GATHER_DATA = {
        v = DATA_VERSION,
        realms = {},
    }
end

-- Serialize items to compact string format
-- Format: itemId:name:quality:level:auction1;auction2;...\n
local function serializeItems(items)
    local lines = {}

    for itemId, itemData in pairs(items) do
        local auctionParts = {}
        for _, a in ipairs(itemData.auctions) do
            -- count,minBid,buyout,timeLeft (owner removed for size)
            table.insert(auctionParts, string.format("%d,%d,%d,%d",
                a.count or 1,
                a.minBid or 0,
                a.buyout or 0,
                a.timeLeft or 0
            ))
        end

        -- Format: itemId:name:quality:level:auctions
        local line = string.format("%d:%s:%d:%d:%s",
            itemId,
            (itemData.name or ""):gsub(":", ""),  -- remove colons from name
            itemData.quality or 0,
            itemData.level or 0,
            table.concat(auctionParts, ";")
        )
        table.insert(lines, line)
    end

    return table.concat(lines, "\n")
end

local function obfuscate(data)
    if not AG.Encoder then
        AG:Debug("Encoder not available, saving raw")
        return data
    end
    return AG.Encoder:Base64Encode(data):reverse()
end

-- Save a completed scan
-- @param scanData table - Processed scan data from Scanner
-- @param isEarlyTermination boolean - true when AH was closed before scan fully completed
-- NOTE: This method is kept for compatibility and testing.
-- The Scanner now uses SaveEncoded() via the async pipeline instead.
function Storage:SaveScan(scanData, isEarlyTermination)
    if not scanData or not scanData.items then
        AG:Debug("SaveScan: No data to save")
        return false
    end

    local totalAuctions = scanData.totalAuctions or 0
    local uniqueItems = scanData.uniqueItems or 0
    local mode = scanData.mode or "unknown"

    -- Check minimum auctions threshold (silent — don't spam chat during normal AH browsing)
    if totalAuctions < MIN_AUCTIONS then
        AG:Debug("SaveScan: Only " .. totalAuctions .. " auctions (min " .. MIN_AUCTIONS .. "), skipping")
        return false
    end

    -- Check minimum unique items threshold (silent)
    if uniqueItems < MIN_UNIQUE_ITEMS then
        AG:Debug("SaveScan: Only " .. uniqueItems .. " unique items (min " .. MIN_UNIQUE_ITEMS .. "), skipping")
        return false
    end

    -- When AH was closed mid-scan, only discard if we have very little data
    -- relative to the existing scan (< 50%). A partial scan with 50%+ of
    -- the previous data is still valuable (recent prices, partial market view).
    if isEarlyTermination then
        local realmKeyCheck = AG:GetRealmKey()
        local existing = AUCTION_GATHER_DATA and AUCTION_GATHER_DATA.realms and
                         AUCTION_GATHER_DATA.realms[realmKeyCheck]
        if existing and existing.n and existing.n > 0 then
            local pct = totalAuctions / existing.n
            if pct < 0.5 then
                AG:Debug(string.format(
                    "SaveScan: Early termination with %d auctions (%.0f%% of existing %d), skipping",
                    totalAuctions, pct * 100, existing.n
                ))
                AG:Print(string.format(
                    "|cFFFF6600Scan aborted.|r Only %s/%s auctions (%.0f%%). Keeping previous scan.",
                    AG:FormatNumber(totalAuctions),
                    AG:FormatNumber(existing.n),
                    pct * 100
                ))
                return false
            end
        end
    end

    -- Get identifiers
    local realmKey    = AG:GetRealmKey()
    local realm       = AG:GetRealmNameNormalized()
    local faction     = UnitFactionGroup("player") or "Unknown"
    local region      = AG:GetRegion()
    local gameVersion = AG:GetGameVersion()
    local gameBuild   = AG:GetGameBuild()
    local timestamp   = AG:GetTimestamp()
    local character   = UnitName("player") or "Unknown"

    AG:Debug("Saving scan for " .. realmKey .. " (" .. totalAuctions .. " auctions)")

    -- Serialize items to compact string
    AG:Debug("Serializing " .. uniqueItems .. " items...")
    local serialized = serializeItems(scanData.items)
    AG:Debug("Serialized size: " .. #serialized .. " bytes")

    -- Obfuscate (Base64 + reverse)
    AG:Debug("Obfuscating...")
    local payload = obfuscate(serialized)
    AG:Debug("Payload size: " .. #payload .. " bytes")

    -- Calculate checksum
    local checksum = AG.Encoder and AG.Encoder:Checksum(payload) or "none"

    -- Cache for display (runtime only)
    self.lastScanInfo = {
        realmKey      = realmKey,
        realm         = realm,
        faction       = faction,
        region        = region,
        gameVersion   = gameVersion,
        gameBuild     = gameBuild,
        timestamp     = timestamp,
        totalAuctions = totalAuctions,
        uniqueItems   = uniqueItems,
    }

    -- Save to realm slot (overwrites previous scan for this realm+faction+version)
    AUCTION_GATHER_DATA.realms[realmKey] = {
        -- Metadata (readable without decoding)
        t = timestamp,              -- unix timestamp
        n = totalAuctions,          -- total auctions count
        u = uniqueItems,            -- unique items count

        -- Identification
        realm   = realm,            -- realm name (English)
        faction = faction,          -- Horde/Alliance/Neutral
        region  = region,           -- EU/US/KR/TW/CN
        gv      = gameVersion,      -- short code: classic/tbc/wotlk/cata/mop/...
        build   = gameBuild,        -- full build string, e.g. "3.4.1"
        char    = character,        -- who scanned

        -- Diagnostics
        mode = mode,                -- "getall", "paged", or "manual"
        pages = scanData.pagesRead, -- number of pages read

        -- Payload
        cs = checksum,              -- checksum for verification
        d = payload,                -- encoded data (Base64 reversed)
    }

    -- Update character stats
    AUCTION_GATHER_CHARACTER.lastScanTime = timestamp
    AUCTION_GATHER_CHARACTER.scanCount = (AUCTION_GATHER_CHARACTER.scanCount or 0) + 1

    AG:Print(string.format(
        "|cFF00FF00Scan saved!|r %s: %s auctions, %s items (%s, %.1fs)",
        realmKey,
        AG:FormatNumber(totalAuctions),
        AG:FormatNumber(uniqueItems),
        mode,
        scanData.duration or 0
    ))
    AG:Print("|cFF88BBFFTo upload:|r Logout or |cFFFFFF00/reload|r to save file, then upload on site.")

    -- Fire event for UI
    if AG.Events then
        AG.Events:FireCallback("SCAN_SAVED", realmKey)
    end

    return true
end

-- Save an already-encoded scan payload produced by the async pipeline.
-- The payload has already been Base64-encoded and reversed by Scanner.
-- @param metadata table - { totalAuctions, uniqueItems, totalBuyout, duration, mode, pagesRead, payload }
-- @param isEarlyTermination boolean - true when AH was closed before scan fully completed
function Storage:SaveEncoded(metadata, isEarlyTermination)
    if not metadata or not metadata.payload then
        AG:Debug("SaveEncoded: No payload to save")
        return false
    end

    local totalAuctions = metadata.totalAuctions or 0
    local uniqueItems   = metadata.uniqueItems   or 0
    local mode          = metadata.mode          or "unknown"

    -- Check minimum auctions threshold (silent)
    if totalAuctions < MIN_AUCTIONS then
        AG:Debug("SaveEncoded: Only " .. totalAuctions .. " auctions (min " .. MIN_AUCTIONS .. "), skipping")
        return false
    end

    -- Check minimum unique items threshold (silent)
    if uniqueItems < MIN_UNIQUE_ITEMS then
        AG:Debug("SaveEncoded: Only " .. uniqueItems .. " unique items (min " .. MIN_UNIQUE_ITEMS .. "), skipping")
        return false
    end

    -- When AH was closed mid-scan, only discard if we have very little data
    -- relative to the existing scan (< 50%).
    if isEarlyTermination then
        local realmKeyCheck = AG:GetRealmKey()
        local existing = AUCTION_GATHER_DATA and AUCTION_GATHER_DATA.realms and
                         AUCTION_GATHER_DATA.realms[realmKeyCheck]
        if existing and existing.n and existing.n > 0 then
            local pct = totalAuctions / existing.n
            if pct < 0.5 then
                AG:Debug(string.format(
                    "SaveEncoded: Early termination with %d auctions (%.0f%% of existing %d), skipping",
                    totalAuctions, pct * 100, existing.n
                ))
                AG:Print(string.format(
                    "|cFFFF6600Scan aborted.|r Only %s/%s auctions (%.0f%%). Keeping previous scan.",
                    AG:FormatNumber(totalAuctions),
                    AG:FormatNumber(existing.n),
                    pct * 100
                ))
                return false
            end
        end
    end

    -- Get identifiers
    local realmKey    = AG:GetRealmKey()
    local realm       = AG:GetRealmNameNormalized()
    local faction     = UnitFactionGroup("player") or "Unknown"
    local region      = AG:GetRegion()
    local gameVersion = AG:GetGameVersion()
    local gameBuild   = AG:GetGameBuild()
    local timestamp   = AG:GetTimestamp()
    local character   = UnitName("player") or "Unknown"

    AG:Debug("SaveEncoded: persisting scan for " .. realmKey .. " (" .. totalAuctions .. " auctions)")

    -- Compute checksum over the already-encoded payload
    local checksum = AG.Encoder and AG.Encoder:Checksum(metadata.payload) or "none"

    -- Cache for display (runtime only)
    self.lastScanInfo = {
        realmKey      = realmKey,
        realm         = realm,
        faction       = faction,
        region        = region,
        gameVersion   = gameVersion,
        gameBuild     = gameBuild,
        timestamp     = timestamp,
        totalAuctions = totalAuctions,
        uniqueItems   = uniqueItems,
    }

    -- Save to realm slot (overwrites previous scan for this realm+faction+version)
    AUCTION_GATHER_DATA.realms[realmKey] = {
        -- Metadata (readable without decoding)
        t = timestamp,      -- unix timestamp
        n = totalAuctions,  -- total auctions count
        u = uniqueItems,    -- unique items count

        -- Identification
        realm   = realm,        -- realm name (English)
        faction = faction,      -- Horde/Alliance/Neutral
        region  = region,       -- EU/US/KR/TW/CN
        gv      = gameVersion,  -- short code: classic/tbc/wotlk/cata/mop/...
        build   = gameBuild,    -- full build string, e.g. "3.4.1"
        char    = character,    -- who scanned

        -- Diagnostics
        mode  = mode,                -- "getall", "paged", or "manual"
        pages = metadata.pagesRead,  -- number of pages read

        -- Payload
        cs = checksum,           -- checksum for verification
        d  = metadata.payload,   -- encoded data (Base64 reversed)
    }

    -- Update character stats
    AUCTION_GATHER_CHARACTER.lastScanTime = timestamp
    AUCTION_GATHER_CHARACTER.scanCount = (AUCTION_GATHER_CHARACTER.scanCount or 0) + 1

    AG:Print(string.format(
        "|cFF00FF00Scan saved!|r %s: %s auctions, %s items (%s, %.1fs)",
        realmKey,
        AG:FormatNumber(totalAuctions),
        AG:FormatNumber(uniqueItems),
        mode,
        metadata.duration or 0
    ))
    AG:Print("|cFF88BBFFTo upload:|r Logout or |cFFFFFF00/reload|r to save file, then upload on site.")

    -- Fire event for UI
    if AG.Events then
        AG.Events:FireCallback("SCAN_SAVED", realmKey)
    end

    return true
end

-- Get number of stored realms
function Storage:GetRealmCount()
    if AUCTION_GATHER_DATA and AUCTION_GATHER_DATA.realms then
        local count = 0
        for _ in pairs(AUCTION_GATHER_DATA.realms) do
            count = count + 1
        end
        return count
    end
    return 0
end

-- Get scan for specific realm
function Storage:GetRealmScan(realmKey)
    if AUCTION_GATHER_DATA and AUCTION_GATHER_DATA.realms then
        return AUCTION_GATHER_DATA.realms[realmKey]
    end
    return nil
end

-- Get current realm's scan
function Storage:GetCurrentRealmScan()
    local realmKey = AG:GetRealmKey()
    return self:GetRealmScan(realmKey)
end

-- Print status for all realms
function Storage:PrintStatus()
    AG:Print("Stored scans:")

    if not AUCTION_GATHER_DATA or not AUCTION_GATHER_DATA.realms then
        print("  No data")
        return
    end

    local count = 0
    for realmKey, data in pairs(AUCTION_GATHER_DATA.realms) do
        count = count + 1
        local age = AG:GetTimestamp() - (data.t or 0)
        local ageStr = ""
        if age < 3600 then
            ageStr = math.floor(age / 60) .. "m ago"
        elseif age < 86400 then
            ageStr = math.floor(age / 3600) .. "h ago"
        else
            ageStr = math.floor(age / 86400) .. "d ago"
        end

        print(string.format("  %s [%s/%s]: %s auctions, %s items (%s)",
            realmKey,
            data.region or "??",
            data.gv or "?",
            AG:FormatNumber(data.n or 0),
            AG:FormatNumber(data.u or 0),
            ageStr
        ))
    end

    if count == 0 then
        print("  No scans yet")
    end
end

-- Print last scan info (from runtime cache or current realm)
function Storage:PrintLastScan()
    -- Try runtime cache first
    if self.lastScanInfo then
        AG:Print("Last scan (this session):")
        print("  Realm: " .. (self.lastScanInfo.realm or "unknown"))
        print("  Faction: " .. (self.lastScanInfo.faction or "unknown"))
        print("  Region: " .. (self.lastScanInfo.region or "unknown"))
        print("  Version: " .. (self.lastScanInfo.gameVersion or "unknown") ..
              " (" .. (self.lastScanInfo.gameBuild or "?") .. ")")
        print("  Time: " .. date("%Y-%m-%d %H:%M:%S", self.lastScanInfo.timestamp or 0))
        print("  Total auctions: " .. AG:FormatNumber(self.lastScanInfo.totalAuctions or 0))
        print("  Unique items: " .. AG:FormatNumber(self.lastScanInfo.uniqueItems or 0))
        return
    end

    -- Fall back to current realm data
    local scan = self:GetCurrentRealmScan()
    if scan then
        AG:Print("Stored scan for " .. AG:GetRealmKey() .. ":")
        print("  Time: " .. date("%Y-%m-%d %H:%M:%S", scan.t or 0))
        print("  Total auctions: " .. AG:FormatNumber(scan.n or 0))
        print("  Unique items: " .. AG:FormatNumber(scan.u or 0))
        print("  Payload size: " .. AG:FormatNumber(#(scan.d or "")) .. " bytes")
        print("  Checksum: " .. (scan.cs or "none"))
    else
        AG:Print("No scan for " .. AG:GetRealmKey())
    end
end

-- Clear all stored data
function Storage:ClearAllData()
    AUCTION_GATHER_DATA = {
        v = DATA_VERSION,
        realms = {},
    }
    AUCTION_GATHER_CHARACTER.scanCount = 0
    self.lastScanInfo = nil
    AG:Print("All data cleared")
end

-- Clear specific realm
function Storage:ClearRealm(realmKey)
    realmKey = realmKey or AG:GetRealmKey()
    if AUCTION_GATHER_DATA and AUCTION_GATHER_DATA.realms then
        AUCTION_GATHER_DATA.realms[realmKey] = nil
        AG:Print("Cleared data for " .. realmKey)
    end
end

-- Get total storage size (approximate)
function Storage:GetStorageSize()
    local total = 0
    if AUCTION_GATHER_DATA and AUCTION_GATHER_DATA.realms then
        for _, scan in pairs(AUCTION_GATHER_DATA.realms) do
            total = total + #(scan.d or "")
        end
    end
    return total
end
