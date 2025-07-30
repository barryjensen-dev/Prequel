-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Teams = game:GetService("Teams")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- SETTINGS
local ESP_COLOR = Color3.fromRGB(255, 0, 0)        -- Custom ESP color (red)
local TRACER_COLOR = Color3.fromRGB(0, 255, 0)     -- Custom tracer color (green)
local LINE_THICKNESS = 1
local ROTATE_SPEED = 0.15

-- PREDICTION SETTINGS
local PROJECTILE_SPEED = 125 -- fallback default
local PREDICTION_FACTOR = 1

-- TOOL NAMES TO AUTO AIM/FIRE (update this list for your tools)
local TOOL_NAMES = {"M9", "Remington 870", "AK-47", "M4A1"}

-- ESP STORAGE
local ESP = {}

-- Script enabled toggle
local enabled = true

-- DRAWING LINE HELPER
local function newLine(color)
	local success, line = pcall(function()
		local l = Drawing.new("Line")
		l.Color = color
		l.Thickness = LINE_THICKNESS
		l.Visible = true
		return l
	end)
	if success then return line else return nil end
end

-- GET JOINTS (works for R6 and R15)
local function getJoints(char)
	local joints = {}
	joints.Head = char:FindFirstChild("Head")
	joints.Torso = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	joints.LeftArm = char:FindFirstChild("Left Arm") or char:FindFirstChild("LeftUpperArm")
	joints.RightArm = char:FindFirstChild("Right Arm") or char:FindFirstChild("RightUpperArm")
	joints.LeftLeg = char:FindFirstChild("Left Leg") or char:FindFirstChild("LeftUpperLeg")
	joints.RightLeg = char:FindFirstChild("Right Leg") or char:FindFirstChild("RightUpperLeg")
	return joints
end

-- CREATE ESP FOR A PLAYER
local function createESP(player)
	if player == LocalPlayer then return end
	if ESP[player] then return end
	local lines = {
		Tracer = newLine(TRACER_COLOR),
		HeadTorso = newLine(ESP_COLOR),
		LeftArm = newLine(ESP_COLOR),
		RightArm = newLine(ESP_COLOR),
		LeftLeg = newLine(ESP_COLOR),
		RightLeg = newLine(ESP_COLOR),
	}
	ESP[player] = lines
end

-- REMOVE ESP
local function removeESP(player)
	if ESP[player] then
		for _, v in pairs(ESP[player]) do
			if v and v.Remove then
				pcall(function() v:Remove() end)
			end
		end
		ESP[player] = nil
	end
end

-- FIND NEAREST VALID TARGET
local function getNearestEnemy()
	if not enabled then return nil end
	local closest, minDist = nil, math.huge
	for _, player in pairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			if player.Team == LocalPlayer.Team then continue end
			if LocalPlayer:IsFriendsWith(player.UserId) then continue end
			local hrp = player.Character.HumanoidRootPart
			local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
			if not onScreen then continue end
			local dist = (Camera.CFrame.Position - hrp.Position).Magnitude
			if dist < minDist then
				minDist = dist
				closest = player
			end
		end
	end
	return closest
end

-- PREDICT ENEMY MOVEMENT
local function getPredictedPosition(target)
	if not enabled then return nil end
	local targetChar = target.Character
	if not targetChar then return nil end
	local hrp = targetChar:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local velocity = hrp.Velocity
	local distance = (Camera.CFrame.Position - hrp.Position).Magnitude
	local timeToHit = distance / PROJECTILE_SPEED
	local predicted = hrp.Position + (velocity * timeToHit * PREDICTION_FACTOR)
	return predicted
end

-- FACE TOWARD TARGET
local function faceTarget(target)
	if not enabled then return end
	local myChar = LocalPlayer.Character
	local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
	local predicted = getPredictedPosition(target)
	if not (myHRP and predicted) then return end
	local direction = (predicted - myHRP.Position).Unit
	local look = CFrame.lookAt(myHRP.Position, myHRP.Position + direction)
	myHRP.CFrame = myHRP.CFrame:Lerp(look, ROTATE_SPEED)
end

-- AUTO-AIM TOOL + AUTO-FIRE (Uses Tool in Backpack)
local lastFireTime = 0
local FIRE_COOLDOWN = 0.3 -- seconds between shots

local function autoAimToolAt(target)
	if not enabled then return end
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if not backpack then return end

	-- Find the first tool in backpack matching TOOL_NAMES
	local tool
	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") and table.find(TOOL_NAMES, item.Name) then
			tool = item
			break
		end
	end
	if not tool then return end

	local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
	if not handle then return end

	local predicted = getPredictedPosition(target)
	if not predicted then return end

	local direction = (predicted - handle.Position).Unit
	handle.CFrame = CFrame.lookAt(handle.Position, handle.Position + direction)

	-- Auto-fire when cooldown passed
	local now = tick()
	if now - lastFireTime >= FIRE_COOLDOWN then
		lastFireTime = now

		pcall(function()
			tool:Activate()
		end)
	end
end

-- AUTO-DETECT PROJECTILE SPEED (Prison Life specific)
local function setupProjectileSpeedDetector()
	local gunProjectilesFolder = workspace:FindFirstChild("GunProjectiles")
	
	if gunProjectilesFolder then
		gunProjectilesFolder.ChildAdded:Connect(function(bullet)
			if bullet:IsA("BasePart") and bullet.Name == "Bullet" then
				local startPos = bullet.Position
				local startTime = tick()
				delay(0.1, function()
					if bullet and bullet.Parent then
						local endPos = bullet.Position
						local endTime = tick()
						local dist = (endPos - startPos).Magnitude
						local dt = endTime - startTime
						if dt > 0 then
							local speed = dist / dt
							if speed > 5 then -- sanity check
								PROJECTILE_SPEED = speed
								print("[AutoAim] Detected projectile speed:", math.floor(speed))
							end
						end
					end
				end)
			end
		end)
	end
	
	-- Also listen for bullets spawned directly under workspace (sometimes Prison Life does this)
	workspace.ChildAdded:Connect(function(bullet)
		if bullet:IsA("BasePart") and bullet.Name == "Bullet" then
			local startPos = bullet.Position
			local startTime = tick()
			delay(0.1, function()
				if bullet and bullet.Parent then
					local endPos = bullet.Position
					local endTime = tick()
					local dist = (endPos - startPos).Magnitude
					local dt = endTime - startTime
					if dt > 0 then
						local speed = dist / dt
						if speed > 5 then
							PROJECTILE_SPEED = speed
							print("[AutoAim] Detected projectile speed:", math.floor(speed))
						end
					end
				end
			end)
		end
	end)
end

-- TOGGLE HANDLER
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.RightControl then
		enabled = not enabled
		if not enabled then
			-- Hide all ESP when disabled
			for _, lines in pairs(ESP) do
				for _, line in pairs(lines) do
					if line then
						line.Visible = false
					end
				end
			end
		end
		print("[AutoAim] Enabled:", enabled)
	end
end)

-- MAIN LOOP
RunService.RenderStepped:Connect(function()
	if not enabled then return end
	local myChar = LocalPlayer.Character
	local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")

	-- Update ESP
	for player, lines in pairs(ESP) do
		local char = player.Character
		local joints = char and getJoints(char)
		local hrp = joints and joints.Torso
		if char and joints and joints.Head and hrp then
			local headPos, headVisible = Camera:WorldToViewportPoint(joints.Head.Position)
			local torsoPos, torsoVisible = Camera:WorldToViewportPoint(hrp.Position)

			lines.HeadTorso.Visible = headVisible and torsoVisible
			if lines.HeadTorso.Visible then
				lines.HeadTorso.From = Vector2.new(headPos.X, headPos.Y)
				lines.HeadTorso.To = Vector2.new(torsoPos.X, torsoPos.Y)
			end

			for limb, part in pairs({LeftArm = joints.LeftArm, RightArm = joints.RightArm, LeftLeg = joints.LeftLeg, RightLeg = joints.RightLeg}) do
				if part then
					local limbPos, limbVisible = Camera:WorldToViewportPoint(part.Position)
					lines[limb].Visible = limbVisible and torsoVisible
					if lines[limb].Visible then
						lines[limb].From = Vector2.new(torsoPos.X, torsoPos.Y)
						lines[limb].To = Vector2.new(limbPos.X, limbPos.Y)
					end
				else
					lines[limb].Visible = false
				end
			end

			local tracerPos, visible = Camera:WorldToViewportPoint(hrp.Position)
			lines.Tracer.Visible = visible
			if visible then
				lines.Tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
				lines.Tracer.To = Vector2.new(tracerPos.X, tracerPos.Y)
			end
		else
			for _, line in pairs(lines) do
				line.Visible = false
			end
		end
	end

	-- Auto-Lock + Predictive Facing + Tool Aim + Auto-fire
	local target = getNearestEnemy()
	if target then
		faceTarget(target)
		autoAimToolAt(target)
	end
end)

-- PLAYER HANDLING
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function()
		wait(1)
		createESP(p)
	end)
end)

Players.PlayerRemoving:Connect(removeESP)

-- INIT
for _, player in ipairs(Players:GetPlayers()) do
	if player ~= LocalPlayer then
		createESP(player)
	end
end

-- Start projectile speed detection
setupProjectileSpeedDetector()
