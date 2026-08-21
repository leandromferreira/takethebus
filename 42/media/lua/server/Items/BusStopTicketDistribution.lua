-- BusStopTicketDistribution.lua
-- Adds the Bus Ticket item to a handful of existing loot distributions
-- (schools, offices, houses, and zombies) instead of touching vanilla's own
-- Distributions.lua / ProceduralDistributions.lua files directly.

-- Representative container/procedural-list keys, grouped by the
-- schools/offices/houses categories requested for this item.
local BUILDING_LISTS = {
    -- Schools
    "ClassroomDesk", "ClassroomMisc", "ClassroomShelves",
    -- Offices
    "DeskGeneric", "FilingCabinetGeneric",
    -- Houses
    "BedroomDresser", "BedroomSidetable", "LivingRoomShelf", "LivingRoomSideTable",
}

-- Zombie corpse loot lives in Distributions.lua's "all" room block, not in
-- ProceduralDistributions.list — a separate table keyed by container name
-- (inventorymale/inventoryfemale = any zombie) or by outfit
-- ("Outfit_<Name>" = only zombies wearing that outfit). Commuter-type
-- outfits are picked to match the schools/offices theme above.
local ZOMBIE_LISTS = {
    "inventorymale", "inventoryfemale",                       -- any zombie
    "Outfit_OfficeWorker", "Outfit_OfficeWorkerSkirt",         -- office commuters
    "Outfit_Student", "Outfit_Teacher",                        -- school commuters
}

local function injectItem(dist, listName, itemType, rate)
    if dist and dist.items then
        table.insert(dist.items, itemType)
        table.insert(dist.items, rate)
        return true
    end
    print("[BusStop] WARNING: distribution list '" .. listName .. "' not found — skipped")
    return false
end

-- Events.OnPreDistributionMerge fires after vanilla has populated
-- ProceduralDistributions.list but before it's finalized/merged, which is
-- the documented safe point for a mod to inject extra items there.
local function addTicketToBuildingLoot()
    local sv = SandboxVars.BusStop or {}
    if sv.SpawnTicketInBuildings == false then return end

    local rate = tonumber(sv.TicketBuildingSpawnRate)
    if not rate or rate <= 0 then return end

    local itemType = sv.TicketItem or "BusStop.BusTicket"

    local added = 0
    for _, listName in ipairs(BUILDING_LISTS) do
        if injectItem(ProceduralDistributions.list[listName], listName, itemType, rate) then
            added = added + 1
        end
    end
    print("[BusStop] BusTicket added to " .. added .. "/" .. #BUILDING_LISTS .. " building loot distribution(s) at rate " .. tostring(rate))
end

-- Distributions.lua's "all" room table (and therefore zombie corpse loot)
-- only exists as SuburbsDistributions after the merge runs, so this has to
-- wait for OnPostDistributionMerge rather than OnPreDistributionMerge.
local function addTicketToZombieLoot()
    local sv = SandboxVars.BusStop or {}
    if sv.SpawnTicketOnZombies == false then return end

    local rate = tonumber(sv.TicketZombieSpawnRate)
    if not rate or rate <= 0 then return end

    if not SuburbsDistributions or not SuburbsDistributions.all then
        print("[BusStop] WARNING: SuburbsDistributions.all not available — zombie loot skipped")
        return
    end

    local itemType = sv.TicketItem or "BusStop.BusTicket"

    local added = 0
    for _, listName in ipairs(ZOMBIE_LISTS) do
        if injectItem(SuburbsDistributions.all[listName], listName, itemType, rate) then
            added = added + 1
        end
    end
    print("[BusStop] BusTicket added to " .. added .. "/" .. #ZOMBIE_LISTS .. " zombie loot distribution(s) at rate " .. tostring(rate))
end

Events.OnPreDistributionMerge.Add(addTicketToBuildingLoot)
Events.OnPostDistributionMerge.Add(addTicketToZombieLoot)
