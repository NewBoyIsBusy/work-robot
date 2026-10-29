-- Jobs are reserved while walking and validated again at the animation frame.
-- All ownership changes happen on the server, one item at a time.
local reservations = setmetatable({}, {__mode="k"})
local Navigation = require("wr_navigation")
local Regions = require("wr_regions")
local function Valid(e) return e ~= nil and e:IsValid() and not e:IsInLimbo() end
local function Count(item) return item.components.stackable and item.components.stackable:StackSize() or 1 end
local function Seed(item) return item.components.farmplantable ~= nil end
local function Safe(e)
    return Valid(e) and not e:HasTag("burnt")
        and not (e.components.burnable and e.components.burnable:IsBurning())
end

local Worker = Class(function(self, inst)
    self.inst = inst
    self.config = {}
    for k,v in pairs(TUNING.WORK_ROBOT) do self.config[k]=v end
    self.config.cook = false
    self.config.guard = false
    self.config.paused = false
    self.config.recipe = "meatballs"
    self.blocked = setmetatable({}, {__mode="k"})
    self.failures = setmetatable({}, {__mode="k"})
    self.nextscan = 0
end)

function Worker:InvalidateScan()
    self.nextscan=0
    self.entitycache=nil
end
function Worker:SetHome(pt)
    self:Cancel()
    local previous=self.region
    self.region=nil
    self.home = {x=pt.x, z=pt.z}
    self.commandrevision=(self.commandrevision or 0)+1
    self:InvalidateScan()
    self.inst:PushEvent("wr_regionchanged",{old=previous})
    self:Sync()
end
function Worker:SetRegion(region)
    if type(region)~="table" then return false end
    local bounds=Regions.NormalizeBounds(region.bounds)
    if not bounds then return false end
    local p=self.inst:GetPosition()
    local home=Regions.FindHome(bounds,{x=p.x,z=p.z})
    if not home then return false end
    local copy=Regions.Copy(region)
    copy.bounds=bounds
    self:Cancel()
    local previous=self.region
    self.region=copy
    self.home=home
    self.commandrevision=(self.commandrevision or 0)+1
    self:InvalidateScan()
    self.inst:PushEvent("wr_regionchanged",{old=previous,region=self.region})
    self:Sync()
    return true
end
function Worker:ClearRegion()
    self:Cancel()
    local previous=self.region
    self.region=nil
    local p=self.inst:GetPosition()
    self.home=Navigation.IsWalkable(p.x,p.z) and {x=p.x,z=p.z} or nil
    self.config.paused=true
    self.commandrevision=(self.commandrevision or 0)+1
    self:InvalidateScan()
    self.inst:PushEvent("wr_regionchanged",{old=previous})
    self:Sync("工作区域已解除，机器人已暂停。")
end
function Worker:OnSave()
    local refs={}
    local data={home=self.home,config=self.config,label=self.label,group=self.group,region=self.region}
    for _,role in ipairs({"supply","output"}) do
        if self[role] and self[role]:IsValid() then data[role]=self[role].GUID;refs[#refs+1]=self[role].GUID end
    end
    return data,refs
end
function Worker:OnLoad(data)
    if data then
        self.home=data.home
        self.label=data.label;self.group=data.group
        if data.config then self:ApplyPolicy(data.config) end
        if data.region and Regions.NormalizeBounds(data.region.bounds) then
            -- Restoring the assigned rectangle must not silently erase it when
            -- its old standby point has since become obstructed.
            self.region=Regions.Copy(data.region)
            self.region.bounds=Regions.NormalizeBounds(data.region.bounds)
            self.home=Regions.FindHome(self.region.bounds,self.home)
            if not self.home then self.config.paused=true end
        end
    end
end
function Worker:LoadPostPass(ents,data)
    for _,role in ipairs({"supply","output"}) do
        if data and data[role] and ents[data[role]] then self[role]=ents[data[role]].entity end
    end
    self:Sync()
end
function Worker:ApplyPolicy(policy)
    local normalized=require("wr_policy").Validate(policy)
    if not normalized then return false end
    self:Cancel()
    self.inst.components.locomotor:Stop()
    self.inst:ClearBufferedAction()
    for k,v in pairs(normalized) do self.config[k]=v end
    self:InvalidateScan()
    self:Sync()
    return true
end
function Worker:Sync(message)
    if message then self.notice=message end
    if self.inst._wr_state then
        self.inst._wr_state:set(require("json").encode({config=self.config,home=self.home,region=self.region,
            supply=self.supply and self.supply:IsValid() and self.supply.GUID or nil,
            output=self.output and self.output:IsValid() and self.output.GUID or nil,
            notice=self.notice or "",job=self.job and self.job.kind or "idle"}))
    end
end
function Worker:CanWork()
    return self.home ~= nil and not self.config.paused and not self.inst:HasTag("broken")
        and not self.inst.components.inventoryitem:IsHeld()
        and not self.inst:IsInLimbo() and self.inst:GetCurrentPlatform() == nil
        and TheWorld.Map:IsPassableAtPoint(self.inst.Transform:GetWorldPosition())
end
function Worker:Inside(e)
    local x, _, z = e.Transform:GetWorldPosition()
    if self.region then return Regions.Inside(self.region.bounds,x,z) end
    return self.home~=nil and (x-self.home.x)^2+(z-self.home.z)^2 <= self.config.radius^2
end
function Worker:Available(e)
    local r = reservations[e]
    return Safe(e) and self:Inside(e) and e:GetCurrentPlatform() == nil
        and (self.blocked[e] == nil or self.blocked[e] <= GetTime())
        and (r == nil or r.worker == self or not r.worker.inst:IsValid() or r.untiltime < GetTime())
end
function Worker:Chest(e)
    local c = e.components.container
    return Safe(e) and e:GetCurrentPlatform() == nil and c ~= nil and c.type == "chest"
        and e:HasTag("structure") and not e:HasTag("irreplaceable")
        and c.canbeopened and not c.readonlycontainer and c.restrictedtag == nil
        and c:CanOpen() and not c:IsOpen()
end
function Worker:Destination(item, entities)
    -- Prefer matching stock, then allow an empty slot in another ordinary chest.
    for pass=1,2 do
        for _, e in ipairs(entities) do
            if (self.output==nil or e==self.output) and self:Available(e) and self:Chest(e) then
                local c=e.components.container
                if c:CanAcceptCount(item) >= Count(item)
                    and (pass == 2 or c:FindItem(function(v) return v.prefab == item.prefab end)) then
                    return e
                end
            end
        end
    end
end
function Worker:Cancel()
    if self.job and self.job.target and reservations[self.job.target]
        and reservations[self.job.target].worker == self then reservations[self.job.target]=nil end
    self.job = nil
    if self.watchdog then self.watchdog:Cancel(); self.watchdog=nil end
    self.inst.components.locomotor:Stop()
    self.inst.components.locomotor:Clear()
    self.inst:ClearBufferedAction()
end
function Worker:FailJob(job,message,navigation)
    if self.job~=job then return end
    local delay=20
    if navigation and job.target then
        self.failures[job.target]=math.min(3,(self.failures[job.target] or 0)+1)
        delay=self.failures[job.target]*60
    end
    if job.target then self.blocked[job.target]=GetTime()+delay
    else self.homeblocked=GetTime()+60 end
    self:Cancel()
    self.nextscan=0
    self:Sync(message or "目标暂时无法操作，已跳过并继续其他工作。")
end
function Worker:ActionForJob(job)
    local waypoint=job.waypoint
    local walk=waypoint or (job.kind=="return" and job.position or nil)
    local act=walk and BufferedAction(self.inst,nil,ACTIONS.WALKTO,nil,Vector3(walk.x,0,walk.z))
        or BufferedAction(self.inst,job.target,ACTIONS.WR_WORK,nil,nil,nil,
            job.kind=="fish" and 3 or job.kind=="attack" and 1 or 1.5)
    act.wr_job=job
    job.action=act
    job.waiting=false
    act:AddSuccessAction(function()
        if self.job~=job or job.action~=act then return end
        if waypoint then
            job.waypoint=nil;job.action=nil;job.waiting=true
            local x,_,z=self.inst.Transform:GetWorldPosition()
            local tx,tz=self:JobDestination(job)
            Navigation.ResetProgress(job.navigation,GetTime(),x,z,tx,tz)
            self:Sync("已绕过障碍，继续原任务。")
        else
            if job.target then self.failures[job.target]=nil end
            self:Cancel()
            self:InvalidateScan()
            self:Sync("")
        end
    end)
    act:AddFailAction(function()
        if self.job==job and job.action==act then
            if waypoint then self:Recover(job)
            else self:FailJob(job) end
        end
    end)
    return act
end
function Worker:JobDestination(job)
    if job.waypoint then return job.waypoint.x,job.waypoint.z end
    if job.target and job.target:IsValid() then
        local x,_,z=job.target.Transform:GetWorldPosition()
        return x,z
    end
    local p=job.position or self.home
    return p.x,p.z
end
function Worker:Recover(job)
    if self.job~=job then return end
    -- Suppress the obsolete work action's callback before Clear fails it.
    -- DoAction still receives that failure, then requests the detour next tick.
    job.action=nil
    job.waypoint=nil
    self.inst.components.locomotor:Stop()
    self.inst.components.locomotor:Clear()
    self.inst:ClearBufferedAction()
    local tx,tz=self:JobDestination(job)
    local point=Navigation.Waypoint(self.inst,job.navigation,tx,tz)
    if not point then
        self:FailJob(job,"路线受阻，无法安全绕行；已释放目标并暂时跳过，继续其他工作。",true)
        return
    end
    job.waypoint=point;job.waiting=true
    local x,_,z=self.inst.Transform:GetWorldPosition()
    Navigation.ResetProgress(job.navigation,GetTime(),x,z,point.x,point.z)
    self:Sync("路线受阻，正在尝试绕行（"..job.navigation.attempts.."/"..Navigation.MAX_RETRIES.."）。")
end
function Worker:MonitorJob(job)
    if self.job~=job then return end
    if not self:CanWork() or self.inst:IsAsleep() then
        self:Cancel();self:Sync();return
    end
    if job.target and (not self:Available(job.target)
        or (job.kind=="attack" and (not self.config.guard or not self:IsEnemy(job.target)
            or self.inst.components.health:GetPercent()<=.2))) then
        self:FailJob(job,"目标已离开工作区或无法继续操作，改做其他工作。")
        return
    end
    local now=GetTime()
    local x,_,z=self.inst.Transform:GetWorldPosition()
    local tx,tz=self:JobDestination(job)
    local state=Navigation.Progress(job.navigation,now,x,z,tx,tz,
        self.inst.sg and self.inst.sg:HasStateTag("busy"),job.kind=="attack" and not job.waypoint)
    if state=="expired" then
        self:FailJob(job,"任务路程耗时过长，已释放目标并暂时跳过，继续其他工作。",true)
    elseif state=="stalled" then
        self:Recover(job)
    elseif job.target then
        reservations[job.target]={worker=self,untiltime=math.min(job.navigation.deadline,now+Navigation.LEASE_SECONDS)}
    end
end
function Worker:MakeAction(kind, target, item)
    self:Cancel()
    local job={kind=kind,target=target,item=item,position=kind=="return" and self.home or nil}
    self.job=job
    local x,_,z=self.inst.Transform:GetWorldPosition()
    local tx,tz=self:JobDestination(job)
    job.navigation=Navigation.New(GetTime(),x,z,tx,tz,self.inst.components.locomotor.walkspeed,kind)
    if target then reservations[target]={worker=self,untiltime=GetTime()+Navigation.LEASE_SECONDS} end
    self.watchdog=self.inst:DoPeriodicTask(.5,function() self:MonitorJob(job) end)
    self:Sync()
    return self:ActionForJob(job)
end
function Worker:Entities()
    if not self.entitycache or GetTime()>=(self.entitycachetime or 0) then
        local center=self.region and Regions.Center(self.region.bounds) or self.home
        local radius=self.config.radius
        if self.region then
            local b=self.region.bounds
            radius=math.sqrt((b.x2-b.x1)^2+(b.z2-b.z1)^2)*.5+.01
        end
        self.entitycache=TheSim:FindEntities(center.x,0,center.z,radius,nil,{"INLIMBO","FX","DECOR"})
        self.entitycachetime=GetTime()+3
    end
    local es={}
    for _,e in ipairs(self.entitycache) do
        if Valid(e) and self:Inside(e) then es[#es+1]=e end
    end
    table.sort(es,function(a,b)
        local da=self.inst:GetDistanceSqToInst(a)
        local db=self.inst:GetDistanceSqToInst(b)
        return da==db and a.GUID<b.GUID or da<db
    end)
    return es
end
function Worker:NextAction()
    if not self:CanWork() then return end
    if self.job then
        if self.job.waiting then return self:ActionForJob(self.job) end
        return
    end
    if GetTime()<self.nextscan then return end
    self.nextscan=GetTime()+1
    local es=self:Entities()
    local inv=self.inst.components.inventory
    if self.config.guard and self.inst.components.health:GetPercent()>.2 then
        for _,e in ipairs(es) do
            if self:Available(e) and self:IsEnemy(e) and not self.inst.components.combat:InCooldown() then
                return self:MakeAction("attack",e)
            end
        end
    end
    if self.config.cook then
        local act=require("wr_cooking").NextAction(self,es)
        if act then return act end
    end
    if self.config.haul and self.supply and self.output and self.supply~=self.output
        and self:Available(self.supply) and self:Chest(self.supply) and not inv:IsFull() then
        local cargo=inv:GetFirstItemInAnySlot() or inv:GetActiveItem()
        if not cargo then
            for slot=1,self.supply.components.container:GetNumSlots() do
                local item=self.supply.components.container:GetItemInSlot(slot)
                if item and not item:HasTag("irreplaceable") and self:Destination(item,es) then
                    return self:MakeAction("haul_fetch",self.supply,item)
                end
            end
        end
    end
    local soil,seed
    if self.config.farm then
        for _,e in ipairs(es) do
            if self:Available(e) and e.prefab=="farm_soil" and e:HasTag("soil") and e._plow==nil then soil=e;break end
        end
        seed=inv:FindItem(Seed)
    end
    -- Deliver cargo before starting another job. Seeds are kept only for a real soil target.
    for slot=1,inv.maxslots do
        local item=inv:GetItemInSlot(slot)
        if item and not (item==seed and soil) then
            local dest=self:Destination(item,es)
            if dest then return self:MakeAction("store",dest,item) end
        end
    end
    local active=inv:GetActiveItem()
    if active then
        local dest=self:Destination(active,es)
        if dest then return self:MakeAction("store",dest,active) end
    end
    if soil and seed then
        return self:MakeAction(soil:HasTag("NOBLOCK") and "till" or "plant",soil,seed)
    end
    if soil and not inv:IsFull() then
        for _,e in ipairs(es) do
            if (self.supply==nil or e==self.supply) and self:Available(e) and self:Chest(e) then
                for slot=1,e.components.container:GetNumSlots() do
                    local item=e.components.container:GetItemInSlot(slot)
                    if item and Seed(item) then return self:MakeAction("seed",e,item) end
                end
            end
        end
    end
    if not inv:IsFull() then
        local free=0
        for slot=1,inv.maxslots do if inv:GetItemInSlot(slot)==nil then free=free+1 end end
        for _,e in ipairs(es) do
            if free>=3 and self:Available(e) and self.config.harvest and e:HasTag("farm_plant")
                and not e:HasTag("weed") and not e:HasTag("farm_plant_killjoy")
                and not e.is_oversized and e.components.pickable
                and e.components.pickable:CanBePicked() then
                return self:MakeAction("harvest",e)
            end
        end
        if self.config.fish then
            for _,e in ipairs(es) do
                if self:Available(e) and e.prefab=="ocean_trawler" and e.components.oceantrawler
                    and e.components.container and not e.components.container:IsOpen()
                    and not e.components.container.readonlycontainer then
                    for slot=1,e.components.container:GetNumSlots() do
                        local item=e.components.container:GetItemInSlot(slot)
                        if item and item:HasTag("oceanfish") and self:Destination(item,es) then
                            return self:MakeAction("fish",e,item)
                        end
                    end
                end
            end
        end
        if self.config.haul then
            for _,e in ipairs(es) do
                local ii=e.components.inventoryitem
                if self:Available(e) and ii and ii.canbepickedup and not ii:IsHeld()
                    and not e:HasTag("wr_robot") and not e:HasTag("irreplaceable")
                    and not e:HasTag("heavy") and not e:HasTag("trap")
                    and e.components.health==nil and not e:HasTag("outofreach")
                    and inv:CanAcceptCount(e)>=Count(e) and self:Destination(e,es) then
                    return self:MakeAction("pickup",e)
                end
            end
        end
    end
    if self.config.tend then
        for _,e in ipairs(es) do
            if self:Available(e) and e:HasTag("farm_plant") and not e:HasTag("weed")
                and e.components.farmplanttendable and e.components.farmplanttendable.tendable then
                return self:MakeAction("tend",e)
            end
        end
    end
    if (not self.region or not self:Inside(self.inst))
        and GetTime()>=(self.homeblocked or 0)
        and self.inst:GetDistanceSqToPoint(self.home.x,0,self.home.z)>4 then
        return self:MakeAction("return")
    end
end

local function MoveOne(source,dest,item)
    if not item or not item:IsValid() or dest:CanAcceptCount(item,1)<1 then return false end
    local unit=source:RemoveItem(item,false)
    if unit==nil then return false end
    local ok=dest:GiveItem(unit,nil,nil,false)
    local success=ok and (not unit:IsValid() or unit.components.inventoryitem.owner==dest.inst)
    if not success and unit:IsValid() then source:GiveItem(unit) end
    return success and true or false
end

function Worker:IsEnemy(e)
    if not Safe(e) or not self:Inside(e) or e:HasTag("player") or e:HasTag("companion")
        or e:HasTag("epic") or not e.components.combat or not e.components.health
        or e.components.health:IsDead() or (e.components.follower and e.components.follower.leader)
        or not TheWorld.Map:IsPassableAtPoint(e.Transform:GetWorldPosition()) then return false end
    local target=e.components.combat.target
    return self.inst.components.combat:CanTarget(e) and
        (target==self.inst or (target and target:HasTag("player")) or e:HasTag("hostile"))
end

function Worker:Perform(job)
    if job==nil or job~=self.job or not self:CanWork() then return false end
    local e,item,kind=job.target,job.item,job.kind
    if not self:Available(e) or self.inst:GetDistanceSqToInst(e)>(kind=="fish" and 4 or 2.5)^2 then return false end
    local inv=self.inst.components.inventory
    if kind=="attack" then
        if self.config.guard and self:IsEnemy(e) and not self.inst.components.combat:InCooldown()
            and self.inst.components.health:GetPercent()>.2 then
            self.inst.components.combat:StartAttack()
            self.inst.components.combat:DoAttack(e)
            return true
        end
        return false
    elseif kind=="cook_fetch" or kind=="cook_start" or kind=="cook_harvest" then
        return self.config.cook and require("wr_cooking").Perform(self,job)
    elseif kind=="store" then
        return self:Chest(e) and item:IsValid() and inv:IsHolding(item)
            and MoveOne(inv,e.components.container,item)
    elseif kind=="haul_fetch" then
        return self.config.haul and self.supply==e and self.output~=e and self:Chest(e)
            and item:IsValid() and item.components.inventoryitem.owner==e
            and MoveOne(e.components.container,inv,item)
    elseif kind=="seed" then
        return self:Chest(e) and item:IsValid() and Seed(item)
            and item.components.inventoryitem.owner==e and MoveOne(e.components.container,inv,item)
    elseif kind=="till" then
        return self.config.farm and e:HasTag("soil") and e:HasTag("NOBLOCK")
            and self.inst.components.farmtiller:Till(e:GetPosition(),self.inst)
    elseif kind=="plant" then
        return self.config.farm and e:HasTag("soil") and not e:HasTag("NOBLOCK")
            and item:IsValid() and inv:IsHolding(item)
            and ACTIONS.PLANTSOIL.fn(BufferedAction(self.inst,e,ACTIONS.PLANTSOIL,item))
    elseif kind=="harvest" then
        return self.config.harvest and not inv:IsFull() and e.components.pickable
            and not e:HasTag("farm_plant_killjoy") and e.components.pickable:Pick(self.inst) or false
    elseif kind=="tend" then
        if self.config.tend and e.components.farmplanttendable and e.components.farmplanttendable.tendable then
            return e.components.farmplanttendable:TendTo(self.inst) == true
        end
    elseif kind=="pickup" then
        if self.config.haul and not e.components.inventoryitem:IsHeld() and inv:CanAcceptCount(e)>=Count(e) then
            return ACTIONS.PICKUP.fn(BufferedAction(self.inst,e,ACTIONS.PICKUP))
        end
    elseif kind=="fish" then
        local c,trawler=e.components.container,e.components.oceantrawler
        if not self.config.fish or not c or c:IsOpen() or c.readonlycontainer or not trawler
            or not item:IsValid() or item.components.inventoryitem.owner~=e
            or not item:HasTag("oceanfish") or inv:CanAcceptCount(item,1)<1 then return false end
        local lowered=trawler:IsLowered()
        if lowered then trawler:Raise() end
        local ok=MoveOne(c,inv,item)
        -- Preserve the player's raised/lowered setting; bait stays inside.
        if lowered and e:IsValid() then trawler:Lower() end
        return ok
    end
    return false
end
return Worker
