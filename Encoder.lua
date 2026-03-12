--[[
    AuctionGather - Lightweight Auction Scanner
    Encoder.lua - Simple encoding utilities

    Only Base64 encoding (no compression, no XOR).
    Obfuscation is done by reversing the Base64 string.
]]

local ADDON_NAME, AG = ...

AG.Encoder = {}
local Encoder = AG.Encoder

---------------------------------------------------------------------
-- BASE64 ENCODING
---------------------------------------------------------------------

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Precomputed lookup table: index 0..63 → character
-- Avoids repeated B64_CHARS:sub(i,i) calls in the hot encode loop
local _b64Lookup = {}
for i = 0, 63 do _b64Lookup[i] = B64_CHARS:sub(i + 1, i + 1) end

-- Detect WoW's bit library (available in WoW 4.x+; absent on some emulators)
local _bit = bit  -- WoW exposes the bit library as a global

-- Base64 encode a string
-- Uses precomputed lookup table and direct table indexing for performance.
-- Falls back to arithmetic bit-ops if the bit library is unavailable.
function Encoder:Base64Encode(data)
    if not data or #data == 0 then
        return ""
    end

    local result = {}
    local n = 1  -- next write position in result (faster than table.insert)

    if _bit then
        -- Fast path: use WoW's bit library for bit operations
        local rshift = _bit.rshift
        local band   = _bit.band

        for i = 1, #data, 3 do
            local b1 = data:byte(i)     or 0
            local b2 = data:byte(i + 1) or 0
            local b3 = data:byte(i + 2) or 0

            -- Pack three bytes into a 24-bit integer
            local v = b1 * 65536 + b2 * 256 + b3

            result[n]     = _b64Lookup[rshift(v, 18)]
            result[n + 1] = _b64Lookup[band(rshift(v, 12), 0x3F)]

            if i + 1 <= #data then
                result[n + 2] = _b64Lookup[band(rshift(v, 6), 0x3F)]
            else
                result[n + 2] = "="
            end

            if i + 2 <= #data then
                result[n + 3] = _b64Lookup[band(v, 0x3F)]
            else
                result[n + 3] = "="
            end

            n = n + 4
        end
    else
        -- Fallback path: arithmetic only (no bit library)
        for i = 1, #data, 3 do
            local b1 = data:byte(i)     or 0
            local b2 = data:byte(i + 1) or 0
            local b3 = data:byte(i + 2) or 0

            local v = b1 * 65536 + b2 * 256 + b3

            local c1 = math.floor(v / 262144) % 64
            local c2 = math.floor(v / 4096)   % 64
            local c3 = math.floor(v / 64)     % 64
            local c4 = v % 64

            result[n]     = _b64Lookup[c1]
            result[n + 1] = _b64Lookup[c2]
            result[n + 2] = (i + 1 <= #data) and _b64Lookup[c3] or "="
            result[n + 3] = (i + 2 <= #data) and _b64Lookup[c4] or "="

            n = n + 4
        end
    end

    return table.concat(result)
end

-- Base64 decode a string
function Encoder:Base64Decode(data)
    if not data or #data == 0 then
        return ""
    end

    local result = {}

    -- Build reverse lookup
    local b64Lookup = {}
    for i = 1, #B64_CHARS do
        b64Lookup[B64_CHARS:sub(i, i)] = i - 1
    end

    -- Remove padding and whitespace
    data = data:gsub("[^" .. B64_CHARS .. "]", "")

    for i = 1, #data, 4 do
        local c1 = b64Lookup[data:sub(i, i)] or 0
        local c2 = b64Lookup[data:sub(i + 1, i + 1)] or 0
        local c3 = b64Lookup[data:sub(i + 2, i + 2)] or 0
        local c4 = b64Lookup[data:sub(i + 3, i + 3)] or 0

        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4

        table.insert(result, string.char(math.floor(n / 65536) % 256))

        if data:sub(i + 2, i + 2) ~= "=" and data:sub(i + 2, i + 2) ~= "" then
            table.insert(result, string.char(math.floor(n / 256) % 256))
        end

        if data:sub(i + 3, i + 3) ~= "=" and data:sub(i + 3, i + 3) ~= "" then
            table.insert(result, string.char(n % 256))
        end
    end

    return table.concat(result)
end

---------------------------------------------------------------------
-- CHECKSUM
---------------------------------------------------------------------

-- Simple checksum for data verification
function Encoder:Checksum(data)
    if not data or #data == 0 then
        return "00000000"
    end

    local sum = 0
    local len = math.min(#data, 200000)  -- Limit for performance

    for i = 1, len do
        sum = (sum * 31 + data:byte(i)) % 4294967296
    end

    return string.format("%08x", sum)
end

---------------------------------------------------------------------
-- ENCODING (for external use)
---------------------------------------------------------------------

function Encoder:Obfuscate(data)
    return self:Base64Encode(data):reverse()
end

function Encoder:Deobfuscate(data)
    return self:Base64Decode(data:reverse())
end

---------------------------------------------------------------------
-- COMPRESSION (using LibDeflate)
---------------------------------------------------------------------

local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)

-- Compress string using LibDeflate
function Encoder:Compress(data)
    if not data or #data == 0 then
        return ""
    end

    if not LibDeflate then
        AG:Debug("LibDeflate not available, returning raw")
        return data
    end

    local compressed = LibDeflate:CompressDeflate(data)
    -- Encode to printable string for SavedVariables
    return LibDeflate:EncodeForPrint(compressed)
end

-- Decompress string
function Encoder:Decompress(data)
    if not data or #data == 0 then
        return ""
    end

    if not LibDeflate then
        AG:Debug("LibDeflate not available, returning raw")
        return data
    end

    local decoded = LibDeflate:DecodeForPrint(data)
    if not decoded then
        return data  -- Not compressed, return as-is
    end

    local decompressed = LibDeflate:DecompressDeflate(decoded)
    return decompressed or data
end

---------------------------------------------------------------------
-- TEST
---------------------------------------------------------------------

function Encoder:Test()
    local testData = "Hello, World! Test 123. ItemId:12345:Sword:4:60:1,100,200,3;2,150,300,4"
    AG:Print("Testing encoder...")
    AG:Print("Original: " .. testData)
    AG:Print("Original size: " .. #testData .. " bytes")

    -- Encode
    local encoded = self:Base64Encode(testData)
    AG:Print("Base64: " .. encoded:sub(1, 50) .. "...")
    AG:Print("Base64 size: " .. #encoded .. " bytes")

    -- Obfuscate
    local obfuscated = self:Obfuscate(testData)
    AG:Print("Obfuscated: " .. obfuscated:sub(1, 50) .. "...")

    -- Deobfuscate
    local deobfuscated = self:Deobfuscate(obfuscated)
    AG:Print("Deobfuscated: " .. deobfuscated)

    -- Verify
    AG:Print("Match: " .. tostring(testData == deobfuscated))

    -- Checksum
    AG:Print("Checksum: " .. self:Checksum(obfuscated))
end
