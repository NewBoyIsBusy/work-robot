local M={MAX_SIDE=160,MAX_ZONES=32,MAX_ROBOTS=16}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<=8192 end
function M.NormalizeBounds(b)
    if type(b)~="table" then return nil,"请先在地图上框选工作区域。" end
    for _,k in ipairs({"x1","z1","x2","z2"}) do if not finite(b[k]) then return nil,"区域坐标无效。" end end
    local x1,x2=math.min(b.x1,b.x2),math.max(b.x1,b.x2)
    local z1,z2=math.min(b.z1,b.z2),math.max(b.z1,b.z2)
    if x2-x1<4 or z2-z1<4 then return nil,"区域宽和高至少为 4（一块地皮）。" end
    if x2-x1>M.MAX_SIDE or z2-z1>M.MAX_SIDE then return nil,"单个区域最大为 160×160，请拆成多个工作区。" end
    return {x1=x1,z1=z1,x2=x2,z2=z2}
end
function M.Inside(b,x,z) return b and x>=b.x1 and x<=b.x2 and z>=b.z1 and z<=b.z2 end
function M.Center(b) return {x=(b.x1+b.x2)/2,z=(b.z1+b.z2)/2} end
function M.Copy(region)
    if not region then return nil end
    local b=M.NormalizeBounds(region.bounds)
    if not b then return nil end
    return {id=region.id,label=region.label,mode=region.mode,bounds=b}
end
function M.FindHome(bounds,preferred)
    local b=M.NormalizeBounds(bounds)
    if not b then return nil end
    local candidates={}
    if preferred then candidates[#candidates+1]={x=math.max(b.x1+.5,math.min(b.x2-.5,preferred.x)),z=math.max(b.z1+.5,math.min(b.z2-.5,preferred.z))} end
    candidates[#candidates+1]=M.Center(b)
    for i=0,4 do for j=0,4 do
        candidates[#candidates+1]={x=b.x1+.5+(b.x2-b.x1-1)*i/4,z=b.z1+.5+(b.z2-b.z1-1)*j/4}
    end end
    for _,pt in ipairs(candidates) do
        if TheWorld.Map:IsPassableAtPoint(pt.x,0,pt.z) and not TheWorld.Map:IsOceanAtPoint(pt.x,0,pt.z)
            and not TheWorld.Map:IsGroundTargetBlocked(Vector3(pt.x,0,pt.z)) then return pt end
    end
    return nil
end
return M
