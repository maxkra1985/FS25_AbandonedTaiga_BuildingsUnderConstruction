-- FS25 WoodElevatorStorageInfo
-- Version 2.0.0.0
--
-- WoodElevator UI integration:
-- 1) Adds storage-only crops to ProductionPoint info HUD.
-- 2) Adds total "used / capacity" row to the info HUD.
-- 3) Adds WoodElevator contents to InGameMenuPricesFrame "Storage" column.
--
-- Does NOT create fake production recipes and does NOT modify production logic.

WoodElevatorStorageInfo = WoodElevatorStorageInfo or {}

local WESI = WoodElevatorStorageInfo

WESI.LOG_PREFIX = "[WoodElevatorStorageInfo]"
WESI.infoHookInstalled = WESI.infoHookInstalled or false
WESI.pricesHookInstalled = WESI.pricesHookInstalled or false

WESI.EXTRA_FILL_TYPES = {
    "CANOLA",
    "SUNFLOWER",
    "SOYBEAN",
    "MAIZE"
}

local function normalizePath(path)
    if path == nil then
        return ""
    end

    return string.lower(string.gsub(tostring(path), "\\", "/"))
end

function WESI:isWoodElevator(productionPoint)
    if productionPoint == nil or productionPoint.owningPlaceable == nil then
        return false
    end

    local filename = normalizePath(productionPoint.owningPlaceable.configFileName)

    return string.find(
        filename,
        "/map/placeables/woodelevator/woodelevator.xml",
        1,
        true
    ) ~= nil
end

function WESI:getStorageUsage(storage)
    if storage == nil then
        return 0, 0
    end

    local used = 0
    local fillLevels = storage:getFillLevels()

    if fillLevels ~= nil then
        for _, fillLevel in pairs(fillLevels) do
            used = used + (fillLevel or 0)
        end
    end

    -- FS25 Storage supports two capacity models:
    --
    -- A) Shared capacity:
    --      <storage capacity="5000000" fillTypes="..."/>
    --
    -- B) Separate capacities:
    --      <capacity fillType="WHEAT" capacity="500000"/>
    --      ...
    --
    -- If ALL supported fillTypes have custom capacities, their capacities are
    -- independent and therefore summed.
    --
    -- If no custom capacities exist, storage.capacity is the shared total.
    --
    -- Mixed mode is also handled: custom capacities are independent and one
    -- shared storage.capacity pool is counted once for all non-custom fillTypes.

    local supportedFillTypes = storage:getSupportedFillTypes() or {}
    local customCapacities = storage.capacities or {}

    local customCapacity = 0
    local numCustom = 0
    local numShared = 0

    for fillTypeId, supported in pairs(supportedFillTypes) do
        if supported then
            local capacity = customCapacities[fillTypeId]

            if capacity ~= nil then
                customCapacity = customCapacity + capacity
                numCustom = numCustom + 1
            else
                numShared = numShared + 1
            end
        end
    end

    local totalCapacity

    if numCustom > 0 and numShared == 0 then
        totalCapacity = customCapacity
    elseif numCustom == 0 then
        totalCapacity = storage.capacity or 0
    else
        totalCapacity = customCapacity + (storage.capacity or 0)
    end

    return used, totalCapacity
end

function WESI:removeStorageEmptyRow(productionPoint, infoTable)
    if productionPoint == nil
        or productionPoint.infoTables == nil
        or productionPoint.infoTables.storageEmpty == nil then
        return
    end

    local emptyRow = productionPoint.infoTables.storageEmpty

    for i = #infoTable, 1, -1 do
        if infoTable[i] == emptyRow then
            table.remove(infoTable, i)
        end
    end
end

function WESI:insertStorageUsageRow(productionPoint, infoTable)
    if productionPoint == nil or productionPoint.storage == nil then
        return
    end

    local used, totalCapacity = self:getStorageUsage(productionPoint.storage)

    local title = g_i18n:getText("woodElevator_storageUsage")
    if title == nil or title == "" or title == "woodElevator_storageUsage" then
        title = "Storage"
    end

    local row = {
        title = title,
        text = string.format(
            "%s / %s",
            g_i18n:formatVolume(used, 0),
            g_i18n:formatVolume(totalCapacity, 0)
        )
    }

    -- Put the total directly below the vanilla "Storage" section heading.
    local storageHeader =
        productionPoint.infoTables ~= nil
        and productionPoint.infoTables.storage
        or nil

    if storageHeader ~= nil then
        for i, existingRow in ipairs(infoTable) do
            if existingRow == storageHeader then
                table.insert(infoTable, i + 1, row)
                return
            end
        end
    end

    table.insert(infoTable, row)
end

function WESI:updateInfo(productionPoint, superFunc, infoTable)
    superFunc(productionPoint, infoTable)

    if not self:isWoodElevator(productionPoint) then
        return
    end

    local storage = productionPoint.storage
    if storage == nil then
        return
    end

    -- Total used / configured capacity.
    self:insertStorageUsageRow(productionPoint, infoTable)

    -- FillTypes which are storage-only and therefore absent from vanilla
    -- ProductionPoint.inputFillTypeIdsArray/outputFillTypeIdsArray.
    local addedAny = false

    for _, fillTypeName in ipairs(self.EXTRA_FILL_TYPES) do
        local fillTypeId = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)

        if fillTypeId ~= nil then
            -- If the fillType later becomes a real recipe input/output,
            -- vanilla ProductionPoint:updateInfo already displays it.
            local alreadyVanilla =
                productionPoint.inputFillTypeIds[fillTypeId] == true
                or productionPoint.outputFillTypeIds[fillTypeId] == true

            if not alreadyVanilla and storage:getIsFillTypeSupported(fillTypeId) then
                local fillLevel = storage:getFillLevel(fillTypeId)

                -- Vanilla ProductionPoint:updateInfo uses the same > 1 L threshold.
                if fillLevel > 1 then
                    table.insert(infoTable, {
                        title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeId),
                        text = g_i18n:formatVolume(fillLevel, 0)
                    })

                    addedAny = true
                end
            end
        end
    end

    if addedAny then
        self:removeStorageEmptyRow(productionPoint, infoTable)
    end
end

function WESI:getCurrentFarmId()
    if g_currentMission == nil then
        return nil
    end

    if g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end

    if g_currentMission.player ~= nil then
        return g_currentMission.player.farmId
    end

    return nil
end

function WESI:getElevatorStorageForFillType(fillTypeId)
    local totalFillLevel = 0
    local totalCapacity = 0
    local found = false

    if g_currentMission == nil
        or g_currentMission.productionChainManager == nil
        or g_currentMission.productionChainManager.productionPoints == nil then
        return totalFillLevel, totalCapacity, found
    end

    local currentFarmId = self:getCurrentFarmId()

    for _, productionPoint in ipairs(
        g_currentMission.productionChainManager.productionPoints
    ) do
        if self:isWoodElevator(productionPoint) then
            local ownerFarmId = productionPoint:getOwnerFarmId()

            -- The Prices menu "Storage" column represents storage owned by
            -- the current farm, so do not expose other farms' elevators.
            if currentFarmId == nil or ownerFarmId == currentFarmId then
                local storage = productionPoint.storage

                if storage ~= nil
                    and storage:getIsFillTypeSupported(fillTypeId) then

                    totalFillLevel =
                        totalFillLevel + storage:getFillLevel(fillTypeId)

                    totalCapacity =
                        totalCapacity + storage:getCapacity(fillTypeId)

                    found = true
                end
            end
        end
    end

    return totalFillLevel, totalCapacity, found
end

function WESI:getStorageFillLevel(
    pricesFrame,
    superFunc,
    fillTypeId,
    farmSilo
)
    local fillLevel, capacity =
        superFunc(pricesFrame, fillTypeId, farmSilo)

    -- InGameMenuPricesFrame#getStorageFillLevel(..., true) is the value used
    -- for owned farm storage ("Storage" column). Only extend that branch.
    if farmSilo ~= true then
        return fillLevel, capacity
    end

    local elevatorFillLevel, elevatorCapacity, found =
        self:getElevatorStorageForFillType(fillTypeId)

    if not found then
        return fillLevel, capacity
    end

    -- Vanilla returns negative values when no ordinary silo exists.
    if fillLevel == nil or fillLevel < 0 then
        fillLevel = 0
    end

    if capacity == nil or capacity < 0 then
        capacity = 0
    end

    return
        fillLevel + elevatorFillLevel,
        capacity + elevatorCapacity
end

function WESI:installInfoHook()
    if self.infoHookInstalled then
        return true
    end

    if ProductionPoint == nil or ProductionPoint.updateInfo == nil then
        return false
    end

    ProductionPoint.updateInfo = Utils.overwrittenFunction(
        ProductionPoint.updateInfo,
        function(productionPoint, superFunc, infoTable)
            WESI:updateInfo(productionPoint, superFunc, infoTable)
        end
    )

    self.infoHookInstalled = true

    Logging.info(
        "%s ProductionPoint info HUD hook installed",
        self.LOG_PREFIX
    )

    return true
end

function WESI:installPricesHook()
    if self.pricesHookInstalled then
        return true
    end

    if InGameMenuPricesFrame == nil
        or InGameMenuPricesFrame.getStorageFillLevel == nil then
        return false
    end

    InGameMenuPricesFrame.getStorageFillLevel = Utils.overwrittenFunction(
        InGameMenuPricesFrame.getStorageFillLevel,
        function(pricesFrame, superFunc, fillTypeId, farmSilo)
            return WESI:getStorageFillLevel(
                pricesFrame,
                superFunc,
                fillTypeId,
                farmSilo
            )
        end
    )

    self.pricesHookInstalled = true

    Logging.info(
        "%s Prices menu storage hook installed",
        self.LOG_PREFIX
    )

    return true
end

function WESI:install()
    local infoOk = self:installInfoHook()
    local pricesOk = self:installPricesHook()

    Logging.info(
        "%s install complete: infoHud=%s pricesStorage=%s extraFillTypes=%s",
        self.LOG_PREFIX,
        tostring(infoOk),
        tostring(pricesOk),
        table.concat(self.EXTRA_FILL_TYPES, ", ")
    )
end

WESI:install()
