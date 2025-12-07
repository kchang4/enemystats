local database = {};

-- Path to the local SQL files (inside the addon directory)
local SQL_PATH = AshitaCore:GetInstallPath() .. 'addons/enemystats/sql/';

database.CurrentZone = 0;
database.Mobs = {};     -- Key: Index (0-1023), Value: MobData
database.Families = {}; -- Cache for families
database.Pools = {};    -- Cache for pools
database.Groups = {};   -- Cache for groups

-- Helper to parse SQL INSERT statements
local function ParseSQL(filename, callback)
    local path = SQL_PATH .. filename;
    local f = io.open(path, 'r');
    if (f == nil) then
        print('[EnemyStats] Failed to open SQL file: ' .. path);
        return;
    end

    for line in f:lines() do
        -- Remove comments
        local comment = string.find(line, '%-%-');
        if (comment) then
            line = string.sub(line, 1, comment - 1);
        end

        if (string.match(line, 'INSERT INTO')) then
            local start = string.find(line, '%(');
            local finish = string.find(line, '%)');
            if (start and finish) then
                local content = string.sub(line, start + 1, finish - 1);
                local parts = {};
                for part in string.gmatch(content, "([^,]+)") do
                    part = part:match("^%s*(.-)%s*$");
                    part = part:gsub("^'(.*)'$", "%1");
                    table.insert(parts, part);
                end
                callback(parts);
            end
        end
    end
    f:close();
end

function database:Initialize()
    -- Load Families (Global)
    -- Note: Using next() to check if table is empty since # doesn't work on hash tables
    if (next(self.Families) == nil) then
        print('[EnemyStats] Loading families...');
        ParseSQL('mob_family_system.sql', function(parts)
            local id = tonumber(parts[1]);
            -- Columns: 1=familyID, 2=family, 3=superFamilyID, 4=superFamily, 5=ecosystemID,
            --          6=ecosystem, 7=mobradius, 8=speed, 9=HP, 10=MP,
            --          11=STR, 12=DEX, 13=VIT, 14=AGI, 15=INT, 16=MND, 17=CHR,
            --          18=ATT, 19=DEF, 20=ACC, 21=EVA, 22=Element, 23=detects, 24=charmable
            if (id) then
                self.Families[id] = {
                    FamilyId = id,
                    FamilyName = parts[4] or parts[2], -- Use superFamily (cleaner) if available, else family
                    HP = tonumber(parts[9]) or 100,
                    MP = tonumber(parts[10]) or 100,
                    STR = tonumber(parts[11]) or 3,
                    DEX = tonumber(parts[12]) or 3,
                    VIT = tonumber(parts[13]) or 3,
                    AGI = tonumber(parts[14]) or 3,
                    INT = tonumber(parts[15]) or 3,
                    MND = tonumber(parts[16]) or 3,
                    CHR = tonumber(parts[17]) or 3,
                    ATT = tonumber(parts[18]) or 3,
                    DEF = tonumber(parts[19]) or 3,
                    ACC = tonumber(parts[20]) or 3,
                    EVA = tonumber(parts[21]) or 3,
                    Detect = tonumber(parts[23]) or 0
                };
            end
        end);
    end

    -- Load Resistances (Global)
    if (self.Resistances == nil) then
        self.Resistances = {};
        print('[EnemyStats] Loading resistances...');
        ParseSQL('mob_resistances.sql', function(parts)
            local id = tonumber(parts[1]); -- resist_id (usually matches familyId)
            -- SQL Columns:
            --   1=resist_id, 2=name
            --   3=slash_sdt, 4=pierce_sdt, 5=h2h_sdt, 6=impact_sdt, 7=magical_sdt
            --   8=fire_sdt, 9=ice_sdt, 10=wind_sdt, 11=earth_sdt, 12=lightning_sdt, 13=water_sdt, 14=light_sdt, 15=dark_sdt
            --   16=fire_res_rank, 17=ice_res_rank, 18=wind_res_rank, 19=earth_res_rank, 20=lightning_res_rank, 21=water_res_rank, 22=light_res_rank, 23=dark_res_rank
            --
            -- SDT (Stoneskin/Damage Taken): Affects damage multiplier
            --   0 = 100% damage, negative = takes more damage (weakness), positive = takes less damage (resist)
            --   Physical SDT is in 1/100ths (basis points), so -2500 = +25% damage taken
            --   Elemental SDT is in 1/10000ths, so -5000 = +50% damage taken
            --
            -- RES_RANK (Resistance Rank): Affects spell land rate and resist tiers
            --   Range: -3 (weak) to +11 (immune)
            --   -3: Easier to land spells, max resist tier is 1/2
            --   0: Neutral
            --   +4 and above: Much harder to land spells
            --
            -- FFXI has 3 physical damage types:
            --   Slashing (swords, axes, scythes, great swords, katanas)
            --   Piercing (daggers, polearms, archery, marksmanship)
            --   Blunt (hand-to-hand, clubs, staves) - uses impact_sdt column
            if (id) then
                local function getVal(val)
                    return tonumber(val) or 0;
                end
                self.Resistances[id] = {
                    -- Physical SDT (damage taken modifier)
                    Slashing = getVal(parts[3]),
                    Piercing = getVal(parts[4]),
                    Blunt = getVal(parts[6]), -- impact_sdt is Blunt damage
                    -- Elemental SDT (damage taken modifier)
                    FireSDT = getVal(parts[8]),
                    IceSDT = getVal(parts[9]),
                    WindSDT = getVal(parts[10]),
                    EarthSDT = getVal(parts[11]),
                    LightningSDT = getVal(parts[12]),
                    WaterSDT = getVal(parts[13]),
                    LightSDT = getVal(parts[14]),
                    DarkSDT = getVal(parts[15]),
                    -- Elemental RES_RANK (resist rate modifier)
                    FireRank = getVal(parts[16]),
                    IceRank = getVal(parts[17]),
                    WindRank = getVal(parts[18]),
                    EarthRank = getVal(parts[19]),
                    LightningRank = getVal(parts[20]),
                    WaterRank = getVal(parts[21]),
                    LightRank = getVal(parts[22]),
                    DarkRank = getVal(parts[23])
                };
            end
        end);
    end

    -- Load Pools (Global) - index by both ID and name for flexible lookup
    -- Columns: 1=poolid, 2=name, 3=packet_name, 4=familyid, 5=modelid, 6=mJob, 7=sJob,
    --          8=cmbSkill, 9=cmbDelay, 10=cmbDmgMult, 11=behavior, 12=aggro, 13=true_detection,
    --          14=links, 15=mobType, ...
    if (next(self.Pools) == nil) then
        print('[EnemyStats] Loading pools...');
        self.PoolsByName = {}; -- Additional index by name
        ParseSQL('mob_pools.sql', function(parts)
            local id = tonumber(parts[1]);
            if (id) then
                local name = parts[2];
                local familyId = tonumber(parts[4]);
                local mobType = tonumber(parts[15]) or 0;

                local poolData = {
                    PoolId = id,
                    Name = name,
                    FamilyId = familyId,
                    Job = tonumber(parts[6]),
                    SubJob = tonumber(parts[7]),
                    Aggro = (parts[12] == '1'),
                    TrueSight = (tonumber(parts[13]) or 0) > 0,
                    Link = (parts[14] == '1'),
                    MobType = mobType,
                    IsNM = bit.band(mobType, 0x02) ~= 0 -- MOBTYPE_NOTORIOUS = 0x02
                };
                self.Pools[id] = poolData;
                -- Also index by name for direct lookup
                if (name) then
                    self.PoolsByName[name] = poolData;
                end
            end
        end);
    end
end

function database:Load(zone)
    if (zone == self.CurrentZone) then
        return;
    end

    self.CurrentZone = zone;
    self.Mobs = {};
    self.Groups = {};

    self:Initialize();

    print(string.format('[EnemyStats] Loading data for zone %d...', zone));

    -- Load Groups for this zone
    -- Columns: 1=groupid, 2=poolid, 3=zoneid, 4=name, 5=respawntime, 6=spawntype, 7=dropid,
    --          8=HP (override), 9=MP (override), 10=minLevel, 11=maxLevel, 12=allegiance
    ParseSQL('mob_groups.sql', function(parts)
        local id = tonumber(parts[1]);
        local zoneId = tonumber(parts[3]);
        if (id and zoneId == zone) then
            self.Groups[id] = {
                GroupId = id,
                PoolId = tonumber(parts[2]),
                HPOverride = tonumber(parts[8]) or 0, -- HP override (when > 0, use instead of formula)
                MPOverride = tonumber(parts[9]) or 0, -- MP override (when > 0, use instead of formula)
                MinLevel = tonumber(parts[10]),
                MaxLevel = tonumber(parts[11])
            };
        end
    end);

    -- Load Spawns for this zone (filtered by zone ID in mobId)
    -- Mob ID format: zone is encoded as (mobId >> 12) & 0x1FF
    -- Columns: mobid(1), spawnset(2), mobname(3), polutils_name(4), groupid(5)
    local spawnCount = 0;
    ParseSQL('mob_spawn_points.sql', function(parts)
        local id = tonumber(parts[1]);
        if (not id) then return; end

        -- Extract zone from mob ID: (mobId >> 12) & 0x1FF
        local mobZone = bit.band(bit.rshift(id, 12), 0x1FF);
        if (mobZone ~= zone) then return; end -- Skip mobs not in this zone

        local groupId = tonumber(parts[5]);
        local mobName = parts[3];

        if (groupId and self.Groups[groupId]) then
            spawnCount = spawnCount + 1;
            local group = self.Groups[groupId];

            -- Try to find pool by mob name first (more accurate), fall back to group's poolId
            local pool = nil;
            if (mobName and self.PoolsByName[mobName]) then
                pool = self.PoolsByName[mobName];
            else
                pool = self.Pools[group.PoolId];
            end

            local family = nil;
            local resists = nil;
            if (pool) then
                family = self.Families[pool.FamilyId];
                resists = self.Resistances[pool.FamilyId];
            end

            local index = bit.band(id, 0x3FF);

            self.Mobs[index] = {
                Id = id,
                Name = parts[3],
                Job = pool and pool.Job or 0,
                SubJob = pool and pool.SubJob or 0,
                MinLevel = group.MinLevel,
                MaxLevel = group.MaxLevel,
                HPOverride = group.HPOverride or 0, -- HP override from mob_groups (when > 0, use instead of formula)
                MPOverride = group.MPOverride or 0, -- MP override from mob_groups (when > 0, use instead of formula)
                IsNM = pool and pool.IsNM or false, -- MOBTYPE_NOTORIOUS flag
                Aggro = pool and pool.Aggro or false,
                Link = pool and pool.Link or false,
                TrueSight = pool and pool.TrueSight or false,
                Family = family and family.FamilyName or 'Unknown',
                HPScale = family and family.HP or 100,
                STR = family and family.STR or 3,
                DEX = family and family.DEX or 3,
                VIT = family and family.VIT or 3,
                AGI = family and family.AGI or 3,
                INT = family and family.INT or 3,
                MND = family and family.MND or 3,
                CHR = family and family.CHR or 3,
                ATT = family and family.ATT or 3,
                DEF = family and family.DEF or 3,
                ACC = family and family.ACC or 3,
                EVA = family and family.EVA or 3,
                Detect = family and family.Detect or 0,
                Resistances = resists
            };
        end
    end);
    print(string.format('[EnemyStats] Zone data loaded. Spawns: %d', spawnCount));
end

function database:GetMob(index)
    if (self.Mobs and self.Mobs[index]) then
        return self.Mobs[index];
    end
    return nil;
end

-- Fallback lookup by mob name (useful for dynamically spawned NMs not in spawn_points)
-- This searches all loaded mobs in the current zone for a matching name
-- If not found in current zone's mobs, falls back to pool data with estimated levels
function database:GetMobByName(name)
    if (not name) then
        return nil;
    end

    -- Normalize name for comparison: underscores to spaces, lowercase
    local searchName = name:gsub('_', ' '):lower();

    -- First: search mobs in current zone by normalized name
    if (self.Mobs) then
        for _, mob in pairs(self.Mobs) do
            if (mob.Name) then
                -- Normalize database name the same way
                local mobNameNorm = mob.Name:gsub('_', ' '):lower();
                if (mobNameNorm == searchName) then
                    return mob;
                end
            end
        end
    end

    -- Second: search pools by name (for mobs not in spawn_points but defined in pools)
    -- Try both original name and underscore-converted version
    local pool = self.PoolsByName and self.PoolsByName[name];
    if (not pool) then
        -- Try with spaces replaced by underscores (database uses underscores)
        local underscoreName = name:gsub(' ', '_');
        pool = self.PoolsByName and self.PoolsByName[underscoreName];
    end

    if (pool) then
        local family = self.Families and self.Families[pool.FamilyId];
        local resists = self.Resistances and self.Resistances[pool.FamilyId];

        -- Create a synthetic mob entry from pool data
        -- Note: MinLevel/MaxLevel and HP/MP overrides are unknown for pool-only mobs
        -- We use 75 as a sensible default for ITG mobs (NMs)
        return {
            Id = 0, -- Unknown
            Name = pool.Name,
            Job = pool.Job or 0,
            SubJob = pool.SubJob or 0,
            MinLevel = 75,             -- Default for NMs (user can /check to get exact level for non-ITG)
            MaxLevel = 75,             -- ITG mobs are typically 75+ era NMs
            HPOverride = 0,            -- Unknown for pool-only lookup (no mob_groups data)
            MPOverride = 0,            -- Unknown for pool-only lookup
            IsNM = pool.IsNM or false, -- From pool's mobType flag
            Aggro = pool.Aggro or false,
            Link = pool.Link or false,
            TrueSight = pool.TrueSight or false,
            Family = family and family.FamilyName or 'Unknown',
            HPScale = family and family.HP or 100,
            STR = family and family.STR or 3,
            DEX = family and family.DEX or 3,
            VIT = family and family.VIT or 3,
            AGI = family and family.AGI or 3,
            INT = family and family.INT or 3,
            MND = family and family.MND or 3,
            CHR = family and family.CHR or 3,
            ATT = family and family.ATT or 3,
            DEF = family and family.DEF or 3,
            ACC = family and family.ACC or 3,
            EVA = family and family.EVA or 3,
            Detect = family and family.Detect or 0,
            Resistances = resists,
            _fromPool = true -- Flag to indicate this is synthetic data (no HP override available)
        };
    end

    return nil;
end

return database;
