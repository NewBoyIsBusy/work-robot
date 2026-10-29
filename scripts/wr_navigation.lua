-- Navigation only proposes ordinary walk actions. It never changes transforms,
-- collision masks, pathfinder walls, or the world's sleeping entity behaviour.
local M = {MAX_RETRIES=3, STALL_SECONDS=3, LEASE_SECONDS=8}

function M.New(now, x, z, tx, tz, speed, kind)
    local distance=math.sqrt((tx-x)^2+(tz-z)^2)
    local duration=math.min(240,math.max(45,20+distance/math.max(1,speed)*4))
    if kind=="attack" then duration=30 elseif kind=="return" then duration=math.min(90,duration) end
    return {deadline=now+duration, x=x,z=z, movedat=now,
        bestdistance=distance, advancedat=now, tx=tx,tz=tz, attempts=0, visited={}}
end

function M.ResetProgress(nav, now, x, z, tx, tz)
    nav.x=x;nav.z=z;nav.movedat=now
    nav.bestdistance=math.sqrt((tx-x)^2+(tz-z)^2);nav.advancedat=now
    nav.tx=tx;nav.tz=tz
end

function M.Progress(nav, now, x, z, tx, tz, busy, movingtarget)
    if now>=nav.deadline then return "expired" end
    if busy then M.ResetProgress(nav,now,x,z,tx,tz);return "moving" end
    if (x-nav.x)^2+(z-nav.z)^2>=.36 then
        nav.x=x;nav.z=z;nav.movedat=now
    end
    local distance=math.sqrt((tx-x)^2+(tz-z)^2)
    if distance<nav.bestdistance-.5
        or (movingtarget and (tx-nav.tx)^2+(tz-nav.tz)^2>1) then
        nav.bestdistance=distance;nav.advancedat=now;nav.tx=tx;nav.tz=tz
    end
    if now-nav.movedat>=M.STALL_SECONDS or now-nav.advancedat>=18 then return "stalled" end
    return "moving"
end

function M.IsWalkable(x,z,radius)
    local map=TheWorld.Map
    return map:IsPassableAtPoint(x,0,z) and not map:IsOceanAtPoint(x,0,z)
        and not map:IsGroundTargetBlocked(Vector3(x,0,z),radius or .5)
end

-- Each attempted waypoint has a clear ground segment from the current position.
-- The usual locomotor still executes it and checks collisions while walking.
function M.Waypoint(inst,nav,tx,tz)
    if nav.attempts>=M.MAX_RETRIES then return nil end
    local x,_,z=inst.Transform:GetWorldPosition()
    local angle=math.atan2(tz-z,tx-x)
    local candidates={}
    local radius=inst:GetPhysicsRadius(.4)+.15
    for _,distance in ipairs({3,6,10}) do
        for _,degrees in ipairs({60,-60,90,-90,120,-120,150,-150,180}) do
            local a=angle+degrees*math.pi/180
            local px,pz=x+math.cos(a)*distance,z+math.sin(a)*distance
            local visited=false
            for _,old in ipairs(nav.visited) do
                if (old.x-px)^2+(old.z-pz)^2<4 then visited=true;break end
            end
            if not visited and M.IsWalkable(px,pz,radius)
                and TheWorld.Pathfinder:IsClear(x,0,z,px,0,pz,inst.components.locomotor.pathcaps) then
                local clear=TheWorld.Pathfinder:IsClear(px,0,pz,tx,0,tz,inst.components.locomotor.pathcaps)
                candidates[#candidates+1]={x=px,z=pz,
                    score=math.sqrt((tx-px)^2+(tz-pz)^2)+distance*.2+(clear and 0 or 12)}
            end
        end
    end
    table.sort(candidates,function(a,b)return a.score<b.score end)
    local point=candidates[1]
    if point then
        nav.attempts=nav.attempts+1
        nav.visited[#nav.visited+1]={x=point.x,z=point.z}
    end
    return point
end

return M
