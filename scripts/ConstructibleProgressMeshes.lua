--[[
    ConstructibleProgressMeshes.lua

    Расширение штатного ConstructibleStateBuilding без создания нового класса состояния.
    Добавляет в XML строительных состояний элементы <toggleProgressMesh>.

    Поддерживаются два режима:
    1. progressStepByStep="true"
       Все Shape внутри указанной ноды рекурсивно отображаются по одному по мере роста прогресса.\n       TransformGroup используются только для организации Scenegraph.
    2. progressStepMin / progressStepMax
       Вся указанная нода включается только в заданном диапазоне прогресса.

    progressFillType можно задать:
    - у state: используется как значение по умолчанию для всех toggleProgressMesh;
    - у отдельного toggleProgressMesh: переопределяет значение state.

    Если progressFillType не задан, прогресс рассчитывается по общему объёму
    израсходованных материалов состояния, аналогично штатному ConstructibleStateBuilding.
]]

ConstructibleProgressMeshes = ConstructibleProgressMeshes or {}

local CPM = ConstructibleProgressMeshes
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


-- Изменяет видимость узла и, если требуется, синхронно меняет его физику.
local function setNodeState(node, isVisible, updatePhysics)
    if updatePhysics then
        if isVisible then
            addToPhysics(node)
        else
            removeFromPhysics(node)
        end
    end

    setVisibility(node, isVisible)
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
-- Диапазоны сделаны полуоткрытыми: [min, max), кроме max=100, где 100 включён.
-- Это исключает одновременное отображение соседних диапазонов на общей границе.
local function isProgressInRange(progress, stepMin, stepMax)
    local percent = clampProgress(progress) * 100

    if stepMax >= 100 then
        return percent >= stepMin and percent <= stepMax + PROGRESS_EPSILON
    end

    return percent >= stepMin and percent < stepMax
end


-- Применяет прогресс к пошаговой ноде.
-- Каждый прямой дочерний узел является одним шагом строительства.
local function applyStepByStepProgress(entry, progress, force)
    local numChildren = #entry.children

    if numChildren == 0 then
        return false
    end

    local visibleCount = math.floor(clampProgress(progress) * numChildren + PROGRESS_EPSILON)
    visibleCount = math.max(0, math.min(numChildren, visibleCount))

    if not force and entry.lastVisibleCount == visibleCount then
        return false
    end

    setVisibility(entry.node, true)

    local changed = entry.lastVisibleCount ~= visibleCount

    for index, child in ipairs(entry.children) do
        local baseVisible = index <= visibleCount
        local shouldBeVisible = entry.active and baseVisible or not baseVisible

        if force or entry.childVisibility[index] ~= shouldBeVisible then
            setNodeState(child, shouldBeVisible, entry.updatePhysics)
            entry.childVisibility[index] = shouldBeVisible
        end
    end

    entry.lastVisibleCount = visibleCount

    return changed
end


-- Применяет прогресс к ноде, которая целиком показывается только внутри заданного диапазона.
local function applyRangeProgress(entry, progress, force)
    local inRange = isProgressInRange(progress, entry.progressStepMin, entry.progressStepMax)
    local shouldBeVisible = entry.active and inRange or not inRange

    if not force and entry.lastVisibility == shouldBeVisible then
        return false
    end

    local changed = entry.lastVisibility ~= shouldBeVisible

    setNodeState(entry.node, shouldBeVisible, entry.updatePhysics)
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
        if entry.progressStepByStep then
            for index, child in ipairs(entry.children) do
                setNodeState(child, false, entry.updatePhysics)
                entry.childVisibility[index] = false
            end

            setVisibility(entry.node, false)
            entry.lastVisibleCount = nil
        else
            setNodeState(entry.node, false, entry.updatePhysics)
            entry.lastVisibility = nil
        end
    end
end


-- Загружает настройки toggleProgressMesh для одного ConstructibleStateBuilding.
function CPM.loadState(state, xmlFile, key)
    state.progressToggleMeshes = {}

    local stateProgressFillTypeName = xmlFile:getValue(key .. "#progressFillType")

    for _, progressKey in xmlFile:iterator(key .. ".toggleProgressMesh") do
        local node = xmlFile:getValue(
            progressKey .. "#node",
            nil,
            state.constructible.components,
            state.constructible.i3dMappings
        )

        if node ~= nil then
            local entry = {
                node = node,
                active = xmlFile:getValue(progressKey .. "#active", true),
                updatePhysics = xmlFile:getValue(progressKey .. "#updatePhysics", false),
                progressStepByStep = xmlFile:getValue(progressKey .. "#progressStepByStep", false),
                progressStepMin = xmlFile:getValue(progressKey .. "#progressStepMin", 0),
                progressStepMax = xmlFile:getValue(progressKey .. "#progressStepMax", 100),
                children = {},
                childVisibility = {},
                disabled = false
            }

            if entry.progressStepByStep then
                -- TransformGroup используется только как структурный контейнер.
                -- Шагами являются все Shape внутри ноды, собранные рекурсивно
                -- в порядке Scenegraph: row01, затем row02 и т.д.
                local function collectStepShapes(parentNode)
                    local numChildren = getNumOfChildren(parentNode)

                    for childIndex = 0, numChildren - 1 do
                        local child = getChildAt(parentNode, childIndex)

                        if getHasClassId(child, ClassIds.SHAPE) then
                            table.insert(entry.children, child)
                        elseif getNumOfChildren(child) > 0 then
                            collectStepShapes(child)
                        end
                    end
                end

                collectStepShapes(node)

                if #entry.children == 0 then
                    Logging.xmlError(
                        xmlFile,
                        "toggleProgressMesh '%s' at '%s' uses progressStepByStep but contains no Shape nodes",
                        getName(node),
                        progressKey
                    )
                    entry.disabled = true
                end
            else
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

            local progressFillTypeName = xmlFile:getValue(
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
            "Show direct child nodes one by one",
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

    local superLoad = ConstructibleStateBuilding.load
    ConstructibleStateBuilding.load = function(state, xmlFile, key)
        superLoad(state, xmlFile, key)
        CPM.loadState(state, xmlFile, key)
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
                -- При нормальном переходе вперёд завершённая строительная часть остаётся построенной.
                applyProgressValue(state, 1, true, false)
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

    local superUpdateRemainingAmount = ConstructibleStateBuilding.updateRemainingAmount
    ConstructibleStateBuilding.updateRemainingAmount = function(state, input, amount)
        superUpdateRemainingAmount(state, input, amount)

        -- Этот метод вызывается штатным кодом при каждом фактическом расходовании материала,
        -- а также при сетевой синхронизации и загрузке сохранения.
        if not state.progressMeshesSuppressUpdate and getIsCurrentState(state) then
            updateProgressMeshes(state, false, true)
        end
    end

    Logging.info("ConstructibleProgressMeshes: installed")
end


CPM.install()
