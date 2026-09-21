--[[
    FS25 - BunkerFillPlanes
    Version 2.0.0.0

    Universal visual bunker controller for ProductionPoint placeables.

    Add once to modDesc.xml:
        <sourceFile filename="scripts/BunkerFillPlanes.lua"/>

    Then any ProductionPoint in the mod may use:
        <productionPoint>
            <storage capacity="20000000" fillTypes="...">
                <bunkerFillPlane
                    node="fillPlane01"
                    fillTypes="WHEAT"
                    minY="0"
                    maxY="3.8"/>
            </storage>
        </productionPoint>

    No placeable type or placeable filename is hardcoded.
    No capacity, bunker count, fill type or height is hardcoded.

    Number of physical bunkers = number of <bunkerFillPlane> entries.
    Capacity per visual bunker = real Storage total capacity / bunker count.

    One bunker may represent several fill types:
        fillTypes="WHEAT_CLEAN BARLEY_CLEAN OAT_CLEAN SORGHUM_CLEAN"

    The displayed fill level for that bunker is the sum of those real
    Storage fill levels.

    Updates are event-driven through Storage:addFillLevelChangedListeners().
    There is no per-frame update.
]]

BunkerFillPlanes = BunkerFillPlanes or {}

local BFP = BunkerFillPlanes
BFP.VERSION = "2.0.0.0"
BFP.LOG_PREFIX = "[BunkerFillPlanes]"
BFP.hooksInstalled = BFP.hooksInstalled or false

local function registerBunkerXMLPaths(schema, productionPath)
    local key = productionPath .. ".storage.bunkerFillPlane(?)"

    schema:register(
        XMLValueType.NODE_INDEX,
        key .. "#node",
        "Visual bunker fill-plane node"
    )

    schema:register(
        XMLValueType.STRING,
        key .. "#fillTypes",
        "Space-separated fill types represented by this visual bunker"
    )

    schema:register(
        XMLValueType.FLOAT,
        key .. "#minY",
        "Local Y of visual surface at empty state",
        0
    )

    schema:register(
        XMLValueType.FLOAT,
        key .. "#maxY",
        "Local Y of visual surface at full state",
        1
    )
end

function BFP:registerXMLPaths(schema, basePath)
    registerBunkerXMLPaths(
        schema,
        basePath .. ".productionPoint"
    )

    registerBunkerXMLPaths(
        schema,
        basePath
            .. ".productionPoint.productionPointConfigurations"
            .. ".productionPointConfiguration(?).productionPoint"
    )
end

function BFP:getProductionKey(placeable)
    local configurationId = 1

    if placeable.configurations ~= nil then
        configurationId =
            Utils.getNoNil(
                placeable.configurations.productionPoint,
                1
            )
    end

    local configKey = string.format(
        "placeable.productionPoint.productionPointConfigurations"
            .. ".productionPointConfiguration(%d).productionPoint",
        configurationId - 1
    )

    if placeable.xmlFile:hasProperty(configKey) then
        return configKey
    end

    return "placeable.productionPoint"
end

function BFP:getTotalStorageCapacity(storage)
    if storage == nil then
        return 0
    end

    local supportedFillTypes =
        storage:getSupportedFillTypes() or {}
    local customCapacities =
        storage.capacities or {}

    local customCapacity = 0
    local numCustom = 0
    local numShared = 0

    for fillTypeId, supported in pairs(supportedFillTypes) do
        if supported then
            local capacity =
                customCapacities[fillTypeId]

            if capacity ~= nil then
                customCapacity =
                    customCapacity + capacity
                numCustom =
                    numCustom + 1
            else
                numShared =
                    numShared + 1
            end
        end
    end

    -- Shared capacity:
    -- <storage capacity="20000000" fillTypes="..."/>
    if numCustom == 0 then
        return storage.capacity or 0
    end

    -- Every supported fill type has its own independent capacity.
    if numShared == 0 then
        return customCapacity
    end

    -- Mixed model: independent custom capacities plus one shared pool.
    return customCapacity + (storage.capacity or 0)
end

function BFP:getState(placeable, create)
    if placeable.bunkerFillPlanesState == nil and create then
        placeable.bunkerFillPlanesState = {
            bunkers = {},
            storage = nil,
            listener = nil,
            listenerAttached = false,
            capacityWarningShown = false
        }
    end

    return placeable.bunkerFillPlanesState
end

function BFP:loadPlaceable(placeable)
    if placeable == nil
        or placeable.xmlFile == nil
        or placeable.spec_productionPoint == nil then
        return
    end

    local productionKey =
        self:getProductionKey(placeable)
    local storageKey =
        productionKey .. ".storage"

    if not placeable.xmlFile:hasProperty(
        storageKey .. ".bunkerFillPlane(0)"
    ) then
        return
    end

    local state =
        self:getState(placeable, true)

    state.bunkers = {}

    placeable.xmlFile:iterate(
        storageKey .. ".bunkerFillPlane",
        function(index, bunkerKey)
            local bunker = {}

            bunker.node =
                placeable.xmlFile:getValue(
                    bunkerKey .. "#node",
                    nil,
                    placeable.components,
                    placeable.i3dMappings
                )

            bunker.minY =
                placeable.xmlFile:getValue(
                    bunkerKey .. "#minY",
                    0
                )

            bunker.maxY =
                placeable.xmlFile:getValue(
                    bunkerKey .. "#maxY",
                    1
                )

            bunker.fillTypeNames =
                placeable.xmlFile:getValue(
                    bunkerKey .. "#fillTypes",
                    ""
                )

            bunker.fillTypes = {}

            if bunker.fillTypeNames ~= nil
                and bunker.fillTypeNames ~= "" then

                local fillTypeIds =
                    g_fillTypeManager:getFillTypesByNames(
                        bunker.fillTypeNames,
                        string.format(
                            "Warning: bunkerFillPlane has invalid fillType '%%s' in '%s'.",
                            tostring(placeable.configFileName)
                        )
                    )

                if fillTypeIds ~= nil then
                    for _, fillTypeId in ipairs(fillTypeIds) do
                        table.insert(
                            bunker.fillTypes,
                            fillTypeId
                        )
                    end
                end
            end

            if bunker.node ~= nil then
                bunker.x, bunker.originalY, bunker.z =
                    getTranslation(bunker.node)

                -- Hide editor/default state until real Storage is applied.
                setVisibility(
                    bunker.node,
                    false
                )
            else
                bunker.x = 0
                bunker.originalY = 0
                bunker.z = 0

                Logging.warning(
                    "%s bunkerFillPlane[%s] has invalid node in '%s'",
                    self.LOG_PREFIX,
                    tostring(index),
                    tostring(placeable.configFileName)
                )
            end

            if #bunker.fillTypes == 0 then
                Logging.warning(
                    "%s bunkerFillPlane[%s] has no valid fillTypes in '%s'",
                    self.LOG_PREFIX,
                    tostring(index),
                    tostring(placeable.configFileName)
                )
            end

            -- Every XML entry counts as one physical bunker.
            table.insert(
                state.bunkers,
                bunker
            )
        end
    )

    Logging.info(
        "%s loaded %d visual bunker(s) from '%s'",
        self.LOG_PREFIX,
        #state.bunkers,
        tostring(placeable.configFileName)
    )

    self:connectStorage(placeable)
end

function BFP:connectStorage(placeable)
    local state =
        self:getState(placeable, false)

    if state == nil
        or state.bunkers == nil
        or #state.bunkers == 0
        or not placeable.isClient then
        return
    end

    local productionSpec =
        placeable.spec_productionPoint
    local productionPoint =
        productionSpec ~= nil
        and productionSpec.productionPoint
        or nil
    local storage =
        productionPoint ~= nil
        and productionPoint.storage
        or nil

    if storage == nil then
        return
    end

    if state.listenerAttached
        and state.storage == storage then
        self:updatePlaceable(placeable)
        return
    end

    if state.listenerAttached
        and state.storage ~= nil
        and state.listener ~= nil then

        state.storage:removeFillLevelChangedListeners(
            state.listener
        )

        state.listenerAttached = false
    end

    state.storage = storage

    state.listener =
        function(fillTypeId, delta)
            self:updatePlaceable(placeable)
        end

    storage:addFillLevelChangedListeners(
        state.listener
    )

    state.listenerAttached = true

    self:updatePlaceable(placeable)

    local totalCapacity =
        self:getTotalStorageCapacity(storage)
    local bunkerCapacity =
        #state.bunkers > 0
        and totalCapacity / #state.bunkers
        or 0

    Logging.info(
        "%s connected %d bunker(s): totalCapacity=%.0f L, capacityPerBunker=%.3f L, file='%s'",
        self.LOG_PREFIX,
        #state.bunkers,
        totalCapacity,
        bunkerCapacity,
        tostring(placeable.configFileName)
    )
end

function BFP:updatePlaceable(placeable)
    local state =
        self:getState(placeable, false)

    if state == nil
        or state.storage == nil
        or state.bunkers == nil
        or #state.bunkers == 0 then
        return
    end

    local productionSpec =
        placeable.spec_productionPoint
    local productionPoint =
        productionSpec ~= nil
        and productionSpec.productionPoint
        or nil

    -- Constructible ProductionPoints must not show stored grain
    -- while the production itself is not finalized.
    if productionPoint ~= nil
        and productionPoint.isFinalized == false then

        for _, bunker in ipairs(state.bunkers) do
            if bunker.node ~= nil then
                setVisibility(
                    bunker.node,
                    false
                )
            end
        end

        return
    end

    local totalCapacity =
        self:getTotalStorageCapacity(state.storage)
    local bunkerCount =
        #state.bunkers

    if totalCapacity <= 0
        or bunkerCount <= 0 then

        if not state.capacityWarningShown then
            Logging.warning(
                "%s unable to calculate visual bunker capacity: totalCapacity=%.3f bunkers=%d file='%s'",
                self.LOG_PREFIX,
                totalCapacity,
                bunkerCount,
                tostring(placeable.configFileName)
            )

            state.capacityWarningShown = true
        end

        return
    end

    state.capacityWarningShown = false

    local bunkerCapacity =
        totalCapacity / bunkerCount

    for _, bunker in ipairs(state.bunkers) do
        if bunker.node ~= nil then
            local fillLevel = 0

            for _, fillTypeId in ipairs(
                bunker.fillTypes
            ) do
                fillLevel =
                    fillLevel
                    + state.storage:getFillLevel(
                        fillTypeId
                    )
            end

            local factor =
                math.clamp(
                    fillLevel / bunkerCapacity,
                    0,
                    1
                )

            local y =
                MathUtil.lerp(
                    bunker.minY,
                    bunker.maxY,
                    factor
                )

            setTranslation(
                bunker.node,
                bunker.x,
                y,
                bunker.z
            )

            setVisibility(
                bunker.node,
                fillLevel > 0.1
            )
        end
    end
end

function BFP:deletePlaceable(placeable)
    local state =
        self:getState(placeable, false)

    if state == nil then
        return
    end

    if state.listenerAttached
        and state.storage ~= nil
        and state.listener ~= nil then

        state.storage:removeFillLevelChangedListeners(
            state.listener
        )
    end

    placeable.bunkerFillPlanesState = nil
end

function BFP:installHooks()
    if self.hooksInstalled then
        return
    end

    self.hooksInstalled = true

    -- Register our custom XML children for every placeable type that
    -- includes PlaceableProductionPoint. No custom placeable type needed.
    PlaceableProductionPoint.registerXMLPaths =
        Utils.appendedFunction(
            PlaceableProductionPoint.registerXMLPaths,
            function(schema, basePath)
                BFP:registerXMLPaths(
                    schema,
                    basePath
                )
            end
        )

    PlaceableProductionPoint.onLoad =
        Utils.appendedFunction(
            PlaceableProductionPoint.onLoad,
            function(placeable, savegame)
                BFP:loadPlaceable(
                    placeable
                )
            end
        )

    PlaceableProductionPoint.onFinalizePlacement =
        Utils.appendedFunction(
            PlaceableProductionPoint.onFinalizePlacement,
            function(placeable)
                BFP:connectStorage(
                    placeable
                )
            end
        )

    -- Initial MP stream may arrive after onLoad.
    PlaceableProductionPoint.onReadStream =
        Utils.appendedFunction(
            PlaceableProductionPoint.onReadStream,
            function(placeable, streamId, connection)
                BFP:connectStorage(
                    placeable
                )
                BFP:updatePlaceable(
                    placeable
                )
            end
        )

    -- Construction FINALIZE can happen long after normal placement.
    PlaceableProductionPoint.finalizeConstruction =
        Utils.appendedFunction(
            PlaceableProductionPoint.finalizeConstruction,
            function(placeable)
                BFP:connectStorage(
                    placeable
                )
                BFP:updatePlaceable(
                    placeable
                )
            end
        )

    -- Remove listener before vanilla ProductionPoint deletion.
    PlaceableProductionPoint.onDelete =
        Utils.prependedFunction(
            PlaceableProductionPoint.onDelete,
            function(placeable)
                BFP:deletePlaceable(
                    placeable
                )
            end
        )

    Logging.info(
        "%s hooks installed, version=%s",
        self.LOG_PREFIX,
        self.VERSION
    )
end

BFP:installHooks()
