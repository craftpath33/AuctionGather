--[[
    AuctionGather - Lightweight Auction Scanner
    ScannerModern.lua - Modern (C_AuctionHouse) auction-house reading backend

    For clients using the MODERN auction API (cata, mists/MoP, retail):
    C_AuctionHouse.ReplicateItems / GetNumReplicateItems / GetReplicateItemInfo /
    GetReplicateItemTimeLeft, driven by the REPLICATE_ITEM_LIST_UPDATE event.

    "Replicate" is the modern equivalent of the legacy GetAll full scan and
    returns the WHOLE auction house in one pass. REPLICATE_ITEM_LIST_UPDATE is a
    GLOBAL event: it fires for every addon whenever ANY addon (e.g. Auctionator,
    TSM) calls ReplicateItems(), and the buffer is readable by all. So the
    primary model here is PASSIVE — we listen and read whatever any addon
    triggered, exactly like the legacy backend piggybacks on GetAll.

    An optional active trigger (Modern:TriggerScan) is provided for clients that
    don't run another scanner; it is opt-in to avoid consuming the shared 15-min
    ReplicateItems cooldown out from under Auctionator/TSM.

    This backend only READS auctions; it feeds the shared engine (AG.Scanner)
    accumulator and reuses the engine's debounced finalize + async save pipeline,
    so the serialized output is byte-identical to the legacy backend.
]]

local ADDON_NAME, AG = ...

-- Shared engine (defined in Scanner.lua, loaded before this file)
local Engine = AG.Scanner

AG.Scanner.modern = {}
local Modern = AG.Scanner.modern

-- Modern scanner configuration
local REPLICATE_BATCH_SIZE  = 250    -- Items per batch (matches Auctionator's stepSize)
local REPLICATE_BATCH_DELAY = 0.01   -- Delay between batches in seconds
local REPLICATE_COOLDOWN    = 15 * 60 -- ReplicateItems server cooldown (15 min)

-- Cooldown tracking for the optional active trigger (modern-only concern,
-- kept off the shared engine state since it has no legacy counterpart)
Modern.lastTrigger = nil

-- The modern replicate buffer is TRUNCATED when the AH closes mid-scan, so a partial
-- read is unreliable. Opt INTO discarding on close. (The engine's default is to keep and
-- finish in the background, which is correct for the legacy GetAll buffer but not here.)
Modern.discardOnClose = true

function Modern:Initialize()
    AG:Debug("Modern scanner backend ready")
end

-- Called on each REPLICATE_ITEM_LIST_UPDATE event (our trigger OR another addon's).
-- Mirrors the legacy OnDataReceived guard chain; there is no GetAll-vs-paged
-- distinction here — a replicate update always means the full buffer is ready.
function Modern:OnReplicateUpdate()
    -- Capability guard: the modern replicate API may be absent. We register this event
    -- unconditionally (dual-listen), so bail if the modern API isn't here.
    if not (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems) then
        return
    end

    -- Don't start new reads while batched processing is running
    if Engine.state.isProcessing then
        AG:Debug("OnReplicateUpdate: skip — isProcessing")
        return
    end

    -- Don't start a new accumulator while background finalization is pending
    if Engine.state.pendingCloseFinalize then
        AG:Debug("OnReplicateUpdate: skip — pendingCloseFinalize")
        return
    end

    local count = C_AuctionHouse.GetNumReplicateItems()
    if not count or count == 0 then
        AG:Debug("OnReplicateUpdate: no replicate items")
        return
    end

    -- AH-open auto-correct: replicate data implies the AH is queryable.
    -- Foreign addons (Auctionator/TSM) may scan without our AUCTION_HOUSE_SHOW
    -- flag being set; the data is clearly available, so trust it.
    if not AG.State.auctionHouseOpen then
        AG:Warn("Replicate data received but AH not detected as open — auto-correcting.")
        AG.State.auctionHouseOpen = true
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
        Engine.state.startTime = debugprofilestop() / 1000
        Engine.state.scanSavedThisSession = false
        Engine:ResetAccumulator("replicate")
        AG:Print("|cFFFFFF00Scanning auction house...|r " .. AG:FormatNumber(count) .. " auctions (replicate)")
    end

    -- Guard against duplicate REPLICATE_ITEM_LIST_UPDATE events restarting
    -- batched reading mid-process
    if not Engine.accumulator.batchedReadStarted then
        self:StartBatchedRead(count)
    end

    -- Schedule finalization (debounced)
    Engine:ScheduleFinalize()
end

-- Start batched reading of the replicate buffer (avoids client freeze)
function Modern:StartBatchedRead(total)
    AG:Debug("Reading replicate data... (" .. AG:FormatNumber(total) .. " auctions)")

    Engine.state.isProcessing = true
    Engine.state.capturingBackend = self
    Engine.state.currentIndex = 0          -- 0-BASED cursor (replicate API is 0-indexed)
    Engine.state.totalItems = total
    Engine.accumulator.pagesRead = 1       -- replicate = one "page"
    Engine.accumulator.batchedReadStarted = true  -- Guard against double-start

    self:ProcessBatch()
end

-- Process a batch of replicate auctions.
-- IMPORTANT: replicate indices are 0-based (0 .. totalItems-1), unlike the
-- legacy backend which uses 1-based "list" indices. The shared state.currentIndex
-- is therefore interpreted 0-based while the modern backend is active.
function Modern:ProcessBatch()
    if not Engine.state.isProcessing then
        return
    end

    -- Note: no auctionHouseOpen check here — the replicate buffer was already
    -- fetched from the server and persists client-side. OnAuctionHouseClosed sets
    -- pendingCloseFinalize and we finish reading whatever was delivered.

    local ok, err = pcall(function()
        -- 0-based inclusive end index for this batch
        local batchEnd = math.min(
            Engine.state.currentIndex + REPLICATE_BATCH_SIZE - 1,
            Engine.state.totalItems - 1
        )

        local withOwner = AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.includeOwner
        local withBid = AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.includeBid

        for i = Engine.state.currentIndex, batchEnd do
            local aok, auction = pcall(function()
                return self:GetReplicateInfo(i, withOwner, withBid)
            end)

            if not aok then
                AG:Debug("Error getting replicate item " .. i .. ", skipping")
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

        -- Continue or finish batched reading (currentIndex = next 0-based index)
        if Engine.state.currentIndex < Engine.state.totalItems then
            C_Timer.After(REPLICATE_BATCH_DELAY, function()
                Modern:ProcessBatch()
            end)
        else
            -- Batched reading done — the debounce timer will finalize and save.
            -- No close handling here: on modern, closing the AH mid-read ABORTS the scan
            -- (OnAuctionHouseClosed cancels it, because the replicate buffer truncates on
            -- close). So reaching this point means reading completed with the AH still open.
            AG:Print("|cFFFFFF00Processing complete.|r Saving data...")
            Engine.state.isProcessing = false
        end
    end)

    -- If the batch errored, reset processing state so the addon doesn't get stuck.
    if not ok then
        AG:Debug("ProcessBatch error: " .. tostring(err))
        Engine.state.isProcessing = false
        Engine.state.pendingCloseFinalize = false
        Engine.state.pendingFinalize = false
        Engine.accumulator = nil
        AG:Print("|cFFFF6600Scan error.|r Processing failed, scan discarded. Try again.")
    end
end

-- Get info for a single replicate auction.
-- @param index number - Replicate index (0-based)
-- @return table - Auction data (same shape as the legacy backend), or nil to skip
function Modern:GetReplicateInfo(index, withOwner, withBid)
    -- C_AuctionHouse.GetReplicateItemInfo(index) returns the SAME 18-field layout
    -- as the legacy GetAuctionItemInfo:
    --   name(1), texture(2), count(3), quality(4), usable(5), level(6), levelType(7),
    --   minBid(8), minIncrement(9), buyoutPrice(10), bidAmount(11), highBidder(12),
    --   bidderFullName(13), owner(14), ownerFullName(15), saleStatus(16),
    --   itemID(17), hasAllInfo(18)
    local info = { C_AuctionHouse.GetReplicateItemInfo(index) }

    local itemId = info[17]
    if not itemId or itemId == 0 then
        return nil
    end

    -- We only need itemId + prices, so we DELIBERATELY do not wait for hasAllInfo
    -- (info[18]) / RequestLoadItemDataByID: itemId/count/minBid/buyout are present
    -- regardless. name is best-effort from the same call (may be "" if not cached).
    local timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(index)

    local auction = {
        itemId   = itemId,
        name     = info[1] or "",
        count    = info[3] or 1,
        quality  = info[4] or 0,
        level    = info[6] or 0,
        minBid   = info[8] or 0,
        buyout   = info[10] or 0,
        timeLeft = timeLeft or 0,
    }

    -- Optional fields (not serialized, kept for parity with the legacy backend)
    if withBid then
        auction.bidAmount = info[11] or 0
        auction.highBidder = info[12]
    end

    if withOwner then
        auction.owner = info[14]
    end

    return auction
end

-- True if a fresh ReplicateItems() call is allowed (15-min cooldown).
function Modern:CanTrigger()
    return self.lastTrigger == nil or (time() - self.lastTrigger) > REPLICATE_COOLDOWN
end

-- Optional active trigger: initiate our own full scan.
-- Completion arrives via the passive OnReplicateUpdate handler.
function Modern:TriggerScan()
    if not AG.State.auctionHouseOpen then
        AG:Print("|cFFFF9900Open the auction house first, then|r |cFFFFFF00/ag scan|r.")
        return
    end

    if Engine.state.isProcessing then
        AG:Print("|cFFFF9900A scan is already in progress.|r")
        return
    end

    if not self:CanTrigger() then
        local wait = REPLICATE_COOLDOWN - (time() - self.lastTrigger)
        AG:Print(string.format("|cFFFF9900Full scan on cooldown.|r Next in %dm %ds.",
            math.floor(wait / 60), wait % 60))
        return
    end

    self.lastTrigger = time()
    AG:Print("|cFFFFFF00Starting full auction scan...|r")
    C_AuctionHouse.ReplicateItems()
end

-- Optional autoscan-on-open. Opt-in via the autoTriggerScan config flag (default off)
-- so we don't consume the shared ReplicateItems cooldown when the user runs another
-- scanner addon. A short delay lets the AH settle before triggering.
function Modern:OnAuctionHouseShow()
    if AUCTION_GATHER_CONFIG and AUCTION_GATHER_CONFIG.autoTriggerScan and self:CanTrigger() then
        C_Timer.After(1, function()
            if AG.State.auctionHouseOpen and self:CanTrigger() and not Engine.state.isProcessing then
                self:TriggerScan()
            end
        end)
    end
end
