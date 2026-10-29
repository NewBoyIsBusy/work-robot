local spawned={}
local count=0
local base
for _,node in ipairs(TheWorld.topology.nodes) do
    if node.type~=NODE_TYPE.SeparatedRoom and TheWorld.Map:IsPassableAtPoint(node.x,0,node.y)
        and not TheWorld.Map:IsOceanAtPoint(node.x,0,node.y) then base=Vector3(node.x,0,node.y);break end
end
assert(base,"No land found")
local function cleararea()
    for _,e in ipairs(TheSim:FindEntities(base.x,0,base.z,18)) do
        if e~=TheWorld and e:IsValid() then e:Remove() end
    end
end
cleararea()
local function spawn(name,x,z)
    local e=assert(SpawnPrefab(name),name)
    e.Transform:SetPosition(base.x+(x or 0),0,base.z+(z or 0))
    spawned[#spawned+1]=e
    return e
end
local function setup()
    local r=spawn("work_robot")
    r:StopBrain()
    r.components.wr_worker:SetHome(base)
    return r,r.components.wr_worker
end
local function nextjob(w,kind)
    w.nextscan=0
    local act=w:NextAction()
    assert(act and act.wr_job,"Expected "..kind..", no job")
    assert(act.wr_job.kind==kind,"Expected "..kind..", got "..act.wr_job.kind)
    return act
end
local function perform(w,act)
    local p=act.target:GetPosition()
    w.inst.Transform:SetPosition(p.x+.8,0,p.z)
    assert(act:Do(),"Job failed: "..act.wr_job.kind)
end
local function test(name,fn)
    fn();count=count+1;print("WR_GAME_PASS "..name)
    for _,e in ipairs(spawned) do if e:IsValid() then e:Remove() end end
    spawned={}
    cleararea()
end
local function stack(name,n)
    local e=spawn(name)
    e.components.stackable:SetStackSize(n)
    return e
end

test("recipe requires the original W.O.B.O.T.",function()
    local recipe=assert(AllRecipes.work_robot)
    assert(recipe.ingredients[1].type=="storage_robot" and recipe.ingredients[1].amount==1)
    assert(recipe.atlas and recipe.image=="storage_robot.tex")
    local player=spawn("wilson")
    local original=spawn("storage_robot")
    player.components.inventory:GiveItem(original)
    player.components.inventory:GiveItem(stack("transistor",2))
    player.components.inventory:GiveItem(stack("boards",4))
    local built
    player:ListenForEvent("builditem",function(_,data) built=data.item end)
    assert(player.components.builder:DoBuild("work_robot"))
    assert(built and built.prefab=="work_robot" and not original:IsValid())
    spawned[#spawned+1]=built
end)
test("seed withdrawal and sowing consume exactly one",function()
    local r,w=setup()
    local c=spawn("treasurechest",1).components.container
    local seeds=stack("carrot_seeds",5);c:GiveItem(seeds)
    local soil=spawn("farm_soil",2)
    perform(w,nextjob(w,"seed"))
    assert(seeds.components.stackable:StackSize()==4)
    perform(w,nextjob(w,"plant"));assert(not soil:IsValid())
    local plants=TheSim:FindEntities(base.x+2,0,base.z,1,{"farm_plant"})
    assert(#plants==1 and plants[1].prefab=="farm_plant_carrot")
    spawned[#spawned+1]=plants[1]
end)
test("harvest and deposit keep the vanilla yield",function()
    local r,w=setup()
    local c=spawn("treasurechest",1).components.container
    local plant=spawn("farm_plant_carrot",2)
    plant.components.growable:SetStage(5)
    perform(w,nextjob(w,"harvest"));assert(not plant:IsValid())
    assert(r.components.inventory:FindItem(function(e)return e.prefab=="carrot" end))
    for i=1,6 do
        w.nextscan=0;local act=w:NextAction()
        if not act or not act.wr_job or act.wr_job.kind~="store" then break end
        perform(w,act)
    end
    assert(c:FindItem(function(e)return e.prefab=="carrot" end))
    for _,e in ipairs(TheSim:FindEntities(base.x+2,0,base.z,1,{"soil"})) do spawned[#spawned+1]=e end
end)
test("tending uses the native plant callback",function()
    local r,w=setup();local p=spawn("farm_plant_carrot",1)
    perform(w,nextjob(w,"tend"));assert(not p.components.farmplanttendable.tendable)
end)
test("collapsed farm soil is tilled and replanted in place",function()
    local r,w=setup()
    local tx,tz=TheWorld.Map:GetTileCoordsAtPoint(base.x+3,0,base.z)
    local oldtile=TheWorld.Map:GetTile(tx,tz)
    TheWorld.Map:SetTile(tx,tz,WORLD_TILES.FARMING_SOIL)
    local soil=spawn("farm_soil",3);soil:PushEvent("breaksoil")
    local seed=spawn("carrot_seeds");r.components.inventory:GiveItem(seed)
    perform(w,nextjob(w,"till"))
    perform(w,nextjob(w,"plant"))
    local plants=TheSim:FindEntities(base.x+3,0,base.z,1,{"farm_plant"})
    assert(#plants==1)
    TheWorld.Map:SetTile(tx,tz,oldtile)
end)
test("ground pickup and chest delivery conserve a stack",function()
    local r,w=setup();local c=spawn("treasurechest",1).components.container
    local logs=stack("log",3)
    perform(w,nextjob(w,"pickup"))
    assert(r.components.inventory:IsHolding(logs))
    for i=1,3 do perform(w,nextjob(w,"store")) end
    local stored=c:FindItem(function(e)return e.prefab=="log" end)
    assert(stored.components.stackable:StackSize()==3)
end)
test("full chest does not attract pickups",function()
    local r,w=setup();local c=spawn("treasurechest",1).components.container
    for i=1,c:GetNumSlots() do local e=stack("rocks",40);c:GiveItem(e,i) end
    local log=spawn("log",1)
    w.nextscan=0;assert(w:NextAction()==nil);assert(not log.components.inventoryitem:IsHeld())
end)
test("two robots cannot reserve the same item",function()
    local r,w=setup();local r2,w2=setup();spawn("treasurechest",1);spawn("log",2)
    nextjob(w,"pickup")
    w2.nextscan=0;assert(w2:NextAction()==nil)
    w:Cancel();nextjob(w2,"pickup")
end)
test("opened chest is not touched",function()
    local r,w=setup();local c=spawn("treasurechest",1).components.container
    local log=spawn("log");r.components.inventory:GiveItem(log)
    local old=c.IsOpen;c.IsOpen=function()return true end
    w.nextscan=0;assert(w:NextAction()==nil)
    c.IsOpen=old;perform(w,nextjob(w,"store"))
end)
test("destination rejection restores original inventory",function()
    local r,w=setup();local c=spawn("treasurechest",1).components.container
    local log=stack("log",3);r.components.inventory:GiveItem(log)
    local act=nextjob(w,"store");local old=c.GiveItem
    c.GiveItem=function()return false end
    assert(not act:Do());assert(log.components.stackable:StackSize()==3)
    assert(r.components.inventory:IsHolding(log));c.GiveItem=old
end)
test("trawler fish collected, bait kept, net lowered again",function()
    local r,w=setup();spawn("treasurechest",1)
    local trap=spawn("ocean_trawler",2)
    local c=trap.components.container
    local fish=spawn("oceanfish_small_1_inv");assert(c:GiveItem(fish))
    local bait=spawn("seeds");assert(c:GiveItem(bait))
    trap.components.oceantrawler:Lower()
    perform(w,nextjob(w,"fish"))
    assert(r.components.inventory:IsHolding(fish))
    assert(bait.components.inventoryitem.owner==trap and trap.components.oceantrawler:IsLowered())
end)
test("save records contain cargo and the fixed work origin",function()
    local r,w=setup();r.components.inventory:GiveItem(stack("log",3))
    local record=r:GetSaveRecord()
    assert(record.data.wr_worker.home.x==base.x)
    local restored=assert(SpawnSaveRecord(record));spawned[#spawned+1]=restored;restored:StopBrain()
    assert(restored.components.wr_worker.home.x==base.x)
    assert(restored.components.inventory:FindItem(function(e)return e.prefab=="log" end))
end)
test("chat command selects, pauses, binds a chest and changes radius",function()
    local r,w=setup();local player=spawn("wilson",1)
    local c=spawn("treasurechest",2)
    local commands=require("wr_commands")
    local responses={}
    local function send(s) responses[#responses+1]=s end
    commands.Handle(player,"选择",send,{})
    assert(player._wr_selected==r)
    commands.Handle(player,"暂停",send,{})
    assert(w.config.paused and not w:CanWork())
    commands.Handle(player,"半径 8",send,{})
    assert(w.config.radius==8)
    commands.Handle(player,"补给箱",send,{})
    assert(w.supply==c)
    commands.Handle(player,"只收菜，不播种",send,{})
    assert(w.config.harvest and not w.config.farm and not w.config.paused)
    assert(require("usercommands").GetCommandFromName("robot"))
end)
test("bound source and destination perform chest to chest hauling",function()
    local r,w=setup();w:ApplyPolicy(require("wr_policy").Preset("haul"))
    local input=spawn("treasurechest",1);local output=spawn("treasurechest",3)
    w.supply=input;w.output=output
    local logs=stack("log",3);input.components.container:GiveItem(logs)
    perform(w,nextjob(w,"haul_fetch"));perform(w,nextjob(w,"store"))
    assert(logs.components.stackable:StackSize()==2)
    assert(output.components.container:FindItem(function(e)return e.prefab=="log" end))
end)
test("cook fetches one meat and three berries, cooks and harvests meatballs",function()
    local r,w=setup();w:ApplyPolicy(require("wr_policy").Preset("cook"))
    local box=spawn("treasurechest",1).components.container
    local meat=stack("monstermeat",2);local berries=stack("berries",6)
    box:GiveItem(meat);box:GiveItem(berries)
    local pot=spawn("cookpot",3)
    perform(w,nextjob(w,"cook_fetch"))
    assert(meat.components.stackable:StackSize()==1 and berries.components.stackable:StackSize()==3)
    perform(w,nextjob(w,"cook_start"));assert(pot.components.stewer:IsCooking())
    assert(pot.components.stewer.product=="meatballs")
    pot.components.stewer:LongUpdate(pot.components.stewer:GetTimeToCook()+.1)
    perform(w,nextjob(w,"cook_harvest"))
    assert(r.components.inventory:FindItem(function(e)return e.prefab=="meatballs" end))
end)
test("guard damages hostile creatures and leaves neutral creatures and bosses",function()
    local r,w=setup();w:ApplyPolicy(require("wr_policy").Preset("guard"))
    local enemy=spawn("hound",1);enemy:StopBrain()
    local hp=enemy.components.health.currenthealth
    perform(w,nextjob(w,"attack"));assert(enemy.components.health.currenthealth<hp)
    enemy:AddTag("epic");assert(not w:IsEnemy(enemy))
    local pig=spawn("pigman",1);pig:StopBrain();assert(not w:IsEnemy(pig))
    local player=spawn("wilson",1);assert(not w:IsEnemy(player))
    enemy:RemoveTag("epic");enemy.Transform:SetPosition(base.x+30,0,base.z);assert(not w:IsEnemy(enemy))
end)
test("damaged robot breaks safely and can be repaired with rocks",function()
    local r,w=setup()
    r.components.health:DoDelta(-1000)
    assert(r:HasTag("broken") and not w:CanWork())
    local player=spawn("wilson",1);local rocks=spawn("rocks")
    assert(r.components.trader:AcceptGift(player,rocks))
    assert(not r:HasTag("broken") and r.components.health.currenthealth>1)
end)
test("named robots can be grouped and commanded without affecting another group",function()
    local r,w=setup();local r2,w2=setup();local r3,w3=setup()
    r2.Transform:SetPosition(base.x+2,0,base.z);r3.Transform:SetPosition(base.x+4,0,base.z)
    local p=spawn("wilson",1)
    local C=require("wr_commands")
    local function command(s) C.Handle(p,s,function()end,{}) end
    command("选择 "..r.GUID);command("命名 小农")
    command("加选 "..r2.GUID);command("编组 农田组")
    command("选择 "..r3.GUID);command("命名 小卫")
    command("站哨")
    command("选择组 农田组");command("暂停")
    assert(w.config.paused and w2.config.paused and not w3.config.paused)
    command("@农田组 种田")
    assert(w.config.farm and w2.config.farm and w3.config.guard and not w3.config.farm)
    local data=w:OnSave()
    assert(data.label=="小农" and data.group=="农田组")
end)
test("map zones assign multiple robots with API disabled and filter rectangle corners",function()
    local r,w=setup();local r2,w2=setup();local p=spawn("wilson",1)
    local zones=assert(TheWorld.components.wr_workzones)
    local previousbox=spawn("treasurechest",0,12);w.supply=previousbox
    local bounds={x1=base.x-8,z1=base.z-4,x2=base.x+8,z2=base.z+4}
    local ok,msg=zones:Apply(p,{op="save",bounds=bounds,mode="farm",robots={r.GUID,r2.GUID}})
    assert(ok,msg);assert(w.region and w2.region and w.region.id==w2.region.id and w.config.farm)
    assert(w.supply==nil,"reassignment must release the old out-of-area supply binding")
    local inside=spawn("log",7,3);local outside=spawn("log",0,5)
    assert(w:Inside(inside) and not w:Inside(outside))
    for _,e in ipairs(w:Entities()) do assert(e~=outside,"entity outside rectangle entered work search") end
    assert(zones:Apply(p,{op="pause",id=w.region.id}));assert(w.config.paused and w2.config.paused)
    assert(zones:Apply(p,{op="resume",id=w.region.id}));assert(not w.config.paused)
    local id=w.region.id
    assert(zones:Apply(p,{op="save",id=id,bounds=bounds,mode="guard",robots={r.GUID}}))
    assert(w.config.guard and not w.config.farm and not w2.region and w2.config.paused)
    assert(zones:Apply(p,{op="delete",id=id}));assert(not w.region and w.config.paused)
end)
test("invalid or stale map assignment never partially updates robots",function()
    local r,w=setup();local p=spawn("wilson",1);local zones=TheWorld.components.wr_workzones
    local old=w.config.farm
    local b={x1=base.x-8,z1=base.z-8,x2=base.x+8,z2=base.z+8}
    assert(not zones:Apply(p,{op="save",bounds=b,mode="guard",robots={r.GUID,999999999}}))
    assert(w.region==nil and w.config.farm==old)
    assert(not zones:Apply(p,{op="save",bounds=b,mode="guard",robots={r.GUID,r.GUID}}))
    b.x2=b.x1+161
    assert(not zones:Apply(p,{op="save",bounds=b,mode="guard",robots={r.GUID}}))
    assert(w.region==nil)
end)
test("map areas and robot assignment survive save records",function()
    local r,w=setup();local p=spawn("wilson",1);local zones=TheWorld.components.wr_workzones
    assert(zones:Apply(p,{op="save",bounds={x1=base.x-7,z1=base.z-7,x2=base.x+7,z2=base.z+7},mode="haul",robots={r.GUID},label="营地搬运"}))
    local id=w.region.id
    local record=r:GetSaveRecord()
    assert(record.data.wr_worker.region.id==id)
    local restored=assert(SpawnSaveRecord(record));spawned[#spawned+1]=restored;restored:StopBrain()
    assert(restored.components.wr_worker.region.id==id and restored.components.wr_worker.config.haul)
    local data=zones:OnSave();zones:OnLoad(data)
    assert(zones:Find(id).label=="营地搬运")
    assert(zones:Apply(p,{op="delete",id=id}))
end)
print("WR_GAME_RESULT "..count.." synchronous cases passed")

-- Keep this actor awake so a real server brain walks, animates, picks up, and stores.
local robot=spawn("work_robot")
robot.entity:SetCanSleep(false)
robot.components.wr_worker:SetHome(base)
-- A temporary native speed modifier deterministically reproduces a wedged
-- actor. It must recover through normal WALKTO/WR_WORK actions after release.
robot.components.locomotor:SetExternalSpeedMultiplier(robot,"navigation_test",0)
local recovered=false
local monitor=robot:DoPeriodicTask(.25,function()
    local job=robot.components.wr_worker.job
    if job and job.navigation and job.navigation.attempts>0 then recovered=true end
end)
robot:DoTaskInTime(4.5,function()
    robot.components.locomotor:RemoveExternalSpeedMultiplier(robot,"navigation_test")
end)
local chest=spawn("treasurechest",4)
local logs=spawn("log",-4)
local ai_robot,ai_worker=setup()
ai_robot.Transform:SetPosition(base.x,0,base.z+5)
local ai_robot2,ai_worker2=setup()
ai_robot2.Transform:SetPosition(base.x+2,0,base.z+5)
local ai_player=spawn("wilson",0,5)
require("wr_commands").Select(ai_player,{ai_robot,ai_robot2})
local ai_received=false
require("wr_commands").Handle(ai_player,"守着农田顺便收菜",function(s)
    if ai_worker.config.guard and ai_worker.config.harvest and ai_worker2.config.guard and ai_worker2.config.harvest then ai_received=true end
end,{enabled=true,allplayers=true,endpoint="http://127.0.0.1:8766/plan"})
TheWorld:DoTaskInTime(24,function()
    local ok,err=pcall(function()
        assert(chest.components.container:FindItem(function(e)return e.prefab=="log" end),"brain did not finish pickup and delivery")
        print("WR_GAME_PASS autonomous walking animation pickup delivery")
        assert(recovered,"stationary robot did not attempt a safe detour")
        monitor:Cancel()
        print("WR_GAME_PASS native movement stall detects detours and resumes original work")
        assert(ai_received,"native HTTP bridge callback did not apply policy")
        print("WR_GAME_PASS native HTTP loopback bridge with a deterministic fake model (no API charge)")
        print("WR_GAME_SUCCESS")
    end)
    if not ok then print("WR_GAME_FAILURE "..tostring(err)) end
    c_shutdown(false)
end)
