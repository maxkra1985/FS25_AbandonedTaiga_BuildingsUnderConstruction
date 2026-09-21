AnimalScreenTrailerMeatPlant = {}
local AnimalScreenTrailerMeatPlant_mt = Class(AnimalScreenTrailerMeatPlant, AnimalScreenTrailerFarm)

function AnimalScreenTrailerMeatPlant.new(meatPlant, trailer)
    local self = AnimalScreenTrailerFarm.new(meatPlant, trailer, AnimalScreenTrailerMeatPlant_mt)
    self.meatPlant = meatPlant
    return self
end

function AnimalScreenTrailerMeatPlant:reset()
    if self.meatPlant ~= nil and self.meatPlant.setAnimalScreenController ~= nil then
        self.meatPlant:setAnimalScreenController(nil)
    end

    AnimalScreenTrailerMeatPlant:superClass().reset(self)
end

function AnimalScreenTrailerMeatPlant:initTargetItems()
    self.targetItems = {}
end

function AnimalScreenTrailerMeatPlant:getSourceAnimalTypes()
    local animalType = self.trailer ~= nil and self.trailer:getCurrentAnimalType() or nil
    if animalType == nil then
        return {}
    end

    return {g_currentMission.animalSystem:getTypeByIndex(animalType.typeIndex)}
end

function AnimalScreenTrailerMeatPlant:getTargetName()
    if self.meatPlant == nil or self.trailer == nil then
        return ""
    end

    local clusters = self.trailer:getClusters()
    if clusters == nil or #clusters == 0 then
        return self.meatPlant:getName()
    end

    local title, fillLevel, capacity = self.meatPlant:meatAnimalGetStorageInfo(clusters[1]:getSubTypeIndex())
    if title == nil then
        return self.meatPlant:getName()
    end

    return string.format("%s - %s (%d / %d kg)", self.meatPlant:getName(), title, math.floor(fillLevel + 0.5), math.floor(capacity + 0.5))
end

function AnimalScreenTrailerMeatPlant:getSourceActionText()
    if self.moveButtonText ~= nil and self.plantName ~= nil then
        return string.format(self.moveButtonText, self.plantName)
    end

    return g_i18n:getText("action_tip")
end

function AnimalScreenTrailerMeatPlant:getTargetActionText()
    return ""
end

function AnimalScreenTrailerMeatPlant:getSourceMaxNumAnimals(animalTypeIndex, itemIndex)
    local items = self.sourceItems[animalTypeIndex]
    if items == nil then
        return 0
    end

    local item = items[itemIndex]
    if item == nil or item.cluster == nil or self.meatPlant == nil then
        return 0
    end

    local maxByWeight = self.meatPlant:meatAnimalGetMaxAcceptableAnimals(item.cluster)
    return math.min(self:getMaxNumAnimals(), item:getNumAnimals(), maxByWeight)
end

function AnimalScreenTrailerMeatPlant:getTargetMaxNumAnimals(itemIndex)
    return 0
end

function AnimalScreenTrailerMeatPlant:getTargetData()
    return {self.meatPlant}, g_i18n:getText("ui_husbandryInformation")
end

function AnimalScreenTrailerMeatPlant:getApplySourceConfirmationText(animalTypeIndex, itemIndex, numItems)
    local item = self.sourceItems[animalTypeIndex] ~= nil and self.sourceItems[animalTypeIndex][itemIndex] or nil
    if item == nil or item.cluster == nil then
        return ""
    end

    local _, totalWeight = self.meatPlant:meatAnimalCalculateWeight(item.cluster, numItems)
    local name = string.format("%s, %s", item:getTitle(), item:getName())

    local text
    if self.unloadConfirmationText ~= nil and self.plantName ~= nil then
        text = string.format(self.unloadConfirmationText, numItems, name, self.plantName)
    else
        text = string.format("Move %d animals (%s)?", numItems, name)
    end

    return string.format("%s\n%d kg", text, math.floor(totalWeight + 0.5))
end

function AnimalScreenTrailerMeatPlant:getErrorText(errorCode)
    if errorCode == MeatAnimalMoveEvent.ERROR_NO_PERMISSION then
        return g_i18n:getText("shop_messageNoPermissionToTradeAnimals")
    elseif errorCode == MeatAnimalMoveEvent.ERROR_INVALID_CLUSTER then
        return g_i18n:getText("shop_messageInvalidCluster")
    elseif errorCode == MeatAnimalMoveEvent.ERROR_ANIMAL_NOT_SUPPORTED then
        return g_i18n:getText("shop_messageAnimalTypeNotSupported")
    elseif errorCode == MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_ANIMALS then
        return g_i18n:getText("shop_messageNotEnoughAnimals")
    elseif errorCode == MeatAnimalMoveEvent.ERROR_NOT_ENOUGH_SPACE then
        return "Not enough free storage for the calculated animal weight"
    end

    return "Animal could not be moved to the meat processing plant"
end

function AnimalScreenTrailerMeatPlant:applySource(animalTypeIndex, itemIndex, numItems)
    local item = self.sourceItems[animalTypeIndex] ~= nil and self.sourceItems[animalTypeIndex][itemIndex] or nil
    if item == nil then
        return false
    end

    local clusterId = item:getClusterId()
    local farmId = self.trailer:getOwnerFarmId()
    local errorCode = MeatAnimalMoveEvent.validate(self.trailer, self.meatPlant, clusterId, numItems, farmId)

    if errorCode ~= nil then
        self.errorCallback(self:getErrorText(errorCode))
        return false
    end

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_SOURCE, self:getSourceActionText())
    g_messageCenter:subscribe(MeatAnimalMoveEvent, self.onAnimalMovedToPlant, self)
    g_client:getServerConnection():sendEvent(MeatAnimalMoveEvent.new(self.trailer, self.meatPlant, clusterId, numItems))
    return true
end

function AnimalScreenTrailerMeatPlant:onAnimalMovedToPlant(errorCode, movedWeight)
    g_messageCenter:unsubscribe(MeatAnimalMoveEvent, self)
    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_NONE, nil)

    if errorCode == MeatAnimalMoveEvent.SUCCESS then
        local text
        if self.unloadSuccessText ~= nil and self.plantName ~= nil then
            text = string.format(self.unloadSuccessText, self.plantName)
        else
            text = "Animals were moved to the meat processing plant"
        end

        text = string.format("%s (%d kg)", text, math.floor((movedWeight or 0) + 0.5))
        self.sourceActionFinished(false, text)
    else
        self.sourceActionFinished(true, self:getErrorText(errorCode))
    end
end

function AnimalScreenTrailerMeatPlant:applyTarget(animalTypeIndex, itemIndex, numItems)
    return false
end

function AnimalScreenTrailerMeatPlant:onAnimalsChanged(obj, clusters)
    if obj == self.trailer then
        self:initItems()
        if self.animalsChangedCallback ~= nil then
            self.animalsChangedCallback()
        end
    end
end
