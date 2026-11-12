-- ========== WindUI 加载 ==========
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

-- ========== 防重复运行 ==========
if getgenv().DEAutoDelivery then
    WindUI:Notify({
        Title = "自动配送",
        Content = "脚本已经在运行了，不要重复执行。",
        Duration = 4,
        Icon = "alert-triangle",
    })
    return
end
getgenv().DEAutoDelivery = true

-- ========== 原始脚本服务与模块 ==========
local Plrs = game:GetService('Players')
local RunService = game:GetService('RunService')
local CS = game:GetService('CollectionService')
local RS = game:GetService('ReplicatedStorage')
local VU = game:GetService('VirtualUser')

local plr = Plrs.LocalPlayer

local delivery = require(RS.Modules.Client.Jobs.Tasks.DeliveryJobTask)
local deliveryUtil = require(RS.Modules.Shared.Jobs.Delivery.DeliveryUtil)
local vehicles = require(RS.Modules.Client.Vehicles.VehicleController)
local vehicleUtil = require(RS.Modules.Shared.Vehicles.VehicleUtil)
local towablesUtil = require(RS.Modules.Shared.Towables.TowablesUtil)
local towables = require(RS.Modules.Client.Towables.TowablesController)
local towablesData = require(RS.Modules.Shared.DataManager.Data.TowablesData)
local vehicleData = require(RS.Modules.Shared.DataManager.Data.VehicleData)
local tpGuard = require(RS.Modules.Client.Exploit.VehicleTeleportDetectionController)

-- ========== 防挂机 ==========
if getconnections then
    pcall(function()
        for _, v in ipairs(getconnections(plr.Idled)) do
            v:Disable()
        end
    end)
end

plr.Idled:Connect(function()
    pcall(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.zero)
    end)
end)

-- ========== 原始函数（未改动逻辑） ==========
local function getLoc(pos, skipLast, towing)
    local loc, dist
    for _, v in ipairs(CS:GetTagged('DeliveryLocation')) do
        if v:IsA('BasePart') and v.Parent
            and (towing == nil or deliveryUtil.IsLocationAllowedForTrailer(v, towing)) then
            if not skipLast or not deliveryUtil.IsLastDeliveryLocation(plr, v) then
                local d = (v.Position - pos).Magnitude
                if not dist or d < dist then loc, dist = v, d end
            end
        end
    end
    return loc
end

local hover, hoverPart

local function clearHover()
    if hover then hover:Destroy() end
    hover, hoverPart = nil, nil
end

local carId, trailerId, checked, spawnAt, trailerAt

local function setupVehicle(hum, state)
    if not checked then
        local owned = vehicleData.GetOwnedVehicleIds(plr, true)
        local capacity = 0
        for id, v in pairs(towablesUtil.GetEnabledTowables()) do
            if v.ChassisType == 'Generic' and (v.CargoCapacity or 0) > capacity
                and towablesData.IsTowableUnlocked(plr, id) then
                for _, vehicleId in ipairs(owned) do
                    if towablesUtil.CanVehicleTowTowable(vehicleId, id, plr) then
                        carId, trailerId, capacity = vehicleId, id, v.CargoCapacity
                        break
                    end
                end
            end
        end
        checked = true
    end

    if not carId then
        if hum.SeatPart then
            clearHover()
            hum.Sit = false
            hum.Jump = true
            return false
        end
        return true
    end

    local model = vehicleUtil.GetPlayerSpawnedVehicle(plr)
    local carType = model and model:FindFirstChild('CarType')

    if not carType or carType.Value ~= carId then
        if state and ((state.ItemsCarried or 0) > 0 or state.IsDropping) then return false end
        if not spawnAt or tick() - spawnAt > 10 then
            clearHover()
            spawnAt, trailerAt = tick(), nil
            RS.Remotes.VehicleEvent:FireServer('Spawn', carId)
        end
        return false
    end

    local car = vehicleUtil.getPlayerData(plr)
    if not car or car.Model ~= model then
        clearHover()
        local seat = model:FindFirstChild('VehicleSeat')
        if seat and not seat.Occupant then seat:Sit(hum) end
        return false
    end

    local trailer = towablesUtil.GetAttachedTrailerFromVehicle(model)
    if not trailer or trailer:GetAttribute('TowableId') ~= trailerId then
        if state and ((state.ItemsCarried or 0) > 0 or state.IsDropping) then return false end
        if not trailerAt or tick() - trailerAt > 10 then
            clearHover()
            trailerAt = tick()
            local ok, err = towables.AttemptToSpawnTowable(trailerId)
            if not ok then warn('[自动配送] ' .. tostring(err)) end
        end
        return false
    end
    return true
end

local function tp(cf)
    local char = plr.Character
    if not char then return false end

    local car = vehicleUtil.getPlayerData(plr)
    local chassis = vehicles.getActiveChassisController()

    if car and car.Model and car.WeightPart then
        if not car.Model.Parent or not car.WeightPart.Parent then return false end
        local trailer = towablesUtil.GetAttachedTrailerFromVehicle(car.Model)
        local offset = trailer and car.WeightPart.CFrame:ToObjectSpace(trailer:GetPivot())
        local hum = char:FindFirstChildOfClass('Humanoid')
        if hum and hum.SeatPart then cf = cf * hum.SeatPart.CFrame:ToObjectSpace(car.WeightPart.CFrame) end
        if chassis then chassis.Teleporting = true end
        task.defer(function() if chassis then chassis.Teleporting = false end end)

        tpGuard.AuthorizeNextTeleport()
        car.Model.PrimaryPart = car.WeightPart
        car.Model:SetPrimaryPartCFrame(cf)
        if trailer and trailer.Parent then trailer:PivotTo(cf * offset) end
        car.WeightPart.Anchored = false
        clearHover()

        hover = Instance.new('BodyVelocity')
        hover.MaxForce = Vector3.new(1e9, 1e9, 1e9)
        hover.Velocity = Vector3.zero
        hover.Parent = car.WeightPart
        hoverPart = car.WeightPart

        for _, model in ipairs({car.Model, trailer}) do
            for _, v in ipairs(model:GetDescendants()) do
                if v:IsA('BasePart') then
                    v.AssemblyLinearVelocity = Vector3.zero
                    v.AssemblyAngularVelocity = Vector3.zero
                end
            end
        end
    else
        local hum = char:FindFirstChildOfClass('Humanoid')
        if hum and hum.SeatPart then return false end
        char:PivotTo(cf)

        local hrp = char:FindFirstChild('HumanoidRootPart')
        if hrp then
            clearHover()
            hover = Instance.new('BodyVelocity')
            hover.MaxForce = Vector3.new(1e9, 1e9, 1e9)
            hover.Velocity = Vector3.zero
            hover.Parent = hrp
            hoverPart = hrp
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end
    end
    return true
end

RunService.Heartbeat:Connect(function()
    local char = plr.Character
    local hrp = char and char:FindFirstChild('HumanoidRootPart')
    local hum = char and char:FindFirstChildOfClass('Humanoid')

    if hoverPart and (not hoverPart.Parent or not hrp or plr:GetAttribute('JobId') ~= 'Delivery'
        or (hoverPart ~= hrp and (not hum or not hum.SeatPart))) then
        clearHover()
    end
    if hrp then hrp.Anchored = false end
    if hum and hover and hover.Parent == hrp then
        hum:ChangeState(Enum.HumanoidStateType.Freefall)
    end
end)

local curTarget, curLoc, curPhase, lastTick, lastFire, progressAt, lastTp, lastChar, lastState, retryAt

RS.Remotes.DeliveryCompleted.OnClientEvent:Connect(function(result)
    if result and result.FailureReason then
        local msg = '[自动配送] 配送失败：' .. tostring(result.FailureReason)
            .. '，阶段=' .. tostring(curPhase)
            .. '，携带=' .. tostring(lastState and lastState.ItemsCarried)
            .. '，取货中=' .. tostring(lastState and lastState.IsCollecting)
            .. '，卸货中=' .. tostring(lastState and lastState.IsDropping)
        warn(msg)
        if _G.DE_Log then _G.DE_Log(msg) end
    end
end)

local function step()
    local char = plr.Character
    local hrp = char and char:FindFirstChild('HumanoidRootPart')
    local hum = char and char:FindFirstChildOfClass('Humanoid')

    if char ~= lastChar then
        clearHover()
        curTarget, curLoc, curPhase, lastTick, lastFire, progressAt, lastTp, lastState = nil, nil, nil, nil, nil, nil, nil, nil
        lastChar = char
        spawnAt, trailerAt, retryAt = nil, nil, nil
    end

    if hrp and hum and hum.Health > 0 then
        if retryAt and tick() < retryAt then return end
        retryAt = nil

        local state = delivery.GetCurrentDeliveryState()
        if not setupVehicle(hum, state) then return end

        if plr:GetAttribute('JobId') ~= 'Delivery' then
            RS.Remotes.RequestStartJobSession:FireServer('Delivery', 'deliveryHub', 'HighRisk')
            clearHover()
            curTarget, curLoc, curPhase, lastTick, lastFire, progressAt, lastTp, lastState = nil, nil, nil, nil, nil, nil, nil, nil
            task.wait(0.5)
        else
            local target, phase
            local remaining = state and state.ExpirationTime and state.ExpirationTime - workspace:GetServerTimeNow()
            local newRoute = state and (not lastState or state.PickupPosition ~= lastState.PickupPosition
                or state.DestinationPosition ~= lastState.DestinationPosition
                or state.DeliveryStartTime ~= lastState.DeliveryStartTime)

            if newRoute then curTarget, curLoc, curPhase, lastFire = nil, nil, nil, nil end

            if not progressAt or newRoute or (state == nil) ~= (lastState == nil)
                or (state and lastState and (state.ItemsCarried ~= lastState.ItemsCarried
                    or state.PackagesRemainingAtPickup ~= lastState.PackagesRemainingAtPickup
                    or state.IsPlanned ~= lastState.IsPlanned)) then
                progressAt = tick()
            end
            lastState = state

            if state then
                lastTick = nil
                local carried = state.ItemsCarried or 0
                local cap = state.MaxCapacity or carried
                local full = carried >= cap
                local noMore = state.PackagesRemainingAtPickup == 0

                if state.IsDropping or curPhase == 'drop'
                    or carried > 0 and (full or noMore or remaining and remaining <= 5) then
                    phase = 'drop'
                    target = state.DestinationPosition
                else
                    phase = 'pickup'
                    target = state.PickupPosition
                end
            else
                lastTick = lastTick or tick()
                if tick() - lastTick > 0.25 then
                    local car = vehicleUtil.getPlayerData(plr)
                    local towing = car and towablesUtil.GetAttachedTrailerFromVehicle(car.Model) ~= nil or false
                    local loc = getLoc(hrp.Position, true, towing)
                    phase = 'new'
                    target = loc and loc.Position
                end
            end

            if target then
                local pos = target + Vector3.new(0, math.min(3.5, deliveryUtil.GetPickupRadius() / 2), 0)
                local part = hum.SeatPart or hrp

                if target ~= curTarget or phase ~= curPhase
                    or ((part.Position - pos).Magnitude > deliveryUtil.GetPickupRadius() / 2 and tick() - (lastTp or 0) > 2) then
                    if curLoc then RS.Remotes.DeliveryLocationLeft:FireServer(curLoc) end
                    if not tp(CFrame.new(pos)) then return end
                    curTarget, curPhase, lastTp = target, phase, tick()
                    curLoc, lastFire = nil, nil
                end

                if tick() - (lastTp or 0) < 0.5 then return end

                local loc = getLoc(target)
                if loc and (loc.Position - target).Magnitude < 1
                    and (part.Position - loc.Position).Magnitude <= deliveryUtil.GetPickupRadius() then
                    if loc ~= curLoc then progressAt = tick() end
                    local timeout = math.max(10, deliveryUtil.GetItemCollectTime(plr) * 3)
                    if phase == 'drop' and remaining then timeout = math.min(timeout, math.max(2, remaining / 2)) end

                    if loc == curLoc and tick() - progressAt > timeout then
                        RS.Remotes.DeliveryLocationLeft:FireServer(loc)
                        if not tp(CFrame.new(target + Vector3.new(deliveryUtil.GetPickupRadius() + 8, 3.5, 0))) then return end
                        curTarget, curLoc, lastFire = nil, nil, nil
                        progressAt, retryAt = tick(), tick() + 0.5
                        return
                    end

                    local busy = state and (phase == 'drop' and state.IsDropping
                        or phase ~= 'drop' and state.IsCollecting)
                    if loc ~= curLoc or not busy and tick() - (lastFire or 0) > 2 then
                        RS.Remotes.DeliveryLocationInteracted:FireServer(loc)
                        curLoc, lastFire = loc, tick()
                    end
                end
            end
        end
    end
end

-- ========== WindUI 界面 ==========
local Window = WindUI:CreateWindow({
    Title = "自动配送",
    Icon = "truck",
    Author = "汉化版",
    Folder = "DEAutoDelivery",
    Size = UDim2.fromOffset(460, 380),
    Transparent = true,
    Theme = "Dark",
    Resizable = true,
})

local Tab = Window:Tab({
    Title = "配送控制",
    Icon = "truck",
})

-- 日志函数，挂到 _G 上让上面的 DeliveryCompleted 回调也能用
_G.DE_Log = function(msg)
    pcall(function()
        if Tab and Tab.Paragraph then
            Tab:Paragraph({
                Title = "日志",
                Desc = tostring(msg),
            })
        end
    end)
end

local running = false
local mainThread = nil

local Toggle = Tab:Toggle({
    Title = "自动配送",
    Desc = "打开后开始自动跑配送，关闭会停止并清理状态",
    Icon = "play",
    Type = "Checkbox",
    Value = false,
    Callback = function(state)
        running = state

        if state then
            -- 启动主循环
            if mainThread then
                task.cancel(mainThread)
                mainThread = nil
            end
            mainThread = task.spawn(function()
                while running do
                    task.wait(0.1)
                    local ok, err = pcall(step)
                    if not ok then
                        curTarget, curLoc, curPhase, lastTick, lastFire, progressAt, lastTp, lastState = nil, nil, nil, nil, nil, nil, nil, nil
                        clearHover()
                        warn('[自动配送] ' .. tostring(err))
                        if _G.DE_Log then _G.DE_Log("出错：" .. tostring(err)) end
                        task.wait(1)
                    end
                end
            end)

            WindUI:Notify({
                Title = "自动配送",
                Content = "已启动",
                Duration = 3,
                Icon = "check",
            })
        else
            -- 停止：清理悬浮稳定器 + 下车
            clearHover()

            local char = plr.Character
            local hum = char and char:FindFirstChildOfClass('Humanoid')
            if hum and hum.SeatPart then
                pcall(function()
                    hum.Sit = false
                    hum.Jump = true
                end)
            end

            WindUI:Notify({
                Title = "自动配送",
                Content = "已停止",
                Duration = 3,
                Icon = "x",
            })
        end
    end,
})

-- 状态信息（手动刷新按钮）
Tab:Button({
    Title = "刷新状态",
    Desc = "查看当前配送阶段、携带包裹数等",
    Icon = "refresh-cw",
    Callback = function()
        local state = delivery.GetCurrentDeliveryState()
        local lines = {}

        if state then
            local carried = state.ItemsCarried or 0
            local cap = state.MaxCapacity or carried
            table.insert(lines, "携带包裹：" .. carried .. " / " .. cap)

            if state.ExpirationTime then
                local remaining = math.max(0, state.ExpirationTime - workspace:GetServerTimeNow())
                table.insert(lines, "剩余时间：" .. string.format("%.0f", remaining) .. " 秒")
            end

            if state.IsCollecting then table.insert(lines, "状态：取货中") end
            if state.IsDropping then table.insert(lines, "状态：卸货中") end
            if not state.IsCollecting and not state.IsDropping then table.insert(lines, "状态：移动中") end
        else
            table.insert(lines, "当前没有进行中的配送任务")
        end

        Tab:Paragraph({
            Title = "当前状态",
            Desc = table.concat(lines, "\n"),
            Color = "Blue",
        })
    end,
})

-- 手动停止并下车
Tab:Button({
    Title = "停止并下车",
    Desc = "强制关闭配送并让你从车上下来",
    Icon = "log-out",
    Callback = function()
        running = false
        if Toggle and Toggle.Set then Toggle:Set(false) end
        clearHover()

        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass('Humanoid')
        if hum and hum.SeatPart then
            pcall(function()
                hum.Sit = false
                hum.Jump = true
            end)
        end

        WindUI:Notify({
            Title = "自动配送",
            Content = "已强制停止并下车",
            Duration = 3,
            Icon = "log-out",
        })
    end,
})
