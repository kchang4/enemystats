local grades = {};

-- Job Grades (HP, MP, STR, DEX, VIT, AGI, INT, MND, CHR)
-- 0=NON, 1=WAR, 2=MNK, 3=WHM, 4=BLM, 5=RDM, 6=THF, 7=PLD, 8=DRK, 9=BST, 10=BRD, 11=RNG, 12=SAM, 13=NIN, 14=DRG, 15=SMN, 16=BLU, 17=COR, 18=PUP, 19=DNC, 20=SCH, 21=GEO, 22=RUN
grades.JobGrades = {
    [0]  = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }, -- NON
    [1]  = { 2, 0, 1, 3, 4, 3, 6, 6, 5 }, -- WAR
    [2]  = { 1, 0, 3, 2, 1, 6, 7, 4, 5 }, -- MNK
    [3]  = { 5, 3, 4, 6, 4, 5, 5, 1, 3 }, -- WHM
    [4]  = { 6, 2, 6, 3, 6, 3, 1, 5, 4 }, -- BLM
    [5]  = { 4, 4, 4, 4, 5, 5, 3, 3, 4 }, -- RDM
    [6]  = { 4, 0, 4, 1, 4, 2, 3, 7, 7 }, -- THF
    [7]  = { 3, 6, 2, 5, 1, 7, 7, 3, 3 }, -- PLD
    [8]  = { 3, 6, 1, 3, 3, 4, 3, 7, 7 }, -- DRK
    [9]  = { 3, 0, 4, 3, 4, 6, 5, 5, 1 }, -- BST
    [10] = { 4, 0, 4, 4, 4, 6, 4, 4, 2 }, -- BRD
    [11] = { 5, 0, 5, 4, 4, 1, 5, 4, 5 }, -- RNG
    [12] = { 2, 0, 3, 3, 3, 4, 5, 5, 4 }, -- SAM
    [13] = { 4, 0, 3, 2, 3, 2, 4, 7, 6 }, -- NIN
    [14] = { 3, 0, 2, 4, 3, 4, 6, 5, 3 }, -- DRG
    [15] = { 7, 1, 6, 5, 6, 4, 2, 2, 2 }, -- SMN
    [16] = { 4, 4, 5, 5, 5, 5, 5, 5, 5 }, -- BLU
    [17] = { 4, 0, 5, 3, 5, 2, 3, 5, 5 }, -- COR
    [18] = { 4, 0, 5, 2, 4, 3, 5, 6, 3 }, -- PUP
    [19] = { 4, 0, 4, 3, 5, 2, 6, 6, 2 }, -- DNC
    [20] = { 5, 4, 6, 4, 5, 4, 3, 4, 3 }, -- SCH
    [21] = { 3, 2, 6, 4, 5, 4, 3, 3, 4 }, -- GEO
    [22] = { 3, 6, 3, 4, 5, 2, 4, 4, 6 }  -- RUN
};

-- Mob HP Scale (Base, JobScale, ScaleX)
-- 1=A, 2=B, 3=C, 4=D, 5=E, 6=F, 7=G
grades.MobHPScale = {
    [0] = { 0, 0, 0 },
    [1] = { 36, 9, 1 }, -- A
    [2] = { 33, 8, 1 }, -- B
    [3] = { 32, 7, 1 }, -- C
    [4] = { 29, 6, 0 }, -- D
    [5] = { 27, 5, 0 }, -- E
    [6] = { 24, 4, 0 }, -- F
    [7] = { 22, 3, 0 }, -- G
};

-- Random Increment (RI, Scale)
grades.MobRBI = {
    [0] = { 0, 0 },
    [1] = { 1, 0 },
    [2] = { 2, 0 },
    [3] = { 3, 3 },
    [4] = { 4, 7 },
    [5] = { 5, 14 },
};

function grades.GetJobGrade(job, statIndex)
    if (grades.JobGrades[job]) then
        return grades.JobGrades[job][statIndex];
    end
    return 0;
end

function grades.GetMobHPScale(rank, index)
    if (grades.MobHPScale[rank]) then
        return grades.MobHPScale[rank][index];
    end
    return 0;
end

function grades.GetMobRBI(rank, index)
    if (grades.MobRBI[rank]) then
        return grades.MobRBI[rank][index];
    end
    return 0;
end

function grades.GetBaseToRank(rank, lvl)
    if (rank == 1) then return math.floor(5 + ((lvl - 1) * 50) / 100); end -- A
    if (rank == 2) then return math.floor(4 + ((lvl - 1) * 45) / 100); end -- B
    if (rank == 3) then return math.floor(4 + ((lvl - 1) * 40) / 100); end -- C
    if (rank == 4) then return math.floor(3 + ((lvl - 1) * 35) / 100); end -- D
    if (rank == 5) then return math.floor(3 + ((lvl - 1) * 30) / 100); end -- E
    if (rank == 6) then return math.floor(2 + ((lvl - 1) * 25) / 100); end -- F
    if (rank == 7) then return math.floor(2 + ((lvl - 1) * 20) / 100); end -- G
    return 0;
end

return grades;
