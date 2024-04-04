--!nocheck
--!optimize 2

local Keep = {
	assumeDeadLock = 0,

	ServiceDone = false,

	_activeSaveJobs = 0,
}
Keep.__index = Keep

local Promise = require(script.Parent.Promise)
local Signal = require(script.Parent.Signal)

local DefaultMetaData = {
	ActiveSession = { PlaceID = game.PlaceId, JobID = game.JobId },

	LastUpdate = 0,

	Created = 0,
	LoadCount = 0,
}

local DefaultGlobalUpdates = {
	ID = 0,

	Updates = {},
}

local DefaultKeep = {
	Data = {},

	MetaData = DefaultMetaData,
	GlobalUpdates = DefaultGlobalUpdates,

	UserIds = {},
}

local releaseCache = {}

local function DeepCopy(tbl)
	local copy = {}

	for key, value in pairs(tbl) do
		if type(value) == "table" then
			copy[key] = DeepCopy(value)
		else
			copy[key] = value
		end
	end

	return copy
end

local function isType(value, reference)
	if typeof(reference) == "table" then
		if typeof(value) ~= "table" then
			return false
		end

		for key, _ in pairs(reference) do
			if not isType(value[key], reference[key]) then
				return false
			end
		end

		return true
	end

	return typeof(value) == typeof(reference)
end

function Keep.new(structure, dataTemplate)
	return setmetatable({
		Data = structure.Data or DeepCopy(dataTemplate),
		MetaData = structure.MetaData or DefaultKeep.MetaData,

		GlobalUpdates = structure.GlobalUpdates or DefaultKeep.GlobalUpdates,

		_pending_global_lock_removes = {},
		_pending_global_locks = {},

		UserIds = structure.UserIds or DefaultKeep.UserIds,

		LatestKeep = {
			Data = DeepCopy(structure.Data or dataTemplate),
			GlobalUpdates = DeepCopy(structure.GlobalUpdates or DefaultKeep.GlobalUpdates),

			MetaData = DeepCopy(structure.MetaData or DefaultKeep.MetaData),

			UserIds = DeepCopy(structure.UserIds or DefaultKeep.UserIds),
		},

		Releasing = Signal.new(),
		_released = false,

		_view_only = false,
		_overwriting = false,
		_global_updates_only = false,

		OnGlobalUpdate = Signal.new(),
		GlobalStateProcessor = function(_, lock, _)
			lock()
		end,

		_keyInfo = {},

		_store = nil,
		_key = "",

		_keep_store = nil,

		_last_save = os.clock(),
		Saving = Signal.new(),
		_store_info = { Name = "", Scope = "" },

		_data_template = dataTemplate,
	}, Keep)
end

local function isKeepLocked(metaData)
	if metaData.ActiveSession == nil then
		return false
	end

	if metaData.ActiveSession.PlaceID ~= game.PlaceId or metaData.ActiveSession.JobID ~= game.JobId then
		return true
	end

	return false
end

local function transformUpdate(keep, newestData, release)
	local empty = newestData == nil
		or type(newestData) ~= "table"
		or type(newestData.Data) ~= "table" and newestData.Data == nil and newestData.MetaData == nil and newestData.GlobalUpdates == nil
		or type(newestData.MetaData) ~= "table"
	local corrupted = newestData ~= nil
		and (type(newestData) ~= "table" or type(newestData.Data) ~= "table" or type(newestData.MetaData) ~= "table")

	if type(newestData) == "table" then
		if type(newestData.Data) == "table" and typeof(newestData.MetaData) == "table" then
			if not isKeepLocked(newestData.MetaData) and keep._keep_store then
				local keepStore = keep._keep_store

				local valid, err = keepStore.validate(newestData.Data)

				if valid then
					newestData.Data = keep.Data

					newestData.UserIds = keep.UserIds
				else
					if not keep._keep_store then
						return newestData
					end

					keep._keep_store._processError(err, 0)
				end
			end
		end

		if type(newestData.GlobalUpdates) == "table" then
			local latestKeep = keep.LatestKeep

			local currentGlobals = latestKeep.GlobalUpdates
			local newGlobals = newestData.GlobalUpdates

			local finalGlobals = {
				ID = 0,
				Updates = {},
			}

			local id = 0

			for _, newUpdate in newGlobals.Updates do
				id += 1
				finalGlobals.ID = id

				local oldGlobal = nil

				local updates = currentGlobals.Updates

				for _, oldUpdate in updates do
					if oldUpdate.ID == newUpdate.ID then
						oldGlobal = oldUpdate
						break
					end
				end

				local isNewGlobal = oldGlobal == nil or newUpdate.Locked ~= oldGlobal.Locked

				if not isNewGlobal then
					oldGlobal.ID = id
					table.insert(finalGlobals.Updates, oldGlobal)
					continue
				end

				newUpdate.ID = id

				if not newUpdate.Locked then
					local isPendingLock = false

					for _, pendingLock in ipairs(keep._pending_global_locks) do
						if pendingLock == newUpdate.ID then
							isPendingLock = true

							break
						end
					end

					if isPendingLock then
						newUpdate.Locked = true
					end
				end

				local isPendingRemoval = false

				for _, pendingRemoval in ipairs(keep._pending_global_lock_removes) do
					if pendingRemoval == newUpdate.ID then
						isPendingRemoval = true
						break
					end
				end

				if isPendingRemoval then
					continue
				end

				keep.OnGlobalUpdate:Fire(newUpdate.Data, newUpdate.ID)

				table.insert(finalGlobals.Updates, newUpdate)
			end

			newestData.GlobalUpdates = finalGlobals
		end
	end

	if empty then
		keep.MetaData.Created = os.time()

		newestData = {
			Data = keep.Data,
			MetaData = keep.MetaData,

			GlobalUpdates = keep.GlobalUpdates,
			UserIds = keep.UserIds,
		}
	end

	if corrupted then
		local replaceData = {
			Data = newestData.Data,
			MetaData = newestData.MetaData or DefaultKeep.MetaData,

			GlobalUpdates = newestData.GlobalUpdates or DefaultKeep.GlobalUpdates,
			UserIds = newestData.UserIds or DefaultKeep.UserIds,
		}

		newestData = replaceData
	end

	if not isKeepLocked(newestData.MetaData) then
		newestData.MetaData.ActiveSession = if release and newestData.MetaData.ForceLoad
			then newestData.MetaData.ForceLoad
			else DefaultMetaData.ActiveSession

		local activeSession = DefaultMetaData.ActiveSession
		if release then
			if newestData.MetaData.ForceLoad then
				newestData.MetaData.ActiveSession = newestData.MetaData.ForceLoad
			else
				activeSession = nil
			end

			newestData.MetaData.ForceLoad = nil
		end

		newestData.MetaData.ActiveSession = activeSession

		newestData.MetaData.LastUpdate = os.time()

		if not empty then
			keep.LatestKeep = DeepCopy(newestData)
		end
	end

	keep._last_save = os.clock()
	newestData.MetaData.ForceLoad = keep.MetaData.ForceLoad
	newestData.MetaData.LoadCount = keep.MetaData.LoadCount

	return newestData, newestData.UserIds
end

function Keep:_save(newestData, release)
	if not self:IsActive() then
		if self.MetaData.ForceLoad == nil then
			return newestData
		end
	end

	if self._view_only and not self._overwriting then
		self._keep_store._processError("Attempted to save a view only keep, do you mean :Overwrite()?", 2)
		return newestData
	elseif self._overwriting then
		self._overwriting = false
	end

	local waitingForceLoad = false

	if
		newestData
		and newestData.MetaData
		and newestData.MetaData.ForceLoad
		and (newestData.MetaData.ForceLoad.PlaceID ~= game.PlaceId or newestData.MetaData.ForceLoad.JobID ~= game.JobId)
	then
		waitingForceLoad = true
	elseif newestData and newestData.MetaData and newestData.MetaData.ForceLoad then
		newestData.MetaData.ForceLoad = nil
	end

	release = release or waitingForceLoad

	local latestGlobals = self.GlobalUpdates

	local globalClears = self._pending_global_lock_removes

	for _, updateId in ipairs(globalClears) do
		for i = 1, #latestGlobals.Updates do
			if latestGlobals.Updates[i].ID == updateId and latestGlobals.Updates[i].Locked then
				table.remove(latestGlobals.Updates, i)
				break
			end
		end
	end

	local globalUpdates = self.GlobalUpdates.Updates

	local function lockGlobalUpdate(index)
		return Promise.new(function(resolve, reject)
			if not self:IsActive() then
				return reject()
			end

			table.insert(self._pending_global_locks, globalUpdates[index].ID, index)

			return resolve()
		end)
	end

	local function removeLockedUpdate(index, updateId)
		return Promise.new(function(resolve, reject)
			if not self:IsActive() then
				return reject()
			end

			if globalUpdates[index].ID ~= updateId then
				return reject()
			end

			if not globalUpdates[index].Locked and not self._pending_global_locks[index] then
				self._keep_store._processError("Attempted to remove a global update that was not locked", 2)
				return reject()
			end

			table.insert(self._pending_global_lock_removes, updateId)
			return resolve()
		end)
	end

	local processUpdates = {}

	if globalUpdates then
		for i = 1, #globalUpdates do
			if not globalUpdates[i].Locked then
				self.GlobalStateProcessor(globalUpdates[i].Data, function()
					table.insert(processUpdates, function()
						lockGlobalUpdate(i)
					end)
				end, function()
					table.insert(processUpdates, function()
						removeLockedUpdate(i, globalUpdates[i].ID)
					end)
				end)
			end
		end
	else
		self.GlobalUpdates = DefaultGlobalUpdates
	end

	for _, updateProcessor in processUpdates do
		updateProcessor()
	end

	local transformedData = transformUpdate(self, newestData, release)

	if self._keep_store and self._keep_store._preSave then
		local compressedData = self._keep_store._preSave(DeepCopy(transformedData.Data))

		transformedData.Data = compressedData
	end

	return transformedData
end

function Keep:Save()
	Keep._activeSaveJobs += 1

	local savingState = Promise.new(function(resolve)
		local dataKeyInfo = self._store:UpdateAsync(self._key, function(newestData)
			return self:_save(newestData, false)
		end)

		self._last_save = os.clock()

		if dataKeyInfo then
			self._keyInfo = {
				CreatedTime = dataKeyInfo.CreatedTime,
				UpdatedTime = dataKeyInfo.UpdatedTime,
				Version = dataKeyInfo.Version,
			}
		end

		resolve(dataKeyInfo or {})
	end)
		:catch(function(err)
			local keepStore = self._keep_store

			keepStore._processError(err, 1)
		end)
		:finally(function()
			Keep._activeSaveJobs -= 1
		end)

	self.Saving:Fire(savingState)

	return savingState
end

function Keep:Overwrite()
	local savingState = Promise.new(function(resolve)
		self._overwriting = true
		local dataKeyInfo = self._store:UpdateAsync(self._key, function(newestData)
			return self:_save(newestData, false)
		end)

		self._last_save = os.clock()

		self._keyInfo = {
			CreatedTime = dataKeyInfo.CreatedTime,
			UpdatedTime = dataKeyInfo.UpdatedTime,
			Version = dataKeyInfo.Version,
		}

		resolve(dataKeyInfo)
	end):catch(function(err)
		local keepStore = self._keep_store

		keepStore._processError(err, 1)
	end)

	self.Saving:Fire(savingState)

	return savingState
end

function Keep:IsActive()
	return not isKeepLocked(self.MetaData)
end

function Keep:Identify()
	return string.format(
		"%s/%s%s",
		self._store_info.Name,
		string.format("%s%s", self._store_info.Scope, if self._store_info.Scope ~= "" then "/" else ""),
		self._key
	)
end

function Keep:GetKeyInfo()
	return self._keyInfo
end

function Keep:Release()
	if releaseCache[self:Identify()] then
		return releaseCache[self:Identify()]
	end

	if self._released then
		return
	end

	Keep._activeSaveJobs += 1

	local updater = Promise.new(function(resolve)
		local dataKeyInfo = self._store:UpdateAsync(self._key, function(newestData)
			return self:_save(newestData, true)
		end)

		self._last_save = os.clock()

		if dataKeyInfo then
			self._keyInfo = {
				CreatedTime = dataKeyInfo.CreatedTime,
				UpdatedTime = dataKeyInfo.UpdatedTime,
				Version = dataKeyInfo.Version,
			}
		end

		resolve(dataKeyInfo or {})
	end)
	self.Saving:Fire(updater)

	self._last_save = os.clock()

	updater
		:andThen(function()
			self.OnGlobalUpdate:Destroy()

			self._keep_store._cachedKeepPromises[self:Identify()] = nil
			self._released = true

			releaseCache[self:Identify()] = nil
		end)
		:catch(function(err)
			local keepStore = self._keep_store

			keepStore._processError("Failed to release: " .. err, 2)

			error(err)
		end)
		:finally(function()
			Keep._activeSaveJobs -= 1
		end)

	if not self._released then
		self.Releasing:Fire(updater)
	end

	releaseCache[self:Identify()] = updater

	return updater
end

function Keep:Reconcile()
	local function reconcileData(data, template)
		if type(data) ~= "table" then
			return template
		end

		for key, value in pairs(template) do
			if data[key] == nil then
				data[key] = value
			elseif type(data[key]) == "table" then
				data[key] = reconcileData(data[key], value)
			end
		end

		return data
	end

	self.Data = reconcileData(self.Data, self._data_template)
	self.MetaData = reconcileData(self.MetaData, DefaultKeep.MetaData)
end

function Keep:AddUserId(userId)
	if not self:IsActive() then
		return
	end

	if table.find(self.UserIds, userId) then
		return
	end

	table.insert(self.UserIds, userId)
end

function Keep:RemoveUserId(userId)
	local index = table.find(self.UserIds, userId)

	if index then
		table.remove(self.UserIds, index)
	end
end

function Keep:GetVersions(minDate, maxDate)
	return Promise.new(function(resolve)
		local versions = self._store:ListVersionsAsync(self._key, Enum.SortDirection.Ascending, minDate, maxDate)

		local versionMap = {}

		table.insert(versionMap, versions:GetCurrentPage())
		while not versions.IsFinished do
			versions:AdvanceToNextPageAsync()

			table.insert(versionMap, versions:GetCurrentPage())
		end

		local iteratorIndex = 1
		local iteratorPage = 1

		local iterator = {
			Current = function()
				return versionMap[iteratorPage][iteratorIndex]
			end,

			Next = function()
				if #versionMap == 0 or #versionMap[iteratorPage] == 0 then
					return
				end

				if iteratorIndex >= #versionMap[iteratorPage] then
					iteratorPage += 1
					iteratorIndex = 0
				end

				iteratorIndex += 1

				local page = versionMap[iteratorPage]

				if page == nil then
					return nil
				end

				local version = page[iteratorIndex]

				return version
			end,

			PageUp = function()
				if #versionMap == 0 or #versionMap[iteratorPage] == 0 then
					return
				end

				if iteratorPage > #versionMap then
					iteratorPage = 0
				end

				iteratorPage += 1
				iteratorIndex = 1
			end,

			PageDown = function()
				if #versionMap == 0 or #versionMap[iteratorPage] == 0 then
					return
				end

				if iteratorPage == 0 then
					iteratorPage = #versionMap
				end

				iteratorPage -= 1
				iteratorIndex = 1
			end,

			SkipEnd = function()
				iteratorPage = #versionMap
				iteratorIndex = #versionMap[iteratorPage]
			end,

			SkipStart = function()
				iteratorPage = 1
				iteratorIndex = 1
			end,

			Previous = function()
				if #versionMap == 0 or #versionMap[iteratorPage] == 0 then
					return
				end

				if iteratorIndex == 1 then
					iteratorPage -= 1

					if iteratorPage == 0 then
						return
					end

					iteratorIndex = #versionMap[iteratorPage] + 1
				end

				iteratorIndex -= 1

				local page = versionMap[iteratorPage]

				if page == nil then
					return
				end

				local version = page[iteratorIndex]

				return version
			end,
		}

		return resolve(iterator)
	end)
end

function Keep:SetVersion(version, migrateProcessor)
	if migrateProcessor == nil then
		migrateProcessor = function(versionKeep)
			return versionKeep
		end
	end

	return Promise.new(function(resolve, reject)
		if not self:IsActive() then
			return reject()
		end

		local oldKeep = {
			Data = DeepCopy(self.Data),
			MetaData = DeepCopy(self.MetaData),
			GlobalUpdates = DeepCopy(self.GlobalUpdates),
			UserIds = DeepCopy(self.UserIds),
		}

		local versionKeep = self._keep_store
			:ViewKeep(self._key, version)
			:catch(function(err)
				self._keep_store._processError(err, 1)
			end)
			:awaitValue()

		versionKeep = migrateProcessor(versionKeep)

		self.Data = versionKeep.Data
		self.MetaData = versionKeep.MetaData
		self.GlobalUpdates = versionKeep.GlobalUpdates
		self.UserIds = versionKeep.UserIds

		resolve(oldKeep)
	end)
end

function Keep:GetActiveGlobalUpdates()
	local activeUpdates = {}

	for _, update in ipairs(self.GlobalUpdates.Updates) do
		if not update.Locked then
			table.insert(activeUpdates, { Data = update.Data, ID = update.ID })
		end
	end

	return activeUpdates
end

function Keep:GetLockedGlobalUpdates()
	local lockedUpdates = {}

	for _, update in ipairs(self.GlobalUpdates.Updates) do
		if update.Locked then
			table.insert(lockedUpdates, { Data = update.Data, ID = update.ID })
		end
	end

	return lockedUpdates
end

function Keep:ClearLockedUpdate(id)
	return Promise.new(function(resolve, reject)
		if not self:IsActive() then
			return reject()
		end
		local globalUpdates = self.GlobalUpdates

		if id > globalUpdates.ID then
			return reject()
		end

		for i = 1, #globalUpdates.Updates do
			if globalUpdates.Updates[i].ID == id and globalUpdates.Updates[i].Locked then
				table.insert(self._pending_global_lock_removes, id)
				return resolve()
			end
		end

		if table.find(self._pending_global_locks, id) then
			table.insert(self._pending_global_lock_removes, id)
			return resolve()
		end

		error("Can't :ClearLockedUpdate on an active update")
	end)
end

return Keep
