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

test("explicit targets are toggled and persisted without an area",function()
    local w=setup()
    local chest=entity(8,0);chest.tags.structure=true
    chest.components.container={canbeopened=true,readonlycontainer=false,restrictedtag=nil}
    local plant=entity(12,0);plant.components.pickable={}
    assert(w:ToggleTarget(chest));assert(w:ToggleTarget(plant))
    local data,refs=w:OnSave()
    assert(#data.boxes==1 and data.boxes[1]==chest.GUID)
    assert(#data.targets==1 and data.targets[1]==plant.GUID and #refs==2)
    assert(w:IsAssigned(chest)and w:IsAssigned(plant))
    assert(w:ToggleTarget(plant));assert(not w:IsAssigned(plant))
end)

test("guard point replaces the old rectangular assignment",function()
    local w=setup(-5,-5)
    assert(not w:SetRegion({bounds={x1=-10,z1=-10,x2=10,z2=10}}))
    assert(w:SetGuardPoint(9,4)and w.guardpoint.x==9 and w.guardpoint.z==4)
    w:ClearGuardPoint();assert(w.guardpoint==nil)
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
    resumed:Succeed();assert(w.job==nil and w.notice=="")
end)

test("three failed detours release the target with a longer cooldown",function()
    local w=setup();local target=entity(30,0)
    bind(w,w:MakeAction("pickup",target));local job=w.job
    for i=1,5 do
        if w.job then
            now=i*3.2;w:MonitorJob(job)
            if w.job then bind(w,w:NextAction()) end
        end
    end
    assert(w.job==nil and w.blocked[target]>now)
    assert(not w:Available(target) and w.notice:find("路线受阻"))
    local other=setup();assert(other:Available(target))
end)

test("blocked geometry never proposes a wall crossing or teleport",function()
    local w,e=setup();local target=entity(30,0)
    bind(w,w:MakeAction("pickup",target));local job=w.job;clear=false
    now=3.1;w:MonitorJob(job)
    assert(w.job==nil and e.x==0 and e.z==0 and w.blocked[target]>=33)
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

test("moving enemy pursuit remains bounded by the hard deadline",function()
    local w,e=setup();local target=entity(30,0)
    w.IsEnemy=function()return true end
    e.components.health={GetPercent=function()return 1 end}
    bind(w,w:MakeAction("attack",target));local job=w.job
    assert(job.navigation.deadline==30)
    now=1;e.x=3;target.x=90;w:MonitorJob(job);assert(w.job==job)
    now=job.navigation.deadline+.1;w:MonitorJob(job)
    assert(w.job==nil and w.notice:find("耗时过长"))
end)

test("small oscillations cannot hold a reservation forever",function()
    local nav=Navigation.New(0,0,0,40,0,4,"pickup")
    for i=1,17 do assert(Navigation.Progress(nav,i,0,i%2,40,0,false,false)=="moving")end
    assert(Navigation.Progress(nav,18,0,0,40,0,false,false)=="stalled")
end)
print("WR_NAV_SUCCESS "..checks)
