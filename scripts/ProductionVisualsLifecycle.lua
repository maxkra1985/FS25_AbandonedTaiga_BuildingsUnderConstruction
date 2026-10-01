--[[
    Shared lifecycle dispatcher for ProductionPoint visual extensions.

    BunkerFillPlanes and ProductionFillVolumes implement different visual systems
    and remain independent modules. This file owns their common hooks into
    PlaceableProductionPoint / ProductionPoint so the same GIANTS functions are
    wrapped only once even when one placeable uses both systems.
]]

ProductionVisualsLifecycle = ProductionVisualsLifecycle or {}

local PVL = ProductionVisualsLifecycle
PVL.VERSION = "1.0.0.0"
PVL.LOG_PREFIX = "[ProductionVisualsLifecycle]"
PVL.modules = PVL.modules or {}
PVL.moduleNames = PVL.moduleNames or {}
PVL.hooksInstalled = PVL.hooksInstalled or false

function PVL:registerModule(name, module)
    if module == nil then
        Logging.error("%s unable to register nil module '%s'", self.LOG_PREFIX, tostring(name))
        return
    end

    if self.moduleNames[name] ~= nil then
        return
    end

    self.moduleNames[name] = module
    table.insert(self.modules, module)

    self:installHooks()

    Logging.info("%s registered module '%s'", self.LOG_PREFIX, tostring(name))
end

function PVL:dispatch(methodName, ...)
    for _, module in ipairs(self.modules) do
        local callback = module[methodName]
        if callback ~= nil then
            callback(module, ...)
        end
    end
end

function PVL:installHooks()
    if self.hooksInstalled then
        return
    end

    if PlaceableProductionPoint == nil then
        Logging.error("%s PlaceableProductionPoint is not available", self.LOG_PREFIX)
        return
    end

    self.hooksInstalled = true

    PlaceableProductionPoint.registerXMLPaths =
        Utils.appendedFunction(
            PlaceableProductionPoint.registerXMLPaths,
            function(schema, basePath)
                PVL:dispatch("registerXMLPaths", schema, basePath)
            end
        )

    PlaceableProductionPoint.onLoad =
        Utils.appendedFunction(
            PlaceableProductionPoint.onLoad,
            function(placeable, savegame)
                PVL:dispatch("loadPlaceable", placeable, savegame)
            end
        )

    PlaceableProductionPoint.onFinalizePlacement =
        Utils.appendedFunction(
            PlaceableProductionPoint.onFinalizePlacement,
            function(placeable)
                PVL:dispatch("connectStorage", placeable)
            end
        )

    PlaceableProductionPoint.onReadStream =
        Utils.appendedFunction(
            PlaceableProductionPoint.onReadStream,
            function(placeable, streamId, connection)
                PVL:dispatch("connectStorage", placeable)
                PVL:dispatch("updatePlaceable", placeable)
            end
        )

    PlaceableProductionPoint.finalizeConstruction =
        Utils.appendedFunction(
            PlaceableProductionPoint.finalizeConstruction,
            function(placeable)
                PVL:dispatch("connectStorage", placeable)
                PVL:dispatch("updatePlaceable", placeable)
            end
        )

    PlaceableProductionPoint.onDelete =
        Utils.prependedFunction(
            PlaceableProductionPoint.onDelete,
            function(placeable)
                PVL:dispatch("deletePlaceable", placeable)
            end
        )

    if ProductionPoint ~= nil and ProductionPoint.setProductionState ~= nil then
        ProductionPoint.setProductionState =
            Utils.appendedFunction(
                ProductionPoint.setProductionState,
                function(productionPoint, productionId, isEnabled, noEventSend)
                    PVL:dispatch(
                        "onProductionStateChanged",
                        productionPoint,
                        productionId,
                        isEnabled,
                        noEventSend
                    )
                end
            )
    end

    Logging.info("%s hooks installed, version=%s", self.LOG_PREFIX, self.VERSION)
end
