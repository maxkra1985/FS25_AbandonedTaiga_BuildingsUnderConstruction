--[[
    ConstructibleProgressMeshes.lua

    Расширение штатного ConstructibleStateBuilding без создания нового класса состояния.
    Добавляет в XML строительных состояний элементы <toggleProgressMesh>.

    Поддерживаются два режима:
    1. progressStepByStep="true"
       Все Shape внутри указанной ноды рекурсивно отображаются по одному по мере роста прогресса.\n       TransformGroup используются только для организации Scenegraph.
    2. progressStepMin / progressStepMax
       Все Shape внутри указанной ноды включаются только в заданном диапазоне прогресса.

    progressFillType можно задать:
    - у state: используется как значение по умолчанию для всех toggleProgressMesh;
    - у отдельного toggleProgressMesh: переопределяет значение state.

    Если progressFillType не задан, прогресс рассчитывается по общему объёму
    израсходованных материалов состояния, аналогично штатному ConstructibleStateBuilding.

    В construction preview постоянные пошаговые фазы показываются полностью,
    а временные диапазонные props скрываются.
]]

ConstructibleProgressMeshes = ConstructibleProgressMeshes or {}

local CPM = ConstructibleProgressMeshes
CPM.VERSION = "0.6.0"

local PROGRESS_EPSILON = 0.0000001


-- Возвращает значение, ограниченное диапазоном 0..1.
local function clampProgress(value)
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end

    return value
end


-- Изменяет видимость Shape и, если требуется, синхронно меняет его физику.
-- Возвращает true, если фактическая видимость Shape отличалась от требуемой.
local function setNodeState(node, isVisible, updatePhysics, force)
    local visibilityChanged = getVisibility(node) ~= isVisible

    if force or visibilityChanged then
        if updatePhysics then
            if isVisible then
                addToPhysics(node)
            else
                removeFromPhysics(node)
            end
        end

        setVisibility(node, isVisible)
    end

    return visibilityChanged
end


-- Собирает Shape и все вложенные в него Shape.
-- Такая группа является одной неделимой визуальной единицей progressStepByStep.
local function collectShapeTree(node, shapes)
    if getHasClassId(node, ClassIds.SHAPE) then
        table.insert(shapes, node)
    end

    local numChildren = getNumOfChildren(node)

    for childIndex = 0, numChildren - 1 do
        collectShapeTree(getChildAt(node, childIndex), shapes)
    end
end


-- Собирает визуальные единицы внутри ноды в порядке Scenegraph.
-- TransformGroup служит только контейнером. Как только найден Shape,
-- он становится одной единицей, а вложенные Shape входят в ту же единицу.
local function collectShapeUnits(node, units)
    if getHasClassId(node, ClassIds.SHAPE) then
        local unit = {
            root = node,
            shapes = {}
        }

        collectShapeTree(node, unit.shapes)
        table.insert(units, unit)
        return
    end

    local numChildren = getNumOfChildren(node)

    for childIndex = 0, numChildren - 1 do
        collectShapeUnits(getChildAt(node, childIndex), units)
    end
end


-- Переключает видимость и физику всех Shape одной визуальной единицы.
-- Даже если кэш прогресса не изменился, фактическая visibility каждого Shape проверяется отдельно.
local function setShapeUnitState(unit, isVisible, updatePhysics, force)
    local changed = false

    for _, shape in ipairs(unit.shapes) do
        changed = setNodeState(shape, isVisible, updatePhysics, force) or changed
    end

    return changed
end


-- Переключает все Shape, принадлежащие одному toggleProgressMesh.
local function setEntryShapesState(entry, isVisible, force)
    local changed = false

    for _, unit in ipairs(entry.units) do
        changed = setShapeUnitState(unit, isVisible, entry.updatePhysics, force) or changed
    end

    return changed
end


-- Возвращает индекс состояния в штатной stateMachine.
local function getStateIndex(state)
    local constructible = state.constructible
    local spec = constructible ~= nil and constructible.spec_constructible or nil

    if spec == nil or spec.stateMachine == nil then
        return nil
    end

    for index, currentState in ipairs(spec.stateMachine) do
        if currentState == state then
            return index
        end
    end

    return nil
end


-- Проверяет, является ли состояние текущим активным состоянием constructible.
local function getIsCurrentState(state)
    local constructible = state.constructible
    local spec = constructible ~= nil and constructible.spec_constructible or nil

    if spec == nil or spec.stateMachine == nil or spec.stateIndex == nil then
        return false
    end

    return spec.stateMachine[spec.stateIndex] == state
end


-- Находит input состояния, соответствующий указанному fillType.
local function findProgressInput(state, fillType)
    if fillType == nil then
        return nil
    end

    for _, input in ipairs(state.inputs) do
        if input.fillType ~= nil and input.fillType.index == fillType.index then
            return input
        end
    end

    return nil
end


-- Рассчитывает текущий прогресс для одного toggleProgressMesh.
-- При наличии progressFillType учитывается только выбранный input,
-- иначе используется суммарный расход всех материалов состояния.
local function getEntryProgress(state, entry)
    if entry.progressInput ~= nil then
        local input = entry.progressInput

        if input.amount == nil or input.amount <= 0 then
            return 0
        end

        return clampProgress((input.amount - input.remainingAmount) / input.amount)
    end

    if state.totalAmount == nil or state.totalAmount <= 0 then
        return 0
    end

    local usedAmount = 0

    for _, input in ipairs(state.inputs) do
        usedAmount = usedAmount + (input.amount - input.remainingAmount)
    end

    return clampProgress(usedAmount / state.totalAmount)
end


-- Определяет, входит ли процент прогресса в диапазон progressStepMin/progressStepMax.
-- При 0% все диапазонные props скрыты. После начала расхода диапазоны полуоткрытые:
-- [min, max), кроме max=100, где 100 включён. Это исключает наложение соседних диапазонов.
local function isProgressInRange(progress, stepMin, stepMax)
    local percent = clampProgress(progress) * 100

    -- При полном отсутствии расхода материалов не показываем ни один временный props.
    if percent <= PROGRESS_EPSILON then
        return false
    end

    if stepMax >= 100 then
        return percent >= stepMin and percent <= stepMax + PROGRESS_EPSILON
    end

    return percent >= stepMin and percent < stepMax
end


-- Применяет прогресс к пошаговой ноде.
-- Каждый найденный рекурсивно Shape является одним шагом строительства; вложенный Shape не разбирается дальше.
local function applyStepByStepProgress(entry, progress, force)
    local numUnits = #entry.units

    if numUnits == 0 then
        return false
    end

    local visibleCount = math.floor(clampProgress(progress) * numUnits + PROGRESS_EPSILON)
    visibleCount = math.max(0, math.min(numUnits, visibleCount))

    local changed = entry.lastVisibleCount ~= visibleCount

    for index, unit in ipairs(entry.units) do
        local baseVisible = index <= visibleCount
        local shouldBeVisible = entry.active and baseVisible or not baseVisible

        -- Проверяем реальное состояние Shape, а не только наше сохранённое значение.
        -- Это важно после штатного finalizePlacement/addToPhysics и при загрузке savegame.
        changed = setShapeUnitState(unit, shouldBeVisible, entry.updatePhysics, force) or changed
        entry.unitVisibility[index] = shouldBeVisible
    end

    entry.lastVisibleCount = visibleCount

    return changed
end


-- Применяет прогресс к ноде, которая целиком показывается только внутри заданного диапазона.
local function applyRangeProgress(entry, progress, force)
    local inRange = isProgressInRange(progress, entry.progressStepMin, entry.progressStepMax)
    local shouldBeVisible = entry.active and inRange or not inRange

    local changed = entry.lastVisibility ~= shouldBeVisible

    -- Диапазонные props также проверяются по фактической visibility каждого Shape.
    changed = setEntryShapesState(entry, shouldBeVisible, force) or changed
    entry.lastVisibility = shouldBeVisible

    return changed
end


-- Применяет конкретное значение прогресса ко всем toggleProgressMesh состояния.
local function applyProgressValue(state, progress, force, raiseDirtyFlag)
    if state.progressToggleMeshes == nil then
        return
    end

    local changed = false

    for _, entry in ipairs(state.progressToggleMeshes) do
        if not entry.disabled then
            local entryChanged

            if entry.progressStepByStep then
                entryChanged = applyStepByStepProgress(entry, progress, force)
            else
                entryChanged = applyRangeProgress(entry, progress, force)
            end

            changed = changed or entryChanged
        end
    end

    -- При изменении очередного шага принудительно отправляем штатное состояние inputs.
    -- Клиент сам пересчитает видимость из синхронизированного remainingAmount.
    if changed and raiseDirtyFlag and state.constructible.isServer then
        state.constructible:raiseDirtyFlags(state.dirtyFlag)
    end
end


-- Пересчитывает каждый toggleProgressMesh по его собственному источнику прогресса.
local function updateProgressMeshes(state, force, raiseDirtyFlag)
    if state.progressToggleMeshes == nil then
        return
    end

    local changed = false

    for _, entry in ipairs(state.progressToggleMeshes) do
        if not entry.disabled then
            local progress = getEntryProgress(state, entry)
            local entryChanged

            if entry.progressStepByStep then
                entryChanged = applyStepByStepProgress(entry, progress, force)
            else
                entryChanged = applyRangeProgress(entry, progress, force)
            end

            changed = changed or entryChanged
        end
    end

    if changed and raiseDirtyFlag and state.constructible.isServer then
        state.constructible:raiseDirtyFlags(state.dirtyFlag)
    end
end


-- Полностью скрывает прогрессивные элементы неактивного/сброшенного состояния.
local function resetProgressMeshes(state)
    if state.progressToggleMeshes == nil then
        return
    end

    for _, entry in ipairs(state.progressToggleMeshes) do
        setEntryShapesState(entry, false, true)

        for index = 1, #entry.units do
            entry.unitVisibility[index] = false
        end

        entry.lastVisibleCount = 0
        entry.lastVisibility = false
    end
end


-- Устанавливает визуал полностью завершённой строительной стадии.
-- Постоянная геометрия остаётся построенной, временные диапазонные props скрываются.
local function finishProgressMeshes(state)
    if state.progressToggleMeshes == nil then
        return
    end

    for _, entry in ipairs(state.progressToggleMeshes) do
        if not entry.disabled then
            if entry.progressStepByStep then
                applyStepByStepProgress(entry, 1, true)
            else
                setEntryShapesState(entry, false, true)
                entry.lastVisibility = false
            end
        end
    end
end


-- Загружает настройки toggleProgressMesh для одного ConstructibleStateBuilding.
function CPM.loadState(state, xmlFile, key)
    state.progressToggleMeshes = {}

    local stateProgressFillTypeName = xmlFile:getString(key .. "#progressFillType")

    for _, progressKey in xmlFile:iterator(key .. ".toggleProgressMesh") do
        local node = xmlFile:getNode(
            progressKey .. "#node",
            nil,
            state.constructible.components,
            state.constructible.i3dMappings
        )

        if node ~= nil then
            local entry = {
                node = node,
                active = xmlFile:getBool(progressKey .. "#active", true),
                updatePhysics = xmlFile:getBool(progressKey .. "#updatePhysics", false),
                progressStepByStep = xmlFile:getBool(progressKey .. "#progressStepByStep", false),
                progressStepMin = xmlFile:getFloat(progressKey .. "#progressStepMin", 0),
                progressStepMax = xmlFile:getFloat(progressKey .. "#progressStepMax", 100),
                units = {},
                unitVisibility = {},
                shapeCount = 0,
                disabled = false
            }

            -- Любой toggleProgressMesh управляет конкретными Shape внутри своей ноды.
            -- Для progressStepByStep units задают последовательность появления.
            -- Для progressStepMin/progressStepMax все найденные Shape переключаются вместе.
            collectShapeUnits(node, entry.units)

            for _, unit in ipairs(entry.units) do
                entry.shapeCount = entry.shapeCount + #unit.shapes
            end

            if #entry.units == 0 then
                Logging.xmlError(
                    xmlFile,
                    "toggleProgressMesh '%s' at '%s' contains no Shape nodes",
                    getName(node),
                    progressKey
                )
                entry.disabled = true
            end

            if not entry.progressStepByStep then
                if entry.progressStepMin < 0
                    or entry.progressStepMin > 100
                    or entry.progressStepMax < 0
                    or entry.progressStepMax > 100
                    or entry.progressStepMax < entry.progressStepMin then

                    Logging.xmlError(
                        xmlFile,
                        "Invalid progress range %.3f..%.3f at '%s'. Expected 0 <= min <= max <= 100",
                        entry.progressStepMin,
                        entry.progressStepMax,
                        progressKey
                    )
                    entry.disabled = true
                end
            end

            local progressFillTypeName = xmlFile:getString(
                progressKey .. "#progressFillType",
                stateProgressFillTypeName
            )

            if progressFillTypeName ~= nil and progressFillTypeName ~= "" then
                local fillType = g_fillTypeManager:getFillTypeByName(progressFillTypeName)

                if fillType == nil then
                    Logging.xmlError(
                        xmlFile,
                        "Unknown progressFillType '%s' at '%s'",
                        tostring(progressFillTypeName),
                        progressKey
                    )
                    entry.disabled = true
                else
                    entry.progressInput = findProgressInput(state, fillType)

                    if entry.progressInput == nil then
                        Logging.xmlError(
                            xmlFile,
                            "progressFillType '%s' at '%s' is not defined as an input of this construction state",
                            fillType.name,
                            progressKey
                        )
                        entry.disabled = true
                    end
                end
            end

            table.insert(state.progressToggleMeshes, entry)
        end
    end

    -- До активации состояния его строительные и временные элементы не должны быть видимы.
    resetProgressMeshes(state)
end


-- Загружает toggleProgressMesh для всех ConstructibleStateBuilding уже после того,
-- как штатный PlaceableConstructible создал stateMachine. Используются raw XML getters,
-- поэтому работа не зависит от того, успел ли мод зарегистрировать дополнительные schema paths.
function CPM.loadPlaceableStates(constructible)
    if constructible == nil or constructible.xmlFile == nil then
        return
    end

    local spec = constructible.spec_constructible

    if spec == nil or spec.stateMachine == nil then
        return
    end

    local loadedStates = 0
    local loadedEntries = 0

    for stateIndex, stateKey in constructible.xmlFile:iterator(
        "placeable.constructible.stateMachine.states.state"
    ) do
        local state = spec.stateMachine[stateIndex]

        if state ~= nil and state:isa(ConstructibleStateBuilding) then
            CPM.loadState(state, constructible.xmlFile, stateKey)
            loadedStates = loadedStates + 1
            loadedEntries = loadedEntries + #state.progressToggleMeshes
        end
    end

    if loadedEntries > 0 then
        Logging.info(
            "ConstructibleProgressMeshes v%s: configured %d entries in %d state(s) for '%s' (propertyState=%s, stateIndex=%s)",
            CPM.VERSION,
            loadedEntries,
            loadedStates,
            tostring(constructible.configFileName),
            tostring(constructible.propertyState),
            tostring(spec.stateIndex)
        )
    end
end


-- Формирует чистую проекцию законченного объекта для construction preview.
-- Постоянная геометрия progressStepByStep показывается полностью, а временные
-- props с progressStepMin/progressStepMax всегда скрываются и исключаются из физики.
local function applyConstructionPreviewVisuals(constructible)
    local spec = constructible ~= nil and constructible.spec_constructible or nil

    if spec == nil or spec.stateMachine == nil then
        return
    end

    for _, state in ipairs(spec.stateMachine) do
        if state.progressToggleMeshes ~= nil then
            for _, entry in ipairs(state.progressToggleMeshes) do
                if not entry.disabled then
                    if entry.progressStepByStep then
                        applyStepByStepProgress(entry, 1, true)
                    else
                        setEntryShapesState(entry, false, true)
                        entry.lastVisibility = false
                    end
                end
            end
        end
    end
end


-- Приводит прогрессивный визуал всей state machine к фактическому текущему состоянию.
-- В construction preview показывается законченная постоянная геометрия без временных props.
-- Для размещённого объекта завершённые стадии показываются полностью, текущая
-- восстанавливается из remainingAmount, а все будущие стадии полностью скрываются.
function CPM.synchronizeStateMachineVisuals(constructible)
    if constructible == nil then
        return
    end

    local spec = constructible.spec_constructible

    if spec == nil or spec.stateMachine == nil then
        return
    end

    if constructible.propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW then
        applyConstructionPreviewVisuals(constructible)
        return
    end

    if spec.stateIndex == nil or spec.stateIndex < 1 then
        return
    end

    for stateIndex, state in ipairs(spec.stateMachine) do
        if state.progressToggleMeshes ~= nil then
            if stateIndex < spec.stateIndex then
                finishProgressMeshes(state)
            elseif stateIndex == spec.stateIndex then
                updateProgressMeshes(state, true, false)
            else
                resetProgressMeshes(state)
            end
        end
    end
end


-- Регистрирует XML-пути и устанавливает перехватчики штатного ConstructibleStateBuilding.
function CPM.install()
    if ConstructibleStateBuilding == nil then
        Logging.error("ConstructibleProgressMeshes: ConstructibleStateBuilding is not available")
        return
    end

    if ConstructibleStateBuilding.progressToggleMeshesInstalled then
        return
    end

    ConstructibleStateBuilding.progressToggleMeshesInstalled = true

    local superRegisterXMLPaths = ConstructibleStateBuilding.registerXMLPaths
    ConstructibleStateBuilding.registerXMLPaths = function(schema, basePath)
        superRegisterXMLPaths(schema, basePath)

        schema:register(
            XMLValueType.STRING,
            basePath .. "#progressFillType",
            "Default fill type used to calculate toggleProgressMesh progress"
        )
        schema:register(
            XMLValueType.NODE_INDEX,
            basePath .. ".toggleProgressMesh(?)#node",
            "Node controlled by construction progress"
        )
        schema:register(
            XMLValueType.BOOL,
            basePath .. ".toggleProgressMesh(?)#active",
            "Normal or inverted visibility",
            true
        )
        schema:register(
            XMLValueType.BOOL,
            basePath .. ".toggleProgressMesh(?)#updatePhysics",
            "Update node physics together with visibility",
            false
        )
        schema:register(
            XMLValueType.BOOL,
            basePath .. ".toggleProgressMesh(?)#progressStepByStep",
            "Show Shape units recursively one by one",
            false
        )
        schema:register(
            XMLValueType.FLOAT,
            basePath .. ".toggleProgressMesh(?)#progressStepMin",
            "Minimum progress percentage for full-node visibility",
            0
        )
        schema:register(
            XMLValueType.FLOAT,
            basePath .. ".toggleProgressMesh(?)#progressStepMax",
            "Maximum progress percentage for full-node visibility",
            100
        )
        schema:register(
            XMLValueType.STRING,
            basePath .. ".toggleProgressMesh(?)#progressFillType",
            "Fill type used to calculate progress for this node"
        )
    end

    -- Штатный onLoad сначала полностью создаёт stateMachine. Только после этого
    -- разбираем наши дополнительные XML-элементы и восстанавливаем preview при необходимости.
    if PlaceableConstructible ~= nil
        and PlaceableConstructible.onLoad ~= nil
        and not PlaceableConstructible.progressMeshesOnLoadInstalled then

        PlaceableConstructible.progressMeshesOnLoadInstalled = true

        PlaceableConstructible.onLoad =
            Utils.appendedFunction(
                PlaceableConstructible.onLoad,
                function(constructible, savegame)
                    CPM.loadPlaceableStates(constructible)
                    CPM.synchronizeStateMachineVisuals(constructible)
                end
            )
    end

    local superActivate = ConstructibleStateBuilding.activate
    ConstructibleStateBuilding.activate = function(state)
        superActivate(state)

        -- При активации восстанавливаем визуал из текущих remainingAmount.
        updateProgressMeshes(state, true, false)
    end

    local superDeactivate = ConstructibleStateBuilding.deactivate
    ConstructibleStateBuilding.deactivate = function(state)
        local ownStateIndex = getStateIndex(state)
        local spec = state.constructible ~= nil and state.constructible.spec_constructible or nil
        local targetStateIndex = spec ~= nil and spec.stateIndex or nil

        state.progressMeshesSuppressUpdate = true
        superDeactivate(state)
        state.progressMeshesSuppressUpdate = false

        if ownStateIndex ~= nil and targetStateIndex ~= nil then
            if targetStateIndex > ownStateIndex then
                -- Постоянная часть завершённой стадии остаётся, временные props убираются.
                finishProgressMeshes(state)
            elseif targetStateIndex < ownStateIndex then
                -- При откате назад элементы более позднего состояния должны исчезнуть.
                resetProgressMeshes(state)
            end
        end
    end

    local superReset = ConstructibleStateBuilding.reset
    ConstructibleStateBuilding.reset = function(state)
        state.progressMeshesSuppressUpdate = true
        superReset(state)
        state.progressMeshesSuppressUpdate = false

        -- Неактивное состояние при сбросе не должно показывать даже диапазон 0..N.
        resetProgressMeshes(state)
    end

    local superUpdate = ConstructibleStateBuilding.update
    ConstructibleStateBuilding.update = function(state, dt)
        superUpdate(state, dt)

        -- Штатный update расходует inputs последовательно. Здесь пересчитываем визуал
        -- ещё раз после обработки всех материалов, чтобы итоговый процент кадра был точным.
        if getIsCurrentState(state) then
            updateProgressMeshes(state, false, true)
        end
    end

    local superUpdateRemainingAmount = ConstructibleStateBuilding.updateRemainingAmount
    ConstructibleStateBuilding.updateRemainingAmount = function(state, input, amount)
        superUpdateRemainingAmount(state, input, amount)

        -- Этот метод вызывается штатным кодом при каждом фактическом расходовании материала,
        -- а также при сетевой синхронизации и загрузке сохранения.
        if not state.progressMeshesSuppressUpdate and getIsCurrentState(state) then
            updateProgressMeshes(state, false, true)
        end
    end

    -- После размещения штатный код может восстановить stateIndex уже после
    -- первичной настройки Scenegraph. Повторно синхронизируем весь прогрессивный
    -- визуал по фактическому состоянию constructible и remainingAmount.
    if PlaceableConstructible ~= nil
        and PlaceableConstructible.onFinalizePlacement ~= nil
        and not PlaceableConstructible.progressMeshesFinalizeSyncInstalled then

        PlaceableConstructible.progressMeshesFinalizeSyncInstalled = true

        PlaceableConstructible.onFinalizePlacement =
            Utils.appendedFunction(
                PlaceableConstructible.onFinalizePlacement,
                function(constructible, savegame)
                    CPM.synchronizeStateMachineVisuals(constructible)

                    local spec = constructible.spec_constructible
                    local state = spec ~= nil and spec.stateMachine ~= nil
                        and spec.stateMachine[spec.stateIndex] or nil

                    if state ~= nil and state.progressToggleMeshes ~= nil then
                        for _, entry in ipairs(state.progressToggleMeshes) do
                            if entry.progressStepByStep and not entry.disabled then
                                Logging.info(
                                    "ConstructibleProgressMeshes v%s: finalized '%s' state=%s progress=%.4f visibleUnits=%d/%d shapes=%d",
                                    CPM.VERSION,
                                    tostring(constructible.configFileName),
                                    tostring(state.name),
                                    getEntryProgress(state, entry),
                                    entry.lastVisibleCount or -1,
                                    #entry.units,
                                    entry.shapeCount or 0
                                )
                                break
                            end
                        end
                    end
                end
            )
    end

    -- После первичного MP stream штатный код последовательно проигрывает состояния.
    -- Финальная нормализация гарантирует, что будущие стадии не сохранят визуал
    -- от промежуточных переходов, а текущая стадия точно соответствует remainingAmount.
    if PlaceableConstructible ~= nil
        and PlaceableConstructible.onReadStream ~= nil
        and not PlaceableConstructible.progressMeshesReadStreamSyncInstalled then

        PlaceableConstructible.progressMeshesReadStreamSyncInstalled = true

        PlaceableConstructible.onReadStream =
            Utils.appendedFunction(
                PlaceableConstructible.onReadStream,
                function(constructible, streamId, connection)
                    CPM.synchronizeStateMachineVisuals(constructible)
                end
            )
    end

    -- Placeable:finalizePlacement() сначала вызывает все specialization events и
    -- только после них завершается полностью. Этот hook выполняется последним и ещё раз
    -- приводит progress-геометрию к фактическому stateIndex/remainingAmount.
    -- На клиенте до onReadStream stateIndex может быть -1; там финальная синхронизация
    -- выполняется существующим onReadStream hook.
    if Placeable ~= nil
        and Placeable.finalizePlacement ~= nil
        and not Placeable.progressMeshesPlaceableFinalizeInstalled then

        Placeable.progressMeshesPlaceableFinalizeInstalled = true

        Placeable.finalizePlacement =
            Utils.appendedFunction(
                Placeable.finalizePlacement,
                function(placeable)
                    if placeable ~= nil
                        and placeable.spec_constructible ~= nil then
                        CPM.synchronizeStateMachineVisuals(placeable)
                    end
                end
            )
    end

    Logging.info("ConstructibleProgressMeshes v%s: installed", CPM.VERSION)
end


CPM.install()
