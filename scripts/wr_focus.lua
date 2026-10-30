return function(env)
 local G=env.GLOBAL
 local function Current(player)
  local robot=player and player._wr_focus
  return robot and robot:IsValid()and robot.components.wr_worker and robot or nil
 end
 local function Notice(player,text)
  if player and player.userid then env.SendModRPCToClient(env.GetClientModRPC("work_robot","focus_notice"),player.userid,text or"")end
 end
 local function SetFocus(player,robot)
  player._wr_focus=robot
  env.SendModRPCToClient(env.GetClientModRPC("work_robot","focus_set"),player.userid,robot and tostring(robot.GUID)or"")
 end

 local focus=env.AddAction("WR_FOCUS","设置机器人",function(act)
  if not act.doer or not act.doer:HasTag("player")or not act.target or not act.target.components.wr_worker then return false end
  if Current(act.doer)==act.target then SetFocus(act.doer,nil)else SetFocus(act.doer,act.target)end return true
 end)
 focus.rmb=true focus.priority=4 focus.distance=math.huge focus.instant=true focus.do_not_locomote=true focus.mount_valid=true
 local target=env.AddAction("WR_TARGET","切换机器人目标",function(act)
  local robot=Current(act.doer)if not robot or not act.target then return false end
  local ok,message=robot.components.wr_worker:ToggleTarget(act.target)Notice(act.doer,message)return ok
 end)
 target.rmb=true target.priority=5 target.distance=math.huge target.instant=true target.do_not_locomote=true target.mount_valid=true
 local repair=env.AddAction("WR_REPAIR","维修机器人",function(act)
  if not act.target or not act.target.components.wr_worker then return false end
  local ok,message=act.target.components.wr_worker:Repair(act.doer)Notice(act.doer,message)return ok
 end)
 repair.rmb=true repair.priority=6 repair.distance=4 repair.instant=true repair.do_not_locomote=true

local function ClientFocused(doer)
  local guid=rawget(G,"WORK_ROBOT_FOCUS_GUID")
  return guid~=nil and guid~=0 and doer==G.ThePlayer
 end
 local function AddTargetAction(inst,doer,actions,right)
  if right and not inst:HasTag("wr_robot")and((G.TheWorld and G.TheWorld.ismastersim and Current(doer))or ClientFocused(doer))then
   for _,a in ipairs(actions)do if a==target then return end end table.insert(actions,target)
  end
 end
 env.AddComponentAction("SCENE","wr_worker",function(inst,doer,actions,right)
  if right and not doer:HasTag("playerghost")then
   local damaged=inst.replica.health and inst.replica.health:GetPercent()<1
   if damaged then table.insert(actions,repair)else table.insert(actions,focus)end
  end
 end)
 for _,component in ipairs({"container","pickable","farmplanttendable","trap","stewer","inventoryitem","combat"})do
  env.AddComponentAction("SCENE",component,AddTargetAction)
 end
 env.AddComponentAction("SCENE","inspectable",function(inst,doer,actions,right)
  if inst.prefab=="farm_soil"or inst.prefab=="ocean_trawler"then AddTargetAction(inst,doer,actions,right)end
 end)
 env.AddStategraphActionHandler("wilson",G.ActionHandler(focus,"doshortaction"))
 env.AddStategraphActionHandler("wilson_client",G.ActionHandler(focus,"doshortaction"))
 env.AddStategraphActionHandler("wilson",G.ActionHandler(target,"doshortaction"))
 env.AddStategraphActionHandler("wilson_client",G.ActionHandler(target,"doshortaction"))
 env.AddStategraphActionHandler("wilson",G.ActionHandler(repair,"doshortaction"))
 env.AddStategraphActionHandler("wilson_client",G.ActionHandler(repair,"doshortaction"))

 env.AddModRPCHandler("work_robot","focus_exit",function(player)if Current(player)then SetFocus(player,nil)end end)
 env.AddModRPCHandler("work_robot","guard_set",function(player,x,z)
  local robot=Current(player)if robot then local ok=robot.components.wr_worker:SetGuardPoint(x,z)Notice(player,ok and"已把镜头中心设为站哨点。"or"这里不能站哨。")end
 end)
 env.AddModRPCHandler("work_robot","guard_clear",function(player)
  local robot=Current(player)if robot then robot.components.wr_worker:ClearGuardPoint()Notice(player,"已取消站哨。")end
 end)

 local controller
 env.AddClientModRPCHandler("work_robot","focus_set",function(guid)if controller then controller:Begin(guid)end end)
 env.AddClientModRPCHandler("work_robot","focus_notice",function(message)
  if type(message)=="string"and G.ChatHistory then G.ChatHistory:SendCommandResponse("[勤务机器人] "..message)end
 end)
 if G.TheNet:IsDedicated()then return end
 local Widget=G.require("widgets/widget")
 local Image=G.require("widgets/image")
 local Text=G.require("widgets/text")
 local json=G.require("json")
 local FocusWidget=G.Class(Widget,function(self,owner)
  Widget._ctor(self,"WorkRobotFocus")self.owner=owner self.robot=nil self.guid=0 self.cam=nil self.state=""self.elapsed=0
  self.lines={}
  for i=1,2 do local line=self:AddChild(Image("images/global.xml","square.tex"))line:SetTint(.25,1,.65,.9)line:SetClickable(false)line:Hide()self.lines[i]=line end
  self.help=self:AddChild(Text(G.UIFONT,22,""))self.help:SetHAnchor(G.ANCHOR_MIDDLE)self.help:SetVAnchor(G.ANCHOR_TOP)
  self.help:SetPosition(0,-42)self.help:SetColour(.8,1,.88,1)self:Hide()
  self:StartUpdating()
  self.inst:DoPeriodicTask(.1,function()self:TickCamera(.1)end)
 end)
 local function FindRobot(token)
  for _,entity in pairs(G.Ents)do
   if entity:HasTag("wr_robot")and entity._wr_id and entity._wr_id:value()==token then return entity end
  end
 end
 function FocusWidget:Begin(token)
  self.token=tostring(token or"")
  if self.token==""then return self:Finish()end
  self.robot=FindRobot(self.token)self.guid=self.robot and self.robot.GUID or-1
  rawset(G,"WORK_ROBOT_FOCUS_GUID",self.guid)self.cam=nil self:Show()
  self.help:SetString("机器人设置视角  |  WASD 移动镜头  R 回到机器人  G 设置站哨点  X 取消站哨  Esc 退出\n右键箱子、冰箱、植株、捕鱼器、锅、物品或敌人：添加 / 移除目标")
 end
 function FocusWidget:Finish()
  self.guid=0 self.token=nil self.robot=nil self.cam=nil rawset(G,"WORK_ROBOT_FOCUS_GUID",0)self:Hide()
  for _,line in ipairs(self.lines)do line:Hide()end
  if G.TheCamera and G.ThePlayer then G.TheCamera:SetTarget(G.ThePlayer)G.TheCamera:SetDefaultOffset()G.TheCamera:Snap()end
 end
 function FocusWidget:Center()
  if self.robot and self.robot:IsValid()then local x,_,z=self.robot.Transform:GetWorldPosition()self.cam=G.Vector3(x,1.5,z)
   G.TheCamera:SetTarget(nil)G.TheCamera:SetOffset(self.cam)G.TheCamera:Snap()end
 end
 function FocusWidget:TickCamera(dt)
  if self.guid==0 then return end
  if not self.robot or not self.robot:IsValid()then self.robot=FindRobot(self.token)if self.robot then self.guid=self.robot.GUID rawset(G,"WORK_ROBOT_FOCUS_GUID",self.guid)end end
  if not self.robot then return end if not self.cam then self:Center()end
  local x=G.TheInput:GetAnalogControlValue(G.CONTROL_MOVE_RIGHT)-G.TheInput:GetAnalogControlValue(G.CONTROL_MOVE_LEFT)
  local y=G.TheInput:GetAnalogControlValue(G.CONTROL_MOVE_UP)-G.TheInput:GetAnalogControlValue(G.CONTROL_MOVE_DOWN)
  if x~=0 or y~=0 then local right,down=G.TheCamera:GetRightVec(),G.TheCamera:GetDownVec()local speed=22*dt
   self.cam.x=self.cam.x+(right.x*x-down.x*y)*speed self.cam.z=self.cam.z+(right.z*x-down.z*y)*speed
   G.TheCamera:SetOffset(self.cam)
  end
 end
 local function DrawLine(line,x1,y1,x2,y2,w,h)
  local dx,dy=x2-x1,y2-y1 local length=math.sqrt(dx*dx+dy*dy)
  if length<2 then line:Hide()return end line:SetPosition((x1+x2)/2-w/2,(y1+y2)/2-h/2)
  line:SetSize(length,3)line:SetRotation(-math.atan2(dy,dx)*180/math.pi)line:Show()
 end
 function FocusWidget:OnUpdate(dt)
  if self.guid==0 then return end if not self.robot or not self.robot:IsValid()then self.robot=FindRobot(self.token)if not self.robot then return end self.guid=self.robot.GUID rawset(G,"WORK_ROBOT_FOCUS_GUID",self.guid)end
  self.elapsed=self.elapsed+dt if self.elapsed<.1 then return end self.elapsed=0
  local raw=self.robot._wr_state and self.robot._wr_state:value()or""if raw~=self.state then self.state=raw local ok,data=pcall(json.decode,raw)self.data=ok and data or{}end
  local path=self.data and self.data.p or{}local rx,ry,rz=self.robot.Transform:GetWorldPosition()local sx,sy=G.TheSim:GetScreenPos(rx,ry,rz)
  local w,h=G.TheSim:GetScreenSize()
  for i,line in ipairs(self.lines)do local point=path[i]
   if point then local ex,ey=G.TheSim:GetScreenPos(point[1],0,point[2])DrawLine(line,sx,sy,ex,ey,w,h)sx,sy=ex,ey else line:Hide()end
  end
 end
 env.AddClassPostConstruct("widgets/controls",function(self)
  controller=self:AddChild(FocusWidget(self.owner))rawset(G,"WORK_ROBOT_FOCUS_CONTROLLER",controller)
 end)
 env.AddClassPostConstruct("screens/playerhud",function(self)
  local old=self.OnControl
  self.OnControl=function(hud,control,down)
   if controller and controller.guid~=0 then
    if control==G.CONTROL_PAUSE or control==G.CONTROL_CANCEL then
     if down then env.SendModRPCToServer(env.GetModRPC("work_robot","focus_exit"))controller:Finish()end return true
    elseif control==G.CONTROL_MOVE_UP or control==G.CONTROL_MOVE_DOWN or control==G.CONTROL_MOVE_LEFT or control==G.CONTROL_MOVE_RIGHT then return true end
   end
   return old(hud,control,down)
  end
 end)
 env.AddSimPostInit(function()
  G.TheInput:AddKeyDownHandler(G.KEY_R,function()if controller and controller.guid~=0 then controller:Center()end end)
  G.TheInput:AddKeyDownHandler(G.KEY_G,function()if controller and controller.guid~=0 and controller.cam then
   env.SendModRPCToServer(env.GetModRPC("work_robot","guard_set"),controller.cam.x,controller.cam.z)end end)
  G.TheInput:AddKeyDownHandler(G.KEY_X,function()if controller and controller.guid~=0 then env.SendModRPCToServer(env.GetModRPC("work_robot","guard_clear"))end end)
 end)
end
