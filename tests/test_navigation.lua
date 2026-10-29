-- Deterministic component tests: clocks/terrain/actions are controlled, while
-- the real worker owns retries, reservations, filtering, and cancellation.
local now=0
function GetTime() return now end
function Vector3(x,y,z) return {x=x,y=y,z=z} end
function Class(ctor)
    local c={};c.__index=c
    return setmetatable(c,{__call=function(_,...)local self=setmetatable({},c);ctor(self,...);return self end})
end
package.loaded.json={encode=function(v)return v end}
TUNING={WORK_ROBOT={radius=80,farm=false,harvest=false,tend=false,haul=false,fish=false}}
ACTIONS={WR_WORK={},WALKTO={}}
local clear=true
TheWorld={Map={
    IsPassableAtPoint=function()return true end,
    IsOceanAtPoint=function()return false end,
    IsGroundTargetBlocked=function()return false end,
},Pathfinder={IsClear=function()return clear end}}
function BufferedAction(inst,target,action,item,pos)
    local a={doer=inst,target=target,action=action,pos=pos,success={},failure={}}
    function a:AddSuccessAction(fn)self.success[#self.success+1]=fn end
    function a:AddFailAction(fn)self.failure[#self.failure+1]=fn end
    function a:Succeed()local callbacks=self.success;self.success={};self.failure={};for _,f in ipairs(callbacks)do f()end end
    function a:Fail()local callbacks=self.failure;self.success={};self.failure={};for _,f in ipairs(callbacks)do f()end end
    return a
end
local guid=0
local function entity(x,z)
    guid=guid+1
    local e={GUID=guid,x=x or 0,z=z or 0,components={},tags={}}
    e.Transform={GetWorldPosition=function()return e.x,0,e.z end}
    function e:GetPosition()return Vector3(self.x,0,self.z)end
    function e:IsValid()return not self.removed end
    function e:IsInLimbo()return false end
    function e:IsAsleep()return self.asleep end
    function e:HasTag(tag)return self.tags[tag]end
    function e:GetCurrentPlatform()end
    function e:GetPhysicsRadius()return .4 end
    function e:GetDistanceSqToInst(v)return (self.x-v.x)^2+(self.z-v.z)^2 end
    function e:GetDistanceSqToPoint(x,y,z)return (self.x-x)^2+(self.z-z)^2 end
    function e:PushEvent(name,data)self.event={name,data}end
    function e:ClearBufferedAction()
        local a=self.bufferedaction;self.bufferedaction=nil;if a then a:Fail()end
    end
    function e:DoPeriodicTask(period,fn)
        local task={period=period,fn=fn,Cancel=function(t)t.cancelled=true end}
        self.task=task;return task
    end
    e._wr_state={set=function(_,state)e.state=state end}
    e.components.inventoryitem={IsHeld=function()return e.held end}
    e.components.locomotor={walkspeed=4,pathcaps={},Stop=function(l)l.stopped=true end,
        Clear=function(l)local a=l.bufferedaction;l.bufferedaction=nil;if a then a:Fail()end end}
    e.sg={HasStateTag=function(_,tag)return tag=="busy" and e.busy end}
    return e
end
local Worker=require("components/wr_worker")
local Navigation=require("wr_navigation")
local function setup(x,z)
    local e=entity(x,z)
    local w=Worker(e);e.components.wr_worker=w;w.home={x=0,z=0}
    return w,e
end
local function bind(w,a)w.inst.components.locomotor.bufferedaction=a end
local checks=0
local function test(name,fn)
    now=0;clear=true;fn();checks=checks+1;print("WR_NAV_PASS "..name)
end

test("rectangle filters circumscribed corners and moving cached entities",function()
    local w,e=setup()
    assert(w:SetRegion({id=1,label="farm",mode="farm",bounds={x1=-20,z1=-5,x2=20,z2=5}}))
    local inside=entity(12,3);local outside=entity(0,12);local removed=entity(3,1);removed.removed=true
    local calls=0
    TheSim={FindEntities=function(_,x,y,z,r)
        calls=calls+1;assert(r>20 and r<21);return {outside,inside,removed}
    end}
    local es=w:Entities();assert(#es==1 and es[1]==inside)
    inside.z=9;assert(#w:Entities()==0 and calls==1)
    now=3.1;w:Entities();assert(calls==2)
    assert(w:OnSave().region.id==1 and e.state.region.id==1)
    w:ClearRegion();assert(w.region==nil and w.config.paused and e.state.region==nil)
end)

test("region assignment does not pick ocean center and failed assignment is atomic",function()
    local w,e=setup(-5,-5)
    local old=TheWorld.Map.IsOceanAtPoint
    TheWorld.Map.IsOceanAtPoint=function(_,x,y,z)return x==0 and z==0 end
    assert(w:SetRegion({id=2,bounds={x1=-10,z1=-10,x2=10,z2=10}}))
    assert(w.home.x==-5 and w.home.z==-5)
    local oldhome=w.home
    TheWorld.Map.IsOceanAtPoint=function()return true end
    assert(not w:SetRegion({id=3,bounds={x1=10,z1=10,x2=30,z2=30}}))
    assert(w.region.id==2 and w.home==oldhome)
    TheWorld.Map.IsOceanAtPoint=old
    local revision=w.commandrevision
    w:SetHome({x=2,z=3});assert(w.region==nil and w.commandrevision==revision+1)
end)

test("long walks continue after twenty seconds and renew reservations",function()
    local w,e=setup();w.config.radius=160
    local target=entity(120,0)
    bind(w,w:MakeAction("pickup",target))
    local job=w.job;assert(job.navigation.deadline>100)
    for i=1,50 do now=i*.5;e.x=i;w:MonitorJob(job) end
    assert(w.job==job and job.navigation.attempts==0)
    local other=setup();other.config.radius=160
    assert(not other:Available(target))
    w:Cancel();assert(other:Available(target))
end)

test("stuck work detours and resumes the same reserved job",function()
    local w,e=setup();local target=entity(30,0)
    bind(w,w:MakeAction("pickup",target));local job=w.job
    now=3.1;w:MonitorJob(job)
    assert(w.job==job and job.waiting and job.waypoint and job.navigation.attempts==1)
    local a=w:NextAction();assert(a.action==ACTIONS.WALKTO and a.wr_job==job)
    e.x=job.waypoint.x;e.z=job.waypoint.z;a:Succeed()
    assert(w.job==job and job.waypoint==nil and job.waiting)
    local resumed=w:NextAction()
    assert(resumed.action==ACTIONS.WR_WORK and resumed.target==target and resumed.wr_job==job)
    resumed:Succeed();assert(w.job==nil and e.state.notice=="")
end)

test("three failed detours release the target with a longer cooldown",function()
    local w=setup();local target=entity(30,0)
    bind(w,w:MakeAction("pickup",target));local job=w.job
    for i=1,3 do
        now=i*3.1;w:MonitorJob(job)
        assert(w.job==job and job.navigation.attempts==i)
        bind(w,w:NextAction())
    end
    now=12.4;w:MonitorJob(job)
    assert(w.job==nil and w.blocked[target]>=now+60)
    assert(not w:Available(target) and w.notice:find("路线受阻"))
    local other=setup();assert(other:Available(target))
end)

test("blocked geometry never proposes a wall crossing or teleport",function()
    local w,e=setup();local target=entity(30,0)
    bind(w,w:MakeAction("pickup",target));local job=w.job;clear=false
    now=3.1;w:MonitorJob(job)
    assert(w.job==nil and e.x==0 and e.z==0 and w.blocked[target]>=63)
end)

test("busy animations are tolerated but the hard deadline is final",function()
    local w,e=setup();local target=entity(30,0)
    bind(w,w:MakeAction("pickup",target));local job=w.job;e.busy=true
    now=5;w:MonitorJob(job);assert(w.job==job)
    now=job.navigation.deadline+.1;w:MonitorJob(job)
    assert(w.job==nil and w.notice:find("耗时过长"))
end)

test("held or sleeping robots stop immediately without further waypoints",function()
    for _,property in ipairs({"held","asleep"})do
        local w,e=setup();local target=entity(30,0)
        bind(w,w:MakeAction("pickup",target));local job=w.job;e[property]=true
        now=1;w:MonitorJob(job)
        assert(w.job==nil and e.components.locomotor.stopped and job.navigation.attempts==0)
    end
end)

test("moving enemy leaves its area without an indefinite pursuit",function()
    local w,e=setup();local target=entity(30,0)
    w.config.guard=true;w.IsEnemy=function()return true end
    e.components.health={GetPercent=function()return 1 end}
    bind(w,w:MakeAction("attack",target));local job=w.job
    assert(job.navigation.deadline==30)
    now=1;e.x=3;target.x=90;w:MonitorJob(job)
    assert(w.job==nil and w.notice:find("离开工作区"))
end)

test("small oscillations cannot hold a reservation forever",function()
    local nav=Navigation.New(0,0,0,40,0,4,"pickup")
    for i=1,17 do assert(Navigation.Progress(nav,i,0,i%2,40,0,false,false)=="moving")end
    assert(Navigation.Progress(nav,18,0,0,40,0,false,false)=="stalled")
end)
print("WR_NAV_SUCCESS "..checks)
