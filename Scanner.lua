--[[
    AuctionGather - Lightweight Auction Scanner
    Scanner.lua - Auction data processing

    Uses accumulator pattern to support both GetAll (full scan)
    and page-by-page scanning (e.g. Auctionator).

    GetAll: single large event → batched read → accumulate → finalize
    Page-by-page: many small events → read immediately → accumulate → finalize after silence
]]

local ADDON_NAME, AG = ...

AG.Scanner = {}
local Scanner = AG.Scanner

-- Scanner configuration
local BATCH_SIZE = 200          -- Items per batch for GetAll (smaller = less CPU spike)
local BATCH_DELAY = 0.05        -- Delay between batches in seconds (GetAll only)
local DEBOUNCE_DELAY = 2.0      -- Silence period before finalizing (seconds)
local GETALL_THRESHOLD = 200    -- batch==total and above this = GetAll mode

-- Async save pipeline configuration
local ASYNC_SERIALIZE_CHUNK = 500   -- items per tick during serialization
local ASYNC_ENCODE_CHUNK = 30000    -- bytes per tick during encoding (must be multiple of 3)
local ASYNC_STEP_DELAY = 0.02       -- seconds between async ticks

-- Scanner state
Scanner.state = {
    isProcessing = false,       -- True during batched GetAll reading
    pendingFinalize = false,    -- Debounce flag for finalization
    lastEventTime = 0,          -- Last OnDataReceived time (for debounce)
    startTime = 0,              -- When scanning started (for duration calc)
    currentIndex = 0,           -- Current batch index (GetAll only)
    totalItems = 0,             -- Total items to read (GetAll only)
    scanSavedThisSession = false, -- True after a scan was saved this AH session
                                  -- Prevents AH browsing from creating a new accumulator
                                  -- and overwriting the saved scan. Reset on AH reopen.
    pendingCloseFinalize = false, -- True when AH closed while GetAll batches were running.
                                  -- ProcessBatch will finalize directly when done.
}

-- Accumulator: collects auctions across multiple events
Scanner.accumulator = nil

-- Async save state: non-nil while a save pipeline is running
Scanner.asyncSave = nil

-- One-shot warnings: keys that have already been shown this session.
-- Prevents spamming the same warning on every AUCTION_ITEM_LIST_UPDATE.
Scanner.warnedThisSession = {}

-- Initialize scanner
function Scanner:Initialize()
    AG:Debug("Scanner initialized")
end

-- Called when the auction house is opened: reset per-session state
function Scanner:OnAuctionHouseShow()
    self.state.scanSavedThisSession = false
    self.state.pendingCloseFinalize = false
    self.warnedThisSession = {}  -- clear one-shot warnings so they fire again if needed
    AG:Debug("Scanner session reset (AH opened)")
end

-- Reset accumulator to empty state
function Scanner:ResetAccumulator(mode)
    self.accumulator = {
        items = {},             -- itemId -> { name, quality, level, auctions[] }
        totalAuctions = 0,
        uniqueItems = 0,
        totalBuyout = 0,
        mode = mode or "unknown",  -- "getall" or "paged"
        pagesRead = 0,
        lastReportedProgress = 0,
    }
end

-- Add a single auction to the accumulator
-- Deduplication not needed: WoW API pages don't overlap,
-- and GetAll delivers all auctions in a single batch
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

-- Called on each AUCTION_ITEM_LIST_UPDATE event
function Scanner:OnDataReceived()
    -- Don't start new reads while GetAll batched processing is running
    if self.state.isProcessing then
        AG:Debug("OnDataReceived: skip — isProcessing")
        return
    end

    -- Don't start a new accumulator while background finalization is pending
    -- (AH closed mid-batch, ProcessBatch is finishing up in the background)
    if self.state.pendingCloseFinalize then
        AG:Debug("OnDataReceived: skip — pendingCloseFinalize")
        return
    end

    local batch, total = GetNumAuctionItems("list")
    if not batch or batch == 0 then
        return
    end

    local isGetAll = batch == total and batch >= GETALL_THRESHOLD

    -- Check if AH is open.
    -- Some addons (e.g. Auctionator) close and reopen the AH frame before scanning
    -- without always firing AUCTION_HOUSE_SHOW, leaving our flag stuck at false.
    -- If a GetAll batch arrived, the AH is clearly queryable — trust the data.
    if not AG.State.auctionHouseOpen then
        if isGetAll then
            AG:Warn("GetAll data received but AH not detected as open — auto-correcting.")
            AG.State.auctionHouseOpen = true
        else
            AG:Debug("OnDataReceived: skip — AH not open")
            return
        end
    end

    -- Check config
    if not AUCTION_GATHER_CONFIG then
        if not self.warnedThisSession["no_config"] then
            self.warnedThisSession["no_config"] = true
            AG:Warn("Config not loaded — Storage init may have failed. Try |cFFFFFF00/reload|r or |cFFFFFF00/ag clear|r.")
        end
        return
    end
    if not AUCTION_GATHER_CONFIG.autoScan then
        if not self.warnedThisSession["autoscan_off"] then
            self.warnedThisSession["autoscan_off"] = true
            AG:Warn("autoScan is disabled — scanning is off.")
        end
        return
    end

    -- Initialize accumulator on first event
    if not self.accumulator then
        -- Only GetAll can start a new capture session.
        -- Paged browsing/scans (batch < total) are ignored — partial data would
        -- overwrite a legitimate full scan.
        if not isGetAll then
            AG:Debug(string.format("Ignoring paged event (batch=%d, total=%d)", batch, total))
            return
        end

        self.state.startTime = debugprofilestop() / 1000
        self.state.scanSavedThisSession = false
        self:ResetAccumulator("getall")
        AG:Print("|cFFFFFF00Scanning auction house...|r " .. AG:FormatNumber(total) .. " auctions (GetAll)")
    end

    if isGetAll then
        -- GetAll: entire AH in one batch — use chunked reading to avoid client freeze
        self.accumulator.mode = "getall"
        -- Guard against duplicate GetAll events restarting batched reading mid-process
        if not self.accumulator.batchedReadStarted then
            self:StartBatchedRead(batch)
        end
    else
        -- Paged event while GetAll accumulator is active — read and accumulate
        self.accumulator.mode = self.accumulator.mode == "getall" and "getall" or "paged"
        self:ReadCurrentPage(batch)
    end

    -- Schedule finalization (debounced)
    self:ScheduleFinalize()
end

-- Read all items from the current API buffer (page-by-page mode)
-- batch is small (~50 items), so reading synchronously is fine
function Scanner:ReadCurrentPage(count)
    local withOwner = AUCTION_GATHER_CONFIG.includeOwner
    local withBid = AUCTION_GATHER_CONFIG.includeBid

    for i = 1, count do
        local ok, auction = pcall(function()
            return self:GetAuctionInfo(i, withOwner, withBid)
        end)

        if ok and auction then
            self:AccumulateAuction(auction)
        end
    end

    self.accumulator.pagesRead = self.accumulator.pagesRead + 1
    AG:Debug(string.format("Page read: %d items (total accumulated: %d)",
        count, self.accumulator.totalAuctions))
end

-- Start batched reading for GetAll mode (avoids client freeze)
function Scanner:StartBatchedRead(total)
    AG:Debug("Reading auction data... (" .. AG:FormatNumber(total) .. " auctions, GetAll)")

    self.state.isProcessing = true
    self.state.currentIndex = 1
    self.state.totalItems = total
    self.accumulator.pagesRead = 1       -- GetAll = one "page"
    self.accumulator.batchedReadStarted = true  -- Guard against double-start

    -- Start batch loop
    self:ProcessBatch()
end

-- Process a batch of auctions (GetAll mode only)
function Scanner:ProcessBatch()
    if not self.state.isProcessing then
        return
    end

    -- Note: no auctionHouseOpen check here — GetAll data was already fetched from
    -- the server before the AH window opened. The client buffer persists after close,
    -- so processing continues to completion. OnAuctionHouseClosed sets pendingCloseFinalize.

    local ok, err = pcall(function()
        local batchEnd = math.min(
            self.state.currentIndex + BATCH_SIZE - 1,
            self.state.totalItems
        )

        local withOwner = AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.includeOwner
        local withBid = AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.includeBid

        for i = self.state.currentIndex, batchEnd do
            local aok, auction = pcall(function()
                return self:GetAuctionInfo(i, withOwner, withBid)
            end)

            if not aok then
                AG:Debug("Error getting auction " .. i .. ", skipping")
            elseif auction then
                self:AccumulateAuction(auction)
            end
        end

        self.state.currentIndex = batchEnd + 1

        -- Report progress at 25% milestones (once per milestone)
        local progress = math.floor((self.state.currentIndex / self.state.totalItems) * 100)
        local milestone = progress - (progress % 25)
        if milestone > 0 and milestone > self.accumulator.lastReportedProgress then
            self.accumulator.lastReportedProgress = milestone
            AG:Print("|cFFFFFF00Processing...|r " .. milestone .. "% (" ..
                AG:FormatNumber(self.accumulator.totalAuctions) .. " auctions)")
        end

        -- Continue or finish batched reading
        if self.state.currentIndex <= self.state.totalItems then
            C_Timer.After(BATCH_DELAY, function()
                Scanner:ProcessBatch()
            end)
        else
            -- Batched reading done
            AG:Print("|cFFFFFF00Processing complete.|r Saving data...")
            self.state.isProcessing = false

            -- If AH closed while we were processing, finalize directly now that all
            -- batches are done. isEarlyTermination=false — all data was collected.
            if self.state.pendingCloseFinalize then
                self.state.pendingCloseFinalize = false
                self.state.pendingFinalize = false
                self:FinalizeAccumulator(false)
            end
            -- Otherwise the debounce timer handles finalization
        end
    end)

    -- If the batch errored, reset processing state so the addon doesn't get stuck.
    -- isProcessing/pendingCloseFinalize staying true would silently block all future scans.
    if not ok then
        AG:Debug("ProcessBatch error: " .. tostring(err))
        self.state.isProcessing = false
        self.state.pendingCloseFinalize = false
        self.state.pendingFinalize = false
        self.accumulator = nil
        AG:Print("|cFFFF6600Scan error.|r Processing failed, scan discarded. Try again.")
    end
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

    -- Still processing GetAll batches? Wait more.
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

-- Handle AH close: save accumulated data instead of discarding
function Scanner:OnAuctionHouseClosed()
    -- If GetAll batches are still running, let them finish in the background.
    -- The data was already fetched from the server; the client buffer persists after close.
    -- ProcessBatch will finalize when all batches are done.
    if self.state.isProcessing then
        AG:Print("|cFFFF9900Auction house closed.|r Finishing scan in background...")
        self.state.pendingCloseFinalize = true
        self.state.pendingFinalize = false
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

-- Get current auction count
function Scanner:GetAuctionCount()
    local batch, total = GetNumAuctionItems("list")
    return total or 0
end

-- Get info for a single auction
-- @param index number - Auction index (1-based)
-- @return table - Auction data
function Scanner:GetAuctionInfo(index, withOwner, withBid)
    -- GetAuctionItemInfo returns:
    -- name, texture, count, quality, canUse, level, levelColHeader,
    -- minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
    -- bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo

    local name, texture, count, quality, canUse, level, levelColHeader,
          minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
          bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo =
          GetAuctionItemInfo("list", index)

    -- Skip if no data
    if not name or not itemId then
        return nil
    end

    -- Get time left (1=short, 2=medium, 3=long, 4=very long)
    local timeLeft = GetAuctionItemTimeLeft("list", index)

    -- Build auction record
    local auction = {
        itemId = itemId,
        name = name,
        count = count or 1,
        quality = quality or 0,
        level = level or 0,
        minBid = minBid or 0,
        buyout = buyoutPrice or 0,
        timeLeft = timeLeft,
    }

    -- Optional fields
    if withBid then
        auction.bidAmount = bidAmount or 0
        auction.highBidder = highBidder
    end

    if withOwner then
        auction.owner = owner
    end

    return auction
end
