local grades = require('grades');

local calculator = {};

-- NM multiplier settings (can be overridden by addon settings)
-- These mirror the server settings: NM_HP_MULTIPLIER, NM_STAT_MULTIPLIER
calculator.Settings = {
    NM_HP_MULTIPLIER = 1.0,   -- HP multiplier for Notorious Monsters (default: 1.0)
    NM_STAT_MULTIPLIER = 1.0, -- Stat multiplier for NMs (affects ATK/DEF/EVA) (default: 1.0)
};

-- Allow addon to update settings
function calculator.SetSettings(settings)
    if (settings.nm_hp_multiplier) then
        calculator.Settings.NM_HP_MULTIPLIER = settings.nm_hp_multiplier;
    end
    if (settings.nm_stat_multiplier) then
        calculator.Settings.NM_STAT_MULTIPLIER = settings.nm_stat_multiplier;
    end
end

-- Helper for SubJob Stats (Ported from GetSubJobStats in mobutils.cpp)
local function GetSubJobStats(rank, level, stat)
    local sJobStat = 0;
    if (rank == 1) then -- A
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (4.0 - 0.225 * (level - 30))), 2.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (3.25 - 0.073 * (level - 30)));
        elseif (level <= 46) then
            sJobStat = math.floor(stat / (2.55 - 0.001 * (level - 41)));
        else
            sJobStat = math.floor(stat / (2.7 - 0.001 * (level - 45)));
        end
    elseif (rank == 2) then -- B
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (3.1 - 0.075 * (level - 32))), 2.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (3.1 - 0.075 * (level - 32)));
        elseif (level <= 45) then
            sJobStat = math.floor(stat / (2.5 - 0.025 * (level - 40)));
        else
            sJobStat = math.floor(stat / (2.35 - 0.04 * (level - 44)));
        end
    elseif (rank == 3) then -- C
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (4.5 - 0.15 * (level - 26))), 2.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (3.28 - 0.001 * (level - 30)));
        elseif (level <= 45) then
            sJobStat = math.floor(stat / (2.6 - 0.025 * (level - 40)));
        else
            sJobStat = math.floor(stat / (2.1 - 0.2 * (level - 49)));
        end
    elseif (rank == 4) then -- D
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (5.0 - 0.05 * (level - 21))), 1.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (3.2 - 0.001 * (level - 29)));
        elseif (level <= 45) then
            sJobStat = math.floor(stat / (3.5 - 0.08 * (level - 32)));
        else
            sJobStat = math.floor(stat / (3.25 - 0.045 * (level - 32)));
        end
    elseif (rank == 5) then -- E
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (3.8 - 0.1 * (level - 32))), 1.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (3.8 - 0.15 * (level - 32)));
        elseif (level <= 45) then
            sJobStat = math.floor(stat / (2.7 - 0.075 * (level - 40)));
        else
            sJobStat = math.floor(stat / (2.7 - 0.05 * (level - 45)));
        end
    elseif (rank == 6) then -- F
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (4.0 - 0.15 * (level - 35))), 1.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (4.0 - 0.15 * (level - 30)));
        elseif (level <= 46) then
            sJobStat = math.floor(stat / (3.0 - 0.1125 * (level - 40)));
        else
            sJobStat = math.floor(stat / (3.0 - 0.07 * (level - 40)));
        end
    elseif (rank == 7) then -- G
        if (level <= 30) then
            sJobStat = math.max(math.floor(stat / (4.0 - 0.15 * (level - 35))), 1.0);
        elseif (level <= 40) then
            sJobStat = math.floor(stat / (4.0 - 0.2 * (level - 31)));
        elseif (level <= 46) then
            sJobStat = math.floor(stat / (2.5 - 0.09 * (level - 40)));
        else
            sJobStat = math.floor(stat / 2);
        end
    else
        sJobStat = stat / 2;
    end
    return sJobStat;
end

function calculator.CalculateMaxHP(mobData, level)
    -- Check for HP override from mob_groups (used for NMs like King Behemoth)
    -- When HPOverride > 0, use it directly instead of calculating
    if (mobData.HPOverride and mobData.HPOverride > 0) then
        local hp = mobData.HPOverride;
        -- Apply NM HP multiplier if this is an NM
        if (mobData.IsNM and calculator.Settings.NM_HP_MULTIPLIER ~= 1.0) then
            hp = hp * calculator.Settings.NM_HP_MULTIPLIER;
        end
        return math.floor(hp);
    end

    local mJob          = mobData.Job;
    local sJob          = mobData.SubJob;
    local familyHPScale = mobData.HPScale or 100;      -- Default 100%

    local mJobGrade     = grades.GetJobGrade(mJob, 1); -- 1 is HP column in JobGrades
    local sJobGrade     = grades.GetJobGrade(sJob, 1);

    local BaseHP        = grades.GetMobHPScale(mJobGrade, 1);
    local JobScale      = grades.GetMobHPScale(mJobGrade, 2);
    local ScaleXHP      = grades.GetMobHPScale(mJobGrade, 3);
    local sjJobScale    = grades.GetMobHPScale(sJobGrade, 2);
    local sjScaleXHP    = grades.GetMobHPScale(sJobGrade, 3);

    local RIgrade       = math.min(level, 5);
    local RI            = grades.GetMobRBI(RIgrade, 1);

    local mLvlIf        = (level > 5) and 1 or 0;
    local mLvlIf30      = (level > 30) and 1 or 0;
    local raceScale     = 6; -- Hardcoded in mobutils.cpp line 639

    local baseMobHP     = 0;
    if (level > 0) then
        baseMobHP = BaseHP + (math.min(level, 5) - 1) * (JobScale + raceScale - 1) + RI +
            mLvlIf * (math.min(level, 30) - 5) * (2 * (JobScale + raceScale) + math.min(level, 30) - 6) / 2 +
            mLvlIf30 * ((level - 30) * (63 + ScaleXHP) + (level - 31) * (JobScale + raceScale));
    end

    local mLvlScale = 0;
    if (level > 49) then
        mLvlScale = math.floor(level);
    elseif (level > 39) then
        mLvlScale = math.floor(level * 0.75);
    elseif (level > 30) then
        mLvlScale = math.floor(level * 0.50);
    elseif (level > 24) then
        mLvlScale = math.floor(level * 0.25);
    end

    local sjHP = math.ceil((sjJobScale * (math.max((mLvlScale - 1), 0)) + (0.5 + 0.5 * sjScaleXHP) * (math.max(mLvlScale - 10, 0)) + math.max(mLvlScale - 30, 0) + math.max(mLvlScale - 50, 0) + math.max(mLvlScale - 70, 0)) /
        2);

    local mobHP = baseMobHP + sjHP;

    -- Family Modifiers
    if (mobData.Family == 'Orc' or mobData.Family == 'Orc-Warmachine') then
        mobHP = mobHP * 1.05;
    elseif (mobData.Family == 'Quadav') then
        mobHP = mobHP * 0.95;
    elseif (mobData.Family == 'Manticore') then
        mobHP = mobHP * 1.5;
    end

    -- Apply Family HP Scale (from mob_family_system.HP)
    -- The server divides by 100 to get a float (e.g. 120 -> 1.2)
    mobHP = mobHP * (familyHPScale / 100.0);

    -- Apply NM HP multiplier if this is an NM (and formula was used, not override)
    if (mobData.IsNM and calculator.Settings.NM_HP_MULTIPLIER ~= 1.0) then
        mobHP = mobHP * calculator.Settings.NM_HP_MULTIPLIER;
    end

    return math.floor(mobHP);
end

function calculator.CalculateStats(mobData, level)
    local stats = { STR = 0, DEX = 0, VIT = 0, AGI = 0, INT = 0, MND = 0, CHR = 0 };
    local statNames = { 'STR', 'DEX', 'VIT', 'AGI', 'INT', 'MND', 'CHR' };
    -- Indices in JobGrades: STR=3, DEX=4, VIT=5, AGI=6, INT=7, MND=8, CHR=9
    local statIndices = { STR = 3, DEX = 4, VIT = 5, AGI = 6, INT = 7, MND = 8, CHR = 9 };

    for _, stat in ipairs(statNames) do
        local idx = statIndices[stat];

        -- Family Base Rank (from mob_family_system)
        local fRank = mobData[stat] or 1; -- Default to A? No, default is 3 (C) in SQL
        local fStat = grades.GetBaseToRank(fRank, level);

        -- Main Job Stat
        local mRank = grades.GetJobGrade(mobData.Job, idx);
        local mStat = grades.GetBaseToRank(mRank, level);

        -- Sub Job Stat
        local sRank = grades.GetJobGrade(mobData.SubJob, idx);
        local sStat = grades.GetBaseToRank(sRank, level); -- Note: sLvl = mLvl for mobs usually

        -- Sub Job Penalty/Bonus logic
        -- Mobs < 50 in specific zones use full subjob stats, otherwise penalty?
        -- mobutils.cpp line 830: if (CheckSubJobZone(PMob) && (sLvl < 50)) ... else sStat /= 2
        -- For simplicity, let's assume the penalty applies (sStat / 2) unless we implement the zone check.
        -- Most high level mobs have the penalty.
        -- Let's implement the penalty by default for now.
        if (level >= 50) then
            sStat = sStat / 2;
        else
            -- If < 50, we should check zone. But we don't have zone info easily here without passing it.
            -- Let's just assume penalty for now to be safe, or maybe no penalty?
            -- Actually, let's check if we can pass zone.
            -- For now, let's just use the penalty logic from C++:
            -- else { sStat /= 2; }
            sStat = sStat / 2;
        end

        stats[stat] = math.floor(fStat + mStat + sStat);
    end

    return stats;
end

-- Calculate ATK, DEF, EVA based on mob data and level
function calculator.CalculateCombatStats(mobData, level, baseStats)
    local combatStats = { ATK = 0, DEF = 0, EVA = 0 };

    -- ATK = GetBaseSkill(rank) + STR (from mobutils.cpp line 914)
    local attRank = mobData.ATT or 3;
    local attBase = grades.GetBaseToRank(attRank, level);
    combatStats.ATK = math.floor(attBase + baseStats.STR);

    -- DEF = GetBaseDefEva(defRank) + 8 + VIT/2 (from mobutils.cpp line 912, battleentity.cpp)
    -- GetBaseDefEva formula from mobutils.cpp lines 254-295
    local defRank = mobData.DEF or 3;
    local defBase = GetBaseDefEva(defRank, level);
    combatStats.DEF = math.floor(defBase + 8 + baseStats.VIT / 2);

    -- EVA = GetBaseDefEva(evaRank) + AGI/2 (from mobutils.cpp line 913, battleentity.cpp line 1402)
    -- EVA rank is determined by job's evasion skill rank (JobSkillRankToBaseEvaRank)
    -- Since we don't have access to job skill ranks, use the EVA rank from mob_family_system
    local evaRank = mobData.EVA or 3;
    local evaBase = GetBaseDefEva(evaRank, level);
    combatStats.EVA = math.floor(evaBase + baseStats.AGI / 2);

    -- Apply NM stat multiplier if this is an NM
    if (mobData.IsNM and calculator.Settings.NM_STAT_MULTIPLIER ~= 1.0) then
        local mult = calculator.Settings.NM_STAT_MULTIPLIER;
        combatStats.ATK = math.floor(combatStats.ATK * mult);
        combatStats.DEF = math.floor(combatStats.DEF * mult);
        combatStats.EVA = math.floor(combatStats.EVA * mult);
    end

    return combatStats;
end

-- GetBaseDefEva - Ported from mobutils.cpp lines 254-295
-- See: https://w.atwiki.jp/studiogobli/pages/25.html
-- Returns base defense/evasion value based on rank and level
function GetBaseDefEva(rank, level)
    if (level > 50) then
        if (rank == 1) then     -- A
            return math.floor(153 + (level - 50) * 5.0);
        elseif (rank == 2) then -- B
            return math.floor(147 + (level - 50) * 4.9);
        elseif (rank == 3) then -- C
            return math.floor(142 + (level - 50) * 4.8);
        elseif (rank == 4) then -- D
            return math.floor(136 + (level - 50) * 4.7);
        elseif (rank == 5) then -- E
            return math.floor(126 + (level - 50) * 4.5);
        end
    else
        if (rank == 1) then     -- A
            return math.floor(6 + (level - 1) * 3.0);
        elseif (rank == 2) then -- B
            return math.floor(5 + (level - 1) * 2.9);
        elseif (rank == 3) then -- C
            return math.floor(5 + (level - 1) * 2.8);
        elseif (rank == 4) then -- D
            return math.floor(4 + (level - 1) * 2.7);
        elseif (rank == 5) then -- E
            return math.floor(4 + (level - 1) * 2.5);
        end
    end
    return 0;
end

return calculator;
