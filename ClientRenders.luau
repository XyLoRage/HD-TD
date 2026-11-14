-- Connected Discord-GitHub
--[[
	ClientRenders

	Draws what the server only simulates. The server keeps one Folder per enemy and one
	Target value per tower; every model, animation and bullet here exists on this client
	alone, so a full wave costs the server nothing to replicate. Enemy movement is predicted
	from the same speed and path the server's EnemyAI uses, instead of receiving positions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- ReplicatedFirst starts before the map has replicated, so wait for it here,
-- or direct indexing into the map below could error.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local dataFolder = ReplicatedStorage:WaitForChild("Data")
local EnemyData = require(dataFolder:WaitForChild("EnemyData"))
local TowerData = require(dataFolder:WaitForChild("TowerData"))

-- How fast models swing round to a new direction. Higher is snappier.
local TURN_SPEED = 8
-- Furthest an enemy walks from the path's centre, so a wave doesn't move in single file.
local PATH_SIDE_SPREAD = 0.7
-- Walk animation speed per stud/s of move speed, so faster enemies' feet don't slide.
local WALK_ANIMATION_RATE = 0.15
-- Length of a bullet tracer in studs: how far its head leads its tail.
local BULLET_TRAIL_LENGTH = 6
-- Waypoint rays start this far above each part and travel this far down to find the road.
local GROUND_RAY_HEIGHT = 5
local GROUND_RAY_LENGTH = 20
-- Directions shorter than this are treated as "no direction", since .Unit of one is NaN.
local MIN_DIRECTION_LENGTH = 0.01

local enemiesFolder = Workspace:WaitForChild("Enemies")
local towersFolder = Workspace:WaitForChild("Towers")
local pathFolder = Workspace:WaitForChild("Path")
local roadFolder = Workspace:WaitForChild("Road")
local clientFolder = Workspace:WaitForChild("Client")
local effectsFolder = Workspace:WaitForChild("VFX")
local bulletTemplate = ReplicatedStorage:WaitForChild("VFX")
	:WaitForChild("Projectiles")
	:WaitForChild("Yellow")

local Enemy = {}
Enemy.__index = Enemy

local Tower = {}
Tower.__index = Tower

type EnemyFields = {
	rootPart: BasePart,
	_model: Model,
	_speed: number,
	_position: Vector3,
	_velocity: Vector3,
	_facing: Vector3,
	_nextWaypoint: number,
	_sideOffset: number,
	_heightOffset: Vector3,
}
--[[
	Luau can't name "a table with these fields AND Enemy's methods" directly, so the type is
	inferred from what setmetatable would return. Casting {} to EnemyFields gives the fields,
	the metatable gives :_walk, :update etc., so self is fully typed inside every method.
	typeof() here only runs in the type checker; nothing is created at runtime.
]]
type EnemyObject = typeof(setmetatable({} :: EnemyFields, Enemy))

type TowerStats = {
	damage: number,
	attackInterval: number,
	range: number,
	bulletSpeed: number,
	mode: string,
}

type TowerFields = {
	_rootPart: BasePart,
	_stats: TowerStats,
	_targetValue: ObjectValue,
	_barrel: BasePart,
	_shootTrack: AnimationTrack,
	_cooldown: number,
}
type TowerObject = typeof(setmetatable({} :: TowerFields, Tower))

-- Keyed by the server's enemy Folder, so a tower's Target value looks its enemy up directly.
local enemiesByFolder: { [Instance]: EnemyObject } = {}
local towers: { TowerObject } = {}
local waypoints: { Vector3 } = {}
local bulletPool: { BasePart } = {}
-- Reused every frame by BulkMoveTo, so moving a wave doesn't allocate two tables per frame.
local movedParts: { BasePart } = {}
local movedCFrames: { CFrame } = {}

--[[
	Waypoints float at slightly different heights. Dropping each one onto the road keeps
	the feet on the ground without anyone having to place the parts perfectly. The parts
	are named 1, 2, 3..., so the name doubles as the walking order.
]]
local function buildWaypoints(): ()
	local raycastParams = RaycastParams.new()
	-- Exclusively scans the road.
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = {
		roadFolder,
	}

	for _, waypointPart in ipairs(pathFolder:GetChildren()) do
		-- Start above the waypoint in case it sits at or below the road surface;
		-- a ray that starts inside the road won't hit it.
		local rayOrigin = waypointPart.Position + Vector3.yAxis * GROUND_RAY_HEIGHT
		local rayDirection = Vector3.yAxis * -GROUND_RAY_LENGTH
		local result = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
		local index = tonumber(waypointPart.Name)
		-- Use the road hit if there was one, else fall back to the waypoint's own position.
		waypoints[index] = if result then result.Position else waypointPart.Position
	end
end

--[[
	Removes the height from a direction. Models turn using this, so they spin on the spot
	and never tilt toward a waypoint that sits higher or lower than they do.
]]
local function getFlatDirection(direction: Vector3, fallback: Vector3): Vector3
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)
	-- A (near) zero vector can't be normalized since .Unit divides by the
	-- magnitude, so use the fallback.
	if flatDirection.Magnitude < MIN_DIRECTION_LENGTH then
		return fallback
	end
	return flatDirection.Unit
end

-- Scaling by the frame time keeps turning speed equal at any framerate; a fixed alpha wouldn't.
local function getTurnAlpha(deltaTime: number): number
	-- Clamped at 1 so the lerp never overshoots the target on a long frame.
	return math.clamp(TURN_SPEED * deltaTime, 0, 1)
end

-- Forces looping, because walks and idles must keep going however the asset was exported.
local function playLoopedAnimation(
	animator: Animator,
	animation: Animation,
	speed: number?
): AnimationTrack
	local track = animator:LoadAnimation(animation)
	track.Looped = true
	track:Play(nil, nil, speed)
	return track
end

function Enemy.new(serverFolder: Folder): EnemyObject
	local enemyInfo = EnemyData[serverFolder:GetAttribute("EnemyID")]
	local speed = serverFolder:GetAttribute("Speed")
	local model = enemyInfo.model.Model:Clone()
	local rootPart = model.PrimaryPart

	-- The script positions the root part, but waypoints sit on the ground,
	-- so the root has to be lifted by half its own height plus one leg.
	local heightOffset = Vector3.yAxis * (rootPart.Size.Y / 2 + model["Left Leg"].Size.Y)
	local startPosition = waypoints[1]
	-- Face the second waypoint. -Z is the fallback if waypoints 1 and 2 are stacked,
	-- since it's a CFrame's default LookVector.
	local facing = getFlatDirection(waypoints[2] - startPosition, -Vector3.zAxis)

	local spawnPosition = startPosition + heightOffset
	rootPart.CFrame = CFrame.lookAt(spawnPosition, spawnPosition + facing)
	model.Name = serverFolder.Name
	model.Parent = clientFolder

	local animator = model.AnimationController.Animator
	playLoopedAnimation(animator, model.Animation, speed * WALK_ANIMATION_RATE)

	local self = {
		rootPart = rootPart,
		_model = model,
		_speed = speed,
		_position = startPosition,
		_velocity = facing * speed,
		_facing = facing,
		_nextWaypoint = 2,
		-- Random per enemy, rolled once here so it stays steady instead of jittering.
		_sideOffset = (math.random() * 2 - 1) * PATH_SIDE_SPREAD,
		_heightOffset = heightOffset,
	}
	return setmetatable(self, Enemy)
end

--[[
	Same walking rule as the server's EnemyAI: distance left over after reaching a corner
	carries on toward the next waypoint. Matching that rule is what keeps both sides in
	step without sending positions. At the last waypoint the enemy stops and waits there
	for the server to remove it.
]]
function Enemy:_walk(deltaTime: number): ()
	-- Total studs this enemy is allowed to cover this frame.
	local distanceLeft = self._speed * deltaTime

	-- A loop, not an if: on a laggy frame one step can pass several corners, and each
	-- corner reached spends part of the budget before moving on to the next waypoint.
	while distanceLeft > 0 do
		local waypoint = waypoints[self._nextWaypoint]
		-- Past the last waypoint: stand still (zero velocity so towers stop leading the shot).
		if not waypoint then
			self._velocity = Vector3.zero
			return
		end

		local toWaypoint = waypoint - self._position
		local distance = toWaypoint.Magnitude
		-- Guarded because .Unit of a zero vector is NaN (standing exactly on the waypoint).
		if distance > 0 then
			self._velocity = toWaypoint.Unit * self._speed
			self._facing = getFlatDirection(toWaypoint, self._facing)
		end

		-- Waypoint is further than this frame's budget: step part of the way and stop.
		if distance > distanceLeft then
			self._position += toWaypoint.Unit * distanceLeft
			return
		end

		-- Waypoint is within reach: snap onto it, aim at the next one, and carry the
		-- leftover distance into the next loop so no movement is lost at the corner.
		self._position = waypoint
		self._nextWaypoint += 1
		distanceLeft -= distance
	end
end

--[[
	Returns this frame's CFrame instead of applying it, so the frame loop can move every
	enemy in one BulkMoveTo call, which is far cheaper than setting CFrame on each root.
]]
function Enemy:update(deltaTime: number): CFrame
	self:_walk(deltaTime)

	-- The side offset follows the model's CURRENT facing, not the path's. Using the path's
	-- would snap the enemy sideways at a corner while it is still mid-turn.
	local currentCFrame = self.rootPart.CFrame
	local lookVector = currentCFrame.LookVector
	-- Finds the left/right direction of the model, swapping X and Z and negating one turns
	-- the look vector 90° around the Y axis.
	local sideways = Vector3.new(-lookVector.Z, 0, lookVector.X)
	-- Push the enemy off the path's centre line by its own side offset.
	-- _position is on the road, so heightOffset lifts the root up to standing height.
	local newPosition = self._position + self._heightOffset + sideways * self._sideOffset

	local keptRotation = CFrame.new(newPosition) * currentCFrame.Rotation
	local targetCFrame = CFrame.lookAt(newPosition, newPosition + self._facing)
	-- Both CFrames share the same position, so the lerp only blends
	-- rotation and the model turns gradually.
	return keptRotation:Lerp(targetCFrame, getTurnAlpha(deltaTime))
end

-- Where a bullet fired now should aim, so it meets the enemy instead of landing behind it.
function Enemy:predictPosition(flightTime: number): Vector3
	return self.rootPart.Position + self._velocity * flightTime
end

function Enemy:destroy(): ()
	-- The walk animation track belongs to the model, so it is cleaned up with it.
	self._model:Destroy()
end

local function onEnemyAdded(serverFolder: Instance): ()
	enemiesByFolder[serverFolder] = Enemy.new(serverFolder :: Folder)
end

local function onEnemyRemoved(serverFolder: Instance): ()
	local enemy = enemiesByFolder[serverFolder]
	if not enemy then
		return
	end
	enemy:destroy()
	enemiesByFolder[serverFolder] = nil
end

-- Towers fire constantly, so bullets are recycled instead of being cloned and destroyed.
local function takeBullet(): BasePart
	local bullet = table.remove(bulletPool)
	if bullet then
		return bullet
	end

	bullet = bulletTemplate:Clone()
	-- Hidden until both ends have been moved onto the barrel.
	bullet.Beam.Enabled = false
	bullet.Parent = effectsFolder
	return bullet
end

local function returnBullet(bullet: BasePart): ()
	bullet.Beam.Enabled = false
	table.insert(bulletPool, bullet)
end

--[[
	The Beam stretches between two attachments, so a bullet is both ends travelling: the
	head leaves straight away and the tail chases it after a short delay. That delay is
	what gives the tracer its length, at any bullet speed.
]]
local function fireBullet(origin: Vector3, target: Vector3, speed: number): ()
	local flightTime = (target - origin).Magnitude / speed
	local bullet = takeBullet()
	local head = bullet.Point2
	local tail = bullet.Point1

	bullet.Position = origin
	head.WorldPosition = origin
	tail.WorldPosition = origin
	bullet.Beam.Enabled = true
	-- Delay = trail length / speed. Capped at flightTime so on short shots the tail
	-- doesn't sit at the barrel after the head has already landed.
	local tailDelay = math.min(BULLET_TRAIL_LENGTH / speed, flightTime)
	local headInfo = TweenInfo.new(flightTime, Enum.EasingStyle.Linear)
	local tailInfo = TweenInfo.new(
		flightTime,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.Out,
		0,
		false,
		tailDelay
	)
	local headTween = TweenService:Create(head, headInfo, { WorldPosition = target })
	local tailTween = TweenService:Create(tail, tailInfo, { WorldPosition = target })

	-- The tail lands last, so its Completed is the moment the bullet is free to reuse.
	tailTween.Completed:Once(function()
		returnBullet(bullet)
	end)
	headTween:Play()
	tailTween:Play()
end

--[[
	Each tower's folder holds a folder named after its gun. It's found by class rather
	than by name, so every tower can share this constructor.
]]
function Tower.new(towerFolder: Instance): TowerObject
	local model = towerFolder:WaitForChild("Model")
	local gunFolder = towerFolder:FindFirstChildOfClass("Folder")
	local animator = model.AnimationController.Animator

	-- The rig's joints already reach the gun, but an Animator only drives joints inside
	-- its own model. Without this the gun would stay frozen while the arms moved.
	gunFolder.HandleMiddle.Parent = model

	-- The Sniper's idle was exported at Action priority, the same as its shot, and two
	-- tracks at one priority blend into a half-strength shot. The idle must always lose.
	local idleTrack = playLoopedAnimation(animator, gunFolder.Idle)
	idleTrack.Priority = Enum.AnimationPriority.Idle

	local self = {
		_rootPart = model.PrimaryPart,
		_stats = TowerData[towerFolder.Name],
		_targetValue = model:WaitForChild("Target"),
		_barrel = gunFolder.Barrel.Value,
		_shootTrack = animator:LoadAnimation(gunFolder.Shoot),
		_cooldown = 0,
	}
	return setmetatable(self, Tower)
end

--[[
	Stretches the shot over the attack interval, so a fast and a slow gun can share one
	rule. Length is 0 until the asset has loaded, and dividing by it would break the speed.
]]
function Tower:_playShootAnimation(): ()
	local track = self._shootTrack
	track:Stop()
	track:Play(0)
	if track.Length > 0 then
		track:AdjustSpeed(track.Length / self._stats.attackInterval)
	end
end

function Tower:_fire(enemy: EnemyObject): ()
	local stats = self._stats
	local origin = self._barrel.Position
	-- Dividing by the speed gives the time it takes the bullet to reach the target.
	local flightTime = (enemy.rootPart.Position - origin).Magnitude / stats.bulletSpeed

	self._cooldown = stats.attackInterval
	self:_playShootAnimation()
	-- Aims at the predicted position so the bullet lands on the enemy's model when the tween ends
	fireBullet(origin, enemy:predictPosition(flightTime), stats.bulletSpeed)
end

--[[
	The root is anchored and everything else hangs off it by joints, so turning this one
	part turns the whole tower, gun included.
]]
function Tower:_turnTowards(targetPosition: Vector3, deltaTime: number): ()
	local currentCFrame = self._rootPart.CFrame
	local basePosition = currentCFrame.Position
	local direction = getFlatDirection(targetPosition - basePosition, currentCFrame.LookVector)
	local goalCFrame = CFrame.lookAt(basePosition, basePosition + direction)
	self._rootPart.CFrame = currentCFrame:Lerp(goalCFrame, getTurnAlpha(deltaTime))
end

--[[
	The target can be a destroyed enemy for a moment, since the server only retargets once
	per shot. That enemy is simply missing from the lookup, which is the only check needed.
]]
function Tower:update(deltaTime: number): ()
	self._cooldown -= deltaTime

	local enemy = enemiesByFolder[self._targetValue.Value]
	if not enemy then
		return
	end

	self:_turnTowards(enemy.rootPart.Position, deltaTime)
	if self._cooldown <= 0 then
		self:_fire(enemy)
	end
end

local function onRenderStepped(deltaTime: number): ()
	-- table.clear keeps the arrays' allocated size, so once a big wave has filled them
	-- this loop allocates nothing. New {} each frame would be two tables of GC per frame.
	table.clear(movedParts)
	table.clear(movedCFrames)
	-- BulkMoveTo pairs movedParts[i] with movedCFrames[i], so both are pushed in the
	-- same iteration. If one ever skipped, every later enemy would get the wrong CFrame.
	for _, enemy in pairs(enemiesByFolder) do
		table.insert(movedParts, enemy.rootPart)
		table.insert(movedCFrames, enemy:update(deltaTime))
	end
	-- One engine call for the whole wave instead of a CFrame write per root, where each
	-- write crosses into the engine and fires its own property change events.
	-- FireCFrameChanged only fires CFrame's change signal, skipping Position/Orientation.
	Workspace:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)

	-- Towers update after enemies, so they aim at this frame's positions, not last frame's.
	for _, tower in ipairs(towers) do
		tower:update(deltaTime)
	end
end

buildWaypoints()

for _, towerFolder in ipairs(towersFolder:GetChildren()) do
	table.insert(towers, Tower.new(towerFolder))
end

-- Anything that spawned while this client was loading never fired ChildAdded.
for _, serverFolder in ipairs(enemiesFolder:GetChildren()) do
	onEnemyAdded(serverFolder)
end
enemiesFolder.ChildAdded:Connect(onEnemyAdded)
enemiesFolder.ChildRemoved:Connect(onEnemyRemoved)

--[[
	RenderStepped, not Heartbeat/Stepped: it runs right before the frame is drawn, so moves
	show up this frame. Heartbeat runs after, so they'd appear a frame late. Nothing here
	needs Stepped's pre-physics timing; it's all client-only visuals.
	It blocks the frame until it returns, so keep the work light.
]]
RunService.RenderStepped:Connect(onRenderStepped)
