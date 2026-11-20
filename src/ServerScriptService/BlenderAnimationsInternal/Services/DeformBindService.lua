--!strict

-- BB fork: "Bind Imported Mesh".
--
-- After "Export Deform FBX" in Blender and Studio's Import 3D, this turns the
-- imported model into part of the active rig — the steps that used to be done
-- by hand:
--   * fix the import scale (FBX centimetres usually arrive 100x too big),
--   * remove the importer's nested AnimationController/InitialPoses (a nested
--     controller makes the rig's Animator skip those joints),
--   * place the mesh so its bones sit exactly on the Blender rest (solved from
--     bone positions, so it does not depend on any axis convention),
--   * move the root bones under the right rig part, weld the mesh to it,
--   * keep the original texture (the importer often adds empty SurfaceAppearances),
--   * move the rigid parts the bones replace (and an older bind) to a backup,
--   * rebuild the rig and let Blender stamp the bones with the real Roblox rest.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local State = require(script.Parent.Parent.state)

local DeformBindService = {}
DeformBindService.__index = DeformBindService

local BB_MESH_ATTRIBUTE = "BBrbxDeformMesh"

function DeformBindService.new(rigManager: any, blenderSyncManager: any)
	local self = setmetatable({}, DeformBindService)
	self.rigManager = rigManager
	self.blenderSyncManager = blenderSyncManager
	return self
end

local function result(ok: boolean, message: string)
	return { ok = ok, message = message }
end

local function skinnedMeshParts(root: Instance): { MeshPart }
	local list = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("MeshPart") and (d :: MeshPart).HasSkinnedMesh then
			table.insert(list, d :: MeshPart)
		end
	end
	return list
end

local function bonesOf(mp: Instance): { Bone }
	local list = {}
	for _, d in ipairs(mp:GetDescendants()) do
		if d:IsA("Bone") then
			table.insert(list, d :: Bone)
		end
	end
	return list
end

local function worldOf(inst: Instance): CFrame
	if inst:IsA("Bone") then
		return (inst :: Bone).WorldCFrame
	end
	return (inst :: BasePart).CFrame
end

-- Orthonormal basis from three points (origin + two directions)
local function basis(p0: Vector3, p1: Vector3, p2: Vector3): CFrame?
	local x = p1 - p0
	local v = p2 - p0
	if x.Magnitude < 1e-4 then
		return nil
	end
	x = x.Unit
	local z = x:Cross(v)
	if z.Magnitude < 1e-4 then
		return nil
	end
	z = z.Unit
	local y = z:Cross(x)
	return CFrame.fromMatrix(p0, x, y, z)
end

function DeformBindService:_findImport(rigModel: Instance, skinnedNames: { [string]: any }): (Instance?, MeshPart?)
	local function score(mp: MeshPart): number
		if mp:GetAttribute(BB_MESH_ATTRIBUTE) then
			return 0
		end
		local n = 0
		for _, b in ipairs(bonesOf(mp)) do
			if skinnedNames[b.Name] then
				n += 1
			end
		end
		return n
	end
	local best, bestMp, bestScore = nil, nil, 0
	local function consider(container: Instance)
		for _, mp in ipairs(skinnedMeshParts(container)) do
			local s = score(mp)
			if s > bestScore then
				-- The importer's own Model is the MeshPart's parent (unless it was flattened)
				local parent = mp.Parent
				local owner: Instance = if parent and parent:IsA("Model") and parent ~= rigModel then parent else mp
				best, bestMp, bestScore = owner, mp, s
			end
		end
	end
	for _, sel in ipairs(Selection:Get()) do
		consider(sel)
		if sel:IsA("MeshPart") then
			local s = score(sel :: MeshPart)
			if s > bestScore then
				best, bestMp, bestScore = sel, sel :: MeshPart, s
			end
		end
	end
	if not bestMp then
		consider(rigModel)
	end
	if not bestMp then
		for _, child in ipairs(workspace:GetChildren()) do
			if child:IsA("Model") and child ~= rigModel then
				consider(child)
			end
		end
	end
	return best, bestMp
end

function DeformBindService:bindImportedMesh()
	local rigModel = State.activeRigModel :: Model?
	if not rigModel or not State.activeRig then
		return result(false, "Select the rig first, then press Bind Imported Mesh")
	end
	local sync = self.blenderSyncManager
	local connection = sync.blenderConnectionService
	local port = State.serverPort:get()
	local armature = sync:resolveArmatureName()

	local okLayout, layout, err = connection:BBRequest(port, "GET", "/bb/rig_layout", { armature = armature })
	if not okLayout then
		return result(false, err or "Blender did not answer")
	end
	local channels: { [string]: any } = {}
	local skinned: { [string]: any } = {}
	for _, ch in ipairs(layout.channels or {}) do
		channels[ch.name] = ch
		if ch.skinned then
			skinned[ch.name] = ch
		end
	end
	if next(skinned) == nil then
		return result(false, "Blender reports no skinned bones for " .. tostring(armature) .. " (nothing to bind; use Push Rig)")
	end

	local importModel, mp = self:_findImport(rigModel, skinned)
	if not importModel or not mp then
		return result(false, "No imported skinned mesh with matching bone names found. Import the Export Deform FBX first (Import 3D).")
	end
	local meshPart = mp :: MeshPart

	local rig = State.activeRig
	local function rigInstance(name: string?): Instance?
		if not name then
			return rigModel.PrimaryPart
		end
		local rp = rig.bones and rig.bones[name]
		return rp and rp.part or nil
	end

	local recording = ChangeHistoryService:TryBeginRecording("BBrbx: Bind Imported Mesh")
	local summary = {}
	local ok, bindErr = pcall(function()
		-- 1. Scale (compare bone-to-parent distances with the Blender layout)
		local ratios = {}
		for _, bone in ipairs(bonesOf(meshPart)) do
			local ch = skinned[bone.Name]
			if ch and bone.Parent and bone.Parent:IsA("Bone") then
				local expected = Vector3.new(ch.rel[1], ch.rel[2], ch.rel[3]).Magnitude
				local actual = bone.CFrame.Position.Magnitude
				if expected > 1e-3 and actual > 1e-6 then
					table.insert(ratios, expected / actual)
				end
			end
		end
		table.sort(ratios)
		local ratio = if #ratios > 0 then ratios[math.floor((#ratios + 1) / 2)] else 1
		if math.abs(ratio - 1) > 0.01 and importModel:IsA("Model") then
			local model = importModel :: Model
			model:ScaleTo(model:GetScale() * ratio)
			table.insert(summary, string.format("scaled x%.3g", ratio))
		elseif math.abs(ratio - 1) > 0.01 then
			warn("[BBrbx] Import is scaled x" .. tostring(1 / ratio) .. " but is not inside a Model; can't rescale")
		end

		-- 2. Importer leftovers that break playback
		for _, d in ipairs(importModel:GetDescendants()) do
			if d:IsA("AnimationController") or d:IsA("Humanoid") or (d:IsA("Folder") and d.Name == "InitialPoses") then
				d:Destroy()
			end
		end

		-- 3. Desired world position of every skinned bone (rest from Blender)
		local desired: { [string]: CFrame } = {}
		local function desiredWorld(name: string, depth: number): CFrame?
			if desired[name] then
				return desired[name]
			end
			local ch = channels[name]
			if not ch or depth > 256 then
				return nil
			end
			local parentWorld: CFrame?
			local parentCh = ch.parent and channels[ch.parent]
			if parentCh and skinned[ch.parent] then
				parentWorld = desiredWorld(ch.parent, depth + 1)
			else
				local inst = rigInstance(ch.parent)
				parentWorld = inst and worldOf(inst) or nil
			end
			if not parentWorld then
				return nil
			end
			local w = parentWorld * CFrame.new(table.unpack(ch.rel))
			desired[name] = w
			return w
		end

		local matched = {}
		for _, bone in ipairs(bonesOf(meshPart)) do
			if skinned[bone.Name] and desiredWorld(bone.Name, 0) then
				table.insert(matched, bone)
			end
		end
		if #matched == 0 then
			error("None of the imported bones could be placed (are the rig parts they hang from in the rig?)")
		end

		-- 4. Rigid placement from bone positions (independent of axis conventions)
		local p0 = matched[1]
		local far, farDist = nil, 0
		for _, b in ipairs(matched) do
			local d = (b.WorldPosition - p0.WorldPosition).Magnitude
			if d > farDist then
				far, farDist = b, d
			end
		end
		local third, thirdScore = nil, 0
		if far then
			local axis = (far.WorldPosition - p0.WorldPosition).Unit
			for _, b in ipairs(matched) do
				local v = b.WorldPosition - p0.WorldPosition
				local off = (v - axis * v:Dot(axis)).Magnitude
				if off > thirdScore then
					third, thirdScore = b, off
				end
			end
		end
		local move: CFrame
		local bCur = far and third and basis(p0.WorldPosition, far.WorldPosition, third.WorldPosition)
		local bDes = far and third and basis(desired[p0.Name].Position, desired[far.Name].Position, desired[third.Name].Position)
		if bCur and bDes then
			move = bDes * bCur:Inverse()
		else
			-- Too few bones for a position fit: align the first bone's frame
			move = desired[p0.Name] * p0.WorldCFrame:Inverse()
		end
		meshPart.CFrame = move * meshPart.CFrame
		local worst = 0
		for _, b in ipairs(matched) do
			worst = math.max(worst, (b.WorldPosition - desired[b.Name].Position).Magnitude)
		end
		if worst > 0.02 then
			table.insert(summary, string.format("bone fit off by up to %.3f studs", worst))
		end

		-- 5. Backup what the bones replace: rigid parts with the same names and an older bind
		local backup = ServerStorage:FindFirstChild(rigModel.Name .. "_BB_Replaced")
		if not backup then
			backup = Instance.new("Model")
			backup.Name = rigModel.Name .. "_BB_Replaced"
			backup.Parent = ServerStorage
		end
		local replacedTexture: SurfaceAppearance? = nil
		local replacedTextureId: string? = nil
		local movedCount = 0
		local replacing: { [Instance]: boolean } = {}
		for _, bone in ipairs(matched) do
			local inst = rigInstance(bone.Name)
			if inst and inst ~= meshPart and inst ~= bone then
				replacing[inst] = true
			end
		end
		for inst in pairs(replacing) do
			if inst:IsA("BasePart") then
				replacedTexture = replacedTexture or inst:FindFirstChildOfClass("SurfaceAppearance")
				if inst:IsA("MeshPart") and (inst :: MeshPart).TextureID ~= "" then
					replacedTextureId = replacedTextureId or (inst :: MeshPart).TextureID
				end
			end
		end
		for inst in pairs(replacing) do
			-- Never strand other rig parts that hang from a replaced part
			local blocked = false
			for _, d in ipairs(rigModel:GetDescendants()) do
				if d:IsA("JointInstance") and not d:IsDescendantOf(inst) then
					local j = d :: any
					-- Another (kept) part hangs from this one: moving it would strand that part
					if j.Part0 == inst and j.Part1 and not replacing[j.Part1] then
						blocked = true
						break
					end
				end
			end
			if inst:IsA("Bone") then
				local oldMesh = inst:FindFirstAncestorWhichIsA("MeshPart")
				inst.Parent = backup
				if oldMesh and oldMesh:GetAttribute(BB_MESH_ATTRIBUTE) and oldMesh ~= meshPart then
					oldMesh.Parent = backup
				end
			elseif blocked then
				inst.Name ..= "__bb_replaced"
				if inst:IsA("BasePart") then
					(inst :: BasePart).Transparency = 1
				end
			else
				inst.Parent = backup
			end
			movedCount += 1
		end
		-- An older bind whose bones were all replaced above
		for _, old in ipairs(skinnedMeshParts(rigModel)) do
			if old ~= meshPart and old:GetAttribute(BB_MESH_ATTRIBUTE) and #bonesOf(old) == 0 then
				local stillUsed = false
				for _, b in ipairs(bonesOf(rigModel)) do
					if b:IsDescendantOf(old) then
						stillUsed = true
					end
				end
				if not stillUsed then
					old.Parent = backup
				end
			end
		end
		if movedCount > 0 then
			table.insert(summary, string.format("%d replaced part(s) moved to ServerStorage.%s", movedCount, backup.Name))
		end

		-- 6. Root bones under their rig parts (world placement kept)
		local roots = {}
		for _, b in ipairs(matched) do
			if not (b.Parent and b.Parent:IsA("Bone") and skinned[b.Parent.Name]) then
				table.insert(roots, b)
			end
		end
		for _, b in ipairs(roots) do
			local ch = skinned[b.Name]
			local attach = rigInstance(ch.parent) or rigModel.PrimaryPart
			if attach then
				local world = b.WorldCFrame
				b.Parent = attach
				b.CFrame = worldOf(attach):Inverse() * world
			end
		end

		-- 7. Mesh into the rig, welded to the part the first root hangs from
		local firstCh = skinned[roots[1] and roots[1].Name or matched[1].Name]
		local weldTo = rigInstance(firstCh and firstCh.parent) or rigModel.PrimaryPart
		while weldTo and weldTo:IsA("Bone") do
			weldTo = weldTo.Parent
		end
		meshPart.Anchored = false
		meshPart.CanCollide = false
		meshPart.CanQuery = false
		meshPart.CanTouch = false
		meshPart.Massless = true
		meshPart.CastShadow = false
		meshPart:SetAttribute(BB_MESH_ATTRIBUTE, true)
		meshPart.Parent = (weldTo and weldTo.Parent) or rigModel
		if weldTo and weldTo:IsA("BasePart") then
			local weld = Instance.new("Weld")
			weld.Name = "BBDeformWeld"
			weld.Part0 = weldTo
			weld.Part1 = meshPart
			weld.C0 = (weldTo :: BasePart).CFrame:Inverse() * meshPart.CFrame
			weld.Parent = meshPart
		end

		-- 8. Texture: the importer adds one SurfaceAppearance per material, often empty
		local appearances = {}
		for _, c in ipairs(meshPart:GetChildren()) do
			if c:IsA("SurfaceAppearance") then
				table.insert(appearances, c)
			end
		end
		local usable = 0
		for _, sa in ipairs(appearances) do
			if (sa :: SurfaceAppearance).ColorMap ~= "" then
				usable += 1
			end
		end
		if replacedTexture and (usable ~= 1 or #appearances ~= 1) then
			for _, sa in ipairs(appearances) do
				sa:Destroy()
			end
			replacedTexture:Clone().Parent = meshPart
			table.insert(summary, "kept the original texture")
		elseif #appearances > 1 then
			-- MeshPart only uses one; keep the first with a color map
			local keep = nil
			for _, sa in ipairs(appearances) do
				if not keep and (sa :: SurfaceAppearance).ColorMap ~= "" then
					keep = sa
				end
			end
			for _, sa in ipairs(appearances) do
				if sa ~= keep then
					sa:Destroy()
				end
			end
		elseif #appearances == 0 and replacedTextureId then
			meshPart.TextureID = replacedTextureId
		end

		-- 9. Remove the now-empty import container
		if importModel ~= meshPart and importModel.Parent and #skinnedMeshParts(importModel) == 0 then
			importModel:Destroy()
		end
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		return result(false, "Bind failed: " .. tostring(bindErr))
	end

	-- 10. Rebuild and stamp Blender bones from the real Roblox rest
	sync:invalidateRestCalibration()
	self.rigManager:setRig(rigModel)
	local restData = sync:buildRestCalibration(State.activeRig)
	local okStamp, _, stampErr = connection:BBRequest(port, "POST", "/bb/rig_applied", { armature = armature }, {
		applied = {},
		target_bone_rest = restData,
	})
	if not okStamp then
		table.insert(summary, "Blender stamping failed: " .. tostring(stampErr))
	end
	local message = "Bound " .. meshPart.Name .. (if #summary > 0 then " (" .. table.concat(summary, "; ") .. ")" else "")
	print("[BBrbx] " .. message)
	return result(okStamp, message)
end

return DeformBindService
