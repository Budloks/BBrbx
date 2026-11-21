--!strict

-- BB fork: Synchronise — make the Studio rig match the Blender armature.
--
-- Blender reports every exported bone with its rest relative to its Roblox
-- parent (exactly the value of Bone.CFrame, or a Motor6D C0 with C1 = I).
-- This service creates missing channels, updates rests you edited in Blender,
-- then tells Blender which channels now exist so it stamps those bones and
-- exports them 1:1 from then on.
--
-- Skinned bones are never created or moved here: moving a skinned Bone in
-- Roblox drags its mesh. Those come in with "Export Deform" + "Append deform mesh".

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local State = require(script.Parent.Parent.state)
local BranchScaler = require(script.Parent.BranchScaler)

local RigPushService = {}
RigPushService.__index = RigPushService

export type PushSummary = {
	ok: boolean,
	message: string,
	created: { string },
	updated: { string },
	skippedSkinned: { string },
	failed: { string },
}

function RigPushService.new(rigManager: any, blenderSyncManager: any)
	local self = setmetatable({}, RigPushService)
	self.rigManager = rigManager
	self.blenderSyncManager = blenderSyncManager
	return self
end

local function summary(ok: boolean, message: string): PushSummary
	return { ok = ok, message = message, created = {}, updated = {}, skippedSkinned = {}, failed = {} }
end

local function cframeFrom(components: { number }): CFrame
	return CFrame.new(table.unpack(components))
end

-- Channels sorted so every parent comes before its children
local function topoSort(channels: { any }): { any }
	local byName = {}
	for _, ch in ipairs(channels) do
		byName[ch.name] = ch
	end
	local ordered, visited = {}, {}
	local function visit(ch: any, depth: number)
		if visited[ch.name] or depth > 512 then
			return
		end
		visited[ch.name] = true
		local parent = ch.parent and byName[ch.parent]
		if parent then
			visit(parent, depth + 1)
		end
		table.insert(ordered, ch)
	end
	for _, ch in ipairs(channels) do
		visit(ch, 0)
	end
	return ordered
end

function RigPushService:_findChannel(name: string?, created: { [string]: Instance }): (Instance?, any?)
	if not name then
		return nil, nil
	end
	if created[name] then
		return created[name], nil
	end
	local rig = State.activeRig
	local rigPart = rig and rig.bones and rig.bones[name]
	if rigPart and rigPart.part then
		return rigPart.part, rigPart
	end
	return nil, nil
end

function RigPushService:pushRig(): PushSummary
	local rigModel = State.activeRigModel
	if not rigModel or not State.activeRig then
		return summary(false, "Select a rig first")
	end
	-- Parts may have been added or deleted outside the plugin since the rig
	-- was read; rebuild it so missing channels are created again.
	self.rigManager:setRig(rigModel)
	if not State.activeRig then
		return summary(false, "Could not read the rig")
	end
	local sync = self.blenderSyncManager
	local connection = sync.blenderConnectionService
	local port = State.serverPort:get()
	local armature = sync:resolveArmatureName()

	local ok, layout, err = connection:BBRequest(port, "GET", "/bb/rig_layout", { armature = armature })
	if not ok then
		return summary(false, err or "Blender did not answer")
	end

	local result = summary(true, "")
	local created: { [string]: Instance } = {}
	local applied = {}
	local rescaled: { string } = {}
	local scaledNotes: { string } = {}

	local recording = ChangeHistoryService:TryBeginRecording("BBrbx: Synchronise rig")
	local okApply, applyErr = pcall(function()
		-- Branches scaled in Blender ("Scale with children") first: the rests
		-- Blender reports below already have the new size.
		for _, entry in ipairs(layout.rescale or {}) do
			local okScale, info = BranchScaler.scale(rigModel, State.activeRig, entry)
			if okScale then
				local r = info :: any
				table.insert(rescaled, entry.id)
				table.insert(
					scaledNotes,
					string.format(
						"scaled %s x%s (%d parts, %d saved animations)",
						tostring(entry.root),
						tostring(entry.factor),
						r.parts,
						r.animations
					)
				)
			else
				table.insert(result.failed, "scale " .. tostring(entry.root) .. ": " .. tostring(info))
			end
		end
		for _, ch in ipairs(topoSort(layout.channels or {})) do
			if not ch.parent then
				continue -- root (PrimaryPart) is never touched
			end
			local rel = cframeFrom(ch.rel)
			local existing, rigPart = self:_findChannel(ch.name, created)

			if existing then
				if ch.rest_changed and rigPart then
					if existing:IsA("Bone") then
						if ch.skinned then
							table.insert(result.skippedSkinned, ch.name)
						else
							(existing :: Bone).CFrame = rel
							table.insert(result.updated, ch.name)
							table.insert(applied, { name = ch.name, blender_name = ch.blender_name, kind = "Bone" })
						end
					else
						local joint = rigPart.joint
						if joint and joint:IsA("Motor6D") then
							if rigPart.jointParentIsPart0 then
								(joint :: Motor6D).C0 = rel
							else
								(joint :: Motor6D).C1 = rel
							end
							table.insert(result.updated, ch.name)
							table.insert(applied, { name = ch.name, blender_name = ch.blender_name, kind = "Motor6D" })
						else
							table.insert(result.failed, ch.name .. " (not a Motor6D/Bone, can't update rest)")
						end
					end
				end
				continue
			end

			if ch.skinned then
				-- Comes with its mesh through Export Deform + Append deform mesh
				table.insert(result.skippedSkinned, ch.name)
				continue
			end

			local parentInst = self:_findChannel(ch.parent, created)
			if not parentInst then
				table.insert(result.failed, ch.name .. " (parent '" .. tostring(ch.parent) .. "' not in rig)")
				continue
			end

			if ch.kind == "Bone" or parentInst:IsA("Bone") then
				if not (parentInst:IsA("BasePart") or parentInst:IsA("Bone")) then
					table.insert(result.failed, ch.name .. " (Bones need a part or bone parent)")
					continue
				end
				local bone = Instance.new("Bone")
				bone.Name = ch.name
				bone.CFrame = rel
				bone.Parent = parentInst
				created[ch.name] = bone
				table.insert(result.created, ch.name)
				table.insert(applied, { name = ch.name, blender_name = ch.blender_name, kind = "Bone" })
			else
				local parentPart = parentInst :: BasePart
				local part = Instance.new("Part")
				part.Name = ch.name
				part.Size = Vector3.new(0.2, 0.2, 0.2)
				part.Transparency = 1
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
				part.Massless = true
				part.Anchored = false
				part.CFrame = parentPart.CFrame * rel
				part:SetAttribute("BBrbxHandle", true)
				local motor = Instance.new("Motor6D")
				motor.Name = ch.name
				motor.Part0 = parentPart
				motor.Part1 = part
				motor.C0 = rel
				motor.C1 = CFrame.identity
				motor.Parent = part
				part.Parent = parentPart.Parent
				created[ch.name] = part
				table.insert(result.created, ch.name)
				table.insert(applied, { name = ch.name, blender_name = ch.blender_name, kind = "Motor6D" })
			end
		end
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			if okApply then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not okApply then
		return summary(false, "Synchronise failed: " .. tostring(applyErr))
	end

	-- Rebuild the rig so the new channels exist, then let Blender stamp its bones
	-- (from the Blender rest for new ones, and from the fresh Studio rest for the rest).
	sync:invalidateRestCalibration()
	self.rigManager:setRig(rigModel)
	local restData = sync:buildRestCalibration(State.activeRig)
	local okStamp, _, stampErr = connection:BBRequest(port, "POST", "/bb/rig_applied", { armature = armature }, {
		applied = applied,
		rescaled = rescaled,
		target_bone_rest = restData,
	})

	local parts = {}
	for _, note in ipairs(scaledNotes) do
		table.insert(parts, note)
	end
	if #result.created > 0 then
		table.insert(parts, string.format("created %d", #result.created))
	end
	if #result.updated > 0 then
		table.insert(parts, string.format("updated %d", #result.updated))
	end
	if #result.skippedSkinned > 0 then
		table.insert(parts, string.format("%d skinned (use Export Deform)", #result.skippedSkinned))
	end
	if #result.failed > 0 then
		table.insert(parts, string.format("%d failed", #result.failed))
	end
	if #parts == 0 then
		table.insert(parts, "rig already matches Blender")
	end
	if not okStamp then
		table.insert(parts, "Blender stamping failed: " .. tostring(stampErr))
		result.ok = false
	end
	if layout.warnings and #layout.warnings > 0 then
		table.insert(parts, "warnings: " .. table.concat(layout.warnings, "; "))
	end
	result.message = "Synchronise: " .. table.concat(parts, ", ")
	for _, f in ipairs(result.failed) do
		warn("[BBrbx] Synchronise: " .. f)
	end
	print("[BBrbx] " .. result.message)
	return result
end

return RigPushService
