PlaceableMeatAnimalInput = {}

PlaceableMeatAnimalInput.MOD_NAME = g_currentModName
PlaceableMeatAnimalInput.SPEC_NAME = string.format("%s.meatAnimalInput", g_currentModName)
PlaceableMeatAnimalInput.SPEC = string.format("spec_%s", PlaceableMeatAnimalInput.SPEC_NAME)

local specKey = PlaceableMeatAnimalInput.SPEC

function PlaceableMeatAnimalInput.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableProductionPoint, specializations)
end

function PlaceableMeatAnimalInput.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalCalculateWeight", PlaceableMeatAnimalInput.meatAnimalCalculateWeight)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalCanAcceptCluster", PlaceableMeatAnimalInput.meatAnimalCanAcceptCluster)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalAcceptCluster", PlaceableMeatAnimalInput.meatAnimalAcceptCluster)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalGetMaxAcceptableAnimals", PlaceableMeatAnimalInput.meatAnimalGetMaxAcceptableAnimals)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalGetStorageInfo", PlaceableMeatAnimalInput.meatAnimalGetStorageInfo)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalAppendQuality", PlaceableMeatAnimalInput.meatAnimalAppendQuality)
    SpecializationUtil.registerFunction(placeableType, "meatAnimalConsumeQuality", PlaceableMeatAnimalInput.meatAnimalConsumeQuality)

    -- Minimal husbandry-like information API used only by the stock AnimalScreen layout.
    SpecializationUtil.registerFunction(placeableType, "setAnimalScreenController", PlaceableMeatAnimalInput.setAnimalScreenController)
    SpecializationUtil.registerFunction(placeableType, "getConditionInfos", PlaceableMeatAnimalInput.getEmptyInfo)
    SpecializationUtil.registerFunction(placeableType, "getFoodInfos", PlaceableMeatAnimalInput.getEmptyInfo)
    SpecializationUtil.registerFunction(placeableType, "getAnimalInfos", PlaceableMeatAnimalInput.getEmptyInfo)
    SpecializationUtil.registerFunction(placeableType, "getAnimalDescription", PlaceableMeatAnimalInput.getAnimalDescription)
end

function PlaceableMeatAnimalInput.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableMeatAnimalInput)
    SpecializationUtil.registerEventListener(placeableType, "onPostLoad", PlaceableMeatAnimalInput)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableMeatAnimalInput)
end

function PlaceableMeatAnimalInput.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("MeatAnimalInput")

    local key = basePath .. ".meatAnimalInput"
    schema:register(XMLValueType.NODE_INDEX, key .. "#triggerNode", "Animal trailer trigger")
    schema:register(XMLValueType.STRING, key .. "#moveButtonText", "Optional existing l10n key for move button")
    schema:register(XMLValueType.STRING, key .. "#unloadConfirmationText", "Optional existing l10n key for confirmation")
    schema:register(XMLValueType.STRING, key .. "#unloadSuccessText", "Optional existing l10n key for success")

    schema:register(XMLValueType.STRING, key .. ".animal(?)#type", "Animal type name")
    schema:register(XMLValueType.STRING, key .. ".animal(?)#fillType", "Input fill type representing kilograms")
    schema:register(XMLValueType.FLOAT, key .. ".animal(?)#healthWeightPenalty", "Maximum relative live-weight penalty caused by health", 0.20)
    schema:register(XMLValueType.FLOAT, key .. ".animal(?)#foodWeightPenalty", "Maximum relative live-weight penalty caused by feeding", 0.25)
    schema:register(XMLValueType.FLOAT, key .. ".animal(?)#minWeightFactor", "Absolute minimum final live-weight factor after all penalties", 0.05)
    schema:register(XMLValueType.FLOAT, key .. ".animal(?)#healthYieldPenalty", "Additional maximum yield penalty for condition-sensitive outputs", 0.10)
    schema:register(XMLValueType.FLOAT, key .. ".animal(?)#foodYieldPenalty", "Additional maximum yield penalty for condition-sensitive outputs", 0.10)
    schema:register(XMLValueType.FLOAT, key .. ".animal(?)#minYieldFactor", "Minimum condition-sensitive output factor", 0.70)

    schema:register(XMLValueType.FLOAT, key .. ".animal(?).weight(?)#age", "Age in months")
    schema:register(XMLValueType.FLOAT, key .. ".animal(?).weight(?)#kg", "Base live weight in kilograms")
    schema:register(XMLValueType.STRING, key .. ".animal(?).subType(?)#name", "Animal subtype name")
    schema:register(XMLValueType.FLOAT, key .. ".animal(?).subType(?)#scale", "Subtype weight multiplier", 1)
    schema:register(XMLValueType.STRING, key .. ".animal(?).output(?)#fillType", "Output fill type")
    schema:register(XMLValueType.BOOL, key .. ".animal(?).output(?)#conditionAffected", "Apply extra health/feed yield factor", false)

    schema:setXMLSpecializationType()
end

function PlaceableMeatAnimalInput.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("MeatAnimalInput")
    schema:register(XMLValueType.STRING, basePath .. ".qualityBatch(?)#fillType", "Animal input fill type")
    schema:register(XMLValueType.FLOAT, basePath .. ".qualityBatch(?)#kg", "Remaining kilograms in quality batch")
    schema:register(XMLValueType.FLOAT, basePath .. ".qualityBatch(?)#yieldFactor", "Condition-sensitive output factor")
    schema:setXMLSpecializationType()
end

local function getTranslatedOptional(xmlFile, key, customEnvironment)
    local l10nKey = xmlFile:getString(key)
    if l10nKey == nil then
        return nil
    end

    return g_i18n:getText(l10nKey, customEnvironment)
end

function PlaceableMeatAnimalInput:onLoad(savegame)
    local spec = self[specKey]
    spec.animalsByTypeIndex = {}
    spec.animalsBySubTypeIndex = {}
    spec.animalsByInputFillType = {}
    spec.outputRules = {}
    spec.qualityQueues = {}
    spec.pendingYieldFactor = {}
    spec.animalLoadingTrigger = nil
    spec.animalScreenController = nil

    local baseKey = "placeable.meatAnimalInput"
    spec.triggerNode = self.xmlFile:getValue(baseKey .. "#triggerNode", nil, self.components, self.i3dMappings)
    spec.moveButtonText = getTranslatedOptional(self.xmlFile, baseKey .. "#moveButtonText", self.customEnvironment)
    spec.unloadConfirmationText = getTranslatedOptional(self.xmlFile, baseKey .. "#unloadConfirmationText", self.customEnvironment)
    spec.unloadSuccessText = getTranslatedOptional(self.xmlFile, baseKey .. "#unloadSuccessText", self.customEnvironment)

    local animalSystem = g_currentMission.animalSystem

    self.xmlFile:iterate(baseKey .. ".animal", function(_, animalKey)
        local typeName = self.xmlFile:getString(animalKey .. "#type")
        local animalType = typeName ~= nil and animalSystem:getTypeByName(typeName) or nil
        local fillTypeName = self.xmlFile:getString(animalKey .. "#fillType")
        local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil

        if animalType == nil then
            Logging.xmlError(self.xmlFile, "Unknown animal type '%s' in meatAnimalInput", tostring(typeName))
            return
        end

        if fillTypeIndex == nil then
            Logging.xmlError(self.xmlFile, "Unknown fillType '%s' in meatAnimalInput", tostring(fillTypeName))
            return
        end

        local data = {
            typeIndex = animalType.typeIndex,
            typeName = typeName,
            fillTypeIndex = fillTypeIndex,
            weightPoints = {},
            subTypeScales = {},
            healthWeightPenalty = math.clamp(self.xmlFile:getValue(animalKey .. "#healthWeightPenalty", 0.20), 0, 1),
            foodWeightPenalty = math.clamp(self.xmlFile:getValue(animalKey .. "#foodWeightPenalty", 0.25), 0, 1),
            minWeightFactor = math.clamp(self.xmlFile:getValue(animalKey .. "#minWeightFactor", 0.05), 0.01, 1),
            healthYieldPenalty = math.clamp(self.xmlFile:getValue(animalKey .. "#healthYieldPenalty", 0.10), 0, 1),
            foodYieldPenalty = math.clamp(self.xmlFile:getValue(animalKey .. "#foodYieldPenalty", 0.10), 0, 1),
            minYieldFactor = math.clamp(self.xmlFile:getValue(animalKey .. "#minYieldFactor", 0.70), 0.05, 1)
        }

        self.xmlFile:iterate(animalKey .. ".weight", function(_, weightKey)
            table.insert(data.weightPoints, {
                age = math.max(self.xmlFile:getValue(weightKey .. "#age", 0), 0),
                kg = math.max(self.xmlFile:getValue(weightKey .. "#kg", 0), 0)
            })
        end)

        table.sort(data.weightPoints, function(a, b)
            return a.age < b.age
        end)

        self.xmlFile:iterate(animalKey .. ".subType", function(_, subTypeKey)
            local subTypeName = self.xmlFile:getString(subTypeKey .. "#name")
            local subTypeIndex = subTypeName ~= nil and animalSystem:getSubTypeIndexByName(subTypeName) or nil
            if subTypeIndex ~= nil then
                local scale = math.max(self.xmlFile:getValue(subTypeKey .. "#scale", 1), 0.1)
                data.subTypeScales[subTypeIndex] = scale
                spec.animalsBySubTypeIndex[subTypeIndex] = data
            end
        end)

        -- Every subtype of the animal type is supported, even if no explicit scale is listed.
        for _, subTypeIndex in ipairs(animalType.subTypes) do
            if spec.animalsBySubTypeIndex[subTypeIndex] == nil then
                spec.animalsBySubTypeIndex[subTypeIndex] = data
            end
        end

        self.xmlFile:iterate(animalKey .. ".output", function(_, outputKey)
            local outputFillTypeName = self.xmlFile:getString(outputKey .. "#fillType")
            local outputFillTypeIndex = outputFillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(outputFillTypeName) or nil
            if outputFillTypeIndex ~= nil then
                spec.outputRules[outputFillTypeIndex] = {
                    sourceInputFillType = fillTypeIndex,
                    conditionAffected = self.xmlFile:getValue(outputKey .. "#conditionAffected", false)
                }
            end
        end)

        spec.animalsByTypeIndex[animalType.typeIndex] = data
        spec.animalsByInputFillType[fillTypeIndex] = data
        spec.qualityQueues[fillTypeIndex] = {}
    end)
end

function PlaceableMeatAnimalInput:onPostLoad(savegame)
    local spec = self[specKey]
    local productionPoint = self.spec_productionPoint ~= nil and self.spec_productionPoint.productionPoint or nil

    if productionPoint == nil then
        Logging.error("[%s] meatAnimalInput requires a valid vanilla ProductionPoint", PlaceableMeatAnimalInput.MOD_NAME)
        self:setLoadingState(PlaceableLoadingState.ERROR)
        return
    end

    spec.productionPoint = productionPoint
    spec.storage = productionPoint.storage

    if spec.storage == nil then
        Logging.error("[%s] meatAnimalInput ProductionPoint has no storage", PlaceableMeatAnimalInput.MOD_NAME)
        self:setLoadingState(PlaceableLoadingState.ERROR)
        return
    end

    for fillTypeIndex, _ in pairs(spec.animalsByInputFillType) do
        if not spec.storage:getIsFillTypeSupported(fillTypeIndex) then
            Logging.error("[%s] meatAnimalInput storage does not support input fillType '%s'", PlaceableMeatAnimalInput.MOD_NAME, g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex))
            self:setLoadingState(PlaceableLoadingState.ERROR)
            return
        end
    end

    -- Keep the quality queue aligned with persisted storage. Old saves or manually edited saves
    -- get a neutral batch for any kilograms that have no quality metadata.
    for fillTypeIndex, queue in pairs(spec.qualityQueues) do
        local queuedKg = 0
        for _, batch in ipairs(queue) do
            queuedKg = queuedKg + batch.kg
        end

        local storedKg = spec.storage:getFillLevel(fillTypeIndex) or 0
        if storedKg > queuedKg + 0.001 then
            table.insert(queue, {kg = storedKg - queuedKg, yieldFactor = 1})
        elseif queuedKg > storedKg + 0.001 then
            self:meatAnimalConsumeQuality(fillTypeIndex, queuedKg - storedKg)
        end
    end

    local oldSetFillLevel = spec.storage.setFillLevel
    spec.storage.setFillLevel = Utils.overwrittenFunction(oldSetFillLevel, function(storage, superFunc, fillLevel, fillType, fillInfo)
        local oldFillLevel = storage:getFillLevel(fillType) or 0
        local outputRule = spec.outputRules[fillType]

        -- Vanilla ProductionPoint computes a nominal output. Reduce only outputs explicitly
        -- marked as condition-sensitive; bones/blood remain tied solely to kilograms consumed.
        if outputRule ~= nil and outputRule.conditionAffected and fillLevel > oldFillLevel then
            local factor = spec.pendingYieldFactor[outputRule.sourceInputFillType] or 1
            fillLevel = oldFillLevel + (fillLevel - oldFillLevel) * factor
        end

        superFunc(storage, fillLevel, fillType, fillInfo)

        local newFillLevel = storage:getFillLevel(fillType) or 0
        if spec.animalsByInputFillType[fillType] ~= nil and newFillLevel < oldFillLevel - 0.0001 then
            spec.pendingYieldFactor[fillType] = self:meatAnimalConsumeQuality(fillType, oldFillLevel - newFillLevel)
        end
    end)

    if spec.triggerNode ~= nil and self.isClient then
        local trigger = AnimalLoadingTrigger.new(self.isServer, self.isClient)
        trigger.husbandry = self
        trigger.isDealer = false
        trigger.triggerNode = spec.triggerNode
        trigger.title = self:getName()
        trigger.animalTypes = {}

        for typeIndex, _ in pairs(spec.animalsByTypeIndex) do
            table.insert(trigger.animalTypes, typeIndex)
        end

        trigger.openAnimalMenu = function(loadingTrigger)
            if self.spec_productionPoint ~= nil and self.spec_productionPoint.isFinalized == false then
                return
            end

            if loadingTrigger.loadingVehicle == nil or loadingTrigger.loadingVehicle:getNumOfAnimals() <= 0 then
                return
            end

            local animalScreen = g_animalScreen
            local controller = AnimalScreenTrailerMeatPlant.new(self, loadingTrigger.loadingVehicle)
            self:setAnimalScreenController(controller)

            controller.plantName = self:getName()
            controller.moveButtonText = spec.moveButtonText
            controller.unloadConfirmationText = spec.unloadConfirmationText
            controller.unloadSuccessText = spec.unloadSuccessText
            controller:init()

            animalScreen.isDealer = false
            animalScreen.controller = controller
            controller:setAnimalsChangedCallback(animalScreen.onAnimalsChanged, animalScreen)
            controller:setActionTypeCallback(animalScreen.onActionTypeChanged, animalScreen)
            controller:setSourceActionFinishedCallback(animalScreen.onSourceActionFinished, animalScreen)
            controller:setTargetActionFinishedCallback(animalScreen.onTargetActionFinished, animalScreen)
            controller:setErrorCallback(animalScreen.onError, animalScreen)

            animalScreen.sourceList:reloadData(true)
            g_gui:showGui("AnimalScreen")
            loadingTrigger.activatedTarget = loadingTrigger.loadingVehicle
        end

        trigger.activatable.getIsActivatable = function(activatable)
            local owner = activatable.owner or trigger
            if self.spec_productionPoint ~= nil and self.spec_productionPoint.isFinalized == false then
                return false
            end

            if not owner.isEnabled or g_gui.currentGui ~= nil or owner.loadingVehicle == nil then
                return false
            end

            if owner.loadingVehicle:getNumOfAnimals() <= 0 then
                return false
            end

            local rootVehicle = owner.loadingVehicle.rootVehicle
            local inRange = owner.isPlayerInRange or rootVehicle == g_localPlayer:getCurrentVehicle()
            return inRange and self:getOwnerFarmId() == g_currentMission:getFarmId() and g_currentMission:getHasPlayerPermission("tradeAnimals")
        end

        addTrigger(trigger.triggerNode, "triggerCallback", trigger)
        trigger.isEnabled = true
        spec.animalLoadingTrigger = trigger
    end
end

function PlaceableMeatAnimalInput:onDelete()
    local spec = self[specKey]
    if spec ~= nil and spec.animalLoadingTrigger ~= nil then
        spec.animalLoadingTrigger:delete()
        spec.animalLoadingTrigger = nil
    end
end

function PlaceableMeatAnimalInput:setAnimalScreenController(controller)
    self[specKey].animalScreenController = controller
end

function PlaceableMeatAnimalInput:getEmptyInfo()
    return {}
end

function PlaceableMeatAnimalInput:getAnimalDescription(cluster)
    return ""
end

local function interpolateWeight(points, age)
    if points == nil or #points == 0 then
        return 0
    end

    if age <= points[1].age then
        return points[1].kg
    end

    for i = 2, #points do
        local prev = points[i - 1]
        local nextPoint = points[i]
        if age <= nextPoint.age then
            local range = nextPoint.age - prev.age
            if range <= 0 then
                return nextPoint.kg
            end

            local t = (age - prev.age) / range
            return prev.kg + (nextPoint.kg - prev.kg) * t
        end
    end

    return points[#points].kg
end

function PlaceableMeatAnimalInput:meatAnimalCalculateWeight(cluster, numAnimals)
    if cluster == nil then
        return 0, 0, 1, 1
    end

    local spec = self[specKey]
    local data = spec.animalsBySubTypeIndex[cluster:getSubTypeIndex()]
    if data == nil then
        return 0, 0, 1, 1
    end

    local age = cluster:getAge() or 0
    local baseWeight = interpolateWeight(data.weightPoints, age)
    local subTypeScale = data.subTypeScales[cluster:getSubTypeIndex()] or 1
    baseWeight = baseWeight * subTypeScale

    local health = math.clamp((cluster.health or 0) / 100, 0, 1)
    local food = MeatAnimalCondition.getClusterFoodFactor(cluster)

    -- Condition factor: with the XML defaults a completely unhealthy AND starving
    -- animal reaches 5%. Health and feeding remain independent contributors.
    local conditionFactor = 1 - data.healthWeightPenalty * (1 - health) - data.foodWeightPenalty * (1 - food)
    conditionFactor = math.clamp(conditionFactor, data.minWeightFactor, 1)

    -- Age is represented entirely by the weight curve. The curve may rise quickly,
    -- continue rising slowly and later decline. There is no separate old-age penalty,
    -- so age can never be applied twice to the same animal.
    local weightFactor = conditionFactor

    local perAnimalKg = math.max(baseWeight * weightFactor, 0.01)
    local count = math.max(numAnimals or 1, 0)
    local totalKg = perAnimalKg * count

    local yieldFactor = 1 - data.healthYieldPenalty * (1 - health) - data.foodYieldPenalty * (1 - food)
    yieldFactor = math.clamp(yieldFactor, data.minYieldFactor, 1)

    return perAnimalKg, totalKg, weightFactor, yieldFactor, baseWeight, conditionFactor
end

function PlaceableMeatAnimalInput:meatAnimalGetStorageInfo(subTypeIndex)
    local spec = self[specKey]
    local data = spec.animalsBySubTypeIndex[subTypeIndex]
    if data == nil or spec.storage == nil then
        return nil, 0, 0
    end

    local fillType = g_fillTypeManager:getFillTypeByIndex(data.fillTypeIndex)
    return fillType ~= nil and fillType.title or data.typeName, spec.storage:getFillLevel(data.fillTypeIndex) or 0, spec.storage:getCapacity(data.fillTypeIndex) or 0
end

function PlaceableMeatAnimalInput:meatAnimalGetMaxAcceptableAnimals(cluster)
    if self.spec_productionPoint ~= nil and self.spec_productionPoint.isFinalized == false then
        return 0
    end

    if cluster == nil then
        return 0
    end

    local spec = self[specKey]
    local data = spec.animalsBySubTypeIndex[cluster:getSubTypeIndex()]
    if data == nil or spec.storage == nil then
        return 0
    end

    local perAnimalKg = self:meatAnimalCalculateWeight(cluster, 1)
    if perAnimalKg <= 0 then
        return 0
    end

    local freeCapacity = spec.storage:getFreeCapacity(data.fillTypeIndex) or 0
    return math.max(math.floor((freeCapacity + 0.0001) / perAnimalKg), 0)
end

function PlaceableMeatAnimalInput:meatAnimalCanAcceptCluster(cluster, numAnimals)
    if self.spec_productionPoint ~= nil and self.spec_productionPoint.isFinalized == false then
        return false, MeatAnimalMoveEvent.ERROR_TARGET_MISSING
    end

    local spec = self[specKey]
    local data = cluster ~= nil and spec.animalsBySubTypeIndex[cluster:getSubTypeIndex()] or nil
    if data == nil then
        return false, MeatAnimalMoveEvent.ERROR_ANIMAL_NOT_SUPPORTED
    end

    if spec.storage == nil then
        return false, MeatAnimalMoveEvent.ERROR_INTERNAL
    end

    local _, totalKg = self:meatAnimalCalculateWeight(cluster, numAnimals)
    if totalKg <= 0 then
        return false, MeatAnimalMoveEvent.ERROR_INTERNAL
    end

    local freeCapacity = spec.storage:getFreeCapacity(data.fillTypeIndex) or 0
    if freeCapacity + 0.001 < totalKg then
        return false, MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_SPACE
    end

    return true, nil
end

function PlaceableMeatAnimalInput:meatAnimalAppendQuality(fillTypeIndex, kg, yieldFactor)
    local spec = self[specKey]
    local queue = spec.qualityQueues[fillTypeIndex]
    if queue == nil or kg <= 0 then
        return
    end

    yieldFactor = math.clamp(yieldFactor or 1, 0.05, 1)
    local last = queue[#queue]
    if last ~= nil and math.abs(last.yieldFactor - yieldFactor) < 0.0005 then
        last.kg = last.kg + kg
    else
        table.insert(queue, {kg = kg, yieldFactor = yieldFactor})
    end
end

function PlaceableMeatAnimalInput:meatAnimalConsumeQuality(fillTypeIndex, kg)
    local spec = self[specKey]
    local queue = spec.qualityQueues[fillTypeIndex]
    if queue == nil or kg <= 0 then
        return 1
    end

    local remaining = kg
    local weighted = 0
    local consumed = 0

    while remaining > 0.0001 and #queue > 0 do
        local batch = queue[1]
        local take = math.min(remaining, batch.kg)
        weighted = weighted + take * batch.yieldFactor
        consumed = consumed + take
        remaining = remaining - take
        batch.kg = batch.kg - take

        if batch.kg <= 0.0001 then
            table.remove(queue, 1)
        end
    end

    -- Missing metadata (e.g. an upgraded save) is neutral quality.
    if remaining > 0.0001 then
        weighted = weighted + remaining
        consumed = consumed + remaining
    end

    if consumed <= 0 then
        return 1
    end

    return math.clamp(weighted / consumed, 0.05, 1)
end

function PlaceableMeatAnimalInput:meatAnimalAcceptCluster(cluster, numAnimals)
    local canAccept, reason = self:meatAnimalCanAcceptCluster(cluster, numAnimals)
    if not canAccept then
        return false, reason
    end

    local spec = self[specKey]
    local data = spec.animalsBySubTypeIndex[cluster:getSubTypeIndex()]
    local _, totalKg, weightFactor, yieldFactor, baseWeight, conditionFactor = self:meatAnimalCalculateWeight(cluster, numAnimals)
    local fillTypeIndex = data.fillTypeIndex
    local oldFillLevel = spec.storage:getFillLevel(fillTypeIndex) or 0

    spec.storage:setFillLevel(oldFillLevel + totalKg, fillTypeIndex, nil)
    local newFillLevel = spec.storage:getFillLevel(fillTypeIndex) or 0
    local addedKg = newFillLevel - oldFillLevel

    if addedKg + 0.001 < totalKg then
        -- Server-side race or unexpected capacity change: rollback instead of losing animals.
        spec.storage:setFillLevel(oldFillLevel, fillTypeIndex, nil)
        return false, MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_SPACE
    end

    self:meatAnimalAppendQuality(fillTypeIndex, addedKg, yieldFactor)

    local subType = g_currentMission.animalSystem:getSubTypeByIndex(cluster:getSubTypeIndex())
    Logging.info(
        "[%s] Meat input: %d x %s, age=%.1f months, health=%.0f%%, food=%.0f%% -> %.1f kg (baseWeight %.2f kg, conditionFactor %.3f, weightFactor %.3f, yieldFactor %.3f)",
        PlaceableMeatAnimalInput.MOD_NAME,
        numAnimals,
        subType ~= nil and subType.name or tostring(cluster:getSubTypeIndex()),
        cluster:getAge() or 0,
        cluster.health or 0,
        MeatAnimalCondition.getClusterFoodFactor(cluster) * 100,
        addedKg,
        baseWeight,
        conditionFactor,
        weightFactor,
        yieldFactor
    )

    return true, addedKg
end

function PlaceableMeatAnimalInput:loadFromXMLFile(xmlFile, key)
    local spec = self[specKey]
    if spec == nil then
        return
    end

    spec.qualityQueues = spec.qualityQueues or {}

    xmlFile:iterate(key .. ".qualityBatch", function(_, batchKey)
        local fillTypeName = xmlFile:getString(batchKey .. "#fillType")
        local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil
        local kg = xmlFile:getValue(batchKey .. "#kg", 0)
        local yieldFactor = xmlFile:getValue(batchKey .. "#yieldFactor", 1)

        if fillTypeIndex ~= nil and spec.animalsByInputFillType[fillTypeIndex] ~= nil and kg > 0 then
            spec.qualityQueues[fillTypeIndex] = spec.qualityQueues[fillTypeIndex] or {}
            table.insert(spec.qualityQueues[fillTypeIndex], {kg = kg, yieldFactor = math.clamp(yieldFactor, 0.05, 1)})
        end
    end)
end

function PlaceableMeatAnimalInput:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[specKey]
    if spec == nil then
        return
    end

    local index = 0
    for fillTypeIndex, queue in pairs(spec.qualityQueues) do
        local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
        if fillTypeName ~= nil then
            for _, batch in ipairs(queue) do
                if batch.kg > 0.0001 then
                    local batchKey = string.format("%s.qualityBatch(%d)", key, index)
                    xmlFile:setString(batchKey .. "#fillType", fillTypeName)
                    xmlFile:setFloat(batchKey .. "#kg", batch.kg)
                    xmlFile:setFloat(batchKey .. "#yieldFactor", batch.yieldFactor)
                    index = index + 1
                end
            end
        end
    end
end
