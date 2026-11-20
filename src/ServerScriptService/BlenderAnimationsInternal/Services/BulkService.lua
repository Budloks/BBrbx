--!strict

-- BB fork: bulk import every Blender action of the active rig as its own
-- KeyframeSequence, and bulk upload saves. Replaces the separate
-- "RBXMonkey Bulk Import" plugin + "RBXMonkey Bulk Actions" add-on.
--
-- Every action goes through the regular import path (same rest calibration,
-- adoption, modifiers and KeyframeSequence builder as "Import from Blender").

local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local StudioService = game:GetService("StudioService")

local State = require(script.Parent.Parent.state)

local BulkService = {}
BulkService.__index = BulkService

local SETTINGS_PREFIX = "BBrbx_bulk_"
local BACKUPS_PER_NAME = 5

local DEFAULTS = {
	priority = "Action",
	loop = false,
	overwrite = true,
	outputFolder = "ReplicatedStorage/Animations",
	keepIds = true,
	creatorType = "User",
	groupId = 0,
	writeIdModule = true,
}

function BulkService.new(animationManager: any, blenderSyncManager: any, plugin: Plugin)
	local self = setmetatable({}, BulkService)
	self.animationManager = animationManager
	self.blenderSyncManager = blenderSyncManager
	self.plugin = plugin
	return self
end

function BulkService:getSetting(key: string): any
	local ok, value = pcall(function()
		return self.plugin:GetSetting(SETTINGS_PREFIX .. key)
	end)
	if ok and value ~= nil then
		return value
	end
	return (DEFAULTS :: any)[key]
end

function BulkService:setSetting(key: string, value: any)
	pcall(function()
		self.plugin:SetSetting(SETTINGS_PREFIX .. key, value)
	end)
end

local function animSaves(rigModel: Instance): Instance
	local saves = rigModel:FindFirstChild("AnimSaves")
	if not saves then
		local container = Instance.new("ObjectValue")
		container.Name = "AnimSaves"
		container.Parent = rigModel
		saves = container
	end
	return saves :: Instance
end

-- Cheap, stable fingerprint of an export payload (detects changed actions)
local function fingerprint(body: string): string
	local h = 2166136261
	local len = #body
	local step = math.max(1, math.floor(len / 4096))
	for i = 1, len, step do
		h = bit32.bxor(h, string.byte(body, i))
		h = (h * 16777619) % 4294967296
	end
	return string.format("%08x-%d", h, len)
end

function BulkService:savedSequences(rigModel: Instance?): { KeyframeSequence }
	local list = {}
	local saves = rigModel and rigModel:FindFirstChild("AnimSaves")
	if saves then
		for _, d in ipairs(saves:GetDescendants()) do
			if d:IsA("KeyframeSequence") then
				table.insert(list, d)
			end
		end
	end
	return list
end

-- Actions from Blender merged with existing saves
function BulkService:listActions(): (boolean, any)
	local rigModel = State.activeRigModel
	if not rigModel then
		return false, "Select a rig first"
	end
	local sync = self.blenderSyncManager
	local armature = sync:resolveArmatureName()
	local ok, data, err = sync.blenderConnectionService:BBRequest(State.serverPort:get(), "GET", "/bb/list_actions", {
		armature = armature,
	})
	local rows = {}
	local byName = {}
	if ok then
		for _, action in ipairs(data.actions or {}) do
			local target = (action.settings and action.settings.name) or action.name
			local row = { name = action.name, target = target, blender = true, saved = false, settings = action.settings or {} }
			byName[target] = row
			table.insert(rows, row)
		end
	end
	for _, kfs in ipairs(self:savedSequences(rigModel)) do
		local row = byName[kfs.Name]
		if not row then
			row = { name = kfs.Name, target = kfs.Name, blender = false, saved = true, settings = {} }
			byName[kfs.Name] = row
			table.insert(rows, row)
		end
		row.saved = true
		row.kfs = kfs
		local src, up = kfs:GetAttribute("BBSourceHash"), kfs:GetAttribute("BBUploadedHash")
		row.uploaded = kfs:GetAttribute("AssetId") ~= nil
		row.changed = src ~= nil and src ~= up
	end
	table.sort(rows, function(a, b)
		return a.target:lower() < b.target:lower()
	end)
	return true, { rows = rows, armature = ok and data.armature or armature, blenderError = (not ok) and err or nil }
end

function BulkService:_backup(rigModel: Instance, existing: KeyframeSequence)
	local root = ServerStorage:FindFirstChild("BBrbx_AnimBackups")
	if not root then
		root = Instance.new("Folder")
		root.Name = "BBrbx_AnimBackups"
		root.Parent = ServerStorage
	end
	local rigFolder = (root :: Instance):FindFirstChild(rigModel.Name)
	if not rigFolder then
		rigFolder = Instance.new("Folder")
		rigFolder.Name = rigModel.Name
		rigFolder.Parent = root
	end
	local baseName = existing.Name
	existing.Name = baseName .. "@" .. os.date("%Y%m%d-%H%M%S")
	existing:SetAttribute("BBBackupOf", baseName)
	existing.Parent = rigFolder
	-- prune old backups of the same animation
	local same = {}
	for _, c in ipairs((rigFolder :: Instance):GetChildren()) do
		if c:GetAttribute("BBBackupOf") == baseName then
			table.insert(same, c)
		end
	end
	table.sort(same, function(a, b)
		return a.Name > b.Name
	end)
	for i = BACKUPS_PER_NAME + 1, #same do
		same[i]:Destroy()
	end
end

function BulkService:_save(rigModel: Instance, kfs: KeyframeSequence, overwrite: boolean)
	local saves = animSaves(rigModel)
	local existing: KeyframeSequence? = nil
	for _, d in ipairs(saves:GetDescendants()) do
		if d:IsA("KeyframeSequence") and d.Name == kfs.Name then
			existing = d :: KeyframeSequence
			break
		end
	end
	if existing and overwrite then
		-- Keep the upload identity so "keep the same ID" works after re-importing
		for _, attr in ipairs({ "AssetId", "BBUploadedHash" }) do
			local v = existing:GetAttribute(attr)
			if v ~= nil then
				kfs:SetAttribute(attr, v)
			end
		end
		local parent = existing.Parent
		self:_backup(rigModel, existing)
		kfs.Parent = parent
	else
		if existing then
			local i = 1
			while saves:FindFirstChild(kfs.Name .. "_" .. i, true) do
				i += 1
			end
			kfs.Name = kfs.Name .. "_" .. i
		end
		kfs.Parent = saves
	end
end

export type Progress = (done: number, total: number, label: string) -> ()

function BulkService:importActions(rows: { any }, upload: boolean, onProgress: Progress?): any
	local rigModel = State.activeRigModel
	if not rigModel then
		return { ok = false, message = "Select a rig first" }
	end
	local sync = self.blenderSyncManager
	local connection = sync.blenderConnectionService
	local port = State.serverPort:get()
	local armature = sync:resolveArmatureName()
	local overwrite = self:getSetting("overwrite")
	local failures = {}
	local imported = {}
	local verifyNotes = {}

	for i, row in ipairs(rows) do
		if onProgress then
			onProgress(i - 1, #rows, "Importing " .. row.name)
		end
		local ok, body, err = connection:BBRequest(port, "POST", "/bb/export_action", {
			armature = armature,
			action = row.name,
		}, { target_bone_rest = sync:_getRestCalibration() }, false)
		if not ok then
			table.insert(failures, row.name .. ": " .. tostring(err))
			continue
		end
		local loaded = self.animationManager:loadAnimDataFromText(body, true, { suppressErrors = true, detail = row.name })
		if not loaded then
			table.insert(failures, row.name .. ": could not apply to the rig")
			continue
		end
		local kfs = self.animationManager:createKeyframeSequenceFromState()
		if not kfs then
			table.insert(failures, row.name .. ": no KeyframeSequence produced")
			continue
		end
		local settings = row.settings or {}
		kfs.Name = settings.name or row.name
		local priorityName = settings.priority or self:getSetting("priority")
		local okPriority, priority = pcall(function()
			return (Enum.AnimationPriority :: any)[priorityName]
		end)
		if okPriority and priority then
			kfs.Priority = priority
		end
		local loop = settings.loop
		if loop == nil then
			loop = self:getSetting("loop")
		end
		kfs.Loop = loop == true
		kfs:SetAttribute("BBSourceHash", fingerprint(body))
		kfs:SetAttribute("BBSourceAction", row.name)
		if State.lastImportVerification and State.lastImportVerification ~= "" then
			table.insert(verifyNotes, kfs.Name .. ": " .. State.lastImportVerification)
		end
		self:_save(rigModel, kfs, overwrite)
		table.insert(imported, kfs)
	end

	local uploaded = 0
	if upload and #imported > 0 then
		local res = self:uploadSequences(imported, onProgress)
		uploaded = res.uploaded
		for _, f in ipairs(res.failures) do
			table.insert(failures, f)
		end
	end
	if State.rigManager and State.rigManager.updateSavedAnimationsList then
		State.rigManager:updateSavedAnimationsList()
	end
	if onProgress then
		onProgress(#rows, #rows, "Done")
	end

	local message = string.format("Imported %d/%d", #imported, #rows)
	if upload then
		message ..= string.format(", uploaded %d", uploaded)
	end
	if #failures > 0 then
		message ..= ". Failed: " .. table.concat(failures, "; ")
		for _, f in ipairs(failures) do
			warn("[BBrbx] Bulk: " .. f)
		end
	end
	if #verifyNotes > 0 then
		message ..= ". Check: " .. table.concat(verifyNotes, "; ")
	end
	return { ok = #failures == 0, message = message }
end

-- ---------------------------------------------------------------------------
-- Upload
-- ---------------------------------------------------------------------------

function BulkService:_outputFolder(rigModel: Instance): Instance
	local segments = string.split(self:getSetting("outputFolder"), "/")
	local first = table.remove(segments, 1)
	local okService, node = pcall(game.GetService, game, first)
	if not okService or not node then
		node = workspace:FindFirstChild(first :: string)
		if not node then
			error("ID folder must start with a service, e.g. ReplicatedStorage/Animations", 0)
		end
	end
	table.insert(segments, rigModel.Name)
	for _, name in ipairs(segments) do
		if name ~= "" then
			local child = node:FindFirstChild(name)
			if not child then
				child = Instance.new("Folder")
				child.Name = name
				child.Parent = node
			end
			node = child
		end
	end
	return node
end

function BulkService:_creator(): (number, Enum.AssetCreatorType)
	if self:getSetting("creatorType") == "Group" and tonumber(self:getSetting("groupId")) then
		return tonumber(self:getSetting("groupId")) :: number, Enum.AssetCreatorType.Group
	end
	return StudioService:GetUserId(), Enum.AssetCreatorType.User
end

local function describeUploadError(result: any, detail: any): string
	local text = tostring(detail)
	if string.find(text, "not available", 1, true) then
		return "CreateAssetAsync is disabled. Enable File > Beta Features > \"CreateAssetAsync Luau API\" and restart Studio."
	end
	return tostring(result) .. ": " .. text
end

function BulkService:_uploadOne(kfs: KeyframeSequence, folder: Instance): number
	local creatorId, creatorType = self:_creator()
	local existing = folder:FindFirstChild(kfs.Name)
	local anim: Animation? = if existing and existing:IsA("Animation") then existing :: Animation else nil
	local params = {
		Name = kfs.Name,
		Description = "Uploaded with BBrbx",
		CreatorId = creatorId,
		CreatorType = creatorType,
	}
	local oldId = (anim and tonumber(anim:GetAttribute("AssetId"))) or tonumber(kfs:GetAttribute("AssetId"))
	local sameCreator = anim == nil
		or (anim:GetAttribute("CreatorId") == creatorId and anim:GetAttribute("CreatorType") == creatorType.Name)

	local assetId: number?
	if self:getSetting("keepIds") and oldId and sameCreator then
		local ok, res, detail = pcall(function()
			return (AssetService :: any):CreateAssetVersionAsync(kfs, Enum.AssetType.Animation, oldId, params)
		end)
		if not ok then
			error(describeUploadError("Error", res), 0)
		elseif res ~= Enum.CreateAssetResult.Success then
			error(describeUploadError(res, detail), 0)
		end
		assetId = oldId
	else
		local ok, res, detail = pcall(function()
			return (AssetService :: any):CreateAssetAsync(kfs, Enum.AssetType.Animation, params)
		end)
		if not ok then
			error(describeUploadError("Error", res), 0)
		elseif res ~= Enum.CreateAssetResult.Success then
			error(describeUploadError(res, detail), 0)
		end
		assetId = tonumber(detail)
	end

	local target: Animation = anim or Instance.new("Animation")
	target.Name = kfs.Name
	target.AnimationId = "rbxassetid://" .. tostring(assetId)
	target:SetAttribute("AssetId", assetId)
	target:SetAttribute("CreatorId", creatorId)
	target:SetAttribute("CreatorType", creatorType.Name)
	target.Parent = folder
	kfs:SetAttribute("AssetId", assetId)
	kfs:SetAttribute("BBUploadedHash", kfs:GetAttribute("BBSourceHash") or "uploaded")
	return assetId :: number
end

-- ModuleScript "AnimationIds" next to the Animation objects: name -> id
function BulkService:_writeIdModule(folder: Instance)
	local entries = {}
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("Animation") then
			table.insert(entries, c)
		end
	end
	table.sort(entries, function(a, b)
		return a.Name < b.Name
	end)
	local lines = { "-- Generated by BBrbx. Re-uploading updates this file.", "return {" }
	for _, anim in ipairs(entries) do
		table.insert(lines, string.format("\t[%q] = %q,", anim.Name, (anim :: Animation).AnimationId))
	end
	table.insert(lines, "}")
	local module = folder:FindFirstChild("AnimationIds")
	if not (module and module:IsA("ModuleScript")) then
		module = Instance.new("ModuleScript")
		module.Name = "AnimationIds"
		module.Parent = folder
	end
	(module :: ModuleScript).Source = table.concat(lines, "\n")
end

function BulkService:uploadSequences(list: { KeyframeSequence }, onProgress: Progress?): any
	local rigModel = State.activeRigModel
	if not rigModel then
		return { uploaded = 0, failures = { "Select a rig first" } }
	end
	local failures = {}
	local uploaded = 0
	local okFolder, folderOrErr = pcall(function()
		return self:_outputFolder(rigModel)
	end)
	if not okFolder then
		return { uploaded = 0, failures = { tostring(folderOrErr) } }
	end
	local folder = folderOrErr :: Instance
	for i, kfs in ipairs(list) do
		if onProgress then
			onProgress(i - 1, #list, "Uploading " .. kfs.Name)
		end
		local ok, err = pcall(function()
			self:_uploadOne(kfs, folder)
		end)
		if ok then
			uploaded += 1
		else
			table.insert(failures, kfs.Name .. ": " .. tostring(err))
		end
		task.wait(0.5)
	end
	if self:getSetting("writeIdModule") and uploaded > 0 then
		pcall(function()
			self:_writeIdModule(folder)
		end)
	end
	return { uploaded = uploaded, failures = failures }
end

function BulkService:uploadSaved(rows: { any }, onProgress: Progress?): any
	local list = {}
	for _, row in ipairs(rows) do
		if row.kfs then
			table.insert(list, row.kfs)
		end
	end
	local res = self:uploadSequences(list, onProgress)
	local message = string.format("Uploaded %d/%d", res.uploaded, #list)
	if #res.failures > 0 then
		message ..= ". Failed: " .. table.concat(res.failures, "; ")
	end
	return { ok = #res.failures == 0, message = message }
end

return BulkService
