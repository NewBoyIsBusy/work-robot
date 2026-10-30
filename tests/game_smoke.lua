local spawned,count={},0
local base
for _,node in ipairs(TheWorld.topology.nodes)do
 if node.type~=NODE_TYPE.SeparatedRoom and TheWorld.Map:IsPassableAtPoint(node.x,0,node.y)
  and not TheWorld.Map:IsOceanAtPoint(node.x,0,node.y)then base=Vector3(node.x,0,node.y)break end
end
assert(base,"No land found")
for _,e in ipairs(TheSim:FindEntities(base.x,0,base.z,18))do if e~=TheWorld and e:IsValid()then e:Remove()end end
local function spawn(name,x,z)
 local e=assert(SpawnPrefab(name),name)e.Transform:SetPosition(base.x+(x or 0),0,base.z+(z or 0))spawned[#spawned+1]=e return e
end
local function stack(name,n)local e=spawn(name)if e.components.stackable then e.components.stackable:SetStackSize(n)end return e end
local function setup()
 local r=spawn("work_robot")r:StopBrain()r.components.wr_worker:SetHome(base)return r,r.components.wr_worker
end
local function assign(w,e)local ok,msg=w:ToggleTarget(e)assert(ok,msg)return e end
local function nextjob(w,kind)
 w.nextscan=0 local a=w:NextAction()assert(a and a.wr_job,"Expected "..kind..", no job")
 assert(a.wr_job.kind==kind,"Expected "..kind..", got "..a.wr_job.kind)return a
end
local function perform(w,a)
 if a.target then local p=a.target:GetPosition()w.inst.Transform:SetPosition(p.x+.8,0,p.z)end
 assert(a:Do(),"Job failed: "..a.wr_job.kind)
end
local function test(name,fn)
 fn()count=count+1 print("WR_GAME_PASS "..name)
 for _,e in ipairs(spawned)do if e:IsValid()then e:Remove()end end spawned={}
end

test("recipe requires the original W.O.B.O.T.",function()
 local recipe=assert(AllRecipes.work_robot)assert(recipe.ingredients[1].type=="storage_robot"and recipe.ingredients[1].amount==1)
end)
test("unassigned objects are ignored",function()
 local r,w=setup()spawn("treasurechest",1)spawn("log",2)w.nextscan=0 assert(w:NextAction()==nil)
end)
test("selected loose item is collected into selected box",function()
 local r,w=setup()local box=assign(w,spawn("treasurechest",2))local log=assign(w,spawn("log",1))
 perform(w,nextjob(w,"pickup"))assert(r.components.inventory:IsHolding(log))perform(w,nextjob(w,"store"))
 assert(box.components.container:FindItem(function(e)return e.prefab=="log"end))
end)
test("whole stacks are stored in one fast job",function()
 local r,w=setup()local box=assign(w,spawn("treasurechest",1))local logs=stack("log",12)r.components.inventory:GiveItem(logs)
 perform(w,nextjob(w,"store"))local saved=box.components.container:FindItem(function(e)return e.prefab=="log"end)
 assert(saved and saved.components.stackable:StackSize()==12 and r.components.inventory:NumItems()==0)
end)
test("perishables prefer a preserving container",function()
 local r,w=setup()local chest=assign(w,spawn("treasurechest",1))local fridge=assign(w,spawn("icebox",2))
 local berries=stack("berries",5)r.components.inventory:GiveItem(berries)local act=nextjob(w,"store")assert(act.target==fridge)
 perform(w,act)assert(fridge.components.container:FindItem(function(e)return e.prefab=="berries"end))
 assert(not chest.components.container:FindItem(function(e)return e.prefab=="berries"end))
end)
test("selected farm soil takes seed from a selected box",function()
 local r,w=setup()local box=assign(w,spawn("treasurechest",1))box.components.container:GiveItem(spawn("carrot_seeds"))
 local soil=assign(w,spawn("farm_soil",2))perform(w,nextjob(w,"seed_fetch"))perform(w,nextjob(w,"plant"))
 local plants=TheSim:FindEntities(base.x+2,0,base.z,1,{"farm_plant"})assert(#plants==1 and plants[1].prefab=="farm_plant_carrot")
end)
test("selected plants are tended and harvested",function()
 local r,w=setup()assign(w,spawn("treasurechest",1))local plant=assign(w,spawn("farm_plant_carrot",2))
 plant.components.growable:SetStage(2)plant.components.farmplanttendable.tendable=true perform(w,nextjob(w,"tend"))
 plant.components.growable:SetStage(5)perform(w,nextjob(w,"harvest"))
 assert(r.components.inventory:NumItems()>0)
end)
test("stone fruit bushes fetch fertilizer from target boxes",function()
 local r,w=setup()local box=assign(w,spawn("treasurechest",1))box.components.container:GiveItem(spawn("poop"))
 local bush=assign(w,spawn("rock_avocado_bush",2))bush.components.pickable:MakeBarren()
 assert(bush.components.pickable:CanBeFertilized())perform(w,nextjob(w,"fertilizer_fetch"))perform(w,nextjob(w,"fertilize"))
 assert(not bush.components.pickable:CanBeFertilized())
end)
test("trawler fish are collected and its lowered state is preserved",function()
 local r,w=setup()assign(w,spawn("treasurechest",1))local trawler=assign(w,spawn("ocean_trawler",2))
 local fish=spawn("oceanfish_small_1_inv")assert(trawler.components.container:GiveItem(fish))trawler.components.oceantrawler:Lower()
 perform(w,nextjob(w,"fish"))assert(r.components.inventory:IsHolding(fish)and trawler.components.oceantrawler:IsLowered())
end)
test("selected cookpot uses ingredients from selected boxes",function()
 local r,w=setup()local box=assign(w,spawn("treasurechest",1))box.components.container:GiveItem(stack("monstermeat",2))
 box.components.container:GiveItem(stack("berries",6))local pot=assign(w,spawn("cookpot",3))
 perform(w,nextjob(w,"cook_fetch"))perform(w,nextjob(w,"cook_start"))assert(pot.components.stewer:IsCooking())
 pot.components.stewer:LongUpdate(pot.components.stewer:GetTimeToCook()+.1)perform(w,nextjob(w,"cook_harvest"))
 assert(r.components.inventory:FindItem(function(e)return e.prefab=="meatballs"end))
end)
test("repair consumes rocks from player or target box and revives broken robot",function()
 local r,w=setup()r.components.health:DoDelta(-1000)assert(r:HasTag("broken")and not r:HasTag("notarget"))
 local player=spawn("wilson",1)player.components.inventory:GiveItem(stack("rocks",2))local ok=w:Repair(player)
 assert(ok and not r:HasTag("broken")and r.components.health.currenthealth>1)
 r.components.health:DoDelta(-1000)local box=assign(w,spawn("treasurechest",2))box.components.container:GiveItem(spawn("rocks"))
 assert(w:Repair(player))
end)
test("targets and guard point survive save records",function()
 local r,w=setup()local box=assign(w,spawn("treasurechest",1))local bush=assign(w,spawn("berrybush",2))
 assert(w:SetGuardPoint(base.x+3,base.z+1))local data=w:OnSave()local restored=spawn("work_robot")restored:StopBrain()
 local rw=restored.components.wr_worker rw:OnLoad(data)rw:LoadPostPass({[box.GUID]={entity=box},[bush.GUID]={entity=bush}},data)
 assert(rw.guardpoint and rw.guardpoint.x==base.x+3)
 assert(#rw.boxes==1 and rw.boxes[1]==box and #rw.targets==1 and rw.targets[1]==bush)
end)
test("selected hostile is attacked but players and bosses are rejected",function()
 local r,w=setup()local hound=assign(w,spawn("hound",1))hound:StopBrain()local hp=hound.components.health.currenthealth
 perform(w,nextjob(w,"attack"))assert(hound.components.health.currenthealth<hp)
 local player=spawn("wilson",1)assert(not w:WorkTarget(player))hound:AddTag("epic")assert(not w:IsEnemy(hound))
end)
print("WR_GAME_RESULT "..count.." synchronous cases passed")

-- A real brain must walk, recover from a temporary stall, pick the explicitly
-- selected item, and deposit the whole stack in the explicitly selected box.
local robot=spawn("work_robot")robot.entity:SetCanSleep(false)local worker=robot.components.wr_worker
worker:SetHome(base)local chest=assign(worker,spawn("treasurechest",4))local logs=assign(worker,stack("log",8))logs.Transform:SetPosition(base.x-4,0,base.z)
robot.components.locomotor:SetExternalSpeedMultiplier(robot,"navigation_test",0)local recovered=false
local monitor=robot:DoPeriodicTask(.25,function()local j=worker.job if j and j.navigation and j.navigation.attempts>0 then recovered=true end end)
robot:DoTaskInTime(4.5,function()robot.components.locomotor:RemoveExternalSpeedMultiplier(robot,"navigation_test")end)
TheWorld:DoTaskInTime(24,function()
 local ok,err=pcall(function()
  local saved=chest.components.container:FindItem(function(e)return e.prefab=="log"end)
  assert(saved and saved.components.stackable:StackSize()==8,"brain did not finish explicit pickup and delivery")
  assert(recovered,"stationary robot did not try a safe detour")monitor:Cancel()
  print("WR_GAME_PASS autonomous explicit target walking and delivery")print("WR_GAME_SUCCESS")
 end)
 if not ok then print("WR_GAME_FAILURE "..tostring(err))end c_shutdown(false)
end)
