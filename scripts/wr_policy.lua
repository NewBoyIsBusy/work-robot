local M={}
M.TASKS={"farm","harvest","tend","fish","haul","cook","guard"}
local fields={paused="boolean",radius="number",recipe="string"}
for _,k in ipairs(M.TASKS) do fields[k]="boolean" end
function M.Validate(p)
    if type(p)~="table" then return nil end
    local out={}
    for k,v in pairs(p) do
        if fields[k]==nil or type(v)~=fields[k] then return nil end
        if k=="radius" and (v~=math.floor(v) or v<4 or v>80) then return nil end
        if k=="recipe" and v~="meatballs" then return nil end
        out[k]=v
    end
    return next(out) and out or nil
end
function M.Preset(mode)
    local p={paused=false}
    for _,k in ipairs(M.TASKS) do p[k]=false end
    if mode=="farm" then p.farm=true;p.harvest=true;p.tend=true;p.haul=true
    elseif mode=="fish" then p.fish=true
    elseif mode=="haul" then p.haul=true
    elseif mode=="cook" then p.cook=true
    elseif mode=="guard" then p.guard=true
    elseif mode=="all" then
        for _,k in ipairs({"farm","harvest","tend","fish","haul"}) do p[k]=true end
    else return nil end
    return p
end
-- Exact templates avoid silently dropping unsupported clauses or negations.
function M.Parse(text)
    local presets={ ["种田"]="farm",["务农"]="farm",["收鱼"]="fish",["搬运"]="haul",
        ["做饭"]="cook",["帮忙做饭"]="cook",["做肉丸"]="cook",["站哨"]="guard",["守卫"]="guard",["战斗"]="guard",["自动工作"]="all" }
    text=text:match("^%s*(.-)%s*$")
    if presets[text] then return M.Preset(presets[text]) end
    if text=="停工" or text=="暂停" then return {paused=true} end
    if text=="继续" or text=="开工" then return {paused=false} end
    if text=="收菜" or text=="只收菜" or text=="只收菜，不播种" then
        local p=M.Preset("farm");p.farm=false;p.tend=false;p.haul=false;return p
    end
    local r=text:match("^半径%s*(%d+)$")
    return r and M.Validate({radius=tonumber(r)}) or nil
end
return M
