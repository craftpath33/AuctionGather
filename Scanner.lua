--[[
    AuctionGather - Lightweight Auction Scanner
    Scanner.lua - Shared scan engine + backend dispatcher

    This file holds the API-agnostic engine: the accumulator that collects
    auctions across events, the debounced finalizer, and the async
    serialize -> encode -> save pipeline.

    The actual reading of auctions from the WoW API lives in two backends,
    selected at runtime by Scanner:SelectBackend():
      - AG.Scanner.legacy (ScannerLegacy.lua) - GetAuctionItemInfo / GetAll
                                                 (vanilla, tbc, wrath)
      - AG.Scanner.modern (ScannerModern.lua) - C_AuctionHouse replicate
                                                 (cata, mists/MoP, retail)

    Both backends feed the same accumulator and reuse this engine's pipeline,
    so the serialized output format is identical regardless of source.
]]

local ADDON_NAME, AG = ...

AG.Scanner = {}
local Scanner = AG.Scanner

-- Debounce + async save pipeline configuration (engine-owned, backend-agnostic)
local DEBOUNCE_DELAY = 2.0          -- Silence period before finalizing (seconds)
local ASYNC_SERIALIZE_CHUNK = 500   -- items per tick during serialization
local ASYNC_ENCODE_CHUNK = 30000    -- bytes per tick during encoding (must be multiple of 3)
local ASYNC_STEP_DELAY = 0.02       -- seconds between async ticks

-- Scanner state (shared by whichever backend is active)
Scanner.state = {
    isProcessing = false,       -- True during batched reading
    pendingFinalize = false,    -- Debounce flag for finalization
    lastEventTime = 0,          -- Last data-received time (for debounce)
    startTime = 0,              -- When scanning started (for duration calc)
    currentIndex = 0,           -- Current batch cursor (batched read)
    totalItems = 0,             -- Total items to read (batched read)
    scanSavedThisSession = false, -- True after a scan was saved this AH session
                                  -- Prevents AH browsing from creating a new accumulator
                                  -- and overwriting the saved scan. Reset on AH reopen.
    pendingCloseFinalize = false, -- True when AH closed while batches were running.
                                  -- ProcessBatch will finalize directly when done.
    capturingBackend = nil,       -- Backend (legacy/modern) running the current read;
                                  -- decides close behaviour (see OnAuctionHouseClosed).
}

-- Accumulator: collects auctions across multiple events
Scanner.accumulator = nil

-- Async save state: non-nil while a save pipeline is running
Scanner.asyncSave = nil

-- One-shot warnings: keys that have already been shown this session.
-- Prevents spamming the same warning on every data-received event.
Scanner.warnedThisSession = {}

-- Active backend (AG.Scanner.legacy or AG.Scanner.modern), chosen in Initialize
Scanner.active = nil

-- Select the auction-reading backend.
-- IMPORTANT: do NOT detect by `C_AuctionHouse` presence. The C_AuctionHouse namespace
-- (incl. ReplicateItems) ALSO exists on legacy-AH clients like Classic Era — but the
-- active auction house there is still the LEGACY one. Detecting by presence wrongly routes
-- Classic Era to the modern backend, so its GetAll (AUCTION_ITEM_LIST_UPDATE) is never
-- captured. Mirror Auctionator: trust the project id + IsUsingLegacyAuctionClient().
-- Legacy AH = vanilla / tbc / wrath; modern AH = cata / mists(MoP) / retail.
function Scanner:SelectBackend()
    local isLegacyAH =
        WOW_PROJECT_ID == WOW_PROJECT_CLASSIC                     -- vanilla / Classic Era
        or WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC  -- TBC
        or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC            -- WotLK
        or (IsUsingLegacyAuctionClient ~= nil and IsUsingLegacyAuctionClient())

    if isLegacyAH then
        self.active = self.legacy
    elseif C_AuctionHouse and C_AuctionHouse.ReplicateItems then
        self.active = self.modern
    else
        self.active = self.legacy  -- safe fallback (no modern AH available)
    end
end

-- Initialize scanner: pick the backend, then let it initialize itself
function Scanner:Initialize()
    self:SelectBackend()

    if not self.active then
        AG:Warn("No scanner backend available for this client.")
        return
    end

    -- Dual-listen: BOTH backends must be ready regardless of which one is
    -- "active" (active only gates the manual/auto trigger). The legacy
    -- backend's Initialize also installs the getAll watch hook.
    if self.legacy and self.legacy.Initialize then
        self.legacy:Initialize()
    end
    if self.modern and self.modern.Initialize then
        self.modern:Initialize()
    end

    local which = (self.active == self.modern) and "modern (C_AuctionHouse)" or "legacy (GetAuctionItemInfo)"
    AG:Debug("Scanner initialized — backend: " .. which)
end

-- Called when the auction house is opened: reset per-session state
function Scanner:OnAuctionHouseShow()
    self.state.scanSavedThisSession = false
    self.state.pendingCloseFinalize = false
    self.warnedThisSession = {}  -- clear one-shot warnings so they fire again if needed
    AG:Debug("Scanner session reset (AH opened)")

    -- Let the active backend react (e.g. modern auto-trigger), if it wants to
    if self.active and self.active.OnAuctionHouseShow then
        self.active:OnAuctionHouseShow()
    end
end

-- Routed from Events on legacy AUCTION_ITEM_LIST_UPDATE.
-- Delegates to the active backend (only the legacy backend does real work here).
function Scanner:OnDataReceived()
    if self.active and self.active.OnDataReceived then
        self.active:OnDataReceived()
    end
end

-- Routed from Events on modern REPLICATE_ITEM_LIST_UPDATE.
-- Delegates to the active backend (only the modern backend does real work here).
function Scanner:OnReplicateUpdate()
    if self.active and self.active.OnReplicateUpdate then
        self.active:OnReplicateUpdate()
    end
end

-- Reset accumulator to empty state
function Scanner:ResetAccumulator(mode)
    self.accumulator = {
        items = {},             -- itemId -> { name, quality, level, auctions[] }
        totalAuctions = 0,
        uniqueItems = 0,
        totalBuyout = 0,
        mode = mode or "unknown",  -- "getall", "replicate" or "paged"
        pagesRead = 0,
        lastReportedProgress = 0,
    }
end

-- Add a single auction to the accumulator
-- Deduplication not needed: WoW API pages don't overlap,
-- and GetAll/replicate deliver all auctions in a single pass
function Scanner:AccumulateAuction(auction)
    if not auction or not auction.itemId then
        return
    end

    local acc = self.accumulator
    local itemId = auction.itemId

    if not acc.items[itemId] then
        acc.items[itemId] = {
            name = auction.name,
            quality = auction.quality,
            level = auction.level,
            auctions = {},
        }
        acc.uniqueItems = acc.uniqueItems + 1
    end

    table.insert(acc.items[itemId].auctions, {
        count = auction.count,
        minBid = auction.minBid,
        buyout = auction.buyout,
        bidAmount = auction.bidAmount,
        owner = auction.owner,
        timeLeft = auction.timeLeft,
    })

    acc.totalAuctions = acc.totalAuctions + 1
    acc.totalBuyout = acc.totalBuyout + (auction.buyout or 0)
end

-- Schedule finalization with debounce
function Scanner:ScheduleFinalize()
    self.state.lastEventTime = GetTime()

    if self.state.pendingFinalize then
        -- Already have a pending timer, just update the timestamp
        return
    end

    self.state.pendingFinalize = true
    AG:Debug("Finalization scheduled, waiting " .. DEBOUNCE_DELAY .. "s for silence...")

    C_Timer.After(DEBOUNCE_DELAY, function()
        self:TryFinalize()
    end)
end

-- Try to finalize (called after debounce delay)
function Scanner:TryFinalize()
    if not self.state.pendingFinalize then
        return
    end

    -- Still processing batches? Wait more.
    if self.state.isProcessing then
        AG:Debug("Still processing batches, rescheduling finalization...")
        C_Timer.After(DEBOUNCE_DELAY, function()
            self:TryFinalize()
        end)
        return
    end

    -- Check if enough silence has passed (debounce)
    local timeSinceLastEvent = GetTime() - self.state.lastEventTime
    if timeSinceLastEvent < DEBOUNCE_DELAY - 0.1 then
        AG:Debug("Events still coming, rescheduling...")
        C_Timer.After(DEBOUNCE_DELAY, function()
            self:TryFinalize()
        end)
        return
    end

    -- Clear pending flag
    self.state.pendingFinalize = false

    -- Finalize
    self:FinalizeAccumulator()
end

-- Package accumulated data and hand off to async save pipeline.
-- The accumulator is cleared immediately so a new scan can start;
-- the save pipeline runs in the background via C_Timer ticks.
-- @param isEarlyTermination boolean - true when called from OnAuctionHouseClosed (partial scan)
function Scanner:FinalizeAccumulator(isEarlyTermination)
    if not self.accumulator then
        AG:Debug("FinalizeAccumulator: No accumulator data")
        return
    end

    local acc = self.accumulator
    local endTime = debugprofilestop() / 1000
    local duration = endTime - self.state.startTime

    AG:Debug(string.format("Finalizing: %d auctions, %d unique items, mode=%s, pages=%d, %.2fs (earlyTermination=%s)",
        acc.totalAuctions, acc.uniqueItems, acc.mode, acc.pagesRead, duration, tostring(isEarlyTermination or false)))

    if acc.totalAuctions == 0 then
        AG:Print("|cFFFF6600No auctions listened.|r Try browsing the auction house first.")
        self.accumulator = nil
        return
    end

    -- Clear accumulator immediately so a new scan can begin
    -- (the async pipeline holds its own reference via the local `acc`)
    self.accumulator = nil

    -- Hand off to async save pipeline
    self:StartAsyncSave(acc, duration, isEarlyTermination)
end

-- Begin the async serialize → encode → save pipeline.
-- If a previous async save is still in progress, flush it synchronously first
-- to avoid losing data or mixing payloads.
-- @param acc table        - the accumulator snapshot (items, counts, mode, etc.)
-- @param duration number  - scan duration in seconds
-- @param isEarlyTermination boolean
function Scanner:StartAsyncSave(acc, duration, isEarlyTermination)
    -- If a previous save is still running, complete it synchronously before starting a new one
    if self.asyncSave then
        AG:Debug("Previous async save still running, flushing synchronously before starting new save")
        self:FlushAsyncSave()
    end

    -- Build an ordered item list for deterministic iteration during serialization
    local itemList = {}
    for itemId in pairs(acc.items) do
        itemList[#itemList + 1] = itemId
    end

    self.asyncSave = {
        -- Pipeline phase: "serialize" → "encode" → "save"
        phase = "serialize",

        -- Serialization state
        items     = acc.items,     -- reference to item map
        itemList  = itemList,      -- ordered key list
        itemIndex = 1,             -- next itemList index to process
        lines     = {},            -- accumulated serialized lines

        -- Counts / metadata carried forward
        totalAuctions      = acc.totalAuctions,
        uniqueItems        = acc.uniqueItems,
        totalBuyout        = acc.totalBuyout,
        duration           = duration,
        mode               = acc.mode,
        pagesRead          = acc.pagesRead,
        isEarlyTermination = isEarlyTermination or false,

        -- Encode state (populated after serialize phase)
        rawData   = nil,  -- full serialized string
        byteIndex = 1,    -- next byte offset for encoding
        chunks    = {},   -- accumulated Base64 chunks
    }

    AG:Print("|cFFFFFF00Encoding...|r " .. AG:FormatNumber(acc.totalAuctions) .. " auctions")

    C_Timer.After(0, function()
        Scanner:AsyncSaveStep()
    end)
end

-- Execute one tick of the async save pipeline, then reschedule itself.
-- Each tick handles ASYNC_SERIALIZE_CHUNK items (serialize phase) or
-- ASYNC_ENCODE_CHUNK bytes (encode phase), then yields via C_Timer.After.
function Scanner:AsyncSaveStep()
    if not self.asyncSave then
        return
    end

    local ok, err = pcall(function()
        local s = self.asyncSave

        ----------------------------------------------------------------
        -- Phase: serialize
        -- Convert items dict → compact text lines, ASYNC_SERIALIZE_CHUNK at a time
        ----------------------------------------------------------------
        if s.phase == "serialize" then
            local chunkEnd = math.min(s.itemIndex + ASYNC_SERIALIZE_CHUNK - 1, #s.itemList)

            for i = s.itemIndex, chunkEnd do
                local itemId   = s.itemList[i]
                local itemData = s.items[itemId]

                -- Build auction entries: count,minBid,buyout,timeLeft
                local auctionParts = {}
                for _, a in ipairs(itemData.auctions) do
                    auctionParts[#auctionParts + 1] = string.format("%d,%d,%d,%d",
                        a.count    or 1,
                        a.minBid   or 0,
                        a.buyout   or 0,
                        a.timeLeft or 0
                    )
                end

                -- Format: itemId:name:quality:level:auctions
                s.lines[#s.lines + 1] = string.format("%d:%s:%d:%d:%s",
                    itemId,
                    (itemData.name or ""):gsub(":", ""),  -- strip colons from name
                    itemData.quality or 0,
                    itemData.level   or 0,
                    table.concat(auctionParts, ";")
                )
            end

            s.itemIndex = chunkEnd + 1

            -- All items serialized?
            if s.itemIndex > #s.itemList then
                s.rawData  = table.concat(s.lines, "\n")
                s.lines    = nil
                s.itemList = nil
                s.items    = nil
                s.phase    = "encode"
                AG:Debug("Serialize complete: " .. #s.rawData .. " bytes, switching to encode phase")
            end

            -- Schedule next tick regardless of whether we just switched phase
            C_Timer.After(ASYNC_STEP_DELAY, function()
                Scanner:AsyncSaveStep()
            end)
            return
        end

        ----------------------------------------------------------------
        -- Phase: encode
        -- Base64-encode rawData in ASYNC_ENCODE_CHUNK-byte slices
        ----------------------------------------------------------------
        if s.phase == "encode" then
            local dataLen  = #s.rawData
            local chunkEnd = math.min(s.byteIndex + ASYNC_ENCODE_CHUNK - 1, dataLen)

            -- Align to 3-byte boundary so each chunk encodes cleanly without padding,
            -- UNLESS this is the final chunk (let the encoder add "=" padding normally)
            if chunkEnd < dataLen then
                local aligned = s.byteIndex + math.floor((chunkEnd - s.byteIndex + 1) / 3) * 3 - 1
                if aligned < s.byteIndex then
                    -- Rounding went below start (chunk smaller than 3 bytes) — encode remainder
                    chunkEnd = dataLen
                else
                    chunkEnd = aligned
                end
            end

            s.chunks[#s.chunks + 1] = AG.Encoder:Base64Encode(s.rawData:sub(s.byteIndex, chunkEnd))
            s.byteIndex = chunkEnd + 1

            -- All bytes encoded?
            if s.byteIndex > dataLen then
                s.rawData = nil
                s.phase   = "save"
                AG:Debug("Encode complete: " .. #s.chunks .. " chunks, switching to save phase")
            end

            -- Schedule next tick regardless of whether we just switched phase
            C_Timer.After(ASYNC_STEP_DELAY, function()
                Scanner:AsyncSaveStep()
            end)
            return
        end

        ----------------------------------------------------------------
        -- Phase: save
        ----------------------------------------------------------------
        if s.phase == "save" then
            local payload = table.concat(s.chunks):reverse()
            s.chunks = nil

            local metadata = {
                totalAuctions      = s.totalAuctions,
                uniqueItems        = s.uniqueItems,
                totalBuyout        = s.totalBuyout,
                duration           = s.duration,
                mode               = s.mode,
                pagesRead          = s.pagesRead,
                payload            = payload,
            }

            local saved = false
            if AG.Storage then
                saved = AG.Storage:SaveEncoded(metadata, s.isEarlyTermination)
            end

            -- Update session state after successful save
            if saved then
                self.state.scanSavedThisSession = true
                AG.State.lastScanTime = AG:GetTimestamp()
            end

            -- Fire SCAN_COMPLETE only when actually saved
            if saved and AG.Events then
                -- Reconstruct minimal scanData for callbacks that expect it
                local scanData = {
                    totalAuctions = s.totalAuctions,
                    uniqueItems   = s.uniqueItems,
                    totalBuyout   = s.totalBuyout,
                    duration      = s.duration,
                    mode          = s.mode,
                    pagesRead     = s.pagesRead,
                }
                AG.Events:FireCallback("SCAN_COMPLETE", scanData)
            end

            AG:Debug(string.format(
                "Async save complete: %s auctions, %s items (%s, %.1fs)",
                AG:FormatNumber(s.totalAuctions),
                AG:FormatNumber(s.uniqueItems),
                s.mode,
                s.duration
            ))

            -- Pipeline finished — clear state, do NOT schedule another tick
            self.asyncSave = nil
            return
        end
    end)

    -- If any phase errored, reset async state to avoid stuck pipeline
    if not ok then
        AG:Debug("AsyncSaveStep error: " .. tostring(err))
        AG:Print("|cFFFF6600Async save error.|r Scan data may not have been saved.")
        self.asyncSave = nil
    end
end

-- Complete any in-progress async save pipeline synchronously.
-- Called on PLAYER_LOGOUT so data is written before the game exits.
-- May be slow for large scans, but that is acceptable on logout.
function Scanner:FlushAsyncSave()
    if not self.asyncSave then
        return
    end

    AG:Print("|cFFFF9900Completing scan save before logout...|r")

    -- Run all remaining pipeline steps without yielding via timers
    while self.asyncSave do
        local s = self.asyncSave
        local ok, err = pcall(function()

            ------------------------------------------------------------
            -- Flush: serialize phase
            ------------------------------------------------------------
            if s.phase == "serialize" then
                local chunkEnd = math.min(s.itemIndex + ASYNC_SERIALIZE_CHUNK - 1, #s.itemList)

                for i = s.itemIndex, chunkEnd do
                    local itemId   = s.itemList[i]
                    local itemData = s.items[itemId]

                    local auctionParts = {}
                    for _, a in ipairs(itemData.auctions) do
                        auctionParts[#auctionParts + 1] = string.format("%d,%d,%d,%d",
                            a.count    or 1,
                            a.minBid   or 0,
                            a.buyout   or 0,
                            a.timeLeft or 0
                        )
                    end

                    s.lines[#s.lines + 1] = string.format("%d:%s:%d:%d:%s",
                        itemId,
                        (itemData.name or ""):gsub(":", ""),
                        itemData.quality or 0,
                        itemData.level   or 0,
                        table.concat(auctionParts, ";")
                    )
                end

                s.itemIndex = chunkEnd + 1

                if s.itemIndex > #s.itemList then
                    s.rawData  = table.concat(s.lines, "\n")
                    s.lines    = nil
                    s.itemList = nil
                    s.items    = nil
                    s.phase    = "encode"
                end
                return  -- loop continues to next iteration
            end

            ------------------------------------------------------------
            -- Flush: encode phase
            ------------------------------------------------------------
            if s.phase == "encode" then
                local dataLen  = #s.rawData
                local chunkEnd = math.min(s.byteIndex + ASYNC_ENCODE_CHUNK - 1, dataLen)

                if chunkEnd < dataLen then
                    local aligned = s.byteIndex + math.floor((chunkEnd - s.byteIndex + 1) / 3) * 3 - 1
                    if aligned < s.byteIndex then
                        chunkEnd = dataLen
                    else
                        chunkEnd = aligned
                    end
                end

                s.chunks[#s.chunks + 1] = AG.Encoder:Base64Encode(s.rawData:sub(s.byteIndex, chunkEnd))
                s.byteIndex = chunkEnd + 1

                if s.byteIndex > dataLen then
                    s.rawData = nil
                    s.phase   = "save"
                end
                return  -- loop continues to next iteration
            end

            ------------------------------------------------------------
            -- Flush: save phase
            ------------------------------------------------------------
            if s.phase == "save" then
                local payload = table.concat(s.chunks):reverse()
                s.chunks = nil

                local metadata = {
                    totalAuctions      = s.totalAuctions,
                    uniqueItems        = s.uniqueItems,
                    totalBuyout        = s.totalBuyout,
                    duration           = s.duration,
                    mode               = s.mode,
                    pagesRead          = s.pagesRead,
                    payload            = payload,
                }

                local saved = false
                if AG.Storage then
                    saved = AG.Storage:SaveEncoded(metadata, s.isEarlyTermination)
                end

                if saved then
                    self.state.scanSavedThisSession = true
                    AG.State.lastScanTime = AG:GetTimestamp()
                end

                if saved and AG.Events then
                    local scanData = {
                        totalAuctions = s.totalAuctions,
                        uniqueItems   = s.uniqueItems,
                        totalBuyout   = s.totalBuyout,
                        duration      = s.duration,
                        mode          = s.mode,
                        pagesRead     = s.pagesRead,
                    }
                    AG.Events:FireCallback("SCAN_COMPLETE", scanData)
                end

                -- Pipeline done — clear state and break the while loop
                self.asyncSave = nil
                return
            end
        end)

        if not ok then
            AG:Debug("FlushAsyncSave error: " .. tostring(err))
            AG:Print("|cFFFF6600Flush error.|r Scan data may not have been saved.")
            self.asyncSave = nil
            break
        end
    end
end

-- Handle AH close.
-- DEFAULT when a read is mid-flight is the SAFE one: finish reading in the background and
-- save. This is the original, battle-tested legacy behaviour (the GetAll buffer persists
-- after close). Only a backend that explicitly OPTS IN via `discardOnClose` aborts instead
-- (the modern replicate backend, whose buffer truncates on close). Defaulting to "finish"
-- means a missing / not-yet-loaded backend can never silently discard a legacy scan.
function Scanner:OnAuctionHouseClosed()
    if self.state.isProcessing then
        -- Use the backend that actually started this read (capture is dual-listen, so the
        -- active backend may differ from the capturing one). Modern's replicate buffer
        -- truncates on close -> abort; legacy's GetAll buffer persists -> finish + save.
        local cap = self.state.capturingBackend
        if cap and cap.discardOnClose then
            AG:Print("|cFFFF9900Auction house closed mid-scan — scan cancelled.|r Keep the AH open until the scan finishes.")
            self:CancelCapture()
        else
            AG:Print("|cFFFF9900Auction house closed.|r Finishing scan in background...")
            self.state.pendingCloseFinalize = true
            self.state.pendingFinalize = false
        end
        return
    end

    -- Batches are done (or never started). Finalize immediately.
    -- isEarlyTermination=false: isProcessing=false means all data was collected.
    local hadPendingWork = self.state.pendingFinalize

    if self.state.pendingFinalize then
        self.state.pendingFinalize = false
    end

    if self.accumulator and self.accumulator.totalAuctions > 0 then
        if hadPendingWork then
            AG:Print("Saving " .. AG:FormatNumber(self.accumulator.totalAuctions) .. " collected auctions...")
        end
        self:FinalizeAccumulator(false)
    else
        self.accumulator = nil
    end
end

-- Cancel ongoing capture (used for explicit cancel, not AH close)
function Scanner:CancelCapture()
    -- Cancel pending finalization
    if self.state.pendingFinalize then
        AG:Debug("Pending finalization cancelled")
        self.state.pendingFinalize = false
    end

    -- Cancel active batch processing
    if self.state.isProcessing then
        AG:Debug("Active batch processing cancelled")
        self.state.isProcessing = false
    end

    -- Clear accumulator
    if self.accumulator then
        AG:Debug("Accumulator cleared (" .. self.accumulator.totalAuctions .. " auctions discarded)")
        self.accumulator = nil
    end
end
