MeatAnimalMoveEvent = {}

MeatAnimalMoveEvent.SUCCESS = 0
MeatAnimalMoveEvent.ERROR_NO_PERMISSION = 1
MeatAnimalMoveEvent.ERROR_SOURCE_MISSING = 2
MeatAnimalMoveEvent.ERROR_TARGET_MISSING = 3
MeatAnimalMoveEvent.ERROR_INVALID_CLUSTER = 4
MeatAnimalMoveEvent.ERROR_ANIMAL_NOT_SUPPORTED = 5
MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_SPACE = 6
MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_ANIMALS = 7
MeatAnimalMoveEvent.ERROR_INTERNAL = 8

local MeatAnimalMoveEvent_mt = Class(MeatAnimalMoveEvent, Event)

-- IMPORTANT: custom/mod events must use InitEventClass. InitStaticEventClass is for
-- base-game static events and is not callable from the FS25 mod sandbox.
InitEventClass(MeatAnimalMoveEvent, "MeatAnimalMoveEvent")

function MeatAnimalMoveEvent.emptyNew()
    return Event.new(MeatAnimalMoveEvent_mt)
end

function MeatAnimalMoveEvent.new(sourceObject, targetObject, clusterId, numAnimals)
    local self = MeatAnimalMoveEvent.emptyNew()
    self.sourceObject = sourceObject
    self.targetObject = targetObject
    self.clusterId = clusterId
    self.numAnimals = numAnimals
    return self
end

function MeatAnimalMoveEvent.newServerToClient(errorCode, movedWeight)
    local self = MeatAnimalMoveEvent.emptyNew()
    self.errorCode = errorCode or MeatAnimalMoveEvent.ERROR_INTERNAL
    self.movedWeight = movedWeight or 0
    return self
end

function MeatAnimalMoveEvent:readStream(streamId, connection)
    -- Same direction convention as the vanilla AnimalMoveEvent:
    -- connection:getIsServer() == true  -> client is reading a server response
    -- connection:getIsServer() == false -> server is reading a client request
    if connection:getIsServer() then
        self.errorCode = streamReadUIntN(streamId, 4)
        self.movedWeight = streamReadFloat32(streamId)
    else
        self.sourceObject = NetworkUtil.readNodeObject(streamId)
        self.targetObject = NetworkUtil.readNodeObject(streamId)
        self.clusterId = streamReadInt32(streamId)
        self.numAnimals = streamReadUInt8(streamId)
    end

    self:run(connection)
end

function MeatAnimalMoveEvent:writeStream(streamId, connection)
    if connection:getIsServer() then
        NetworkUtil.writeNodeObject(streamId, self.sourceObject)
        NetworkUtil.writeNodeObject(streamId, self.targetObject)
        streamWriteInt32(streamId, self.clusterId)
        streamWriteUInt8(streamId, self.numAnimals)
    else
        streamWriteUIntN(streamId, self.errorCode or MeatAnimalMoveEvent.ERROR_INTERNAL, 4)
        streamWriteFloat32(streamId, self.movedWeight or 0)
    end
end

function MeatAnimalMoveEvent.validate(sourceObject, targetObject, clusterId, numAnimals, farmId)
    if sourceObject == nil then
        return MeatAnimalMoveEvent.ERROR_SOURCE_MISSING
    end

    if targetObject == nil or targetObject.meatAnimalCanAcceptCluster == nil then
        return MeatAnimalMoveEvent.ERROR_TARGET_MISSING
    end

    if farmId == nil then
        return MeatAnimalMoveEvent.ERROR_NO_PERMISSION
    end

    if not g_currentMission.accessHandler:canFarmAccess(farmId, sourceObject) then
        return MeatAnimalMoveEvent.ERROR_NO_PERMISSION
    end

    if not g_currentMission.accessHandler:canFarmAccess(farmId, targetObject) then
        return MeatAnimalMoveEvent.ERROR_NO_PERMISSION
    end

    if sourceObject.getClusterById == nil then
        return MeatAnimalMoveEvent.ERROR_INVALID_CLUSTER
    end

    local cluster = sourceObject:getClusterById(clusterId)
    if cluster == nil then
        return MeatAnimalMoveEvent.ERROR_INVALID_CLUSTER
    end

    if numAnimals == nil or numAnimals < 1 or cluster:getNumAnimals() < numAnimals then
        return MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_ANIMALS
    end

    local canAccept, reason = targetObject:meatAnimalCanAcceptCluster(cluster, numAnimals)
    if canAccept then
        return nil
    end

    return reason or MeatAnimalMoveEvent.ERROR_INTERNAL
end

function MeatAnimalMoveEvent:run(connection)
    if connection:getIsServer() then
        -- Server -> client response.
        g_messageCenter:publish(MeatAnimalMoveEvent, self.errorCode, self.movedWeight)
        return
    end

    -- Client -> server request. Determine the farm from the sending connection,
    -- never trust a client supplied farm id.
    local farmId = nil
    local uniqueUserId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    if uniqueUserId ~= nil then
        local farm = g_farmManager:getFarmForUniqueUserId(uniqueUserId)
        if farm ~= nil then
            farmId = farm.farmId
        end
    end

    local errorCode = MeatAnimalMoveEvent.validate(self.sourceObject, self.targetObject, self.clusterId, self.numAnimals, farmId)
    local movedWeight = 0

    if errorCode == nil then
        local cluster = self.sourceObject:getClusterById(self.clusterId)
        local accepted, result = self.targetObject:meatAnimalAcceptCluster(cluster, self.numAnimals)

        if accepted then
            movedWeight = result or 0

            -- Only remove animals after the kilograms were successfully committed to
            -- the production storage. This prevents animal loss on a failed transfer.
            cluster:changeNumAnimals(-self.numAnimals)

            if self.sourceObject.getClusterSystem ~= nil then
                local clusterSystem = self.sourceObject:getClusterSystem()
                if clusterSystem ~= nil and clusterSystem.updateNow ~= nil then
                    clusterSystem:updateNow()
                end
            end

            errorCode = MeatAnimalMoveEvent.SUCCESS
        else
            errorCode = result or MeatAnimalMoveEvent.ERROR_INTERNAL
        end
    end

    connection:sendEvent(MeatAnimalMoveEvent.newServerToClient(errorCode, movedWeight))
end
