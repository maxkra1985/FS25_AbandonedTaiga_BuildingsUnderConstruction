MeatAnimalCondition = MeatAnimalCondition or {}

-- Feeding condition is intentionally kept OUTSIDE AnimalCluster serialization.
-- Never append fields to AnimalCluster save/read/write stream functions: doing so
-- changes the vanilla cluster format and can break all husbandries in a savegame.
MeatAnimalCondition.DEFAULT_FOOD_FACTOR = 1
MeatAnimalCondition.factorsByCluster = MeatAnimalCondition.factorsByCluster or setmetatable({}, {__mode = "k"})

local function clampFactor(value)
    return math.clamp(tonumber(value) or MeatAnimalCondition.DEFAULT_FOOD_FACTOR, 0, 1)
end

function MeatAnimalCondition.setClusterFoodFactor(cluster, factor)
    if cluster ~= nil then
        MeatAnimalCondition.factorsByCluster[cluster] = clampFactor(factor)
    end
end

function MeatAnimalCondition.getClusterFoodFactor(cluster)
    if cluster == nil then
        return MeatAnimalCondition.DEFAULT_FOOD_FACTOR
    end

    return clampFactor(MeatAnimalCondition.factorsByCluster[cluster])
end

-- Resolve the current husbandry food/production factor from the owner of the
-- cluster system. For clusters already in a trailer we fall back to the factor
-- previously attached in the weak table.
function MeatAnimalCondition.getSourceFoodFactor(cluster)
    if cluster == nil then
        return MeatAnimalCondition.DEFAULT_FOOD_FACTOR
    end

    local clusterSystem = cluster.clusterSystem
    local owner = clusterSystem ~= nil and clusterSystem.owner or nil

    if owner ~= nil and owner.spec_husbandry ~= nil then
        local factor = nil

        if owner.getProductionFactor ~= nil then
            factor = owner:getProductionFactor()
        end

        if factor == nil then
            factor = owner.spec_husbandry.productionFactor
        end

        if factor ~= nil then
            return clampFactor(factor)
        end
    end

    return MeatAnimalCondition.getClusterFoodFactor(cluster)
end

-- Only clone/merge are extended. Both wrappers preserve the vanilla return
-- values and do not alter savegame XML or network stream layouts.
if AnimalCluster ~= nil and not AnimalCluster.meatConditionRuntimePatched then
    AnimalCluster.meatConditionRuntimePatched = true

    AnimalCluster.clone = Utils.overwrittenFunction(AnimalCluster.clone, function(cluster, superFunc)
        local foodFactor = MeatAnimalCondition.getSourceFoodFactor(cluster)
        local clone = superFunc(cluster)

        if clone ~= nil then
            MeatAnimalCondition.setClusterFoodFactor(clone, foodFactor)
        end

        return clone
    end)

    AnimalCluster.merge = Utils.overwrittenFunction(AnimalCluster.merge, function(cluster, superFunc, otherCluster)
        local ownNumAnimals = cluster ~= nil and (cluster.numAnimals or 0) or 0
        local otherNumAnimals = otherCluster ~= nil and (otherCluster.numAnimals or 0) or 0
        local ownFactor = MeatAnimalCondition.getClusterFoodFactor(cluster)
        local otherFactor = MeatAnimalCondition.getClusterFoodFactor(otherCluster)

        local result = superFunc(cluster, otherCluster)

        if result and cluster ~= nil then
            local total = ownNumAnimals + otherNumAnimals
            if total > 0 then
                MeatAnimalCondition.setClusterFoodFactor(cluster, (ownFactor * ownNumAnimals + otherFactor * otherNumAnimals) / total)
            end
        end

        return result
    end)
end
