addon.name    = 'enemystats';
addon.author  = 'Antigravity';
addon.version = '1.0';
addon.desc    = 'Displays target stats.';
addon.link    = '';

require('common');
local ffi = require('ffi');
local imgui = require('imgui');
local settings = require('settings');

local default_settings = T {
    visible = true,
    debug = true, -- Enable debug prints (set to false to reduce chat spam)
};

local database = require('database');
local calculator = require('calculator');
local textures = require('textures');

-- Cache for exact mob levels (from widescan and /check)
local mobLevels = T {};

-- Cache for mob claim status (from entity update packets)
local mobClaims = T {};

-- Cache for player's real ACC/ATT/EVA/DEF from /checkparam
-- These values include ALL modifiers (gear, food, buffs, merits, etc.)
local playerStats = T {
    ACC = nil,            -- Main hand accuracy (from MSGBASIC_CHECKPARAM_PRIMARY = 712)
    ATT = nil,            -- Main hand attack
    ACC2 = nil,           -- Off-hand accuracy (from MSGBASIC_CHECKPARAM_AUXILIARY = 713)
    ATT2 = nil,           -- Off-hand attack
    RACC = nil,           -- Ranged accuracy (from MSGBASIC_CHECKPARAM_RANGE = 714)
    RATT = nil,           -- Ranged attack
    EVA = nil,            -- Evasion (from MSGBASIC_CHECKPARAM_DEFENSE = 715)
    DEF = nil,            -- Defense
    lastUpdate = 0,       -- Time of last /checkparam
    gearChanged = false,  -- Flag when gear ACC delta is non-zero (shows approximation indicator)
    buffsChanged = false, -- Flag when buff icons have changed since last /checkparam
};

-- Auto-refresh tracking for buffs and gear changes
-- When buffs or gear change, we queue a /checkparam after a short delay (debounced)
local autoRefresh = T {
    lastBuffIcons = {},       -- Cache of buff icon IDs from last packet
    pendingRefresh = false,   -- Whether we have a pending /checkparam
    refreshTime = 0,          -- When to send the /checkparam (os.clock())
    buffRefreshDelay = 0.5,   -- Seconds to wait after buff change before refreshing
    gearRefreshDelay = 1.0,   -- Seconds to wait after gear change (longer for complex swaps)
    awaitingResponse = false, -- True when we've sent auto-refresh and are awaiting response
    blockChatUntil = 0,       -- Block checkparam messages until this time (os.clock())
    gearHashOnSend = nil,     -- Gear hash when we sent checkparam (to validate response)
};

-- Gear set caching: Maps equipment configuration hash to known ACC values
-- When we get /checkparam results, we cache them keyed by current gear hash
-- If we swap to a previously seen gear set, we can use cached ACC instantly
local gearSetCache = T {
    sets = {},         -- Map of gearHash -> { ACC, ATT, timestamp }
    currentHash = nil, -- Hash of current equipment configuration
    maxCacheSets = 50, -- Limit cache size to prevent memory bloat
};

-- Track last known equipment for smart diff detection
local lastEquipment = T {}; -- slot -> itemId

-- Settings and debug helper (must be early for use in other functions)
local enemystats = T {
    settings = settings.load(default_settings),
};

local function update_settings(s)
    if (s ~= nil) then
        enemystats.settings = s;
    end
    settings.save();
end

settings.register('settings', 'settings_update', update_settings);

-- Debug print helper - only prints if debug mode is enabled
local function dbg(msg)
    if (enemystats.settings.debug) then
        print(msg);
    end
end

-- Forward declarations for functions defined later
local GetGearHash;
local CacheCurrentGearSet;
local GetCachedGearSetACC;
local OnGearChanged;

-- Queue a /checkparam refresh (debounced - resets timer on each call)
-- Uses different delays for gear vs buff changes
local function QueueRefresh(reason)
    autoRefresh.pendingRefresh = true;
    local delay = (reason == 'gear') and autoRefresh.gearRefreshDelay or autoRefresh.buffRefreshDelay;
    autoRefresh.refreshTime = os.clock() + delay;
    dbg(string.format('[enemystats] Queued refresh (%s) in %.1fs', reason, delay));
end

-- Check if buff icons have changed and queue refresh if needed
local function OnBuffIconsChanged(newIcons)
    -- Compare to cached icons
    local changed = false;

    -- Check if count differs or any icon differs
    if (#newIcons ~= #autoRefresh.lastBuffIcons) then
        changed = true;
    else
        for i = 1, #newIcons do
            if (newIcons[i] ~= autoRefresh.lastBuffIcons[i]) then
                changed = true;
                break;
            end
        end
    end

    dbg(string.format('[enemystats] Buff packet: %d icons, changed=%s', #newIcons, tostring(changed)));
    if (#newIcons > 0) then
        local iconStr = '';
        for i, icon in ipairs(newIcons) do
            iconStr = iconStr .. tostring(icon) .. ' ';
        end
        dbg('[enemystats] Icons: ' .. iconStr);
    end

    if (changed) then
        local oldCount = #autoRefresh.lastBuffIcons;
        dbg(string.format('[enemystats] Buffs changed: %d -> %d icons', oldCount, #newIcons));
        -- Update cache
        autoRefresh.lastBuffIcons = newIcons;
        playerStats.buffsChanged = true;
        QueueRefresh('buffs');
    end
end

-- Send /checkparam packet directly (bypasses command restrictions like menu open)
-- Packet 0x0DD: Kind=0x02 (CheckParam), targeting self
local function SendCheckParamPacket()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (not party) then
        print('[enemystats] ERROR: Cannot get party manager');
        return false;
    end

    local serverId = party:GetMemberServerId(0);
    local targetIndex = party:GetMemberTargetIndex(0);

    if (serverId == 0 or targetIndex == 0) then
        print('[enemystats] ERROR: Invalid player ID/index');
        return false;
    end

    dbg(string.format('[enemystats] Sending packet 0x0DD: serverId=0x%X targetIndex=%d', serverId, targetIndex));

    -- Build packet 0x0DD (Equip Inspect / CheckParam)
    -- FFXI packet format: [ID, Size(words), SyncLo, SyncHi, ...payload...]
    -- Payload: UniqueNo (4 bytes), ActIndex (4 bytes), Kind (1 byte), padding (3 bytes)
    -- Total: 4 header + 12 payload = 16 bytes = 4 words
    local packet = {
        -- Header
        0xDD, -- Packet ID
        0x04, -- Size in 32-bit words (16 bytes total)
        0x00, -- Sync counter (filled by game)
        0x00, -- Sync counter high
        -- UniqueNo (Server ID) - little endian
        bit.band(serverId, 0xFF),
        bit.band(bit.rshift(serverId, 8), 0xFF),
        bit.band(bit.rshift(serverId, 16), 0xFF),
        bit.band(bit.rshift(serverId, 24), 0xFF),
        -- ActIndex (Target Index) - little endian
        bit.band(targetIndex, 0xFF),
        bit.band(bit.rshift(targetIndex, 8), 0xFF),
        bit.band(bit.rshift(targetIndex, 16), 0xFF),
        bit.band(bit.rshift(targetIndex, 24), 0xFF),
        -- Kind: 0x02 = CheckParam
        0x02,
        -- Padding
        0x00, 0x00, 0x00
    };

    AshitaCore:GetPacketManager():AddOutgoingPacket(0x0DD, packet);
    return true;
end

-- Process pending /checkparam refresh (call from d3d_present)
local function ProcessPendingRefresh()
    if (autoRefresh.pendingRefresh and os.clock() >= autoRefresh.refreshTime) then
        autoRefresh.pendingRefresh = false;
        autoRefresh.awaitingResponse = true;
        autoRefresh.blockChatUntil = os.clock() + 2.0; -- Block chat for up to 2 seconds
        autoRefresh.gearHashOnSend = GetGearHash();    -- Capture gear state when sending

        dbg('[enemystats] Processing refresh, gearHash=' .. string.sub(autoRefresh.gearHashOnSend, 1, 30) .. '...');

        -- Try packet injection (should work even in menus)
        if (SendCheckParamPacket()) then
            dbg('[enemystats] Sent checkparam packet (auto-refresh)');
        else
            -- Fallback to command if packet fails - this DOES need menu check
            local target = AshitaCore:GetMemoryManager():GetTarget();
            if (target and target:GetIsMenuOpen() ~= 0) then
                -- Menu is open, re-queue for later
                dbg('[enemystats] Packet failed, menu open - deferring');
                autoRefresh.pendingRefresh = true;
                autoRefresh.refreshTime = os.clock() + 0.1;
                autoRefresh.awaitingResponse = false;
            else
                dbg('[enemystats] Packet failed, using command fallback');
                AshitaCore:GetChatManager():QueueCommand(1, '/checkparam <me>');
            end
        end
    end
end

-- Equipment slot IDs (from Ashita SDK)
local EQUIP_SLOT = {
    MAIN  = 0,
    SUB   = 1,
    RANGE = 2,
    AMMO  = 3,
    HEAD  = 4,
    BODY  = 5,
    HANDS = 6,
    LEGS  = 7,
    FEET  = 8,
    NECK  = 9,
    WAIST = 10,
    EAR1  = 11,
    EAR2  = 12,
    RING1 = 13,
    RING2 = 14,
    BACK  = 15,
};

-- Cache for currently equipped item IDs
local equippedItems = T {};

-- Get equipped item ID for a slot
local function GetEquippedItemId(slot)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (not inv) then return nil; end

    local eitem = inv:GetEquippedItem(slot);
    if (eitem == nil or eitem.Index == 0) then
        return nil;
    end

    local container = bit.band(eitem.Index, 0xFF00) / 0x0100;
    local index = eitem.Index % 0x0100;
    local iitem = inv:GetContainerItem(container, index);
    if (iitem == nil or iitem.Id == 0 or iitem.Id == 65535) then
        return nil;
    end

    return iitem.Id;
end

-- Generate a hash string for current equipment configuration (gear only)
-- Buffs are stored separately and validated on lookup
GetGearHash = function()
    local parts = {};
    for slot = 0, 15 do
        local itemId = GetEquippedItemId(slot);
        table.insert(parts, tostring(itemId or 0));
    end
    return table.concat(parts, ',');
end

-- Get a sorted string representation of current buffs for comparison
local function GetBuffSignature()
    if (#autoRefresh.lastBuffIcons == 0) then
        return '';
    end
    local sortedBuffs = {};
    for _, icon in ipairs(autoRefresh.lastBuffIcons) do
        table.insert(sortedBuffs, icon);
    end
    table.sort(sortedBuffs);
    return table.concat(sortedBuffs, ',');
end

-- Store current ACC/ATT values in gear set cache
-- Cache is keyed by gear only, but stores buff signature for validation
-- This handles variable buff potency: same gear + same buffs = valid, different buffs = invalid
CacheCurrentGearSet = function(acc, att)
    local gearHash = GetGearHash();
    local buffSig = GetBuffSignature();

    gearSetCache.sets[gearHash] = {
        ACC = acc,
        ATT = att,
        buffSignature = buffSig, -- Store which buffs were active when cached
        timestamp = os.time(),
    };
    gearSetCache.currentHash = gearHash;

    -- Prune cache if too large (remove oldest entries)
    local count = 0;
    for _ in pairs(gearSetCache.sets) do count = count + 1; end
    if (count > gearSetCache.maxCacheSets) then
        -- Find and remove oldest entry
        local oldestHash, oldestTime = nil, os.time();
        for h, data in pairs(gearSetCache.sets) do
            if (data.timestamp < oldestTime) then
                oldestHash = h;
                oldestTime = data.timestamp;
            end
        end
        if (oldestHash) then
            gearSetCache.sets[oldestHash] = nil;
        end
    end

    local buffCount = #autoRefresh.lastBuffIcons;
    dbg('[enemystats] Cached gear set: ACC=' .. acc .. ', buffs=' .. buffCount .. ' (total cached: ' .. count .. ')');
end

-- Look up ACC for current gear configuration from cache
-- Only returns cached value if BOTH gear AND buff signature match
-- This prevents false hits when buff potency could differ
GetCachedGearSetACC = function()
    local gearHash = GetGearHash();
    local cached = gearSetCache.sets[gearHash];
    if (cached) then
        -- Validate buff signature matches
        -- If buffs changed since caching, we can't trust the value (potency might differ)
        local currentBuffSig = GetBuffSignature();
        if (cached.buffSignature == currentBuffSig) then
            -- Update timestamp on access (LRU behavior)
            cached.timestamp = os.time();
            return cached.ACC, cached.ATT;
        else
            -- Gear matches but buffs differ - cache miss
            dbg('[enemystats] Cache miss: gear matches but buffs differ');
            return nil, nil;
        end
    end
    return nil, nil;
end

-- Smart gear change detection - only triggers refresh if items actually changed
-- Returns true if gear changed to a NEW configuration, false if same or cached
OnGearChanged = function()
    -- Snapshot current equipment
    local currentGear = {};
    local changed = false;

    for slot = 0, 15 do
        local itemId = GetEquippedItemId(slot) or 0;
        currentGear[slot] = itemId;
        if (lastEquipment[slot] ~= itemId) then
            changed = true;
        end
    end

    -- Update last equipment tracking
    lastEquipment = currentGear;

    if (not changed) then
        -- Same gear, no action needed
        dbg('[enemystats] Gear packet received, but equipment unchanged');
        return false;
    end

    -- Check if this gear set is already cached (with matching buff state)
    local cachedACC, cachedATT = GetCachedGearSetACC();
    if (cachedACC) then
        -- Cache hit: gear matches AND buff signature matches
        playerStats.ACC = cachedACC;
        playerStats.ATT = cachedATT;
        playerStats.gearChanged = false;
        playerStats.lastUpdate = os.time();
        autoRefresh.pendingRefresh = false; -- Cancel any pending refresh

        local buffCount = #autoRefresh.lastBuffIcons;
        dbg('[enemystats] Cache hit! ACC=' .. cachedACC .. ' (gear + same ' .. buffCount .. ' buffs)');
        return false; -- No refresh needed
    end

    -- Cache miss: either new gear, or same gear but different buffs
    playerStats.gearChanged = true;
    QueueRefresh('gear');
    return true;
end

-- Get real-time ACC - returns cached /checkparam value or nil
-- Auto-refresh handles updating this when gear/buffs change
-- Returns: mainACC, offhandACC (offhand is nil if not dual wielding/H2H)
local function GetRealTimeAccuracy()
    local mainACC = nil;
    local offACC = nil;

    if (playerStats.ACC and playerStats.ACC > 0) then
        mainACC = playerStats.ACC;
    end

    -- ACC2 is only populated for dual wield or H2H
    if (playerStats.ACC2 and playerStats.ACC2 > 0) then
        offACC = playerStats.ACC2;
    end

    return mainACC, offACC, not playerStats.gearChanged;
end

-- Load database for current zone on load
ashita.events.register('load', 'load_cb', function()
    textures:Initialize();
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    database:Load(zone);
end);

-- Reload database on zone change, capture mob levels from widescan and /check
ashita.events.register('packet_in', 'packet_in_cb', function(e)
    -- Zone Enter / Zone Leave - clear level cache, claim cache, and player stats cache
    if (e.id == 0x000A or e.id == 0x000B) then
        mobLevels:clear();
        mobClaims:clear();
        -- Clear player stats cache on zone (gear/buffs may change)
        playerStats.ACC = nil;
        playerStats.ATT = nil;
        playerStats.ACC2 = nil;
        playerStats.ATT2 = nil;
        playerStats.RACC = nil;
        playerStats.RATT = nil;
        playerStats.EVA = nil;
        playerStats.DEF = nil;
        playerStats.lastUpdate = 0;
        playerStats.baselineDEX = nil;
        playerStats.gearChanged = false;
        playerStats.buffsChanged = false;
        -- Clear auto-refresh tracking
        autoRefresh.lastBuffIcons = {};
        autoRefresh.pendingRefresh = false;
        -- Clear last equipment tracking (will re-snapshot on first gear packet)
        -- Note: gearSetCache is NOT cleared - cached ACC values persist across zones
        lastEquipment = T {};
        if (e.id == 0x000A) then
            local zone = struct.unpack('H', e.data, 0x30 + 1);
            database:Load(zone);
        end
        return;
    end

    -- Packet: Entity Update (0x000D) - NPC/Mob spawn/update
    -- Contains claim status at offset 0x2C (ClaimServerId)
    if (e.id == 0x000D) then
        local idx = struct.unpack('H', e.data, 0x08 + 1);
        local updateMask = struct.unpack('B', e.data, 0x0A + 1);
        -- Check if this packet contains claim info (bit 0x20 in update mask, or full update)
        if (idx > 0 and idx < 0x400) then
            local claimId = struct.unpack('I', e.data, 0x2C + 1);
            mobClaims[idx] = claimId;
        end
        return;
    end

    -- Packet: Message Basic (contains /check result with exact level, and /checkparam stats)
    if (e.id == 0x0029) then
        local p1 = struct.unpack('l', e.data, 0x0C + 0x01); -- Param 1 (Data: ACC for checkparam, Level for check)
        local p2 = struct.unpack('L', e.data, 0x10 + 0x01); -- Param 2 (Data2: ATT for checkparam, Check Type for check)
        local m = struct.unpack('H', e.data, 0x18 + 0x01);  -- Message ID

        -- Check if this is a checkparam message we should block from chat
        -- 712-715 = stats, 731 = ilvl, 733 = name header
        local isCheckparamMsg = (m >= 712 and m <= 715) or m == 731 or m == 733;
        local timeRemaining = autoRefresh.blockChatUntil - os.clock();
        local shouldBlockChat = isCheckparamMsg and autoRefresh.awaitingResponse and timeRemaining > 0;

        -- Debug: show all message basic packets with IDs in the checkparam range
        if (isCheckparamMsg) then
            dbg(string.format('[enemystats] Got msg %d: awaiting=%s, timeLeft=%.2f, block=%s',
                m, tostring(autoRefresh.awaitingResponse), timeRemaining, tostring(shouldBlockChat)));
        end

        -- /checkparam message IDs (from server msg_basic.h):
        -- 712 = MSGBASIC_CHECKPARAM_PRIMARY (main hand ACC/ATT)
        -- 713 = MSGBASIC_CHECKPARAM_AUXILIARY (off-hand ACC/ATT)
        -- 714 = MSGBASIC_CHECKPARAM_RANGE (ranged ACC/ATT)
        -- 715 = MSGBASIC_CHECKPARAM_DEFENSE (EVA/DEF)
        if (m == 712) then
            local oldACC = playerStats.ACC or 0;
            playerStats.ACC = p1;
            playerStats.ATT = p2;
            playerStats.lastUpdate = os.time();
            playerStats.gearChanged = false;    -- Fresh data, gear state is known
            playerStats.buffsChanged = false;   -- Fresh data, buff state is known
            autoRefresh.pendingRefresh = false; -- Cancel any pending refresh
            -- NOTE: Don't set awaitingResponse=false here - wait for message 715 (last message)

            -- Only cache if gear hasn't changed since we sent the request
            -- This prevents caching stale ACC values from mid-swap states
            local currentGearHash = GetGearHash();
            if (autoRefresh.gearHashOnSend and currentGearHash == autoRefresh.gearHashOnSend) then
                CacheCurrentGearSet(p1, p2);
            else
                dbg('[enemystats] Gear changed during checkparam - not caching (stale data)');
                -- Re-queue a refresh since this data might be stale
                QueueRefresh('gear-retry');
            end
            autoRefresh.gearHashOnSend = nil; -- Clear after use

            -- Show ACC changes in chat for debugging
            local delta = p1 - oldACC;
            local deltaStr = delta >= 0 and '+' .. delta or tostring(delta);
            if (oldACC > 0 and delta ~= 0) then
                dbg(string.format('[enemystats] ACC updated: %d -> %d (%s)', oldACC, p1, deltaStr));
            else
                dbg('[enemystats] Got /checkparam: ACC=' .. p1 .. ' ATT=' .. p2);
            end
            if (shouldBlockChat) then
                e.blocked = true;
                return;
            end
        elseif (m == 713) then
            playerStats.ACC2 = p1;
            playerStats.ATT2 = p2;
            if (shouldBlockChat) then
                e.blocked = true; return;
            end
        elseif (m == 714) then
            playerStats.RACC = p1;
            playerStats.RATT = p2;
            if (shouldBlockChat) then
                e.blocked = true; return;
            end
        elseif (m == 715) then
            playerStats.EVA = p1;
            playerStats.DEF = p2;
            -- This is the LAST checkparam message, now we can stop blocking
            autoRefresh.awaitingResponse = false;
            if (shouldBlockChat) then
                e.blocked = true; return;
            end
        elseif (m == 731 or m == 733) then
            -- ilvl (731) or name header (733) - just block if needed, no data to capture
            if (shouldBlockChat) then
                e.blocked = true; return;
            end
            -- Check if this is a /check message (types 0x40-0x47, or 0xF9 for impossible)
        elseif ((p2 >= 0x40 and p2 <= 0x47) or m == 0xF9) then
            local targetIdx = struct.unpack('H', e.data, 0x16 + 0x01);
            if (p1 > 0 and targetIdx > 0) then
                mobLevels[targetIdx] = p1;
            end
        end
        return;
    end

    -- Packet: Equipment changes (0x0050, 0x0051, 0x0116, 0x0117)
    -- Smart detection: only refresh if items actually changed and set isn't cached
    if (e.id == 0x0050 or e.id == 0x0051 or e.id == 0x0116 or e.id == 0x0117) then
        OnGearChanged();
        return;
    end

    -- Packet: Widescan Results (contains mob levels)
    if (e.id == 0x00F4) then
        local idx = struct.unpack('H', e.data, 0x04 + 0x01);
        local lvl = struct.unpack('b', e.data, 0x06 + 0x01);
        if (idx > 0 and lvl > 0) then
            mobLevels[idx] = lvl;
        end
        return;
    end

    -- Packet: Status Icons (0x0063 Type 0x09) - Buff icons update
    -- This packet is sent when buffs are gained or lost
    -- Structure: 2 bytes header, 2 bytes type (0x09), 2 bytes size, then:
    --   64 bytes: 32 x uint16 icon IDs (0x00FF = empty)
    --   128 bytes: 32 x uint32 timestamps
    if (e.id == 0x0063) then
        local pktType = struct.unpack('H', e.data, 0x04 + 1);
        if (pktType == 0x09) then
            -- Parse buff icon IDs (32 slots, 2 bytes each, starting at offset 0x08)
            local icons = {};
            for i = 0, 31 do
                local icon = struct.unpack('H', e.data, 0x08 + (i * 2) + 1);
                if (icon ~= 0x00FF and icon ~= 0) then
                    table.insert(icons, icon);
                end
            end
            OnBuffIconsChanged(icons);
        end
        return;
    end
end);

ashita.events.register('d3d_present', 'present_cb', function()
    -- Process any pending /checkparam refresh
    ProcessPendingRefresh();

    if (not enemystats.settings.visible) then
        return;
    end

    local target = AshitaCore:GetMemoryManager():GetTarget();

    if (target == nil) then
        return;
    end

    local index = target:GetTargetIndex(0);
    if (index == 0) then
        return;
    end

    local entMgr = AshitaCore:GetMemoryManager():GetEntity();
    if (entMgr == nil) then
        return;
    end

    local partyMgr = AshitaCore:GetMemoryManager():GetParty();

    if (imgui.Begin('Enemy Stats', true, ImGuiWindowFlags_AlwaysAutoResize)) then
        local mobName = entMgr:GetName(index) or 'Unknown';
        local dist = math.sqrt(entMgr:GetDistance(index));
        local dbMob = database:GetMob(index);

        -- Line 1: Distance (XX.X format, 00.0 to 50.0) with background highlight
        local clampedDist = math.min(dist, 50.0);
        imgui.PushStyleColor(ImGuiCol_Button, { 0.2, 0.2, 0.3, 0.8 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.2, 0.2, 0.3, 0.8 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.2, 0.2, 0.3, 0.8 });
        imgui.SmallButton(string.format('%05.1f', clampedDist));
        imgui.PopStyleColor(3);
        imgui.SameLine(0, 10);

        -- Determine name color based on claim status
        local nameColor = { 1.0, 0.88, 0.58, 1.0 }; -- Yellow (unclaimed) default
        local claimId = mobClaims[index] or 0;

        if (claimId ~= 0) then
            -- Check if claimed by us or party/alliance member
            local claimedByParty = false;
            for i = 0, 17 do
                if (partyMgr:GetMemberServerId(i) == claimId) then
                    claimedByParty = true;
                    break;
                end
            end

            if (claimedByParty) then
                nameColor = { 0.92, 0.24, 0.24, 1.0 }; -- Red (claimed by party)
            else
                nameColor = { 0.66, 0.24, 0.96, 1.0 }; -- Purple (claimed by others)
            end
        end

        imgui.TextColored(nameColor, mobName);

        -- Aggro icons on same line (right of name)
        if (dbMob) then
            imgui.SameLine(0, 10);
            -- Aggro indicator (icon based)
            if (dbMob.Aggro) then
                textures:DrawIconSameLine('AggroNQ', 1.2);
            else
                textures:DrawIconSameLine('PassiveNQ', 1.2);
            end
            -- Link indicator
            if (dbMob.Link) then
                textures:DrawIconSameLine('Link', 1.2);
            end
            -- TrueSight indicator
            if (dbMob.TrueSight) then
                textures:DrawIconSameLine('TrueSight', 1.2);
            end
            -- Detection icons
            local detect = dbMob.Detect or 0;
            if (bit.band(detect, 0x001) ~= 0) then
                textures:DrawIconSameLine('Sight', 1.2);
            end
            if (bit.band(detect, 0x002) ~= 0) then
                textures:DrawIconSameLine('Sound', 1.2);
            end
            if (bit.band(detect, 0x004) ~= 0) then
                textures:DrawIconSameLine('Scent', 1.2);
            end
            if (bit.band(detect, 0x020) ~= 0) then
                textures:DrawIconSameLine('Magic', 1.2);
            end
        end

        -- HP bar with percentage
        local hp = entMgr:GetHPPercent(index);
        local hpFraction = hp / 100.0;

        -- Color gradient: Green (100%) -> Yellow (50%) -> Red (0%)
        local hpColor;
        if (hp > 75) then
            hpColor = { 0.2, 0.8, 0.2, 1.0 }; -- Green
        elseif (hp > 50) then
            hpColor = { 0.6, 0.8, 0.2, 1.0 }; -- Yellow-Green
        elseif (hp > 25) then
            hpColor = { 0.9, 0.7, 0.1, 1.0 }; -- Yellow-Orange
        else
            hpColor = { 0.9, 0.2, 0.2, 1.0 }; -- Red
        end

        if (dbMob) then
            -- Level display
            local exactLevel = mobLevels[index];
            local calcLevel;
            if (exactLevel and exactLevel > 0) then
                imgui.Text(string.format('LVL %03d', exactLevel));
                calcLevel = exactLevel;
            else
                imgui.Text(string.format('LVL %d-%d', dbMob.MinLevel, dbMob.MaxLevel));
                calcLevel = dbMob.MaxLevel;
            end

            -- Calculate Stats
            local maxHP = calculator.CalculateMaxHP(dbMob, calcLevel);
            local stats = calculator.CalculateStats(dbMob, calcLevel);

            -- HP bar in middle
            imgui.SameLine(0, 10);
            imgui.PushStyleColor(ImGuiCol_PlotHistogram, hpColor);
            imgui.ProgressBar(hpFraction, { 150, 16 }, tostring(hp));
            imgui.PopStyleColor(1);

            -- HP number on right
            imgui.SameLine(0, 10);
            if (exactLevel and exactLevel > 0) then
                imgui.Text(string.format('HP: %d', maxHP));
            else
                imgui.Text(string.format('HP: ~%d', maxHP));
            end

            -- Combat stats line (ATK, DEF, EVA) - always shown
            local combatStats = calculator.CalculateCombatStats(dbMob, calcLevel, stats);
            if (exactLevel and exactLevel > 0) then
                imgui.Text(string.format('ATK: %d   DEF: %d   EVA: %d', combatStats.ATK, combatStats.DEF, combatStats
                    .EVA));
            else
                imgui.Text(string.format('ATK: ~%d   DEF: ~%d   EVA: ~%d', combatStats.ATK, combatStats.DEF,
                    combatStats.EVA));
            end

            -- Player accuracy line with hit rate calculation
            -- Use real-time ACC tracking from /checkparam
            local mainAcc, offAcc, isAccurate = GetRealTimeAccuracy();
            local showWarning = false;
            local warningReason = nil;

            if (autoRefresh.pendingRefresh) then
                showWarning = true;
                warningReason = 'refreshing';
            elseif (not playerStats.ACC or playerStats.ACC == 0) then
                showWarning = true;
                warningReason = 'checkparam';
            end

            -- Helper function to calculate hit rate and get color
            local function getHitRateInfo(acc, eva)
                if (not acc or acc <= 0 or not eva or eva <= 0) then
                    return nil, nil;
                end
                -- FFXI hit rate formula: HitRate = 75 + floor((ACC - EVA) / 2), clamped 20-95%
                local accDiff = acc - eva;
                local hitRate = 75 + math.floor(accDiff / 2);
                hitRate = math.max(20, math.min(95, hitRate));

                local color;
                if (hitRate >= 90) then
                    color = { 0.3, 1.0, 0.3, 1.0 }; -- Green - 90%+ hit rate
                elseif (hitRate >= 80) then
                    color = { 1.0, 1.0, 0.3, 1.0 }; -- Yellow - 80-89% hit rate
                else
                    color = { 1.0, 0.3, 0.3, 1.0 }; -- Red - below 80% hit rate
                end
                return hitRate, color;
            end

            local mobEVA = combatStats.EVA;

            if (mainAcc and mainAcc > 0) then
                local mainHitRate, mainColor = getHitRateInfo(mainAcc, mobEVA);

                -- Determine label based on whether we have off-hand
                local mainLabel = offAcc and 'Main' or 'ACC';

                if (mainHitRate) then
                    -- Show main hand ACC with hit rate
                    if (showWarning) then
                        imgui.TextColored(mainColor,
                            string.format('%s: %d (~%d', mainLabel, math.floor(mainAcc), math.floor(mainHitRate)));
                        imgui.SameLine(0, 0);
                        imgui.TextColored(mainColor, '%%)');
                        imgui.SameLine(0, 4);
                        if (warningReason == 'refreshing') then
                            imgui.TextColored({ 0.7, 0.9, 1.0, 1.0 }, '[refreshing...]');
                        else
                            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '[/checkparam]');
                        end
                    else
                        imgui.TextColored(mainColor,
                            string.format('%s: %d (%d', mainLabel, math.floor(mainAcc), math.floor(mainHitRate)));
                        imgui.SameLine(0, 0);
                        imgui.TextColored(mainColor, '%%)');
                    end
                else
                    -- No EVA data, just show ACC
                    imgui.Text(string.format('%s: %d', mainLabel, math.floor(mainAcc)));
                end

                -- Show off-hand if dual wielding / H2H
                if (offAcc) then
                    local offHitRate, offColor = getHitRateInfo(offAcc, mobEVA);
                    if (offHitRate) then
                        imgui.TextColored(offColor,
                            string.format('Off: %d (%d', math.floor(offAcc), math.floor(offHitRate)));
                        imgui.SameLine(0, 0);
                        imgui.TextColored(offColor, '%%)');
                    else
                        imgui.Text(string.format('Off: %d', math.floor(offAcc)));
                    end
                end
            else
                -- No ACC data yet - show waiting message
                if (autoRefresh.pendingRefresh) then
                    imgui.TextColored({ 0.7, 0.9, 1.0, 1.0 }, 'ACC: [refreshing...]');
                else
                    imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, 'ACC: [waiting for /checkparam]');
                end
            end

            if (imgui.TreeNodeEx('Attributes', 0)) then
                imgui.Text('Family: ' .. (dbMob.Family or 'Unknown'));
                imgui.Text(string.format('STR: %d  DEX: %d', stats.STR, stats.DEX));
                imgui.Text(string.format('VIT: %d  AGI: %d', stats.VIT, stats.AGI));
                imgui.Text(string.format('INT: %d  MND: %d', stats.INT, stats.MND));
                imgui.Text(string.format('CHR: %d', stats.CHR));
                imgui.TreePop();
            end

            -- Resistances (only show if there are any non-zero values)
            -- NOTE: Resistance values come directly from the server database (mob_resistances.sql).
            -- If values appear incorrect (e.g., Golems showing +10% all elements instead of Lightning weakness),
            -- it's a data issue in the server database, NOT this addon. The addon always displays database truth.
            if (dbMob.Resistances) then
                local r = dbMob.Resistances;
                -- SDT (Stoneskin/Damage Taken): Affects damage multiplier
                --   Physical SDT values are in basis points (1/100ths): -2500 = takes 25% more damage (weakness)
                --   Elemental SDT values are in 1/10000ths: -5000 = takes 50% more damage (weakness)
                -- RES_RANK: Affects spell resist rate
                --   -3 = weak (spells land easier, max resist tier 1/2)
                --   0 = neutral
                --   +4+ = resistant (spells land harder)
                local function resPhys(sdt)
                    return math.floor((-sdt / 100) + 0.5);
                end
                local function resElem(sdt)
                    -- SDT in 1/10000ths: -5000 = -50% (takes 50% more damage)
                    return math.floor((-sdt / 100) + 0.5);
                end

                -- Physical resistances (group by value)
                local physical = {
                    { name = 'Slashing', val = resPhys(r.Slashing) },
                    { name = 'Piercing', val = resPhys(r.Piercing) },
                    { name = 'Impact',   val = resPhys(r.Blunt) },
                };

                -- Elemental resistances - combine SDT and RES_RANK
                -- If SDT is non-zero, show damage modifier
                -- If RES_RANK is non-zero (-3 = weak, +4+ = resistant), also note that
                -- For display, we'll show the "effective" weakness/resistance
                -- RES_RANK -3 means "weak to element" even if SDT is 0
                local function elemVal(sdt, rank)
                    local sdtPct = resElem(sdt);
                    -- RES_RANK -3 is a significant weakness (easier to land spells, less resists)
                    -- RES_RANK +4 and above is significant resistance
                    -- Convert rank to an approximate "effective" value for display grouping
                    if (rank ~= 0 and sdtPct == 0) then
                        -- If SDT is neutral but rank is non-zero, show rank-based weakness/resistance
                        -- -3 rank = weak to magic, +4 rank = resistant to magic
                        if (rank <= -3) then
                            return -25; -- Display as "weak" (-25%)
                        elseif (rank <= -1) then
                            return -10; -- Display as "slightly weak"
                        elseif (rank >= 4) then
                            return 25;  -- Display as "resistant"
                        elseif (rank >= 1) then
                            return 10;  -- Display as "slightly resistant"
                        end
                    end
                    return sdtPct;
                end

                local elemental = {
                    { name = 'Fire',      val = elemVal(r.FireSDT or 0, r.FireRank or 0),           rank = r.FireRank or 0 },
                    { name = 'Ice',       val = elemVal(r.IceSDT or 0, r.IceRank or 0),             rank = r.IceRank or 0 },
                    { name = 'Wind',      val = elemVal(r.WindSDT or 0, r.WindRank or 0),           rank = r.WindRank or 0 },
                    { name = 'Earth',     val = elemVal(r.EarthSDT or 0, r.EarthRank or 0),         rank = r.EarthRank or 0 },
                    { name = 'Lightning', val = elemVal(r.LightningSDT or 0, r.LightningRank or 0), rank = r.LightningRank or 0 },
                    { name = 'Water',     val = elemVal(r.WaterSDT or 0, r.WaterRank or 0),         rank = r.WaterRank or 0 },
                    { name = 'Light',     val = elemVal(r.LightSDT or 0, r.LightRank or 0),         rank = r.LightRank or 0 },
                    { name = 'Dark',      val = elemVal(r.DarkSDT or 0, r.DarkRank or 0),           rank = r.DarkRank or 0 },
                };

                -- Group items by value, only non-zero (for elemental, also check rank)
                local function groupByValue(items, checkRank)
                    local groups = {};
                    for _, item in ipairs(items) do
                        local shouldInclude = (item.val ~= 0);
                        -- For elemental, also include if rank is significant
                        if (checkRank and item.rank and (item.rank <= -1 or item.rank >= 1)) then
                            shouldInclude = true;
                        end
                        if (shouldInclude) then
                            local key = tostring(item.val);
                            if (not groups[key]) then
                                groups[key] = { val = item.val, names = {}, ranks = {} };
                            end
                            table.insert(groups[key].names, item.name);
                            if (item.rank) then
                                groups[key].ranks[item.name] = item.rank;
                            end
                        end
                    end
                    -- Convert to sorted array (by value descending - resistant first)
                    local result = {};
                    for _, group in pairs(groups) do
                        table.insert(result, group);
                    end
                    table.sort(result, function(a, b) return a.val > b.val; end);
                    return result;
                end

                local physGroups = groupByValue(physical, false);
                local elemGroups = groupByValue(elemental, true);

                -- Only show Resistances section if there's something to display
                if (#physGroups > 0 or #elemGroups > 0) then
                    -- Color based on resistance value (from player's perspective)
                    -- Negative = mob takes MORE damage = good (green)
                    -- Positive = mob takes LESS damage = bad (red)
                    local function resColor(val)
                        if (val < -25) then
                            return { 0.3, 1.0, 0.3, 1.0 }; -- Green (weak - good for us)
                        elseif (val < 0) then
                            return { 0.8, 1.0, 0.3, 1.0 }; -- Yellow-green (slightly weak)
                        elseif (val > 25) then
                            return { 1.0, 0.3, 0.3, 1.0 }; -- Red (resistant - bad for us)
                        else
                            return { 1.0, 0.8, 0.3, 1.0 }; -- Orange (slightly resistant)
                        end
                    end

                    -- Draw grouped resistances on same line, wrapping as needed
                    local function drawGroupsInline(groups)
                        if (#groups == 0) then
                            return false;
                        end
                        local isFirst = true;
                        for _, group in ipairs(groups) do
                            -- Add spacing between groups
                            if (not isFirst) then
                                imgui.SameLine(0, 12);
                            end
                            isFirst = false;

                            -- Draw all icons for this group
                            local firstIcon = true;
                            for _, name in ipairs(group.names) do
                                if (firstIcon) then
                                    textures:DrawIcon(name, 1.2);
                                    firstIcon = false;
                                else
                                    textures:DrawIconSameLine(name, 1.2);
                                end
                            end
                            imgui.SameLine(0, 4);
                            local sign = group.val >= 0 and '+' or '';
                            imgui.TextColored(resColor(group.val), sign .. tostring(group.val) .. '%%');
                        end
                        return true;
                    end

                    if (imgui.TreeNode('Resistances')) then
                        drawGroupsInline(physGroups);
                        if (#physGroups > 0 and #elemGroups > 0) then
                            -- New line for elemental if we had physical
                        end
                        drawGroupsInline(elemGroups);
                        imgui.TreePop();
                    end
                end
            end
        else
            imgui.TextColored({ 1.0, 1.0, 0.5, 1.0 }, 'No DB Data');
        end

        imgui.End();
    end
end);

ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/enemystats') then
        return;
    end

    e.blocked = true;

    if (#args > 1) then
        if (args[2] == 'show') then
            enemystats.settings.visible = true;
        elseif (args[2] == 'hide') then
            enemystats.settings.visible = false;
        elseif (args[2] == 'refresh' or args[2] == 'update') then
            -- Trigger /checkparam to get real player stats via packet injection
            -- Block the chat response since user already knows they requested it
            autoRefresh.awaitingResponse = true;
            autoRefresh.blockChatUntil = os.clock() + 2.0;
            autoRefresh.gearHashOnSend = GetGearHash(); -- Capture gear state
            if (SendCheckParamPacket()) then
                dbg('[enemystats] Sent checkparam packet (manual refresh)');
            else
                print('[enemystats] Failed to send checkparam packet');
                autoRefresh.awaitingResponse = false;
                autoRefresh.gearHashOnSend = nil;
            end
        elseif (args[2] == 'status') then
            -- Show current status
            if (playerStats.ACC2 and playerStats.ACC2 > 0) then
                print('[enemystats] Main ACC: ' ..
                tostring(playerStats.ACC) .. ', Off ACC: ' .. tostring(playerStats.ACC2));
            else
                print('[enemystats] Current ACC: ' .. tostring(playerStats.ACC));
            end
            print('[enemystats] Pending refresh: ' .. tostring(autoRefresh.pendingRefresh));
            print('[enemystats] Cached buff count: ' .. #autoRefresh.lastBuffIcons);
            -- Count cached gear sets
            local cacheCount = 0;
            for _ in pairs(gearSetCache.sets) do cacheCount = cacheCount + 1; end
            print('[enemystats] Cached gear sets: ' .. cacheCount);
            print('[enemystats] Debug mode: ' .. tostring(enemystats.settings.debug));
        elseif (args[2] == 'debug') then
            -- Toggle debug mode
            enemystats.settings.debug = not enemystats.settings.debug;
            print('[enemystats] Debug mode: ' .. (enemystats.settings.debug and 'ON' or 'OFF'));
        end
        update_settings();
    else
        -- Show help
        print('[enemystats] Commands:');
        print('  /enemystats show    - Show the window');
        print('  /enemystats hide    - Hide the window');
        print('  /enemystats refresh - Manually update ACC/ATT/EVA/DEF');
        print('  /enemystats status  - Show current tracking status');
        print('  /enemystats debug   - Toggle debug prints on/off');
        print('[enemystats] Note: ACC auto-updates on buff/gear changes. Gear sets are cached for instant swaps.');
    end
end);
