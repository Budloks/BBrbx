--!strict

-- BB fork: Rig Doctor — scan a rig (or a whole folder of rigs) for the setup
-- problems that silently break animations, and fix the safe ones in one click.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local State = require(script.Parent.Parent.state)

local RigDoctor = {}
RigDoctor.__index = RigDoctor

export type Finding = {
	rig: Model,
	text: string,
	fix: (() -> ())?,
}

function RigDoctor.new(rigManager: any)
	local self = setmetatable({}, RigDoctor)
	self.rigManager = rigManager
	return self
end

local function isRig(inst: Instance): boolean
	return inst:IsA("Model")
		and (inst:FindFirstChildWhichIsA("Humanoid") ~= nil or inst:FindFirstChildWhichIsA("AnimationController") ~= nil)
end

-- Rigs to scan: the selection (rigs inside selected folders/models), else the active rig
function RigDoctor:_targets(): { Model }
	local out, seen = {}, {}
	local function addRig(m: Instance)
		if not seen[m] and isRig(m) then
			-- a sub-model jointed into an enclosing rig is part of that rig
			local outer = self.rigManager:resolveRigForSelection(m)
			if not seen[outer] then
				seen[outer] = true
				table.insert(out, outer :: Model)
			end
			seen[m] = true
		end
	end
	for _, sel in ipairs(Selection:Get()) do
		addRig(sel)
		for _, d in ipairs(sel:GetDescendants()) do
			if d:IsA("Model") then
				addRig(d)
			end
		end
	end
	if #out == 0 and State.activeRigModel then
		addRig(State.activeRigModel)
	end
	return out
end

function RigDoctor:scanRig(rig: Model): { Finding }
	local findings: { Finding } = {}
	local function add(text: string, fix: (() -> ())?)
		table.insert(findings, { rig = rig, text = text, fix = fix })
	end

	if not rig.PrimaryPart then
		add("no PrimaryPart (set it to the root part, e.g. HumanoidRootPart)")
	elseif not rig.PrimaryPart.Anchored then
		add("PrimaryPart is not anchored")
	end

	-- Nested Humanoid/AnimationController in sub-models: the rig's Animator skips their joints
	for _, d in ipairs(rig:GetDescendants()) do
		if (d:IsA("AnimationController") or d:IsA("Humanoid")) and d.Parent ~= rig then
			local holder = d.Parent
			if holder and holder:IsA("Model") and self.rigManager:resolveRigForSelection(holder) == rig then
				local controller = d
				local empty = #controller:GetChildren() == 0
					or (#controller:GetChildren() == 1 and controller:FindFirstChildWhichIsA("Animator") ~= nil)
				add(
					string.format("'%s' has its own %s, so its joints are not animated", holder.Name, controller.ClassName),
					if empty
						then function()
							controller:Destroy()
						end
						else nil
				)
			end
		end
	end

	-- Duplicate bone names (channels are keyed by name)
	local names: { [string]: number } = {}
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("Bone") then
			names[d.Name] = (names[d.Name] or 0) + 1
		end
	end
	for name, count in pairs(names) do
		if count > 1 then
			add(string.format("%d Bones are named '%s' (rename them; channels are keyed by name)", count, name))
		end
	end

	-- A part and a Bone sharing a name make the channel ambiguous
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") and names[d.Name] then
			local hasJoint = false
			for _, j in ipairs(d:GetJoints()) do
				if j:IsA("Motor6D") then
					hasJoint = true
				end
			end
			if hasJoint then
				add(string.format("part '%s' and a Bone share the name; Append deform mesh backs such parts up", d.Name))
			end
		end
	end

	-- Bones that hang from nothing the rig knows about
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("Bone") then
			local p = d.Parent
			if not (p and (p:IsA("BasePart") or p:IsA("Bone"))) then
				add(string.format("Bone '%s' is not under a part or bone", d.Name))
			end
		end
	end

	return findings
end

function RigDoctor:scan(): (string, { Finding })
	local all: { Finding } = {}
	local targets = self:_targets()
	for _, rig in ipairs(targets) do
		for _, f in ipairs(self:scanRig(rig)) do
			table.insert(all, f)
		end
	end
	if #targets == 0 then
		return "Select a rig (or a folder with rigs) first", all
	end
	if #all == 0 then
		return string.format("Checked %d rig(s): no problems", #targets), all
	end
	local fixable = 0
	for _, f in ipairs(all) do
		if f.fix then
			fixable += 1
		end
		warn(string.format("[BBrbx] Rig Doctor: %s: %s", f.rig.Name, f.text))
	end
	return string.format("Checked %d rig(s): %d problem(s), %d fixable (see Output)", #targets, #all, fixable), all
end

function RigDoctor:fixAll(): string
	local _, findings = self:scan()
	local recording = ChangeHistoryService:TryBeginRecording("BBrbx: Rig Doctor fixes")
	local fixed = 0
	for _, f in ipairs(findings) do
		if f.fix then
			local ok = pcall(f.fix)
			if ok then
				fixed += 1
			end
		end
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	if fixed > 0 and State.activeRigModel then
		task.spawn(function()
			self.rigManager:setRig(State.activeRigModel)
		end)
	end
	local remaining = 0
	for _, f in ipairs(findings) do
		if not f.fix then
			remaining += 1
		end
	end
	return string.format("Fixed %d problem(s)%s (Ctrl+Z undoes)", fixed, if remaining > 0 then string.format(", %d need manual work", remaining) else "")
end

return RigDoctor
