--******************************************************************************************************
--** Cybran SACU loadout combos
--**
--** Generates a hidden EnhancementPreset for every valid URL0301 slot combination
--** that is not already a named factory preset. IDs are stable: enhancement names
--** are sorted before the suffix is built, so clients cannot disagree on the string.
--**
--** Existing role presets (RAS, Engineer, Combat, ...) are left untouched and stay
--** on the Quantum Gateway construct grid.
--******************************************************************************************************

local TableInsert = table.insert
local TableGetn = table.getn
local StringLower = string.lower

--- Blueprint IDs that receive generated loadout presets.
--- First slice is Cybran only so the feature can be tested in isolation.
local ComboFactionBaseIds = {
    url0301 = true,
}

local SlotOrder = { 'LCH', 'RCH', 'Back' }

--- @param name string
--- @return boolean
local function IsRemoveEnhancement(name)
    return string.sub(name, -6) == 'Remove'
end

--- Deterministic copy of keys from a hash table.
--- @param hashtable table
--- @return string[]
local function SortedKeys(hashtable)
    local keys = {}
    for key in hashtable do
        TableInsert(keys, key)
    end
    table.sort(keys)
    return keys
end

--- Build the prerequisite chain ending at `enhName` (root first).
--- @param enhName string
--- @param slotDefs table<string, UnitBlueprintEnhancement>
--- @return string[]
local function EnhancementChain(enhName, slotDefs)
    local chain = { enhName }
    local current = enhName
    local guard = 0
    while slotDefs[current] and slotDefs[current].Prerequisite and guard < 8 do
        local pre = slotDefs[current].Prerequisite
        if not slotDefs[pre] then
            break
        end
        TableInsert(chain, 1, pre)
        current = pre
        guard = guard + 1
    end
    return chain
end

--- Every legal choice for one slot, including "leave empty".
--- @param slotDefs table<string, UnitBlueprintEnhancement>
--- @return string[][]
local function SlotChoices(slotDefs)
    local choices = { {} }
    local names = SortedKeys(slotDefs)
    for _, name in names do
        TableInsert(choices, EnhancementChain(name, slotDefs))
    end
    return choices
end

--- @param enhancements table<string, UnitBlueprintEnhancement>
--- @return table<string, table<string, UnitBlueprintEnhancement>>
local function GroupBySlot(enhancements)
    local bySlot = {}
    for name, def in enhancements do
        if def.Slot and not IsRemoveEnhancement(name) then
            bySlot[def.Slot] = bySlot[def.Slot] or {}
            bySlot[def.Slot][name] = def
        end
    end
    return bySlot
end

--- Sorted, pipe-joined key for an enhancement set.
--- @param list string[]
--- @return string
function EnhancementSetKey(list)
    local copy = {}
    for _, name in list do
        TableInsert(copy, name)
    end
    table.sort(copy)
    return string.lower(table.concat(copy, '|'))
end

--- @param namedPresets table
--- @return table<string, string>
local function ExistingPresetKeys(namedPresets)
    local keys = {}
    for presetName, preset in namedPresets do
        if preset.Enhancements then
            keys[EnhancementSetKey(preset.Enhancements)] = presetName
        end
    end
    return keys
end

--- Cartesian product of slot choices. Slot order is fixed so generation
--- order does not depend on Lua hash iteration.
--- @param slotChoices table<string, string[][]>
--- @return string[][]
local function AllCombinations(slotChoices)
    local combos = { {} }
    for _, slot in SlotOrder do
        local choices = slotChoices[slot]
        if choices then
            local nextCombos = {}
            for _, prefix in combos do
                for _, choice in choices do
                    local merged = {}
                    for _, name in prefix do
                        TableInsert(merged, name)
                    end
                    for _, name in choice do
                        TableInsert(merged, name)
                    end
                    TableInsert(nextCombos, merged)
                end
            end
            combos = nextCombos
        end
    end
    return combos
end

--- Stable blueprint suffix: combo_ + sorted lowercase enhancement names.
--- @param enhancements string[]
--- @return string
local function ComboPresetName(enhancements)
    local copy = {}
    for _, name in enhancements do
        TableInsert(copy, StringLower(name))
    end
    table.sort(copy)
    return 'combo_' .. table.concat(copy, '_')
end

--- Display name for a generated loadout.
--- @param enhancements string[]
--- @param bp UnitBlueprint
--- @return string
local function ComboUnitName(enhancements, bp)
    local labels = {}
    for _, name in enhancements do
        local def = bp.Enhancements[name]
        local label = name
        if def and def.Name then
            -- Keep the LOC tag; do not localize during blueprint load.
            label = def.Name
        end
        TableInsert(labels, label)
    end
    return 'SACU (' .. table.concat(labels, ' / ') .. ')'
end

--- Inject hidden combo presets into Cybran SACU, then let HandleUnitWithBuildPresets
--- turn them into real unit IDs the same way RAS / Rambo already work.
--- @param all_bps BlueprintsTable
function InjectSacuLoadoutPresets(all_bps)
    if not all_bps or not all_bps.Unit then
        return
    end

    local generated = 0
    local skippedNamed = 0

    for id, bp in all_bps.Unit do
        if ComboFactionBaseIds[id] and bp.Enhancements and bp.EnhancementPresets then
            local bySlot = GroupBySlot(bp.Enhancements)
            local slotChoices = {}
            for _, slot in SlotOrder do
                if bySlot[slot] then
                    slotChoices[slot] = SlotChoices(bySlot[slot])
                end
            end

            local namedKeys = ExistingPresetKeys(bp.EnhancementPresets)
            local combos = AllCombinations(slotChoices)

            for _, enhList in combos do
                if TableGetn(enhList) > 0 then
                    local setKey = EnhancementSetKey(enhList)
                    if namedKeys[setKey] then
                        skippedNamed = skippedNamed + 1
                    else
                        local presetName = ComboPresetName(enhList)
                        if not bp.EnhancementPresets[presetName] then
                            bp.EnhancementPresets[presetName] = {
                                Description = ComboUnitName(enhList, bp),
                                BuildIconSortPriority = 90,
                                Enhancements = enhList,
                                HelpText = ComboUnitName(enhList, bp),
                                SelectionPriority = 1,
                                SortCategory = 'SORTOTHER',
                                UnitName = ComboUnitName(enhList, bp),
                                HiddenInBuildMenu = true,
                            }
                            generated = generated + 1
                        end
                    end
                end
            end
        end
    end

    SPEW(string.format('SACU loadout: generated %d hidden Cybran combos, reused %d named presets', generated, skippedNamed))
end

--- Mark generated combo units so the construct grid can skip them while the
--- factory can still queue the ID (BUILTBYQUANTUMGATE stays on the unit).
--- @param all_bps BlueprintsTable
function MarkHiddenSacuLoadoutPresets(all_bps)
    if not all_bps or not all_bps.Unit then
        return
    end

    for id, bp in all_bps.Unit do
        local assigned = bp.EnhancementPresetAssigned
        if assigned and assigned.Name and string.sub(assigned.Name, 1, 6) == 'combo_' then
            local baseId = assigned.BaseBlueprintId
            if ComboFactionBaseIds[baseId] then
                bp.CategoriesHash = bp.CategoriesHash or {}
                bp.CategoriesHash['SACULOADOUTCOMBO'] = true
                bp.Categories = table.unhash(bp.CategoriesHash)
            end
        end
    end
end
