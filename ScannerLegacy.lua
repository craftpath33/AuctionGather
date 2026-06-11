--[[
    AuctionGather - Lightweight Auction Scanner
    ScannerLegacy.lua - Legacy auction-house reading backend

    For clients using the LEGACY auction API (vanilla, tbc, wrath):
    GetNumAuctionItems / GetAuctionItemInfo / GetAuctionItemTimeLeft, driven by
    the AUCTION_ITEM_LIST_UPDATE event.

    Supports both GetAll (full scan, single large event → batched read) and
    page-by-page scanning (many small events). This backend only READS auctions;
    it feeds the shared engine (AG.Scanner) accumulator and reuses the engine's
    debounced finalize + async save pipeline.

    NOTE: this is a verbatim extraction of the original Scanner reading logic,
    re-pointed at the shared engine (Engine.state / Engine.accumulator / Engine:*).
]]

local ADDON_NAME, AG = ...

-- Shared engine (defined in Scanner.lua, loaded before this file)
local Engine = AG.Scanner

AG.Scanner.legacy = {}
local Legacy = AG.Scanner.legacy

-- Legacy scanner configuration
local BATCH_SIZE = 200          -- Items per batch for GetAll (smaller = less CPU spike)
local BATCH_DELAY = 0.05        -- Delay between batches in seconds (GetAll only)
local GETALL_THRESHOLD = 200    -- batch==total and above this = GetAll mode
local GETALL_WATCH_INTERVAL = 0.5  -- Buffer poll period while a getAll query is pending
local GETALL_WATCH_TIMEOUT = 60    -- Give up when no data appears within this many seconds
local GETALL_PROCESSING_MAX_WAIT = 300  -- Max politeness wait for the scanning addon to finish

-- The legacy GetAll buffer PERSISTS after the AH closes, so a mid-scan close is finished
-- in the background and saved. That is the engine's DEFAULT behaviour in
-- OnAuctionHouseClosed (it only aborts for backends that set `discardOnClose`), so the
-- legacy backend intentionally sets no flag here.

function Legacy:Initialize()
    self:InstallGetAllWatch()
    AG:Debug("Legacy scanner backend ready")
end

-- Auctionator's legacy full scan UNREGISTERS every other frame from
-- AUCTION_ITEM_LIST_UPDATE for the whole scan-and-processing window (see its
-- FullScanFrameMixin:RegisterForEvents) and re-registers them only after it has
-- finished processing — the single getAll event fires while we are deaf, so the
-- passive event path never sees a fast full scan. The watch sidesteps the event:
-- a post-hook on QueryAuctionItems tells us a getAll was requested, then we poll
-- the (shared, persistent) list buffer until the data lands and feed it into the
-- normal OnDataReceived path. If the event DOES arrive (no interference), the
-- existing guards make the watch a no-op.
function Legacy:InstallGetAllWatch()
    if self.getAllWatchInstalled then
        return
    end
    if not QueryAuctionItems or not hooksecurefunc then
        return  -- modern-only client: no legacy AH to watch
    end

    self.getAllWatchInstalled = true
    hooksecurefunc("QueryAuctionItems", function(_, _, _, _, _, _, getAll)
        if getAll then
            Legacy:OnGetAllQueried()
        end
    end)
    AG:Debug("GetAll watch installed (QueryAuctionItems hook)")
end

-- A getAll query was just issued (by any addon). Poll for its data.
function Legacy:OnGetAllQueried()
    AG:Debug("getAll query detected — watching for scan data")
    self.getAllWatchDeadline = GetTime() + GETALL_WATCH_TIMEOUT
    self.getAllWaitStartedAt = nil
    self.getAllWaitAnnounced = nil

    if self.getAllWatchTicker then
        return  -- already watching; deadline refreshed above
    end

    self.getAllWatchTicker = C_Timer.NewTicker(GETALL_WATCH_INTERVAL, function()
        Legacy:PollGetAllData()
    end)
end

function Legacy:PollGetAllData()
    -- Capture already running (the event got through, or an earlier poll started it)
    if Engine.state.isProcessing or (Engine.accumulator and Engine.accumulator.batchedReadStarted) then
        self:StopGetAllWatch()
        return
    end

    local batch, total = GetNumAuctionItems("list")
    local dataReady = batch and batch == total and batch >= GETALL_THRESHOLD

    if not dataReady then
        if GetTime() > (self.getAllWatchDeadline or 0) then
            AG:Debug("GetAll watch expired — no scan data appeared")
            self:StopGetAllWatch()
        end
        return
    end

    -- Data is in the buffer. If the initiating addon (Auctionator) is still holding our
    -- stolen event registration, it is still crunching that same buffer — reading
    -- alongside it doubles the per-frame load and freezes the client (on 250k-auction
    -- realms badly). The buffer is persistent, so be polite: wait until the initiator
    -- gives the registration back (its EndProcessing / AH-close handler), then read solo.
    -- A hard cap guards against the initiator dying mid-scan and never returning it.
    if not self.getAllWaitStartedAt then
        self.getAllWaitStartedAt = GetTime()
    end

    local eventsFrame = AG.Events and AG.Events.frame
    local blocked = eventsFrame and not eventsFrame:IsEventRegistered("AUCTION_ITEM_LIST_UPDATE")

    if blocked and (GetTime() - self.getAllWaitStartedAt) < GETALL_PROCESSING_MAX_WAIT then
        if not self.getAllWaitAnnounced then
            self.getAllWaitAnnounced = true
            AG:Debug("GetAll watch: data ready, waiting for the scanning addon to finish processing...")
        end
        return
    end

    if blocked then
        -- Initiator never finished: take our registration back and read anyway.
        AG:Warn("Scanning addon did not finish in " .. GETALL_PROCESSING_MAX_WAIT .. "s — capturing anyway.")
        pcall(eventsFrame.RegisterEvent, eventsFrame, "AUCTION_ITEM_LIST_UPDATE")
    end

    AG:Debug(string.format("GetAll watch: data landed (%d auctions) — capturing", batch))
    self:StopGetAllWatch()
    self:OnDataReceived()
end

function Legacy:StopGetAllWatch()
    self.getAllWaitStartedAt = nil
    self.getAllWaitAnnounced = nil

    if self.getAllWatchTicker then
        self.getAllWatchTicker:Cancel()
        self.getAllWatchTicker = nil
    end
end

-- Called on each AUCTION_ITEM_LIST_UPDATE event
function Legacy:OnDataReceived()
    -- Capability guard: the legacy AH API is absent on modern-only clients. We register
    -- this event unconditionally (dual-listen), so bail if the legacy API isn't here.
    if not GetNumAuctionItems then
        return
    end

    -- Don't start new reads while GetAll batched processing is running
    if Engine.state.isProcessing then
        AG:Debug("OnDataReceived: skip — isProcessing")
        return
    end

    -- Don't start a new accumulator while background finalization is pending
    -- (AH closed mid-batch, ProcessBatch is finishing up in the background)
    if Engine.state.pendingCloseFinalize then
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
        if not Engine.warnedThisSession["no_config"] then
            Engine.warnedThisSession["no_config"] = true
            AG:Warn("Config not loaded — Storage init may have failed. Try |cFFFFFF00/reload|r or |cFFFFFF00/ag clear|r.")
        end
        return
    end
    if not AUCTION_GATHER_CONFIG.autoScan then
        if not Engine.warnedThisSession["autoscan_off"] then
            Engine.warnedThisSession["autoscan_off"] = true
            AG:Warn("autoScan is disabled — scanning is off.")
        end
        return
    end

    -- Initialize accumulator on first event
    if not Engine.accumulator then
        -- Only GetAll can start a new capture session.
        -- Paged browsing/scans (batch < total) are ignored — partial data would
        -- overwrite a legitimate full scan.
        if not isGetAll then
            AG:Debug(string.format("Ignoring paged event (batch=%d, total=%d)", batch, total))
            return
        end

        Engine.state.startTime = debugprofilestop() / 1000
        Engine.state.scanSavedThisSession = false
        Engine:ResetAccumulator("getall")
        AG:Print("|cFFFFFF00Scanning auction house...|r " .. AG:FormatNumber(total) .. " auctions (GetAll)")
    end

    if isGetAll then
        -- GetAll: entire AH in one batch — use chunked reading to avoid client freeze
        Engine.accumulator.mode = "getall"
        -- Guard against duplicate GetAll events restarting batched reading mid-process
        if not Engine.accumulator.batchedReadStarted then
            self:StartBatchedRead(batch)
        end
    else
        -- Paged event while GetAll accumulator is active — read and accumulate
        Engine.accumulator.mode = Engine.accumulator.mode == "getall" and "getall" or "paged"
        self:ReadCurrentPage(batch)
    end

    -- Schedule finalization (debounced)
    Engine:ScheduleFinalize()
end

-- Read all items from the current API buffer (page-by-page mode)
-- batch is small (~50 items), so reading synchronously is fine
function Legacy:ReadCurrentPage(count)
    local withOwner = AUCTION_GATHER_CONFIG.includeOwner
    local withBid = AUCTION_GATHER_CONFIG.includeBid

    for i = 1, count do
        local ok, auction = pcall(function()
            return self:GetAuctionInfo(i, withOwner, withBid)
        end)

        if ok and auction then
            Engine:AccumulateAuction(auction)
        end
    end

    Engine.accumulator.pagesRead = Engine.accumulator.pagesRead + 1
    AG:Debug(string.format("Page read: %d items (total accumulated: %d)",
        count, Engine.accumulator.totalAuctions))
end

-- Start batched reading for GetAll mode (avoids client freeze)
function Legacy:StartBatchedRead(total)
    AG:Debug("Reading auction data... (" .. AG:FormatNumber(total) .. " auctions, GetAll)")

    Engine.state.isProcessing = true
    Engine.state.capturingBackend = self
    Engine.state.currentIndex = 1
    Engine.state.totalItems = total
    Engine.accumulator.pagesRead = 1       -- GetAll = one "page"
    Engine.accumulator.batchedReadStarted = true  -- Guard against double-start

    -- Start batch loop
    self:ProcessBatch()
end

-- Process a batch of auctions (GetAll mode only)
function Legacy:ProcessBatch()
    if not Engine.state.isProcessing then
        return
    end

    -- Note: no auctionHouseOpen check here — GetAll data was already fetched from
    -- the server before the AH window opened. The client buffer persists after close,
    -- so processing continues to completion. OnAuctionHouseClosed sets pendingCloseFinalize.

    local ok, err = pcall(function()
        local batchEnd = math.min(
            Engine.state.currentIndex + BATCH_SIZE - 1,
            Engine.state.totalItems
        )

        local withOwner = AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.includeOwner
        local withBid = AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.includeBid

        for i = Engine.state.currentIndex, batchEnd do
            local aok, auction = pcall(function()
                return self:GetAuctionInfo(i, withOwner, withBid)
            end)

            if not aok then
                AG:Debug("Error getting auction " .. i .. ", skipping")
            elseif auction then
                Engine:AccumulateAuction(auction)
            end
        end

        Engine.state.currentIndex = batchEnd + 1

        -- Report progress at 25% milestones (once per milestone)
        local progress = math.floor((Engine.state.currentIndex / Engine.state.totalItems) * 100)
        local milestone = progress - (progress % 25)
        if milestone > 0 and milestone > Engine.accumulator.lastReportedProgress then
            Engine.accumulator.lastReportedProgress = milestone
            AG:Print("|cFFFFFF00Processing...|r " .. milestone .. "% (" ..
                AG:FormatNumber(Engine.accumulator.totalAuctions) .. " auctions)")
        end

        -- Continue or finish batched reading
        if Engine.state.currentIndex <= Engine.state.totalItems then
            C_Timer.After(BATCH_DELAY, function()
                Legacy:ProcessBatch()
            end)
        else
            -- Batched reading done
            AG:Print("|cFFFFFF00Processing complete.|r Saving data...")
            Engine.state.isProcessing = false

            -- If AH closed while we were processing, finalize directly now that all
            -- batches are done. isEarlyTermination=false — all data was collected.
            if Engine.state.pendingCloseFinalize then
                Engine.state.pendingCloseFinalize = false
                Engine.state.pendingFinalize = false
                Engine:FinalizeAccumulator(false)
            end
            -- Otherwise the debounce timer handles finalization
        end
    end)

    -- If the batch errored, reset processing state so the addon doesn't get stuck.
    -- isProcessing/pendingCloseFinalize staying true would silently block all future scans.
    if not ok then
        AG:Warn("ProcessBatch error (legacy): " .. tostring(err))
        Engine.state.isProcessing = false
        Engine.state.pendingCloseFinalize = false
        Engine.state.pendingFinalize = false
        Engine.accumulator = nil
        AG:Print("|cFFFF6600Scan error.|r Processing failed, scan discarded. Try again.")
    end
end

-- Get current auction count
function Legacy:GetAuctionCount()
    local batch, total = GetNumAuctionItems("list")
    return total or 0
end

-- Get info for a single auction
-- @param index number - Auction index (1-based)
-- @return table - Auction data
function Legacy:GetAuctionInfo(index, withOwner, withBid)
    -- GetAuctionItemInfo returns:
    -- name, texture, count, quality, canUse, level, levelColHeader,
    -- minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
    -- bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo

    local name, texture, count, quality, canUse, level, levelColHeader,
          minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
          bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo =
          GetAuctionItemInfo("list", index)

    -- Skip only when there is no item id at all. Items not yet in the client cache
    -- come through with name=nil — those auctions are still valid (itemId + prices
    -- are present) and the server resolves names by itemId, exactly like the modern
    -- replicate reader. Dropping them lost ~45% of a fresh-cache getAll scan.
    if not itemId or itemId == 0 then
        return nil
    end

    -- Get time left (1=short, 2=medium, 3=long, 4=very long)
    local timeLeft = GetAuctionItemTimeLeft("list", index)

    -- Build auction record
    local auction = {
        itemId = itemId,
        name = name or "",
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
