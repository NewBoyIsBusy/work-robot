local Regions=require("wr_regions")
local Policy=require("wr_policy")
local MODES={farm="农田",fish="渔场",haul="搬运",cook="厨房",guard="守卫",auto="综合"}
local Zones=Class(function(self,inst)
    self.inst=inst
    self.zones={}
    self.nextid=1
    self.robots=setmetatable({},{__mode="k"})
end)
local function validrobot(r)
    return r and r:IsValid() and r.components.wr_worker and not r:IsInLimbo()
        and not r.components.inventoryitem:IsHeld()
end
local function validid(id) return type(id)=="number" and id==math.floor(id) and id>0 and id<1000000000 end
function Zones:Register(robot) self.robots[robot]=true end
function Zones:OnSave() return {zones=self.zones,nextid=self.nextid} end
function Zones:OnLoad(data)
    self.zones={};self.nextid=1
    for _,zone in pairs(data and data.zones or {}) do
        local b=Regions.NormalizeBounds(zone.bounds)
        if validid(zone.id) and b and MODES[zone.mode] and #self.zones<Regions.MAX_ZONES then
            local label=type(zone.label)=="string" and zone.label:sub(1,48) or MODES[zone.mode]..zone.id
            self.zones[#self.zones+1]={id=zone.id,label=label,mode=zone.mode,bounds=b,paused=zone.paused==true}
            self.nextid=math.max(self.nextid,zone.id+1)
        end
    end
    if validid(data and data.nextid) then self.nextid=math.max(self.nextid,data.nextid) end
end
function Zones:Find(id)
    for i,z in ipairs(self.zones) do if z.id==id then return z,i end end
end
function Zones:Snapshot(message)
    local robots,zones={},{}
    local byid={}
    for _,zone in ipairs(self.zones) do
        local z=Regions.Copy(zone);z.robots={};z.paused=zone.paused
        zones[#zones+1]=z;byid[z.id]=z
    end
    local ordered={}
    for r in pairs(self.robots) do if validrobot(r) then ordered[#ordered+1]=r end end
    table.sort(ordered,function(a,b)return a.GUID<b.GUID end)
    for i,r in ipairs(ordered) do
        if i>128 then break end
        local w=r.components.wr_worker
        local x,_,z=r.Transform:GetWorldPosition()
        local id=w.region and w.region.id
        robots[#robots+1]={id=r.GUID,label=w.label or "勤务机器人",zone=id,paused=w.config.paused,
            broken=r:HasTag("broken"),sleeping=r:IsAsleep(),x=x,z=z,notice=w.notice or "",job=w.job and w.job.kind or "idle"}
        if id and byid[id] then table.insert(byid[id].robots,r.GUID) end
    end
    return {zones=zones,robots=robots,message=message or ""}
end
function Zones:Apply(player,req)
    if not player or not player:IsValid() or not player:HasTag("player") or player:HasTag("playerghost") then return false,"请以存活玩家身份指挥。" end
    if type(req)~="table" then return false,"指挥数据无效。" end
    local zone,index=self:Find(req.id)
    if req.op=="delete" or req.op=="pause" or req.op=="resume" then
        if not zone then return false,"这个区域已被删除，请刷新地图。" end
        for r in pairs(self.robots) do
            if r:IsValid() and r.components.wr_worker then
                local w=r.components.wr_worker
                if w.region and w.region.id==zone.id then
                    w.commandrevision=(w.commandrevision or 0)+1
                    if req.op=="delete" then w:ClearRegion() else w:ApplyPolicy({paused=req.op=="pause"}) end
                end
            end
        end
        if req.op=="delete" then table.remove(self.zones,index) else zone.paused=req.op=="pause" end
        return true,req.op=="delete" and "区域已删除，原成员停工待命。" or req.op=="pause" and "区域已暂停。" or "区域已继续工作。"
    end
    if req.op~="save" or (req.id~=nil and not zone) then return false,"区域已失效，请刷新后重试。" end
    if not zone and #self.zones>=Regions.MAX_ZONES then return false,"本分片最多保存 32 个工作区域。" end
    local bounds,err=Regions.NormalizeBounds(req.bounds)
    if not bounds then return false,err end
    if not MODES[req.mode] then return false,"请选择受支持的工作任务。" end
    if type(req.robots)~="table" then return false,"请选择机器人。" end
    local selected,ordered={},{}
    for key,id in pairs(req.robots) do
        if type(key)~="number" or key<1 or key~=math.floor(key) or key>Regions.MAX_ROBOTS or not validid(id) or selected[id] then return false,"一次最多分配 16 台不同的机器人。" end
        local r=Ents[id]
        if not self.robots[r] or not validrobot(r) then return false,"选中的机器人已被捡起或离开当前分片，请刷新。" end
        if not Regions.FindHome(bounds,r:GetPosition()) then return false,"区域中没有找到可站立的陆地，请调整范围。" end
        selected[id]=r;ordered[#ordered+1]=r
    end
    if #ordered==0 and not Regions.FindHome(bounds) then return false,"区域中没有找到可站立的陆地，请调整范围。" end
    local id=zone and zone.id or self.nextid
    local label=req.label
    if label~=nil and (type(label)~="string" or #label>48 or label:find("[%c]")) then return false,"区域名最多 16 个汉字，不能包含控制符。" end
    if not label or label:match("^%s*$") then label=MODES[req.mode].."区 "..id end
    local replacement={id=id,label=label,mode=req.mode,bounds=bounds,paused=false}
    -- Validate the complete assignment before changing any robot or zone.
    if zone then
        for r in pairs(self.robots) do
            if r:IsValid() and r.components.wr_worker then
                local w=r.components.wr_worker
                if w.region and w.region.id==id and not selected[r.GUID] then w:ClearRegion() end
            end
        end
    end
    for _,r in ipairs(ordered) do
        local w=r.components.wr_worker
        w:SetRegion(replacement)
        for _,role in ipairs({"supply","output"}) do
            local box=w[role]
            if box and (not box:IsValid() or not w:Inside(box)) then w[role]=nil end
        end
        w:ApplyPolicy(Policy.Preset(req.mode=="auto" and "all" or req.mode))
        w:Sync("已分配到 "..label)
    end
    if index then self.zones[index]=replacement else self.zones[#self.zones+1]=replacement;self.nextid=id+1 end
    return true,label.."已保存，分配 "..#ordered.." 台机器人（无需 API）。"
end
return Zones
