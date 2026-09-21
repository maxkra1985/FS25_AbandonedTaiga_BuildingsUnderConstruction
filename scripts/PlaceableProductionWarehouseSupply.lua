PlaceableProductionWarehouseSupply = {}

PlaceableProductionWarehouseSupply.DEBUG = true
PlaceableProductionWarehouseSupply.VERSION = "0.2.0.0"
PlaceableProductionWarehouseSupply.EPSILON = 0.001

local function debugLog(formatString, ...)
    if PlaceableProductionWarehouseSupply.DEBUG then
        Logging.info("[ProductionWarehouseSupply] " .. formatString, ...)
    end
end

local function normalizeFilename(filename)
    if filename == nil then
        return nil
    end

    return string.lower(string.gsub(filename, "\\", "/"))
end

function PlaceableProductionWarehouseSupply.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableProductionPoint, specializations)
        and SpecializationUtil.hasSpecialization(PlaceableObjectStorage, specializations)
end

function PlaceableProductionWarehouseSupply.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyGetProductionKey", PlaceableProductionWarehouseSupply.productionWarehouseSupplyGetProductionKey)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyGetCyclesPerHour", PlaceableProductionWarehouseSupply.productionWarehouseSupplyGetCyclesPerHour)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyReadRecipes", PlaceableProductionWarehouseSupply.productionWarehouseSupplyReadRecipes)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyEnqueue", PlaceableProductionWarehouseSupply.productionWarehouseSupplyEnqueue)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyFinishCurrentJob", PlaceableProductionWarehouseSupply.productionWarehouseSupplyFinishCurrentJob)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyGetPalletInfo", PlaceableProductionWarehouseSupply.productionWarehouseSupplyGetPalletInfo)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyFindStoredPallet", PlaceableProductionWarehouseSupply.productionWarehouseSupplyFindStoredPallet)
    SpecializationUtil.registerFunction(placeableType, "productionWarehouseSupplyProcessQueue", PlaceableProductionWarehouseSupply.productionWarehouseSupplyProcessQueue)
end

function PlaceableProductionWarehouseSupply.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableProductionWarehouseSupply)
    SpecializationUtil.registerEventListener(placeableType, "onHourChanged", PlaceableProductionWarehouseSupply)
end

function PlaceableProductionWarehouseSupply.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getNeedHourChanged", PlaceableProductionWarehouseSupply.getNeedHourChanged)
end

function PlaceableProductionWarehouseSupply:getNeedHourChanged(superFunc)
    return true
end

function PlaceableProductionWarehouseSupply:onLoad(savegame)
    self.productionWarehouseSupply = {
        recipesById = {},
        palletInfoCache = {},
        queue = {},
        pendingByFillType = {},
        busy = false
    }

    -- All stock manipulation is server authoritative. Clients only receive the
    -- normal ProductionPoint / ObjectStorage synchronization from the game.
    if not self.isServer then
        return
    end

    self:productionWarehouseSupplyReadRecipes()

    local recipeCount = 0
    for _ in pairs(self.productionWarehouseSupply.recipesById) do
        recipeCount = recipeCount + 1
    end
    debugLog("loaded v%s, recipes=%d", PlaceableProductionWarehouseSupply.VERSION, recipeCount)
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyGetProductionKey()
    local productionKey = "placeable.productionPoint"

    if self.configurations ~= nil and self.configurations["productionPoint"] ~= nil then
        local configurationIndex = self.configurations["productionPoint"]
        local configurationKey = string.format(
            "placeable.productionPoint.productionPointConfigurations.productionPointConfiguration(%d).productionPoint",
            configurationIndex - 1
        )

        if self.xmlFile:hasProperty(configurationKey) then
            productionKey = configurationKey
        end
    end

    return productionKey
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyGetCyclesPerHour(productionKey)
    local cyclesPerHour = self.xmlFile:getValue(productionKey .. "#cyclesPerHour")
    if cyclesPerHour ~= nil then
        return cyclesPerHour
    end

    local cyclesPerMinute = self.xmlFile:getValue(productionKey .. "#cyclesPerMinute")
    if cyclesPerMinute ~= nil then
        return cyclesPerMinute * 60
    end

    local cyclesPerMonth = self.xmlFile:getValue(productionKey .. "#cyclesPerMonth")
    if cyclesPerMonth ~= nil then
        -- This is a nominal one-day / 24-hour conversion. It is only a fallback;
        -- cyclesPerHour is preferable for this specialization because the target
        -- reserve itself is defined as "one hour of recipe demand".
        return cyclesPerMonth / 24
    end

    -- GIANTS production defaults correspond to 60 cycles/hour.
    return 60
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyReadRecipes()
    local data = self.productionWarehouseSupply
    local productionRootKey = self:productionWarehouseSupplyGetProductionKey()
    local productionIndex = 0

    local function addHourlyDemand(recipe, productionId, fillTypeName, amountPerCycle, cyclesPerHour, sourceKind)
        local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil

        if fillTypeIndex ~= nil and fillTypeIndex ~= FillType.UNKNOWN and amountPerCycle > 0 then
            local hourlyAmount = amountPerCycle * cyclesPerHour
            recipe.inputs[fillTypeIndex] = (recipe.inputs[fillTypeIndex] or 0) + hourlyAmount

            debugLog(
                "recipe '%s': %s %s %.3f/cycle -> %.3f/hour",
                tostring(productionId),
                tostring(sourceKind),
                tostring(fillTypeName),
                amountPerCycle,
                hourlyAmount
            )
        elseif fillTypeName ~= nil then
            Logging.warning(
                "[ProductionWarehouseSupply] Unknown/invalid %s fillType '%s' in production '%s'",
                tostring(sourceKind),
                tostring(fillTypeName),
                tostring(productionId)
            )
        end
    end

    while true do
        local productionKey = string.format("%s.productions.production(%d)", productionRootKey, productionIndex)
        if not self.xmlFile:hasProperty(productionKey) then
            break
        end

        local productionId = self.xmlFile:getValue(productionKey .. "#id")
        local cyclesPerHour = self:productionWarehouseSupplyGetCyclesPerHour(productionKey)

        if productionId ~= nil and cyclesPerHour > 0 then
            local recipe = {
                id = productionId,
                cyclesPerHour = cyclesPerHour,
                inputs = {}
            }

            local inputIndex = 0
            while true do
                local inputKey = string.format("%s.inputs.input(%d)", productionKey, inputIndex)
                if not self.xmlFile:hasProperty(inputKey) then
                    break
                end

                addHourlyDemand(
                    recipe,
                    productionId,
                    self.xmlFile:getValue(inputKey .. "#fillType"),
                    self.xmlFile:getValue(inputKey .. "#amount", 0),
                    cyclesPerHour,
                    "input"
                )

                inputIndex = inputIndex + 1
            end

            -- Optional boosters are not mandatory for ProductionPoint itself, but
            -- the warehouse policy intentionally tries to keep one nominal hour of
            -- them available as well. If the ObjectStorage cannot store the boost
            -- fillType (e.g. WATER), onHourChanged simply skips the transfer.
            local boostIndex = 0
            while true do
                local boostKey = string.format("%s.inputs.inputBoost(%d)", productionKey, boostIndex)
                if not self.xmlFile:hasProperty(boostKey) then
                    break
                end

                addHourlyDemand(
                    recipe,
                    productionId,
                    self.xmlFile:getValue(boostKey .. "#fillType"),
                    self.xmlFile:getValue(boostKey .. "#amountPerCycle", 0),
                    cyclesPerHour,
                    "inputBoost"
                )

                boostIndex = boostIndex + 1
            end

            data.recipesById[productionId] = recipe
            debugLog("recipe '%s' loaded, cyclesPerHour=%.3f", productionId, cyclesPerHour)
        end

        productionIndex = productionIndex + 1
    end
end

function PlaceableProductionWarehouseSupply:onHourChanged(hour)
    if not self.isServer then
        return
    end

    if self.spec_productionPoint ~= nil and self.spec_productionPoint.isFinalized == false then
        return
    end

    local data = self.productionWarehouseSupply
    local productionPointSpec = self.spec_productionPoint
    local productionPoint = productionPointSpec ~= nil and productionPointSpec.productionPoint or nil
    local storage = productionPoint ~= nil and productionPoint.storage or nil

    if data == nil or productionPoint == nil or storage == nil then
        return
    end

    local demandByFillType = {}

    -- Important: sum the NOMINAL hourly demand of every enabled production.
    -- We intentionally do not divide this reserve by sharedThroughputCapacity:
    -- the requested warehouse policy is "one nominal hour for every active recipe".
    for _, production in ipairs(productionPoint.activeProductions or {}) do
        local recipe = data.recipesById[production.id]
        if recipe ~= nil then
            for fillTypeIndex, hourlyAmount in pairs(recipe.inputs) do
                demandByFillType[fillTypeIndex] = (demandByFillType[fillTypeIndex] or 0) + hourlyAmount
            end
        end
    end

    -- Cancel queued work for resources that are no longer required by an active recipe.
    for _, job in ipairs(data.queue) do
        if demandByFillType[job.fillTypeIndex] == nil then
            job.target = 0
        end
    end

    for fillTypeIndex, hourlyDemand in pairs(demandByFillType) do
        if hourlyDemand > PlaceableProductionWarehouseSupply.EPSILON
            and storage:getIsFillTypeSupported(fillTypeIndex)
            and self:getObjectStorageSupportsFillType(fillTypeIndex) then

            local currentLevel = storage:getFillLevel(fillTypeIndex)
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local fillTypeName = fillType ~= nil and fillType.name or tostring(fillTypeIndex)

            debugLog(
                "hour %s: %s current=%.1f l, hourlyDemand=%.1f l",
                tostring(hour),
                fillTypeName,
                currentLevel,
                hourlyDemand
            )

            -- Strict trigger: only refill when the production has LESS than one
            -- hour of nominal demand. Exactly one hour is already sufficient.
            if currentLevel + PlaceableProductionWarehouseSupply.EPSILON < hourlyDemand then
                self:productionWarehouseSupplyEnqueue(fillTypeIndex, hourlyDemand)
            end
        end
    end

    self:productionWarehouseSupplyProcessQueue()
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyEnqueue(fillTypeIndex, target)
    local data = self.productionWarehouseSupply
    local existingJob = data.pendingByFillType[fillTypeIndex]

    if existingJob ~= nil then
        existingJob.target = target
        return
    end

    local job = {
        fillTypeIndex = fillTypeIndex,
        target = target
    }

    table.insert(data.queue, job)
    data.pendingByFillType[fillTypeIndex] = job
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyFinishCurrentJob(reason)
    local data = self.productionWarehouseSupply
    local job = data.queue[1]

    if job ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(job.fillTypeIndex)
        local fillTypeName = fillType ~= nil and fillType.name or tostring(job.fillTypeIndex)

        debugLog("finish %s: %s", fillTypeName, tostring(reason))

        data.pendingByFillType[job.fillTypeIndex] = nil
        table.remove(data.queue, 1)
    end

    data.busy = false
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyGetPalletInfo(xmlFilename)
    if xmlFilename == nil then
        return nil
    end

    local data = self.productionWarehouseSupply
    local normalizedFilename = normalizeFilename(xmlFilename)
    local cached = data.palletInfoCache[normalizedFilename]
    if cached ~= nil then
        return cached
    end

    local info = {
        supportedFillTypes = {},
        supportedFillTypeCount = 0
    }

    local palletXmlFile = XMLFile.load("productionWarehouseSupplyPallet", xmlFilename, Vehicle.xmlSchema)
    if palletXmlFile ~= nil then
        local fillTypeNamesAndCategories = FillUnit.getFillTypeNamesFromXML(palletXmlFile)
        local fillTypes = {}

        if fillTypeNamesAndCategories ~= nil then
            fillTypes = g_fillTypeManager:getFillTypesByCategoryNames(
                fillTypeNamesAndCategories.fillTypeCategoryNames, nil, fillTypes
            )
            fillTypes = g_fillTypeManager:getFillTypesByNames(
                fillTypeNamesAndCategories.fillTypeNames, nil, fillTypes
            )
        end

        for _, fillTypeIndex in ipairs(fillTypes) do
            if not info.supportedFillTypes[fillTypeIndex] then
                info.supportedFillTypes[fillTypeIndex] = true
                info.supportedFillTypeCount = info.supportedFillTypeCount + 1
            end
        end

        palletXmlFile:delete()
    end

    data.palletInfoCache[normalizedFilename] = info
    return info
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyFindStoredPallet(fillTypeIndex)
    local spec = self.spec_objectStorage
    if spec == nil or spec.storedObjects == nil then
        return nil
    end

    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        return nil
    end

    local wantedPalletFilename = normalizeFilename(fillType.palletFilename)

    for storedIndex, abstractObject in ipairs(spec.storedObjects) do
        local xmlFilename = abstractObject:getXMLFilename()
        local normalizedObjectFilename = normalizeFilename(xmlFilename)

        -- Fast and safest path: the stored object uses the pallet registered by
        -- the requested FillType descriptor.
        if wantedPalletFilename ~= nil and normalizedObjectFilename == wantedPalletFilename then
            return abstractObject, storedIndex
        end

        -- Fallback for custom single-fill pallets whose XML differs from the
        -- FillType's default palletFilename. Multi-fill containers are rejected
        -- here because their actual contents are only known after materializing.
        local palletInfo = self:productionWarehouseSupplyGetPalletInfo(xmlFilename)
        if palletInfo ~= nil
            and palletInfo.supportedFillTypeCount == 1
            and palletInfo.supportedFillTypes[fillTypeIndex] then
            return abstractObject, storedIndex
        end
    end

    return nil
end

function PlaceableProductionWarehouseSupply:productionWarehouseSupplyProcessQueue()
    local data = self.productionWarehouseSupply
    if data == nil or data.busy then
        return
    end

    local job = data.queue[1]
    if job == nil then
        return
    end

    local productionPoint = self.spec_productionPoint ~= nil and self.spec_productionPoint.productionPoint or nil
    local storage = productionPoint ~= nil and productionPoint.storage or nil
    if storage == nil then
        self:productionWarehouseSupplyFinishCurrentJob("production storage missing")
        self:productionWarehouseSupplyProcessQueue()
        return
    end

    local currentLevel = storage:getFillLevel(job.fillTypeIndex)
    if currentLevel + PlaceableProductionWarehouseSupply.EPSILON >= job.target then
        self:productionWarehouseSupplyFinishCurrentJob("target reached")
        self:productionWarehouseSupplyProcessQueue()
        return
    end

    if storage:getFreeCapacity(job.fillTypeIndex) <= PlaceableProductionWarehouseSupply.EPSILON then
        self:productionWarehouseSupplyFinishCurrentJob("production storage is full")
        self:productionWarehouseSupplyProcessQueue()
        return
    end

    local abstractObject, storedIndex = self:productionWarehouseSupplyFindStoredPallet(job.fillTypeIndex)
    if abstractObject == nil then
        self:productionWarehouseSupplyFinishCurrentJob("no matching pallet in objectStorage")
        self:productionWarehouseSupplyProcessQueue()
        return
    end

    -- Mirror the game's own removeAbstractObjectFromStorage bookkeeping, but use
    -- our callback so the spawned pallet can be transferred directly into the
    -- ProductionPoint storage rather than being left in the physical spawn area.
    local objectStorageSpec = self.spec_objectStorage
    table.remove(objectStorageSpec.storedObjects, storedIndex)
    objectStorageSpec.numStoredObjects = #objectStorageSpec.storedObjects
    self:setObjectStorageObjectInfosDirty()

    data.busy = true

    local x, y, z = getWorldTranslation(self.rootNode)
    local rx, ry, rz = getWorldRotation(self.rootNode)

    -- Service materialization point above the placeable. The object exists only
    -- until the asynchronous callback below; normally it is deleted immediately.
    abstractObject:removeFromStorage(
        self,
        x,
        y + 1000,
        z,
        rx,
        ry,
        rz,
        PlaceableProductionWarehouseSupply.onPalletSpawned
    )
end

function PlaceableProductionWarehouseSupply.onPalletSpawned(self, spawnedObject)
    local data = self.productionWarehouseSupply
    local job = data ~= nil and data.queue[1] or nil

    if data == nil then
        if spawnedObject ~= nil and spawnedObject.delete ~= nil then
            spawnedObject:delete()
        end
        return
    end

    data.busy = false

    if job == nil then
        if spawnedObject ~= nil then
            self:addObjectToObjectStorage(spawnedObject, false)
            self:setObjectStorageObjectInfosDirty()
        end
        return
    end

    if spawnedObject == nil then
        self:productionWarehouseSupplyFinishCurrentJob("stored pallet could not be materialized")
        self:productionWarehouseSupplyProcessQueue()
        return
    end

    local requestedFillType = job.fillTypeIndex
    local palletAmount = 0
    local incompatibleContents = false

    if spawnedObject.getFillUnits ~= nil then
        for _, fillUnit in ipairs(spawnedObject:getFillUnits()) do
            local fillUnitIndex = fillUnit.fillUnitIndex
            local fillLevel = spawnedObject:getFillUnitFillLevel(fillUnitIndex) or 0

            if fillLevel > PlaceableProductionWarehouseSupply.EPSILON then
                local actualFillType = spawnedObject:getFillUnitFillType(fillUnitIndex)
                if actualFillType == requestedFillType then
                    palletAmount = palletAmount + fillLevel
                else
                    incompatibleContents = true
                end
            end
        end
    end

    local productionPoint = self.spec_productionPoint ~= nil and self.spec_productionPoint.productionPoint or nil
    local storage = productionPoint ~= nil and productionPoint.storage or nil
    local freeCapacity = storage ~= nil and storage:getFreeCapacity(requestedFillType) or 0

    if not incompatibleContents
        and palletAmount > PlaceableProductionWarehouseSupply.EPSILON
        and freeCapacity + PlaceableProductionWarehouseSupply.EPSILON >= palletAmount then

        local previousLevel = storage:getFillLevel(requestedFillType)
        storage:setFillLevel(previousLevel + palletAmount, requestedFillType, nil)

        -- setFillLevel respects fillLevelSyncThreshold. A 500 l pallet with a
        -- 1000 l threshold would otherwise remain stale on clients until a later
        -- change, so force one normal Storage update after this hourly transfer.
        if storage.isServer and storage.storageDirtyFlag ~= nil then
            storage:raiseDirtyFlags(storage.storageDirtyFlag)
        end

        local fillType = g_fillTypeManager:getFillTypeByIndex(requestedFillType)
        local fillTypeName = fillType ~= nil and fillType.name or tostring(requestedFillType)

        debugLog(
            "transferred one pallet: %s +%.1f l (%.1f -> %.1f / target %.1f)",
            fillTypeName,
            palletAmount,
            previousLevel,
            storage:getFillLevel(requestedFillType),
            job.target
        )

        spawnedObject:delete()

        -- Do not finish yet: if one pallet was not enough, immediately take the
        -- next matching pallet. The loop stops as soon as storage >= target.
        self:productionWarehouseSupplyProcessQueue()
        return
    end

    -- Safety path: never destroy a pallet we could not confidently transfer.
    -- Put it back into the ObjectStorage and stop this resource until next hour.
    self:addObjectToObjectStorage(spawnedObject, false)
    self:setObjectStorageObjectInfosDirty()

    if incompatibleContents then
        self:productionWarehouseSupplyFinishCurrentJob("pallet contains another/mixed fillType")
    elseif palletAmount <= PlaceableProductionWarehouseSupply.EPSILON then
        self:productionWarehouseSupplyFinishCurrentJob("pallet is empty or has no readable fill unit")
    else
        self:productionWarehouseSupplyFinishCurrentJob("not enough free capacity for the whole pallet")
    end

    self:productionWarehouseSupplyProcessQueue()
end
