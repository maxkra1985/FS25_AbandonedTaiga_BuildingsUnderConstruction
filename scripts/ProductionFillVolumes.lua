--[[
    Визуализация сложных fillVolume для ProductionPoint.
    Основной режим повторяет штатный FS25 FillVolume: createFillPlaneShape + fillPlaneAdd.
    Резервный режим показывает исходную Shape целиком только при включённом производстве.
]]

ProductionFillVolumes = ProductionFillVolumes or {}

local PFV = ProductionFillVolumes
PFV.VERSION = "1.0.0.0"
PFV.LOG_PREFIX = "[ProductionFillVolumes]"
PFV.hooksInstalled = PFV.hooksInstalled or false
PFV.placeablesByProductionPoint = PFV.placeablesByProductionPoint or setmetatable({}, {__mode = "k"})

-- Регистрирует XML-параметры визуальных объёмов внутри ProductionPoint Storage.
local function registerProductionFillVolumeXMLPaths(schema, productionPath)
    local key = productionPath .. ".storage.productionFillVolume(?)"

    schema:register(
        XMLValueType.NODE_INDEX,
        key .. "#node",
        "Closed source Shape used to generate the visual fill volume"
    )

    schema:register(
        XMLValueType.STRING,
        key .. "#fillType",
        "Storage fill type that controls the visible amount"
    )

    schema:register(
        XMLValueType.STRING,
        key .. "#visualFillType",
        "Fill type used only for the visual material/texture"
    )

    schema:register(
        XMLValueType.FLOAT,
        key .. "#capacity",
        "Optional visual capacity. If omitted, Storage:getCapacity(fillType) is used"
    )

    schema:register(
        XMLValueType.STRING,
        key .. "#fallbackProductionId",
        "Production id that enables the full-volume fallback if dynamic generation fails"
    )
end

-- Подключает XML-параметры к обычному и конфигурируемому ProductionPoint.
function PFV:registerXMLPaths(schema, basePath)
    registerProductionFillVolumeXMLPaths(
        schema,
        basePath .. ".productionPoint"
    )

    registerProductionFillVolumeXMLPaths(
        schema,
        basePath
            .. ".productionPoint.productionPointConfigurations"
            .. ".productionPointConfiguration(?).productionPoint"
    )
end

-- Возвращает фактический XML-путь ProductionPoint с учётом выбранной конфигурации.
function PFV:getProductionKey(placeable)
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

-- Возвращает или создаёт внутреннее состояние визуальных объёмов placeable.
function PFV:getState(placeable, create)
    if placeable.productionFillVolumesState == nil and create then
        placeable.productionFillVolumesState = {
            volumes = {},
            storage = nil,
            productionPoint = nil,
            listener = nil,
            listenerAttached = false
        }
    end

    return placeable.productionFillVolumesState
end

-- Преобразует имя fillType в индекс и диагностирует ошибочную настройку XML.
function PFV:getFillTypeIndex(name, placeable, key)
    if name == nil or name == "" then
        return nil
    end

    local fillTypeId =
        g_fillTypeManager:getFillTypeIndexByName(name)

    if fillTypeId == nil then
        Logging.warning(
            "%s invalid fillType '%s' at '%s' in '%s'",
            self.LOG_PREFIX,
            tostring(name),
            tostring(key),
            tostring(placeable.configFileName)
        )
    end

    return fillTypeId
end

-- Читает productionFillVolume из XML и сохраняет ссылки на исходные Shape.
function PFV:loadPlaceable(placeable)
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
        storageKey .. ".productionFillVolume(0)"
    ) then
        return
    end

    local state =
        self:getState(placeable, true)

    state.volumes = {}

    placeable.xmlFile:iterate(
        storageKey .. ".productionFillVolume",
        function(index, volumeKey)
            local entry = {}

            entry.node =
                placeable.xmlFile:getValue(
                    volumeKey .. "#node",
                    nil,
                    placeable.components,
                    placeable.i3dMappings
                )

            entry.fillTypeName =
                placeable.xmlFile:getValue(
                    volumeKey .. "#fillType",
                    ""
                )

            entry.visualFillTypeName =
                placeable.xmlFile:getValue(
                    volumeKey .. "#visualFillType",
                    entry.fillTypeName
                )

            entry.fillTypeId =
                self:getFillTypeIndex(
                    entry.fillTypeName,
                    placeable,
                    volumeKey
                )

            entry.visualFillTypeId =
                self:getFillTypeIndex(
                    entry.visualFillTypeName,
                    placeable,
                    volumeKey
                )

            entry.capacityOverride =
                placeable.xmlFile:getValue(
                    volumeKey .. "#capacity"
                )

            entry.fallbackProductionId =
                placeable.xmlFile:getValue(
                    volumeKey .. "#fallbackProductionId"
                )

            entry.dynamicNode = nil
            entry.dynamicAttempted = false
            entry.dynamicFailed = false
            entry.fallbackPrepared = false
            entry.capacity = 0
            entry.currentLevel = 0

            if entry.node == nil then
                Logging.warning(
                    "%s productionFillVolume[%s] has invalid node in '%s'",
                    self.LOG_PREFIX,
                    tostring(index),
                    tostring(placeable.configFileName)
                )
            end

            if entry.node ~= nil
                and entry.fillTypeId ~= nil
                and entry.visualFillTypeId ~= nil then

                table.insert(
                    state.volumes,
                    entry
                )
            end
        end
    )

    Logging.info(
        "%s loaded %d visual volume(s) from '%s'",
        self.LOG_PREFIX,
        #state.volumes,
        tostring(placeable.configFileName)
    )

    self:connectStorage(placeable)
end


-- Назначает штатный fillPlane-материал и текстуру указанного fillType.
function PFV:assignFillPlaneMaterial(node, fillTypeId, isCustomShape)
    if node == nil or node == 0 then
        return false
    end

    if FillPlaneUtil == nil
        or FillPlaneUtil.assignDefaultMaterialsFromTerrain == nil
        or FillPlaneUtil.setFillType == nil then
        return false
    end

    if not FillPlaneUtil.assignDefaultMaterialsFromTerrain(node, g_terrainNode) then
        return false
    end

    FillPlaneUtil.setFillType(node, fillTypeId)

    if isCustomShape then
        setShaderParameter(node, "isCustomShape", 1, 0, 0, 0, false)
    end

    return true
end

-- Готовит исходную Shape для резервного отображения полного объёма.
function PFV:prepareFallback(entry)
    if entry.fallbackPrepared then
        return true
    end

    if entry.node == nil then
        return false
    end

    setIsNonRenderable(entry.node, false)

    local materialAssigned =
        self:assignFillPlaneMaterial(
            entry.node,
            entry.visualFillTypeId,
            true
        )

    if not materialAssigned then
        Logging.warning(
            "%s unable to assign fallback fill material to node '%s'",
            self.LOG_PREFIX,
            tostring(getName(entry.node))
        )
    end

    setVisibility(entry.node, false)
    entry.fallbackPrepared = true

    return true
end

-- Создаёт штатный динамический fill plane внутри сложной исходной Shape.
function PFV:createDynamicVolume(placeable, entry)
    if entry.dynamicAttempted then
        return entry.dynamicNode ~= nil
    end

    entry.dynamicAttempted = true

    local state =
        self:getState(placeable, false)

    if state == nil
        or state.storage == nil
        or entry.node == nil then
        entry.dynamicFailed = true
        return false
    end

    local capacity =
        entry.capacityOverride

    if capacity == nil then
        capacity =
            state.storage:getCapacity(
                entry.fillTypeId
            )
    end

    capacity = capacity or 0

    if capacity <= 0 then
        Logging.warning(
            "%s invalid visual capacity %.3f for node '%s' in '%s'",
            self.LOG_PREFIX,
            capacity,
            tostring(getName(entry.node)),
            tostring(placeable.configFileName)
        )

        entry.dynamicFailed = true
        self:prepareFallback(entry)
        return false
    end

    entry.capacity = capacity

    -- Создаём горизонтальную поверхность; сложную форму стенок задаёт исходная Shape.
    local dynamicNode =
        createFillPlaneShape(
            entry.node,
            "productionFillPlane",
            capacity,
            1,
            0,
            0,
            0.05,
            0.9,
            1.35,
            true,
            false
        )

    if dynamicNode == nil or dynamicNode == 0 then
        Logging.warning(
            "%s dynamic fill plane could not be created from node '%s' in '%s'; using fallback",
            self.LOG_PREFIX,
            tostring(getName(entry.node)),
            tostring(placeable.configFileName)
        )

        entry.dynamicFailed = true
        self:prepareFallback(entry)
        return false
    end

    -- Base Shape остаётся nonRenderable и видимой: её visibility наследует дочерний fill plane.
    link(entry.node, dynamicNode)
    setVisibility(dynamicNode, false)

    if not self:assignFillPlaneMaterial(dynamicNode, entry.visualFillTypeId, false) then
        Logging.warning(
            "%s unable to assign fill material to dynamic node created from '%s'",
            self.LOG_PREFIX,
            tostring(getName(entry.node))
        )
    end

    entry.dynamicNode = dynamicNode
    entry.dynamicFailed = false
    entry.currentLevel = 0

    Logging.info(
        "%s dynamic fill plane created: node='%s', sourceFillType='%s', visualFillType='%s', capacity=%.0f L",
        self.LOG_PREFIX,
        tostring(getName(entry.node)),
        tostring(entry.fillTypeName),
        tostring(entry.visualFillTypeName),
        capacity
    )

    return true
end

-- Синхронизирует геометрию динамического fill plane с фактическим уровнем Storage.
function PFV:setDynamicLevel(entry, fillLevel)
    if entry.dynamicNode == nil
        or entry.capacity <= 0 then
        return
    end

    local targetLevel =
        math.clamp(
            fillLevel or 0,
            0,
            entry.capacity
        )

    local delta =
        targetLevel - entry.currentLevel

    if math.abs(delta) > 0.01 then
        -- Повторяем штатный алгоритм FillVolume для плоской поверхности: область 10x10 м.
        local areaSize = 10
        local x, y, z =
            localToWorld(
                entry.dynamicNode,
                -areaSize * 0.5,
                0,
                -areaSize * 0.5
            )

        local d1x, d1y, d1z =
            localDirectionToWorld(
                entry.dynamicNode,
                areaSize,
                0,
                0
            )

        local d2x, d2y, d2z =
            localDirectionToWorld(
                entry.dynamicNode,
                0,
                0,
                areaSize
            )

        local steps =
            math.clamp(
                math.floor(delta / 400),
                1,
                25
            )

        for _ = 1, steps do
            fillPlaneAdd(
                entry.dynamicNode,
                delta / steps,
                x,
                y,
                z,
                d1x,
                d1y,
                d1z,
                d2x,
                d2y,
                d2z
            )
        end

        entry.currentLevel =
            targetLevel
    end

    setVisibility(
        entry.dynamicNode,
        targetLevel > 0.1
    )
end

-- Проверяет, включён ли рецепт, управляющий резервным отображением.
function PFV:isFallbackProductionActive(state, productionId)
    if state == nil
        or state.productionPoint == nil
        or productionId == nil
        or productionId == "" then
        return false
    end

    return state.productionPoint:getIsProductionEnabled(productionId)
end

-- Обновляет динамический или резервный визуальный режим всех объёмов placeable.
function PFV:updatePlaceable(placeable)
    local state =
        self:getState(placeable, false)

    if state == nil
        or state.storage == nil then
        return
    end

    local isFinalized =
        state.productionPoint == nil
        or state.productionPoint.isFinalized ~= false

    for _, entry in ipairs(state.volumes) do
        if entry.dynamicNode ~= nil then
            if isFinalized then
                self:setDynamicLevel(
                    entry,
                    state.storage:getFillLevel(
                        entry.fillTypeId
                    )
                )
            else
                setVisibility(
                    entry.dynamicNode,
                    false
                )
            end
        elseif entry.dynamicFailed then
            local fallbackVisible =
                isFinalized
                and self:isFallbackProductionActive(
                    state,
                    entry.fallbackProductionId
                )

            setVisibility(
                entry.node,
                fallbackVisible
            )
        end
    end
end

-- Подключает визуальные объёмы к ProductionPoint Storage и его событиям изменения уровня.
function PFV:connectStorage(placeable)
    local state =
        self:getState(placeable, false)

    if state == nil
        or state.volumes == nil
        or #state.volumes == 0
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

    if productionPoint == nil
        or storage == nil then
        return
    end

    state.productionPoint =
        productionPoint

    self.placeablesByProductionPoint[productionPoint] =
        placeable

    if state.listenerAttached
        and state.storage ~= storage
        and state.storage ~= nil
        and state.listener ~= nil then

        state.storage:removeFillLevelChangedListeners(
            state.listener
        )

        state.listenerAttached = false
    end

    state.storage =
        storage

    if not state.listenerAttached then
        state.listener =
            function(fillTypeId, delta)
                for _, entry in ipairs(state.volumes) do
                    if entry.fillTypeId == fillTypeId then
                        Logging.info(
                            "%s storage changed: fillType='%s', delta=%.1f L, level=%.1f L",
                            PFV.LOG_PREFIX,
                            tostring(entry.fillTypeName),
                            delta or 0,
                            storage:getFillLevel(fillTypeId)
                        )

                        PFV:updatePlaceable(
                            placeable
                        )
                        return
                    end
                end
            end

        storage:addFillLevelChangedListeners(
            state.listener
        )

        state.listenerAttached = true
    end

    local dynamicCount = 0
    local fallbackCount = 0

    for _, entry in ipairs(state.volumes) do
        if self:createDynamicVolume(
            placeable,
            entry
        ) then
            dynamicCount =
                dynamicCount + 1
        else
            fallbackCount =
                fallbackCount + 1
        end
    end

    self:updatePlaceable(
        placeable
    )

    Logging.info(
        "%s connected '%s': dynamic=%d fallback=%d",
        self.LOG_PREFIX,
        tostring(placeable.configFileName),
        dynamicCount,
        fallbackCount
    )
end

-- Отписывается от Storage и удаляет созданные движком динамические Shape.
function PFV:deletePlaceable(placeable)
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

    if state.productionPoint ~= nil then
        self.placeablesByProductionPoint[state.productionPoint] =
            nil
    end

    for _, entry in ipairs(state.volumes or {}) do
        if entry.dynamicNode ~= nil then
            delete(
                entry.dynamicNode
            )

            entry.dynamicNode =
                nil
        end
    end

    placeable.productionFillVolumesState =
        nil
end

-- Устанавливает хуки один раз при загрузке sourceFile из modDesc.xml.
function PFV:installHooks()
    if self.hooksInstalled then
        return
    end

    self.hooksInstalled = true

    PlaceableProductionPoint.registerXMLPaths =
        Utils.appendedFunction(
            PlaceableProductionPoint.registerXMLPaths,
            function(schema, basePath)
                PFV:registerXMLPaths(
                    schema,
                    basePath
                )
            end
        )

    PlaceableProductionPoint.onLoad =
        Utils.appendedFunction(
            PlaceableProductionPoint.onLoad,
            function(placeable, savegame)
                PFV:loadPlaceable(
                    placeable
                )
            end
        )

    PlaceableProductionPoint.onFinalizePlacement =
        Utils.appendedFunction(
            PlaceableProductionPoint.onFinalizePlacement,
            function(placeable)
                PFV:connectStorage(
                    placeable
                )
            end
        )

    PlaceableProductionPoint.onReadStream =
        Utils.appendedFunction(
            PlaceableProductionPoint.onReadStream,
            function(placeable, streamId, connection)
                PFV:connectStorage(
                    placeable
                )
                PFV:updatePlaceable(
                    placeable
                )
            end
        )

    PlaceableProductionPoint.finalizeConstruction =
        Utils.appendedFunction(
            PlaceableProductionPoint.finalizeConstruction,
            function(placeable)
                PFV:connectStorage(
                    placeable
                )
                PFV:updatePlaceable(
                    placeable
                )
            end
        )

    PlaceableProductionPoint.onDelete =
        Utils.prependedFunction(
            PlaceableProductionPoint.onDelete,
            function(placeable)
                PFV:deletePlaceable(
                    placeable
                )
            end
        )

    -- Резервный режим реагирует сразу на включение и выключение рецепта.
    if ProductionPoint ~= nil
        and ProductionPoint.setProductionState ~= nil then

        ProductionPoint.setProductionState =
            Utils.appendedFunction(
                ProductionPoint.setProductionState,
                function(productionPoint, productionId, isEnabled, noEventSend)
                    local placeable =
                        PFV.placeablesByProductionPoint[productionPoint]

                    if placeable ~= nil then
                        PFV:updatePlaceable(
                            placeable
                        )
                    end
                end
            )
    end

    Logging.info(
        "%s hooks installed, version=%s",
        self.LOG_PREFIX,
        self.VERSION
    )
end

PFV:installHooks()
