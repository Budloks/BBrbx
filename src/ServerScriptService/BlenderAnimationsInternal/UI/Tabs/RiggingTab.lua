--!native
--!strict
--!optimize 2

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local _OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed
local Observer = Fusion.Observer

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Label = require(StudioComponents.Label)
local Checkbox = require(StudioComponents.Checkbox)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)

local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")
local themeProvider = require(StudioComponentsUtil.themeProvider)


local SharedComponents = require(script.Parent.Parent.SharedComponents)
local Kit = require(script.Parent.Parent.Kit)
local ExportBoneToggles = require(script.Parent.Parent.Components.ExportBoneToggles)

local RiggingTab = {}

-- Create a ViewportFrame that shows a 3D preview of a model/part.
-- `instanceValue` is a Fusion Value<Instance?>.
local function createPreviewSlot(
	instanceValue: any,
	nameValue: any,
	layoutOrder: number,
	pickText: string,
	onPick: () -> (),
	onClear: (() -> ())?,
	hintLabel: string
)
	local viewportCamera = New("Camera")({
		FieldOfView = 40,
	})

	-- When the instance changes, clone it into the viewport and frame it
	local viewportChildren = Value({} :: { Instance })

	-- Spin state
	local spinCenter = Vector3.zero
	local spinDist = 5
	local spinHeight = 0.5
	local spinAngle = 0
	local spinConn: RBXScriptConnection? = nil
	local lastPreviewedInst: Instance? = nil
	local refreshScheduled = false

	local function refreshPreview()
		-- clear old children
		local inst = instanceValue:get()

		-- Skip if the actual instance hasn't changed
		if inst == lastPreviewedInst then
			return
		end
		lastPreviewedInst = inst

		viewportChildren:set({})
		if not inst then
			if spinConn then
				spinConn:Disconnect()
				spinConn = nil
			end
			return
		end

		-- clone into viewport
		local ok, cloned = pcall(function()
			local wasArchivable = inst.Archivable
			inst.Archivable = true
			local c = inst:Clone()
			inst.Archivable = wasArchivable
			return c
		end)
		if not ok or not cloned then
			return
		end

		-- figure out bounding box for camera framing
		local model: Model
		if cloned:IsA("Model") then
			model = cloned :: Model
		else
			model = Instance.new("Model")
			cloned.Parent = model
		end

		local cf, size = model:GetBoundingBox()
		local maxDim = math.max(size.X, size.Y, size.Z, 1)
		local dist = maxDim * 1.8

		-- Use the root part's front face so the camera starts facing the front
		local rootPart = model.PrimaryPart
		local frontDir: Vector3
		if rootPart then
			frontDir = rootPart.CFrame.LookVector
		else
			frontDir = cf.LookVector
		end

		-- Initial angle from front direction
		spinCenter = cf.Position
		spinDist = dist
		spinHeight = dist * 0.15
		spinAngle = math.atan2(frontDir.X, frontDir.Z)

		local camPos = spinCenter
			+ Vector3.new(math.sin(spinAngle) * spinDist, spinHeight, math.cos(spinAngle) * spinDist)
		viewportCamera.CFrame = CFrame.lookAt(camPos, spinCenter)

		viewportChildren:set({ model })

		-- Start slow spin — update at a low rate to avoid per-frame viewport re-renders
		if spinConn then
			spinConn:Disconnect()
		end
		local spinAccum = 0
		local SPIN_INTERVAL = 0.1 -- update camera ~10 times/sec, not every frame
		spinConn = game:GetService("RunService").Heartbeat:Connect(function(dt)
			spinAngle = spinAngle + dt * 0.4 -- ~0.4 rad/s, full rotation in ~16s
			spinAccum = spinAccum + dt
			if spinAccum < SPIN_INTERVAL then
				return
			end
			spinAccum = spinAccum - SPIN_INTERVAL
			local pos = spinCenter
				+ Vector3.new(math.sin(spinAngle) * spinDist, spinHeight, math.cos(spinAngle) * spinDist)
			viewportCamera.CFrame = CFrame.lookAt(pos, spinCenter)
		end)
	end

	-- Debounce refresh so back-to-back reactive updates (e.g. rigModelName + activeRigExists)
	-- only clone once instead of twice.
	local function scheduleRefresh()
		if refreshScheduled then
			return
		end
		refreshScheduled = true
		task.defer(function()
			refreshScheduled = false
			refreshPreview()
		end)
	end

	Observer(instanceValue):onChange(scheduleRefresh)
	task.defer(refreshPreview) -- initial

	local clearButton = onClear
			and New("TextButton")({
				Text = "x",
				Size = UDim2.fromOffset(18, 18),
				Position = UDim2.new(1, -2, 0, 2),
				AnchorPoint = Vector2.new(1, 0),
				BackgroundColor3 = Color3.fromRGB(180, 50, 50),
				TextColor3 = Color3.new(1, 1, 1),
				Font = Enum.Font.SourceSansBold,
				TextSize = 14,
				BorderSizePixel = 0,
				ZIndex = 3,
				Visible = Computed(function()
					return instanceValue:get() ~= nil
				end),
				[New("UICorner")] = nil,
				[Children] = {
					New("UICorner")({ CornerRadius = UDim.new(0, 4) }),
				},
				[OnEvent("Activated")] = onClear,
			})
		or nil

	return New("Frame")({
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, 90),
		BackgroundTransparency = 1,
		[Children] = {
			New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 8),
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),
			-- viewport thumbnail
			New("Frame")({
				LayoutOrder = 1,
				Size = UDim2.fromOffset(80, 80),
				BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground),
				BorderSizePixel = 1,
				BorderColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.InputFieldBorder),
				ClipsDescendants = true,
				[Children] = {
					New("UICorner")({ CornerRadius = UDim.new(0, 4) }),
					New("ViewportFrame")({
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						CurrentCamera = viewportCamera,
						[Children] = Computed(function()
							local items = viewportChildren:get()
							local out = { viewportCamera } :: { Instance }
							for _, item in ipairs(items) do
								table.insert(out, item)
							end
							return out
						end, Fusion.doNothing),
					}),
					-- empty state icon
					New("TextLabel")({
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Text = "?",
						TextSize = 28,
						Font = Enum.Font.SourceSans,
						TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
						Visible = Computed(function()
							return instanceValue:get() == nil
						end),
					}),
					clearButton,
				},
			}),
			-- info + button
			New("Frame")({
				LayoutOrder = 2,
				Size = UDim2.new(1, -88, 1, 0),
				BackgroundTransparency = 1,
				[Children] = {
					New("UIListLayout")({
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 2),
						VerticalAlignment = Enum.VerticalAlignment.Center,
					}),
					Label({
						LayoutOrder = 1,
						Text = Computed(function()
							return hintLabel
						end),
						TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
						TextSize = 11,
					}) :: any,
					Label({
						LayoutOrder = 2,
						Text = nameValue,
						Font = Enum.Font.SourceSansBold,
						TextSize = 14,
						TextTruncate = Enum.TextTruncate.AtEnd,
					}) :: any,
					Kit.Button({
						LayoutOrder = 3,
						Text = pickText,
						Size = UDim2.new(1, 0, 0, 24),
						Activated = onPick,
					}),
				},
			}),
		},
	})
end

function RiggingTab.create(services: any)
	-- One hint per card, so a tooltip always shows in the card you hover.
	local activeHint = Value("")
	local exportHint = Value("")
	local weaponHint = Value("")
	local function setHint(target: any, text: string)
		return function(on: boolean)
			target:set(if on then text else "")
		end
	end

	-- Rig preview uses the lastKnownRigModel / activeRigModel.
	-- Depend on BOTH activeRigExists AND rigModelName (both reactive Values)
	-- so the Computed re-fires on every rig selection / deselection.
	local rigPreviewValue = Computed(function()
		local _ = State.activeRigExists:get()
		local _ = State.rigModelName:get()
		return (State.activeRigModel or State.lastKnownRigModel) :: Instance?
	end, Fusion.doNothing)
	-- Use the actual instance name so the label stays correct even when
	-- activeRigModel is nil but lastKnownRigModel is still shown.
	local rigPreviewName = Computed(function()
		local _ = State.activeRigExists:get()
		local _ = State.rigModelName:get()
		local inst = State.activeRigModel or State.lastKnownRigModel
		if inst then
			return inst.Name
		end
		return "No Rig Selected"
	end)

	-- Re-detect connection when rig changes
	Observer(State.activeRigExists):onChange(function()
		if State.selectedWeapon:get() then
			services.exportManager:detectWeaponConnection()
		end
	end)

	-- BB fork: Blender -> Studio rig section
	local bbStatus = Value("")
	local bbBusy = Value(false)
	local function runBB(label: string, fn: () -> any)
		if bbBusy:get() then
			return
		end
		bbBusy:set(true)
		bbStatus:set(label .. "…")
		task.spawn(function()
			local ok, result = pcall(fn)
			bbBusy:set(false)
			if not ok then
				bbStatus:set("Error: " .. tostring(result))
				warn("[BBrbx] " .. tostring(result))
			elseif type(result) == "table" and result.message then
				bbStatus:set(result.message)
			else
				bbStatus:set("Done")
			end
		end)
	end

	local idle = Computed(function()
		return not bbBusy:get()
	end)
	local idleWithRig = Computed(function()
		return State.activeRigExists:get() and not bbBusy:get()
	end)
	local function hover(text: string)
		return function(on: boolean)
			activeHint:set(if on then text else "")
		end
	end

	return {
		VerticalCollapsibleSection({
			Text = "Rig from Blender",
			Subtitle = "bones you added or moved",
			Collapsed = false,
			LayoutOrder = 0,
			[Children] = {
				Kit.Hint({
					Text = "No skinned meshes: Push rig. Skinned meshes: Export Deform FBX in Blender, Import 3D here, then Bind imported mesh.",
					LayoutOrder = 1,
				}),
				Kit.PrimaryButton({
					Text = "Push rig",
					LayoutOrder = 2,
					Enabled = idleWithRig,
					Activated = function()
						runBB("Pushing rig", function()
							return services.rigPushService:pushRig()
						end)
					end,
					OnHover = hover(
						"Creates bones/joints you added in Blender, updates rests you edited and stamps the Blender bones so animations export 1:1."
					),
				}),
				Kit.Button({
					Text = "Bind imported mesh",
					LayoutOrder = 3,
					Enabled = idleWithRig,
					Activated = function()
						runBB("Binding imported mesh", function()
							return services.deformBindService:bindImportedMesh()
						end)
					end,
					OnHover = hover(
						"After Import 3D: fixes the scale, places the mesh on the Blender rest, hangs its bones on the rig, keeps the texture and backs up the parts it replaces."
					),
				}),
				Kit.FieldLabel({ Text = "Rig Doctor (selected rig or folder)", LayoutOrder = 4 }),
				Kit.Row({
					LayoutOrder = 5,
					[Children] = {
						Kit.Button({
							Text = "Scan",
							LayoutOrder = 1,
							Size = UDim2.new(0, 0, 1, 0),
							Enabled = idle,
							Activated = function()
								runBB("Scanning rigs", function()
									return { message = services.rigDoctor:scan() }
								end)
							end,
							OnHover = hover(
								"Looks for nested AnimationControllers, missing PrimaryPart, duplicate bone names and importer leftovers."
							),
						}),
						Kit.Button({
							Text = "Fix all",
							LayoutOrder = 2,
							Size = UDim2.new(0, 0, 1, 0),
							Enabled = idle,
							Activated = function()
								runBB("Fixing rigs", function()
									return { message = services.rigDoctor:fixAll() }
								end)
							end,
						}),
					},
				}),
				Kit.Hint({
					Text = Computed(function()
						return if activeHint:get() ~= "" then activeHint:get() else bbStatus:get()
					end),
					LayoutOrder = 6,
					Visible = Computed(function()
						return activeHint:get() ~= "" or bbStatus:get() ~= ""
					end),
				}),
			},
		}),
		VerticalCollapsibleSection({
			Text = "Send rig to Blender",
			Subtitle = ".rbxm export",
			Collapsed = true,
			LayoutOrder = 1,
			[Children] = {
				Kit.PrimaryButton({
					Text = "Export rig (.rbxm)",
					LayoutOrder = 1,
					Enabled = State.activeRigExists,
					Activated = function()
						exportHint:set("")
						services.exportManager:exportRigRbxm()
					end,
					OnHover = setHint(
						exportHint,
						"Saves the rig as .rbxm. In Blender: Import / Export, Roblox rig (.rbxm / .rbxl)."
					),
				}),
				Checkbox({
					Value = State.setRigOrigin,
					Text = "Center rig at origin",
					LayoutOrder = 2,
					OnChange = function(newValue: boolean): nil
						State.setRigOrigin:set(newValue)
						return nil
					end,
				}) :: any,
				Kit.Hint({
					Text = Computed(function()
						if exportHint:get() ~= "" then
							return exportHint:get()
						end
						return "You can also right-click the rig and Save to File."
					end),
					LayoutOrder = 3,
				}),
				VerticalCollapsibleSection({
					Text = "Old exporters (discontinued)",
					Collapsed = true,
					LayoutOrder = 4,
					[Children] = {
						Kit.Hint({
							Text = "Only for add-on versions older than 3.0.",
							LayoutOrder = 1,
						}),
						Kit.Button({
							Text = "Export rig (old)",
							LayoutOrder = 2,
							Enabled = State.activeRigExists,
							Activated = function()
								services.exportManager:exportRig()
							end,
						}),
						Kit.Button({
							Text = "Export rig (legacy, skinned)",
							LayoutOrder = 3,
							Enabled = State.activeRigExists,
							Activated = function()
								services.exportManager:exportRigLegacy()
							end,
						}),
						Kit.Button({
							Text = "Clean meta parts",
							LayoutOrder = 4,
							Activated = function()
								services.exportManager:clearMetaParts()
							end,
						}),
						Checkbox({
							Value = State.exportWelds,
							Text = "Export welds",
							LayoutOrder = 5,
							OnChange = function(newValue: boolean): nil
								State.exportWelds:set(newValue)
								return nil
							end,
						}) :: any,
					},
				}),
			},
		}),
		VerticalCollapsibleSection({
			Text = "Weapon or accessory",
			Subtitle = "export to Blender",
			Collapsed = true,
			LayoutOrder = 2,
			[Children] = {
				createPreviewSlot(rigPreviewValue, rigPreviewName, 1, "Select in Explorer", function()
					local rig = State.activeRigModel or State.lastKnownRigModel
					if rig then
						game.Selection:Set({ rig })
					end
				end, nil, "RIG"),
				createPreviewSlot(State.selectedWeapon, State.selectedWeaponName, 2, "Pick from Selection", function()
					services.exportManager:pickWeapon()
				end, function()
					services.exportManager:clearWeapon()
				end, "WEAPON"),
				New("TextLabel")({
					LayoutOrder = 3,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					Font = Enum.Font.BuilderSans,
					TextSize = Kit.SMALL_TEXT,
					TextWrapped = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = Computed(function()
						local status = State.weaponConnectionStatus:get()
						return if status == "" then "Pick a weapon to check how it connects." else status
					end),
					TextColor3 = Computed(function()
						local status = State.weaponConnectionStatus:get()
						if status:find("^[Vv]") or status:find(utf8.char(0x2713)) then
							return Color3.fromRGB(80, 200, 80)
						elseif status:find(utf8.char(0x26A0)) then
							return Color3.fromRGB(220, 160, 40)
						end
						return Kit.color(Enum.StudioStyleGuideColor.DimmedText):get()
					end),
				}),
				Kit.PrimaryButton({
					Text = "Export weapon (.rbxm)",
					LayoutOrder = 4,
					Enabled = Computed(function()
						return State.selectedWeapon:get() ~= nil
					end),
					Activated = function()
						weaponHint:set("")
						services.exportManager:exportWeaponRbxm()
					end,
					OnHover = setHint(
						weaponHint,
						"Saves the weapon as .rbxm. In Blender: Import Roblox (.rbxm / .rbxl) reads parts, Motor6Ds and textures."
					),
				}),
				Kit.Hint({
					Text = weaponHint,
					LayoutOrder = 5,
					Visible = Computed(function()
						return weaponHint:get() ~= ""
					end),
				}),
				VerticalCollapsibleSection({
					Text = "Old exporters (discontinued)",
					Collapsed = true,
					LayoutOrder = 6,
					[Children] = {
						Kit.Button({
							Text = "Export weapon (old)",
							LayoutOrder = 1,
							Enabled = Computed(function()
								local _ = State.activeRigExists:get()
								return State.selectedWeapon:get() ~= nil
									and (State.activeRigModel or State.lastKnownRigModel) ~= nil
							end),
							Activated = function()
								services.exportManager:exportWeapon()
							end,
						}),
						Kit.Button({
							Text = "Clean meta parts",
							LayoutOrder = 2,
							Activated = function()
								services.exportManager:clearMetaParts()
							end,
						}),
					},
				}),
			},
		}),
		ExportBoneToggles.create(services, 3),
	}
end

return RiggingTab
