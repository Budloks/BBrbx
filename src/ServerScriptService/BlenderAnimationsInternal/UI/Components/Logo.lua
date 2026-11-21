--!strict
-- BBrbx wordmark, drawn from its 38x10 pixel grid so the plugin needs no uploaded image.
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)
local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local themeProvider = require(StudioComponents:FindFirstChild("Util").themeProvider)

local New = Fusion.New
local Children = Fusion.Children

local GRID_W, GRID_H = 38, 10
-- {column, row, length}: horizontal runs of lit pixels
local RUNS = {
	{0, 0, 6},
	{8, 0, 6},
	{23, 0, 2},
	{0, 1, 7},
	{8, 1, 7},
	{23, 1, 2},
	{0, 2, 2},
	{5, 2, 2},
	{8, 2, 2},
	{13, 2, 2},
	{16, 2, 2},
	{19, 2, 2},
	{23, 2, 2},
	{26, 2, 3},
	{31, 2, 2},
	{36, 2, 2},
	{0, 3, 2},
	{5, 3, 2},
	{8, 3, 2},
	{13, 3, 2},
	{16, 3, 6},
	{23, 3, 7},
	{31, 3, 3},
	{35, 3, 3},
	{0, 4, 6},
	{8, 4, 6},
	{16, 4, 3},
	{20, 4, 1},
	{23, 4, 2},
	{28, 4, 2},
	{32, 4, 5},
	{0, 5, 7},
	{8, 5, 7},
	{16, 5, 2},
	{23, 5, 2},
	{28, 5, 2},
	{33, 5, 3},
	{0, 6, 2},
	{5, 6, 2},
	{8, 6, 2},
	{13, 6, 2},
	{16, 6, 2},
	{23, 6, 2},
	{28, 6, 2},
	{32, 6, 5},
	{0, 7, 2},
	{5, 7, 2},
	{8, 7, 2},
	{13, 7, 2},
	{16, 7, 2},
	{23, 7, 2},
	{28, 7, 2},
	{31, 7, 3},
	{35, 7, 3},
	{0, 8, 7},
	{8, 8, 7},
	{16, 8, 2},
	{23, 8, 7},
	{31, 8, 2},
	{36, 8, 2},
	{0, 9, 6},
	{8, 9, 6},
	{16, 9, 2},
	{23, 9, 6},
	{31, 9, 2},
	{36, 9, 2},
}

return function(props: { LayoutOrder: number?, Pixel: number? })
	local px = props.Pixel or 3
	local color = themeProvider:GetColor(Enum.StudioStyleGuideColor.MainText)
	local cells = {}
	for i, run in RUNS do
		cells[i] = New("Frame")({
			BorderSizePixel = 0,
			BackgroundColor3 = color,
			Position = UDim2.fromOffset(run[1] * px, run[2] * px),
			Size = UDim2.fromOffset(run[3] * px, px),
		})
	end
	return New("Frame")({
		Name = "BBrbxLogo",
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(GRID_W * px, GRID_H * px),
		[Children] = cells,
	})
end
