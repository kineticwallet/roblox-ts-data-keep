--!nocheck
--!optimize 2

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Promise = require(script.Promise)
local Signal = require(script.Signal)

local MockStore = require(script.MockStore)

local Keep = require(script.Keep)

local Store = {
	mockStore = false,

	_saveInterval = 30,

	_storeQueue = {},

	assumeDeadLock = 10 * 60,

	ServiceDone = false,

	CriticalState = false,
	_criticalStateThreshold = 5,
	CriticalStateSignal = Signal.new(),

	IssueSignal = Signal.new(),
	_issueQueue = {},
	_maxIssueTime = 60,
}
Store.__index = Store

Keep.assumeDeadLock = Store.assumeDeadLock

local GlobalUpdates = {}
GlobalUpdates.__index = GlobalUpdates

local Keeps = {}

local JobID = game.JobId
local PlaceID = game.PlaceId

local saveCycle = 0

local function len(tbl)
	local count = 0

	for _ in tbl do
		count += 1
	end

	return count
end

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

local function canLoad(keep)
	if not keep.MetaData then
		return true
	end

	if not keep.MetaData.ActiveSession then
		return true
	end

	if keep.MetaData.ActiveSession.PlaceID == PlaceID and keep.MetaData.ActiveSession.JobID == JobID then
		return true
	end

	if os.time() - keep.MetaData.LastUpdate > Store.assumeDeadLock then
		return true
	end

	return false
end

local function createMockStore(storeInfo, dataTemplate)
	return setmetatable({
		_store_info = storeInfo,
		_data_template = dataTemplate,

		_store = MockStore.new(),

		_mock = true,

		_keeps = {},

		_cachedKeepPromises = {},

		Wrapper = require(script.Wrapper),

		validate = function()
			return true
		end,
	}, Store)
end

local function releaseKeepInternally(keep)
	Keeps[keep:Identify()] = nil

	local keepStore = keep._keep_store

	keepStore._cachedKeepPromises[keep:Identify()] = nil

	keep.Releasing:Destroy()
end

local function saveKeep(keep, release)
	if keep._released then
		releaseKeepInternally(keep)
		return Promise.resolve()
	end

	release = release or false

	local operation

	if release then
		operation = keep.Release
	else
		operation = keep.Save
	end

	local savingState = operation(keep)
		:andThen(function()
			keep._last_save = os.clock()
		end)
		:catch(function(err)
			local keepStore = keep._keep_store

			keepStore._processError(err, 1)
		end)

	return savingState
end

local mockStoreCheck = Promise.new(function(resolve)
	if game.GameId == 0 then
		print("[DataKeep] Local file, using mock store")
		return resolve(false)
	end

	local success, message = pcall(function()
		DataStoreService:GetDataStore("__LiveCheck"):SetAsync("__LiveCheck", os.time())
	end)

	if message then
		if string.find(message, "ConnectFail", 1, true) then
			warn("[DataKeep] No internet connection, using mock store")
		end

		if string.find(message, "403", 1, true) or string.find(message, "must publish", 1, true) then
			print("[DataKeep] Datastores are not available, using mock store")
		else
			print("[DataKeep] Datastores are available, using real store")
		end
	end

	return resolve(success)
end):andThen(function(isLive)
	Store.mockStore = if not Store.ServiceDone then not isLive else true
end)

function Store.GetStore(storeInfo, dataTemplate)
	local info

	if type(storeInfo) == "string" then
		info = {
			Name = storeInfo,
			Scope = nil,
		}
	else
		info = storeInfo
	end

	local identifier = info.Name .. (info.Scope and info.Scope or "")

	if Store._storeQueue[identifier] then
		return Promise.resolve(Store._storeQueue[identifier])
	end

	return mockStoreCheck:andThen(function()
		local self = setmetatable({
			_store_info = info,
			_data_template = dataTemplate,

			_store = if Store.mockStore then MockStore.new() else DataStoreService:GetDataStore(info.Name, info.Scope),

			Mock = createMockStore(info, dataTemplate),

			_mock = if Store.mockStore then true else false,

			_cachedKeepPromises = {},

			validate = function()
				return true
			end,

			Wrapper = require(script.Wrapper),
		}, Store)

		Store._storeQueue[identifier] = self._store

		local function processError(err, priority)
			Store.IssueSignal:Fire(err)

			priority = priority or 1

			if priority > 1 then
				error(err)
			else
				warn(err)
			end

			local clock = os.clock()

			if priority ~= 0 then
				table.insert(Store._issueQueue, clock)
			end

			if Store._issueQueue[Store._criticalStateThreshold + 1] then
				table.remove(Store._issueQueue, Store._criticalStateThreshold + 1)
			end

			local issueCount = 0

			for _, issueTime in ipairs(Store._issueQueue) do
				if clock - issueTime < Store._maxIssueTime then
					issueCount += 1
				end
			end

			if issueCount >= Store._criticalStateThreshold then
				Store.CriticalState = true
				Store.CriticalStateSignal:Fire()
			end
		end

		self._processError = processError
		self.Mock._processError = processError

		return Promise.resolve(self)
	end)
end

function Store:LoadKeep(key, unReleasedHandler)
	local store = self._store

	if self._mock then
		print("Using mock store!")
	end

	if unReleasedHandler == nil then
		unReleasedHandler = function(_)
			return "Ignore"
		end
	end

	if type(unReleasedHandler) ~= "function" then
		error("UnReleasedHandler must be a function")
	end

	local identifier = string.format(
		"%s/%s%s",
		self._store_info.Name,
		if self._store_info.Scope ~= nil then self._store_info.Scope .. "/" else "",
		key
	)

	if Keeps[identifier] then
		return Promise.resolve(Keeps[identifier])
	elseif
		self._cachedKeepPromises[identifier]
		and self._cachedKeepPromises[identifier].Status ~= Promise.Status.Rejected
		and self._cachedKeepPromises[identifier].Status ~= Promise.Status.Cancelled
	then
		return self._cachedKeepPromises[identifier]
	end

	local promise = Promise.new(function(resolve, reject)
		local keep = store:GetAsync(key) or {}

		local success = canLoad(keep)

		local forceload = nil

		if not success and keep.MetaData.ActiveSession then
			local loadMethod = unReleasedHandler(keep.MetaData.ActiveSession)

			if loadMethod ~= "Ignore" and loadMethod ~= "Cancel" then
				warn("UnReleasedHandler returned an invalid value, defaulting to Ignore")

				loadMethod = "Ignore"
			end

			if loadMethod == "Cancel" then
				reject(nil)
				return
			end

			if loadMethod == "Ignore" then
				forceload = {
					PlaceID = PlaceID,
					JobID = JobID,
				}
			end
		end

		if keep.Data and len(keep.Data) > 0 and self._preLoad then
			keep.Data = self._preLoad(DeepCopy(keep.Data))
		end

		local keepClass = Keep.new(keep, self._data_template)

		keepClass._store = store
		keepClass._key = key
		keepClass._store_info.Name = self._store_info.Name
		keepClass._store_info.Scope = self._store_info.Scope or ""

		keepClass._keep_store = self

		keepClass.MetaData.ForceLoad = forceload

		keepClass.MetaData.LoadCount = (keepClass.MetaData.LoadCount or 0) + 1

		self._storeQueue[key] = keepClass

		saveKeep(keepClass, false)

		Keeps[keepClass:Identify()] = keepClass

		self._cachedKeepPromises[identifier] = nil

		for functionName, func in self.Wrapper do
			keepClass[functionName] = function(...)
				return func(...)
			end
		end

		resolve(keepClass)
	end)

	self._cachedKeepPromises[identifier] = promise

	return promise
end

function Store:ViewKeep(key, version)
	return Promise.new(function(resolve)
		local id = string.format(
			"%s/%s%s",
			self._store_info.Name,
			string.format("%s%s", self._store_info.Scope or "", if self._store_info.Scope ~= nil then "/" else ""),
			key
		)

		if Keeps[id] then
			if Keeps[id]._released then
				Keeps[id] = nil
			else
				return resolve(Keeps[id])
			end
		elseif
			self._cachedKeepPromises[id]
			and self._cachedKeepPromises[id].Status ~= Promise.Status.Rejected
			and self._cachedKeepPromises[id].Status ~= Promise.Status.Cancelled
		then
			return self._cachedKeepPromises[id]
		end

		local data = self._store:GetAsync(key, version) or {}

		if data.Data and len(data.Data) > 0 and self._preLoad then
			data.Data = self._preLoad(DeepCopy(data.Data))
		end

		local keepObject = Keep.new(data, self._data_template)

		self._cachedKeepPromises[id] = nil

		keepObject._view_only = true
		keepObject._released = true

		keepObject._store = self._store
		keepObject._key = key
		keepObject._store_info.Name = self._store_info.Name
		keepObject._store_info.Scope = self._store_info.Scope or ""

		keepObject._keep_store = self

		for functionName, func in self.Wrapper do
			keepObject[functionName] = function(...)
				return func(...)
			end
		end

		return resolve(keepObject)
	end)
end

function Store:PreSave(callback)
	assert(self._preSave == nil, "PreSave can only be set once")
	assert(callback and type(callback) == "function", "Callback must be a function")

	self._preSave = callback
end

function Store:PreLoad(callback)
	assert(self._preLoad == nil, "PreLoad can only be set once")
	assert(callback and type(callback) == "function", "Callback must be a function")

	self._preLoad = callback
end

function Store:PostGlobalUpdate(key, updateHandler)
	return Promise.new(function(resolve)
		if Store.ServiceDone then
			error("Game is closing, can't post global update")
		end

		local id = string.format(
			"%s/%s%s",
			self._store_info.Name,
			string.format("%s%s", self._store_info.Scope or "", if self._store_info.Scope ~= nil then "/" else ""),
			key
		)

		local keep = Keeps[id]

		if not keep then
			keep = self:ViewKeep(key):awaitValue()

			keep._global_updates_only = true
		end

		local globalUpdateObject = {
			_updates = keep.GlobalUpdates,
			_pending_removal = keep._pending_global_lock_removes,
			_view_only = keep._view_only,
			_global_updates_only = keep._global_updates_only,
		}

		setmetatable(globalUpdateObject, GlobalUpdates)

		updateHandler(globalUpdateObject)

		if not keep:IsActive() then
			keep:Release()
		end

		return resolve()
	end)
end

function GlobalUpdates:AddGlobalUpdate(globalData)
	return Promise.new(function(resolve, reject)
		if Store.ServiceDone then
			return reject()
		end

		if self._view_only and not self._global_updates_only then
			error("Can't add global update to a view only Keep")
			return reject()
		end

		local globalUpdates = self._updates

		local updateId = globalUpdates.ID
		updateId += 1

		globalUpdates.ID = updateId

		table.insert(globalUpdates.Updates, {
			ID = updateId,
			Locked = false,
			Data = globalData,
		})

		return resolve(updateId)
	end)
end

function GlobalUpdates:GetActiveUpdates()
	if Store.ServiceDone then
		warn("Game is closing, can't get active updates")
	end

	if self._view_only and not self._global_updates_only then
		error("Can't get active updates from a view only Keep")
		return {}
	end

	local globalUpdates = self._updates

	local updates = {}

	for _, update in ipairs(globalUpdates.Updates) do
		if not update.Locked then
			table.insert(updates, update)
		end
	end

	return updates
end

function GlobalUpdates:RemoveActiveUpdate(updateId)
	return Promise.new(function(resolve, reject)
		if Store.ServiceDone then
			return reject()
		end

		if self._view_only and not self._global_updates_only then
			error("Can't remove active update from a view only Keep")
			return {}
		end

		local globalUpdates = self._updates

		if globalUpdates.ID < updateId then
			return reject()
		end

		local globalUpdateIndex = nil

		for i = 1, #globalUpdates.Updates do
			if globalUpdates.Updates[i].ID == updateId and not globalUpdates.Updates[i].ID then
				globalUpdateIndex = i
				break
			end
		end

		if globalUpdateIndex == nil then
			return reject()
		end

		if globalUpdates.Updates[globalUpdateIndex].Locked then
			error("Can't RemoveActiveUpdate on a locked update")
			return reject()
		end

		table.remove(globalUpdates.Updates, globalUpdateIndex)
		return resolve()
	end)
end

function GlobalUpdates:ChangeActiveUpdate(updateId, globalData)
	return Promise.new(function(resolve, reject)
		if Store.ServiceDone then
			return reject()
		end

		if self._view_only and not self._global_updates_only then
			error("Can't change active update from a view only Keep")
			return {}
		end

		local globalUpdates = self._updates

		if globalUpdates.ID < updateId then
			return reject()
		end

		for _, update in ipairs(globalUpdates.Updates) do
			if update.ID == updateId and not update.Locked then
				update.Data = globalData

				return resolve()
			end
		end

		return reject()
	end)
end

local saveLoop

game:BindToClose(function()
	Store.ServiceDone = true
	Keep.ServiceDone = true

	Store.mockStore = true

	saveLoop:Disconnect()

	local saveSize = len(Keeps)

	if saveSize > 0 then
		for _, keep in Keeps do
			keep:Release()
		end
	end

	while Keep._activeSaveJobs > 0 do
		task.wait()
	end
end)

saveLoop = RunService.Heartbeat:Connect(function(dt)
	saveCycle += dt

	if saveCycle < Store._saveInterval then
		return
	end

	if Store.ServiceDone then
		return
	end

	saveCycle = 0

	local saveSize = len(Keeps)

	if not (saveSize > 0) then
		return
	end

	local saveSpeed = Store._saveInterval / saveSize
	saveSpeed = 1

	local clock = os.clock()

	local keeps = {}

	for _, keep in Keeps do
		if clock - keep._last_save < Store._saveInterval then
			continue
		end

		table.insert(keeps, keep)
	end

	Promise.each(keeps, function(keep)
		return Promise.delay(saveSpeed)
			:andThen(function()
				saveKeep(keep, false)
			end)
			:timeout(Store._saveInterval)
			:catch(function(err)
				keep._keep_store._processError(err, 1)
			end)
	end)
end)

return Store
