--!native
--!strict
--!optimize 2

-- BBrbx: Settings tab (export / live sync options) + About & credits.

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Checkbox = require(StudioComponents.Checkbox)
local Label = require(StudioComponents.Label)
local TextInput = require(StudioComponents.TextInput)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)

local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")
local themeProvider = require(StudioComponentsUtil.themeProvider)

local SharedComponents = require(script.Parent.Parent.SharedComponents)

local MoreTab = {}

local function hinted(activeHint: any, text: string)
	return {
		[OnEvent("MouseEnter")] = function()
			activeHint:set(text)
		end,
		[OnEvent("MouseLeave")] = function()
			activeHint:set("")
		end,
	}
end

local function withHint(props: { [any]: any }, activeHint: any, text: string)
	for k, v in pairs(hinted(activeHint, text)) do
		props[k] = v
	end
	return props
end

function MoreTab.create(services: any)
	local activeHint = Value("")

	return {
		VerticalCollapsibleSection({
			Text = "Blender connection",
			Collapsed = false,
			LayoutOrder = 1,
			[Children] = {
				Checkbox(withHint({
					Value = State.autoConnectToBlender,
					Text = "Connect to Blender automatically",
					LayoutOrder = 1,
					OnChange = function(enabled: boolean): nil
						State.autoConnectToBlender:set(enabled)
						services.plugin:SetSetting("AutoConnectToBlender", enabled)
						return nil
					end,
				}, activeHint, "Connects to BBrbx in Blender when the plugin opens.")),
				Checkbox(withHint({
					Value = State.enableLiveSync,
					Text = "Live Sync (update while you animate)",
					LayoutOrder = 2,
					OnChange = function(enabled: boolean): nil
						State.enableLiveSync:set(enabled)
						services.plugin:SetSetting("EnableLiveSync", enabled)
						if not enabled then
							services.blenderSyncManager:stopLiveSyncing()
						end
						return nil
					end,
				}, activeHint, "Re-imports the animation every time you change it in Blender.")),
			},
		}) :: any,
		VerticalCollapsibleSection({
			Text = "Import sources",
			Collapsed = false,
			LayoutOrder = 2,
			[Children] = {
				Checkbox(withHint({
					Value = State.enableFileExport,
					Text = "Show import from files",
					LayoutOrder = 1,
					OnChange = function(enabled: boolean): nil
						State.enableFileExport:set(enabled)
						services.plugin:SetSetting("EnableFileExport", enabled)
						return nil
					end,
				}, activeHint, "Shows 'Import Animation from File(s)' for animations baked to a file in Blender.")),
				Checkbox(withHint({
					Value = State.enableClipboardExport,
					Text = "Show import from clipboard",
					LayoutOrder = 2,
					OnChange = function(enabled: boolean): nil
						State.enableClipboardExport:set(enabled)
						services.plugin:SetSetting("EnableClipboardExport", enabled)
						return nil
					end,
				}, activeHint, "Shows 'Import Animation from Clipboard' for animations baked to the clipboard.")),
			},
		}) :: any,
		VerticalCollapsibleSection({
			Text = "Interface",
			Collapsed = false,
			LayoutOrder = 3,
			[Children] = {
				Checkbox(withHint({
					Value = State.reducedMotion,
					Text = "Reduced motion",
					LayoutOrder = 1,
					OnChange = function(enabled: boolean): nil
						State.reducedMotion:set(enabled)
						services.plugin:SetSetting("ReducedMotion", enabled)
						return nil
					end,
				}, activeHint, "Turns off most UI animations.")),
			},
		}) :: any,
		SharedComponents.AnimatedHintLabel({
			Text = activeHint,
			LayoutOrder = 4,
			Size = UDim2.new(1, 0, 0, 0),
			TextWrapped = true,
			ClipsDescendants = true,
			Visible = true,
			TextTransparency = 0,
			RichText = true,
		}),
		VerticalCollapsibleSection({
			Text = "About BBrbx",
			Collapsed = false,
			LayoutOrder = 5,
			[Children] = {
				Label({
					LayoutOrder = 1,
					Text = "<b>BBrbx</b> — Blender ⇄ Roblox Studio rigs and animations.",
					RichText = true,
					TextWrapped = true,
				}),
				Label({
					LayoutOrder = 2,
					Text = "Needs the BBrbx add-on in Blender (Edit > Preferences > Add-ons). In Blender the server starts by itself.",
					TextWrapped = true,
					TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
				}),
				VerticalCollapsibleSection({
					Text = "Credits",
					Collapsed = true,
					LayoutOrder = 3,
					[Children] = {
						Label({
							LayoutOrder = 1,
							Text = "Based on RBXMonkey (Blender Animations Plugin) by Cautioned, licensed under GPL-3.0. BBrbx is distributed under the same license.",
							TextWrapped = true,
						}),
						TextInput({
							LayoutOrder = 2,
							Text = "https://github.com/Cautioned/Blender-Animations-Plugin",
						}),
						Label({
							LayoutOrder = 3,
							Text = "UI built with Fusion and StudioComponents.",
							TextWrapped = true,
							TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
						}),
					},
				}) :: any,
			},
		}) :: any,
	}
end

return MoreTab
