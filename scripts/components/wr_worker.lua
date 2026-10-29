-- Jobs are reserved while walking and validated again at the animation frame.
-- All ownership changes happen on the server, one item at a time.
local reservations = setmetatable({}, {__mode="k"})
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
    self.nextscan = 0
end)

function Worker:SetHome(pt)
    self:Cancel()
    self.home = {x=pt.x, z=pt.z}
    self.nextscan = 0
    self:Sync()
end
function Worker:OnSave()
    local refs={}
    local data={home=self.home,config=self.config,label=self.label,group=self.group}
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
    self.nextscan=0
    self:Sync()
    return true
end
function Worker:Sync(message)
    if message then self.notice=message end
    if self.inst._wr_state then
        self.inst._wr_state:set(require("json").encode({config=self.config,home=self.home,
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
    return (x-self.home.x)^2+(z-self.home.z)^2 <= self.config.radius^2
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
    if self.timeout then self.timeout:Cancel(); self.timeout=nil end
end
function Worker:MakeAction(kind, target, item)
    self:Cancel()
    local job={kind=kind,target=target,item=item}
    self.job=job
    self:Sync()
    reservations[target]={worker=self,untiltime=GetTime()+22}
    local act=BufferedAction(self.inst,target,ACTIONS.WR_WORK,nil,nil,nil,kind=="fish" and 3 or kind=="attack" and 1 or 1.5)
    act.wr_job=job
    act:AddSuccessAction(function() if self.job==job then self:Cancel() end end)
    act:AddFailAction(function()
        self.blocked[target]=GetTime()+20
        if self.job==job then self:Cancel() end
    end)
    self.timeout=self.inst:DoTaskInTime(20,function()
        if self.job==job then
            self.blocked[target]=GetTime()+30
            self.inst.components.locomotor:Stop()
            self.inst:ClearBufferedAction()
            self:Cancel()
        end
    end)
    return act
end
function Worker:Entities()
    local es=TheSim:FindEntities(self.home.x,0,self.home.z,self.config.radius,nil,{"INLIMBO","FX","DECOR"})
    table.sort(es,function(a,b)
        local da=self.inst:GetDistanceSqToInst(a)
        local db=self.inst:GetDistanceSqToInst(b)
        return da==db and a.GUID<b.GUID or da<db
    end)
    return es
end
function Worker:NextAction()
    if not self:CanWork() or GetTime()<self.nextscan then return end
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
    if self.inst:GetDistanceSqToPoint(self.home.x,0,self.home.z)>4 then
        return BufferedAction(self.inst,nil,ACTIONS.WALKTO,nil,Vector3(self.home.x,0,self.home.z))
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
