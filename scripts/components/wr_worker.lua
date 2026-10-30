-- Explicit-target worker. Containers are shared sources/destinations; every
-- plant, trap, cookpot, loose item or enemy must be assigned to this robot.
local reservations=setmetatable({},{__mode="k"})
local Navigation=require("wr_navigation")
local function Valid(e)return e~=nil and e:IsValid() and not e:IsInLimbo() end
local function Safe(e)return Valid(e) and not e:HasTag("burnt") and not(e.components.burnable and e.components.burnable:IsBurning())end
local function Count(e)return e.components.stackable and e.components.stackable:StackSize() or 1 end
local function Seed(e)return e.components.farmplantable~=nil end
local function Fertilizer(e)return e.components.fertilizer~=nil end
local function Index(t,e)for i,v in ipairs(t)do if v==e then return i end end end
local function Compact(t)local o={}for _,e in ipairs(t)do if Valid(e)then o[#o+1]=e end end return o end

local Worker=Class(function(self,inst)
 self.inst=inst self.boxes={} self.targets={} self.config={paused=false}
 self.blocked=setmetatable({},{__mode="k"}) self.failures=setmetatable({},{__mode="k"}) self.nextscan=0
end)
function Worker:InvalidateScan()self.nextscan=0 end
function Worker:SetHome(pt)self.home={x=pt.x,z=pt.z}self:InvalidateScan()self:Sync()end
function Worker:SetRegion(_)self.region=nil return false end
function Worker:ClearRegion()self.region=nil self:Sync("旧工作区域已停用，请直接右键选择目标。")end
function Worker:ContainerTarget(e)
 local c=e and e.components.container
 return Safe(e)and c and not e:HasTag("wr_robot")and e.prefab~="ocean_trawler"
  and not e:HasTag("irreplaceable")and c.canbeopened and not c.readonlycontainer and c.restrictedtag==nil
end
function Worker:WorkTarget(e)
 if not Safe(e)or e==self.inst or e:HasTag("player")then return false end
 return e.prefab=="ocean_trawler"or e.prefab=="farm_soil"or e.components.stewer
  or e.components.trap or e.components.pickable or e.components.farmplanttendable
  or(e.components.inventoryitem and not e.components.inventoryitem:IsHeld())
  or(e.components.combat and e.components.health and not e:HasTag("epic")and not e:HasTag("companion"))
end
function Worker:IsAssigned(e)return Index(self.boxes,e)~=nil or Index(self.targets,e)~=nil end
function Worker:ToggleTarget(e)
 self.boxes=Compact(self.boxes)self.targets=Compact(self.targets)
 local list,kind
 local special=e and(e.prefab=="ocean_trawler"or e.prefab=="farm_soil"or e.components.stewer
  or e.components.trap or e.components.pickable or e.components.farmplanttendable)
 if special and self:WorkTarget(e)then list,kind=self.targets,"工作目标"
 elseif self:ContainerTarget(e)then list,kind=self.boxes,"箱子"elseif self:WorkTarget(e)then list,kind=self.targets,"工作目标"
 else return false,"这个对象不能作为机器人目标。"end
 local i=Index(list,e)
 if i then table.remove(list,i)if self.job and self.job.target==e then self:Cancel()end self:InvalidateScan()self:Sync()
  return true,"已移除"..kind.."："..(e.name or e.prefab or "目标")end
 if #list>=48 then return false,kind.."最多选择 48 个。"end
 list[#list+1]=e self:InvalidateScan()self:Sync()
 return true,"已添加"..kind.."："..(e.name or e.prefab or "目标")
end
function Worker:SetGuardPoint(x,z)
 if type(x)~="number"or type(z)~="number"or not TheWorld.Map:IsPassableAtPoint(x,0,z)then return false end
 self.guardpoint={x=x,z=z}self:Cancel()self:InvalidateScan()self:Sync("已设置站哨点。")return true
end
function Worker:ClearGuardPoint()self.guardpoint=nil self:Cancel()self:Sync("已取消站哨。")end
function Worker:Repair(doer)
 local health=self.inst.components.health
 if not health or health:GetPercent()>=1 then return false,"机器人不需要维修。"end
 local paid=false
 if doer and doer.components.inventory and doer.components.inventory:Has("rocks",1,true)then
  doer.components.inventory:ConsumeByName("rocks",1)paid=true
 else
  local box,item=self:FindInBoxes(function(v)return v.prefab=="rocks"end)
  if box and item then
   local c=box.components.container local unit=c:RemoveItem(item,false)
   if unit then unit:Remove()paid=true end
  end
 end
 if not paid then return false,"玩家背包或目标箱里没有石头。"end
 health:SetInvincible(false)health:DoDelta(60)
 self.inst:RemoveTag("broken")self.inst:RemoveTag("notarget")self.inst.sg:GoToState("idle")self:Sync("维修完成。")
 return true,"维修完成，恢复 60 点耐久。"
end
function Worker:OnSave()
 local refs={}local data={home=self.home,guardpoint=self.guardpoint,config={paused=self.config.paused==true},boxes={},targets={}}
 for _,role in ipairs({"boxes","targets"})do for _,e in ipairs(self[role])do if Valid(e)then data[role][#data[role]+1]=e.GUID refs[#refs+1]=e.GUID end end end
 return data,refs
end
function Worker:OnLoad(data)
 if not data then return end self.home=data.home self.guardpoint=data.guardpoint
 self.config.paused=data.config and data.config.paused==true or false self._old_supply=data.supply self._old_output=data.output
end
function Worker:LoadPostPass(ents,data)
 local seen={}
 for _,role in ipairs({"boxes","targets"})do self[role]={}for _,guid in ipairs(data and data[role]or{})do
  local r=ents[guid]local e=r and r.entity if Valid(e)and not seen[e]then self[role][#self[role]+1]=e seen[e]=true end end end
 for _,guid in ipairs({self._old_supply,self._old_output})do local r=guid and ents[guid]local e=r and r.entity
  if Valid(e)and self:ContainerTarget(e)and not seen[e]then self.boxes[#self.boxes+1]=e seen[e]=true end end
 self._old_supply=nil self._old_output=nil self:Sync()
end
function Worker:ApplyPolicy(p)
 if type(p)~="table"then return false end if type(p.paused)=="boolean"then self.config.paused=p.paused end
 self:Cancel()self:InvalidateScan()self:Sync()return true
end
function Worker:PathState()
 local j=self.job if not j then return end local p={}
 if j.waypoint then p[#p+1]={j.waypoint.x,j.waypoint.z}end local x,z=self:JobDestination(j)
 if x and z then p[#p+1]={x,z}end return p
end
function Worker:Sync(message)
 if message~=nil then self.notice=message end
 if self.inst._wr_state then self.inst._wr_state:set(require("json").encode({j=self.job and self.job.kind or"idle",p=self:PathState(),
  b=#Compact(self.boxes),t=#Compact(self.targets),g=self.guardpoint and 1 or 0,n=self.notice or""}))end
end
function Worker:CanWork()
 return not self.config.paused and not self.inst:HasTag("broken")and not self.inst.components.inventoryitem:IsHeld()
  and not self.inst:IsInLimbo()and self.inst:GetCurrentPlatform()==nil
  and TheWorld.Map:IsPassableAtPoint(self.inst.Transform:GetWorldPosition())
end
function Worker:Available(e)
 local r=reservations[e]
 return Safe(e)and e:GetCurrentPlatform()==nil and(self.blocked[e]==nil or self.blocked[e]<=GetTime())
  and(r==nil or r.worker==self or not r.worker.inst:IsValid()or r.untiltime<GetTime())
end
function Worker:Chest(e)
 local c=e and e.components.container
 return self:ContainerTarget(e)and Index(self.boxes,e)~=nil and c:CanOpen()and not c:IsOpen()
end
function Worker:Targets()
 self.boxes=Compact(self.boxes)self.targets=Compact(self.targets)local out={}
 for _,e in ipairs(self.targets)do out[#out+1]=e end
 table.sort(out,function(a,b)local da,db=self.inst:GetDistanceSqToInst(a),self.inst:GetDistanceSqToInst(b)return da==db and a.GUID<b.GUID or da<db end)
 return out
end
local function PerishRate(c,item)
 if not item.components.perishable then return nil end local owner=c.inst local rate=1
 local p=owner.components.preserver
 if p then local ok,value=pcall(p.GetPerishRateMultiplier,p,item)if ok and type(value)=="number"then rate=value end
 elseif owner:HasTag("fridge")then rate=TUNING.PERISH_FRIDGE_MULT or .5
 elseif owner:HasTag("foodpreserver")then rate=TUNING.PERISH_FOOD_PRESERVER_MULT or .25 end
 return rate
end
function Worker:Destination(item)
 local best,bestrate,bestmerge,bestdistance self.boxes=Compact(self.boxes)
 for _,e in ipairs(self.boxes)do if self:Available(e)and self:Chest(e)then local c=e.components.container
  if c:CanAcceptCount(item)>0 then local rate=PerishRate(c,item)local merge=c:FindItem(function(v)return v.prefab==item.prefab end)and 1 or 0
   local distance=self.inst:GetDistanceSqToInst(e)
   if best==nil or(rate~=nil and rate<bestrate)or(rate==bestrate and(merge>bestmerge or(merge==bestmerge and distance<bestdistance)))then
    best,bestrate,bestmerge,bestdistance=e,rate,merge,distance
   end
  end end end return best
end
function Worker:FindInBoxes(test)
 self.boxes=Compact(self.boxes)for _,e in ipairs(self.boxes)do if self:Available(e)and self:Chest(e)then local c=e.components.container
  for slot=1,c:GetNumSlots()do local item=c:GetItemInSlot(slot)if item and test(item)then return e,item end end end end
end
function Worker:Cancel()
 if self.job and self.job.target and reservations[self.job.target]and reservations[self.job.target].worker==self then reservations[self.job.target]=nil end
 self.job=nil if self.watchdog then self.watchdog:Cancel()self.watchdog=nil end
 self.inst.components.locomotor:Stop()self.inst.components.locomotor:Clear()self.inst:ClearBufferedAction()
end
function Worker:FailJob(job,message,navigation)
 if self.job~=job then return end local delay=10
 if navigation and job.target then self.failures[job.target]=math.min(3,(self.failures[job.target]or 0)+1)delay=self.failures[job.target]*30 end
 if job.target then self.blocked[job.target]=GetTime()+delay end self:Cancel()self.nextscan=0 self:Sync(message or"目标暂时无法操作，已跳过。")
end
function Worker:JobDestination(job)
 if job.waypoint then return job.waypoint.x,job.waypoint.z end
 if job.target and job.target:IsValid()then local x,_,z=job.target.Transform:GetWorldPosition()return x,z end
 local p=job.position or self.guardpoint or self.home return p and p.x,p and p.z
end
function Worker:ActionForJob(job)
 local waypoint=job.waypoint local walk=waypoint or((job.kind=="return"or job.kind=="guard_return")and job.position or nil)
 local act=walk and BufferedAction(self.inst,nil,ACTIONS.WALKTO,nil,Vector3(walk.x,0,walk.z))
  or BufferedAction(self.inst,job.target,ACTIONS.WR_WORK,nil,nil,nil,job.kind=="fish"and 3 or job.kind=="attack"and 1 or 1.5)
 act.wr_job=job job.action=act job.waiting=false
 act:AddSuccessAction(function()
  if self.job~=job or job.action~=act then return end
  if waypoint then job.waypoint=nil job.action=nil job.waiting=true local x,_,z=self.inst.Transform:GetWorldPosition()
   local tx,tz=self:JobDestination(job)Navigation.ResetProgress(job.navigation,GetTime(),x,z,tx,tz)self:Sync()
  else if job.target then self.failures[job.target]=nil end self:Cancel()self:InvalidateScan()self:Sync("")end
 end)
 act:AddFailAction(function()if self.job==job and job.action==act then if waypoint then self:Recover(job)else self:FailJob(job)end end end)
 return act
end
function Worker:Recover(job)
 if self.job~=job then return end job.action=nil job.waypoint=nil self.inst.components.locomotor:Stop()
 self.inst.components.locomotor:Clear()self.inst:ClearBufferedAction()
 local tx,tz=self:JobDestination(job)local point=Navigation.Waypoint(self.inst,job.navigation,tx,tz)
 if not point then self:FailJob(job,"路线受阻，已跳过这个目标。",true)return end
 job.waypoint=point job.waiting=true local x,_,z=self.inst.Transform:GetWorldPosition()
 Navigation.ResetProgress(job.navigation,GetTime(),x,z,point.x,point.z)self:Sync("路线受阻，正在绕行。")
end
function Worker:MonitorJob(job)
 if self.job~=job then return end if not self:CanWork()or self.inst:IsAsleep()then self:Cancel()self:Sync()return end
 if job.target and not self:Available(job.target)then self:FailJob(job,"目标已失效，已跳过。")return end
 local now=GetTime()local x,_,z=self.inst.Transform:GetWorldPosition()local tx,tz=self:JobDestination(job)
 if not tx then self:FailJob(job)return end
 local state=Navigation.Progress(job.navigation,now,x,z,tx,tz,self.inst.sg and self.inst.sg:HasStateTag("busy"),job.kind=="attack"and not job.waypoint)
 if state=="expired"then self:FailJob(job,"任务路程耗时过长，已跳过。",true)
 elseif state=="stalled"then self:Recover(job)
 elseif job.target then reservations[job.target]={worker=self,untiltime=math.min(job.navigation.deadline,now+Navigation.LEASE_SECONDS)}end
end
function Worker:MakeAction(kind,target,item,position)
 self:Cancel()local job={kind=kind,target=target,item=item,position=position}self.job=job
 local x,_,z=self.inst.Transform:GetWorldPosition()local tx,tz=self:JobDestination(job)if not tx then self.job=nil return end
 job.navigation=Navigation.New(GetTime(),x,z,tx,tz,self.inst.components.locomotor.walkspeed,kind)
 if target then reservations[target]={worker=self,untiltime=GetTime()+Navigation.LEASE_SECONDS}end
 self.watchdog=self.inst:DoPeriodicTask(.5,function()self:MonitorJob(job)end)self:Sync()return self:ActionForJob(job)
end
local function NeedFertilizer(e)
 if e.components.pickable and e.components.pickable:CanBeFertilized()then return"plant"end
 local s=e.components.farmplantstress
 if s and s.stressors and s.stressors_testfns and s.stressors_testfns.nutrients
  and s.stressors_testfns.nutrients(e,s.stressors.nutrients,false)then return"ground"end
end
function Worker:IsEnemy(e)
 return Safe(e)and not e:HasTag("player")and not e:HasTag("companion")and not e:HasTag("epic")
  and e.components.combat and e.components.health and not e.components.health:IsDead()and self.inst.components.combat:CanTarget(e)
end
function Worker:GuardEnemy()
 if not self.guardpoint or self.inst.components.health:GetPercent()<=.2 then return end
 for _,e in ipairs(TheSim:FindEntities(self.guardpoint.x,0,self.guardpoint.z,8,nil,{"INLIMBO","player","companion","epic"}))do
  if self:IsEnemy(e)and(e:HasTag("hostile")or e.components.combat.target==self.inst
   or(e.components.combat.target and e.components.combat.target:HasTag("player")))then return e end end
end
function Worker:NextAction()
 if not self:CanWork()then return end if self.job then if self.job.waiting then return self:ActionForJob(self.job)end return end
 if GetTime()<self.nextscan then return end self.nextscan=GetTime()+.35
 local inv=self.inst.components.inventory local targets=self:Targets()local enemy=self:GuardEnemy()
 if enemy and self:Available(enemy)and not self.inst.components.combat:InCooldown()then return self:MakeAction("attack",enemy)end
 for _,e in ipairs(targets)do if self:IsEnemy(e)and self:Available(e)and not self.inst.components.combat:InCooldown()
  and self.inst.components.health:GetPercent()>.2 then return self:MakeAction("attack",e)end end
 local cook=require("wr_cooking").NextAction(self,targets)if cook then return cook end
 -- Use carried fertilizer/seeds before depositing cargo.
 for _,e in ipairs(targets)do if self:Available(e)then local need=NeedFertilizer(e)
  if need then local item=inv:FindItem(Fertilizer)
   if item then return self:MakeAction(need=="ground"and"fertilize_ground"or"fertilize",e,item)end
   local box,from=self:FindInBoxes(Fertilizer)if box then return self:MakeAction("fertilizer_fetch",box,from)end
  end end end
 for _,e in ipairs(targets)do if self:Available(e)and e.prefab=="farm_soil"and e:HasTag("soil")and e._plow==nil then
  local item=inv:FindItem(Seed)if item then return self:MakeAction(e:HasTag("NOBLOCK")and"till"or"plant",e,item)end
  local box,from=self:FindInBoxes(Seed)if box then return self:MakeAction("seed_fetch",box,from)end
 end end
 if not inv:IsFull()then for _,e in ipairs(targets)do if self:Available(e)then
  if e.components.pickable and e.components.pickable:CanBePicked()and not e:HasTag("farm_plant_killjoy")then return self:MakeAction("harvest",e)
  elseif e.prefab=="ocean_trawler"and e.components.oceantrawler and e.components.container and not e.components.container:IsOpen()then
   for slot=1,e.components.container:GetNumSlots()do local item=e.components.container:GetItemInSlot(slot)
    if item and item:HasTag("oceanfish")and self:Destination(item)then return self:MakeAction("fish",e,item)end end
  elseif e.components.trap and e.components.trap:HasLoot()then return self:MakeAction("trap",e)
  elseif e.components.inventoryitem and not e.components.inventoryitem:IsHeld()and not e:HasTag("heavy")and not e:HasTag("irreplaceable")
   and inv:CanAcceptCount(e)>=Count(e)and self:Destination(e)then return self:MakeAction("pickup",e)end
 end end end
 for _,e in ipairs(targets)do if self:Available(e)and e.components.farmplanttendable and e.components.farmplanttendable.tendable
  and not e:HasTag("weed")then return self:MakeAction("tend",e)end end
 for slot=1,inv.maxslots do local item=inv:GetItemInSlot(slot)if item then local dest=self:Destination(item)
  if dest then return self:MakeAction("store",dest,item)end end end
 local active=inv:GetActiveItem()if active then local dest=self:Destination(active)if dest then return self:MakeAction("store",dest,active)end end
 if self.guardpoint and self.inst:GetDistanceSqToPoint(self.guardpoint.x,0,self.guardpoint.z)>4 then
  return self:MakeAction("guard_return",nil,nil,self.guardpoint)end
end
local function MoveAmount(source,dest,item,whole)
 if not item or not item:IsValid()then return false end local accepted=dest:CanAcceptCount(item,whole and Count(item)or 1)
 if accepted<1 then return false end local unit
 if item.components.stackable and Count(item)>accepted then unit=item.components.stackable:Get(accepted)
 else unit=source:RemoveItem(item,whole==true)end
 if not unit then return false end local result=dest:GiveItem(unit,nil,nil,false)
 local success=result and(not unit:IsValid()or unit.components.inventoryitem.owner==dest.inst)
 if not success and unit:IsValid()then source:GiveItem(unit)end return success and true or false
end
function Worker:Perform(job)
 if not job or job~=self.job or not self:CanWork()then return false end
 local e,item,kind=job.target,job.item,job.kind
 if e and(not self:Available(e)or self.inst:GetDistanceSqToInst(e)>(kind=="fish"and 4 or 2.5)^2)then return false end
 local inv=self.inst.components.inventory
 if kind=="attack"then
  if self:IsEnemy(e)and not self.inst.components.combat:InCooldown()and self.inst.components.health:GetPercent()>.2 then
   self.inst.components.combat:StartAttack()self.inst.components.combat:DoAttack(e)return true end
 elseif kind=="cook_fetch"or kind=="cook_start"or kind=="cook_harvest"then return require("wr_cooking").Perform(self,job)
 elseif kind=="store"then return self:Chest(e)and item:IsValid()and inv:IsHolding(item)and MoveAmount(inv,e.components.container,item,true)
 elseif kind=="seed_fetch"or kind=="fertilizer_fetch"then local test=kind=="seed_fetch"and Seed or Fertilizer
  return self:Chest(e)and item:IsValid()and test(item)and item.components.inventoryitem.owner==e
   and MoveAmount(e.components.container,inv,item,false)
 elseif kind=="till"then return e:HasTag("soil")and e:HasTag("NOBLOCK")and self.inst.components.farmtiller:Till(e:GetPosition(),self.inst)
 elseif kind=="plant"then return e:HasTag("soil")and not e:HasTag("NOBLOCK")and item:IsValid()and inv:IsHolding(item)
  and ACTIONS.PLANTSOIL.fn(BufferedAction(self.inst,e,ACTIONS.PLANTSOIL,item))
 elseif kind=="harvest"then return not inv:IsFull()and e.components.pickable and e.components.pickable:CanBePicked()
  and e.components.pickable:Pick(self.inst)or false
 elseif kind=="tend"then return e.components.farmplanttendable and e.components.farmplanttendable.tendable
  and e.components.farmplanttendable:TendTo(self.inst)==true
 elseif kind=="fertilize"then return item:IsValid()and inv:IsHolding(item)and Fertilizer(item)
  and ACTIONS.FERTILIZE.fn(BufferedAction(self.inst,e,ACTIONS.FERTILIZE,item))
 elseif kind=="fertilize_ground"then return item:IsValid()and inv:IsHolding(item)and Fertilizer(item)and item.components.deployable
  and ACTIONS.DEPLOY.fn(BufferedAction(self.inst,nil,ACTIONS.DEPLOY,item,e:GetPosition()))
 elseif kind=="pickup"then
  if e.components.inventoryitem and not e.components.inventoryitem:IsHeld()and inv:CanAcceptCount(e)>=Count(e)then
   local success=ACTIONS.PICKUP.fn(BufferedAction(self.inst,e,ACTIONS.PICKUP))
   if success then local i=Index(self.targets,e)if i then table.remove(self.targets,i)end end return success end
 elseif kind=="trap"then return e.components.trap and e.components.trap:HasLoot()
  and ACTIONS.CHECKTRAP.fn(BufferedAction(self.inst,e,ACTIONS.CHECKTRAP))
 elseif kind=="fish"then
  local c,trawler=e.components.container,e.components.oceantrawler
  if not c or c:IsOpen()or c.readonlycontainer or not trawler or not item:IsValid()
   or item.components.inventoryitem.owner~=e or not item:HasTag("oceanfish")or inv:CanAcceptCount(item,1)<1 then return false end
  local lowered=trawler:IsLowered()if lowered then trawler:Raise()end local ok=MoveAmount(c,inv,item,false)
  if lowered and e:IsValid()then trawler:Lower()end return ok
 elseif kind=="return"or kind=="guard_return"then return true end
 return false
end
return Worker
