-- Map commander. Uses the native map projection, UI widgets and mod RPCs only.
return function(env)
    local G = env.GLOBAL
    local json = G.require("json")
    local active

    env.AddClientModRPCHandler("work_robot", "commander_state", function(payload)
        if type(payload) ~= "string" then return end
        local ok, state = pcall(json.decode, payload)
        if ok and type(state) == "table" and active then active:SetState(state) end
    end)
    if G.TheNet:IsDedicated() then return end

    local Widget = G.require("widgets/widget")
    local Image = G.require("widgets/image")
    local Text = G.require("widgets/text")
    local TextButton = G.require("widgets/textbutton")
    local WIDTH, HEIGHT, MAX_SIDE, ROBOTS_PER_PAGE, ZONES_PER_PAGE = 350, 688, 160, 6, 3
    local MODES = {
        {"farm", "种田", {.38, .82, .39}}, {"fish", "收鱼", {.31, .72, .99}},
        {"haul", "搬运", {.95, .73, .31}}, {"cook", "做饭", {.98, .49, .30}},
        {"guard", "站哨", {.88, .43, .56}}, {"auto", "综合", {.56, .71, .93}},
    }
    local MODE_NAMES, MODE_COLOURS = {}, {}
    for _, entry in ipairs(MODES) do MODE_NAMES[entry[1]], MODE_COLOURS[entry[1]] = entry[2], entry[3] end

    local function CopyBounds(bounds)
        return bounds and {x1=bounds.x1, z1=bounds.z1, x2=bounds.x2, z2=bounds.z2} or nil
    end
    local function OrderedBounds(x1, z1, x2, z2)
        return {x1=math.min(x1,x2), z1=math.min(z1,z2), x2=math.max(x1,x2), z2=math.max(z1,z2)}
    end
    local function Count(selected)
        local n = 0
        for _ in pairs(selected) do n = n + 1 end
        return n
    end
    local function ShortLabel(label, fallback, limit)
        label = tostring(label or fallback or "")
        -- Keep UTF-8 characters intact. Names can be supplied by another player.
        local count = 0
        for pos in label:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
            count = count + 1
            if count > (limit or 11) then return label:sub(1,pos-1).."…" end
        end
        return label
    end
    local function RobotLabel(robot)
        local name=robot.label=="勤务机器人" and "机器人" or ShortLabel(robot.label,"机器人",4)
        return name.." #"..tostring(robot.id):sub(-4)
    end
    local function RobotDescription(robot)
        local status=robot.broken and "损坏，给予石头修复" or robot.sleeping and "休眠；玩家靠近后继续工作"
            or robot.paused and "已暂停" or robot.zone and "已分配区域 #"..robot.zone or "尚未分区"
        return tostring(robot.label or "机器人").." #"..robot.id.."\n"..status
            ..(type(robot.notice)=="string" and robot.notice~="" and "\n"..robot.notice or "")
    end

    local function Build(screen)
        local self = {
            screen=screen, state={robots={}, zones={}}, draft={mode="farm"}, selected={},
            robotpage=1, zonepage=1, buttons={}, open=false, drawarmed=false, elapsed=0,
            zonevisuals={}, robotvisuals={}, pending=false,
        }
        screen._wr_commander = self
        active = self

        -- Pixel roots avoid the legacy MapScreen's inaccurate fixed-resolution helpers.
        self.overlay = screen:AddChild(Widget("work_robot_map_overlay"))
        self.overlay:SetClickable(false)
        self.overlay:Hide()
        self.root = screen:AddChild(Widget("work_robot_commander_root"))
        self.panel = self.root:AddChild(Widget("work_robot_commander_panel"))
        self.panel:Hide()

        local function Fill(parent, x, y, w, h, colour)
            local image = parent:AddChild(Image("images/ui.xml", "white.tex"))
            image:SetPosition(x,y)
            image:SetSize(w,h)
            image:SetTint(unpack(colour))
            image:SetClickable(false)
            return image
        end
        local function Label(parent, text, x, y, size, w, h)
            local label = parent:AddChild(Text(G.UIFONT, size or 20, text))
            label:SetPosition(x,y)
            if w then label:SetRegionSize(w,h or 28); label:EnableWordWrap(true) end
            label:SetClickable(false)
            return label
        end
        local function Button(parent, text, x, y, w, h, fn)
            local button = parent:AddChild(TextButton())
            button:SetTextSize(20)
            button:SetText(text)
            button.image:SetTexture("images/ui.xml", "white.tex")
            button.image:SetSize(w,h)
            button.image:SetTint(.14,.20,.22,.97)
            button.image:MoveToBack()
            button:SetTextColour({.88,.93,.90,1})
            button:SetTextFocusColour({1,.88,.55,1})
            button:SetPosition(x,y)
            button.wr_rect={x=x,y=y,w=w,h=h}
            button.wr_click=fn
            self.buttons[#self.buttons+1]=button
            return button
        end
        local function ButtonText(button, text)
            button:SetText(text)
            button.image:SetSize(button.wr_rect.w,button.wr_rect.h)
        end
        self.ButtonText=ButtonText

        self.entry = Button(self.root,"机器人管理",88,-23,176,44,function() self:Open() end)
        Fill(self.panel,WIDTH/2,-HEIGHT/2,WIDTH,HEIGHT,{.045,.073,.075,.97})
        Fill(self.panel,3,-HEIGHT/2,6,HEIGHT,{.42,.76,.58,1})
        Label(self.panel,"机器人管理",159,-27,25)
        Button(self.panel,"×",322,-27,32,32,function() self:Close() end)
        Label(self.panel,"框选区域 → 选择工作和机器人 → 应用",175,-57,18)
        Button(self.panel,"新建区域 · 框选",126,-99,218,40,function() self:NewZone() end)
        Button(self.panel,"刷新",289,-99,78,40,function() self:Query() end)
        self.boundslabel=Label(self.panel,"尚未选择工作区域",175,-137,18,324,32)
        Label(self.panel,"1  选择区域内的工作",175,-170,19)
        self.modebuttons={}
        for i, mode in ipairs(MODES) do
            local key=mode[1]
            self.modebuttons[key]=Button(self.panel,mode[2],66+109*((i-1)%3),-203-37*math.floor((i-1)/3),99,32,function() self:SetMode(key) end)
        end
        self.robotheading=Label(self.panel,"2  勾选机器人（0 台）",124,-278,18,220,28)
        Button(self.panel,"全选",272,-278,45,27,function() self:SelectAll() end)
        Button(self.panel,"清空",321,-278,45,27,function() self.selected={}; self:Refresh() end)
        self.robotbuttons={}
        for i=1,ROBOTS_PER_PAGE do
            local index=i
            self.robotbuttons[i]=Button(self.panel,"",94+163*((i-1)%2),-313-35*math.floor((i-1)/2),155,30,function()
                local robot=self.state.robots[(self.robotpage-1)*ROBOTS_PER_PAGE+index]
                if robot then self:ToggleRobot(robot.id) end
            end)
            self.robotbuttons[i]:SetTextSize(18)
        end
        Button(self.panel,"上一页",54,-415,74,27,function() self.robotpage=math.max(1,self.robotpage-1); self:Refresh() end)
        self.robotpage_label=Label(self.panel,"1 / 1",175,-415,17)
        Button(self.panel,"下一页",296,-415,74,27,function()
            self.robotpage=math.min(math.max(1,math.ceil(#self.state.robots/ROBOTS_PER_PAGE)),self.robotpage+1); self:Refresh()
        end)
        self.applybutton=Button(self.panel,"应用工作区域",175,-455,316,40,function() self:Apply() end)
        Label(self.panel,"已有区域",84,-494,18)
        Button(self.panel,"‹",223,-494,30,25,function() self.zonepage=math.max(1,self.zonepage-1); self:Refresh() end)
        self.zonepage_label=Label(self.panel,"1 / 1",267,-494,16)
        Button(self.panel,"›",313,-494,30,25,function()
            self.zonepage=math.min(math.max(1,math.ceil(#self.state.zones/ZONES_PER_PAGE)),self.zonepage+1); self:Refresh()
        end)
        self.zonebuttons={}
        for i=1,ZONES_PER_PAGE do
            local index=i
            self.zonebuttons[i]=Button(self.panel,"",175,-524-(i-1)*30,316,26,function()
                local zone=self.state.zones[(self.zonepage-1)*ZONES_PER_PAGE+index]
                if zone then self:SelectZone(zone.id) end
            end)
        end
        Button(self.panel,"暂停",66,-622,98,32,function() self:Pause() end)
        Button(self.panel,"继续",175,-622,98,32,function() self:Resume() end)
        Button(self.panel,"删除区域",284,-622,98,32,function() self:Delete() end)
        self.status=Label(self.panel,"原版地图缩放 / 平移；Esc 取消框选",175,-665,17,324,46)

        function self:Message(text)
            self.status:SetString(tostring(text or ""))
        end
        function self:Query()
            env.SendModRPCToServer(env.GetModRPC("work_robot","commander_query"))
        end
        function self:Send(request)
            if self.pending then self:Message("正在等待服务器，请稍候…"); return false end
            self.pending=true
            self.pendingtime=0
            self:Message("正在应用，请稍候…")
            env.SendModRPCToServer(env.GetModRPC("work_robot","commander_apply"),json.encode(request))
            return true
        end
        function self:Open()
            self.open=true; self.entry:Hide(); self.panel:Show(); self.overlay:Show()
            self:Refresh(); self:Query()
        end
        function self:Close()
            self.open=false; self.drawarmed=false; self.dragstart=nil; self.capture=nil
            self.panel:Hide(); self.entry:Show(); self.overlay:Hide()
            screen.minimap.lastpos=nil
        end
        function self:NewZone()
            self.draft={mode=self.draft.mode or "farm"}
            self.drawarmed=true; self.dragstart=nil
            self:Message("在地图空白处按住左键拖出区域；Esc 取消")
            self:Refresh()
        end
        function self:BeginDraw(x,z)
            self.dragstart={x=x,z=z}
            self.draft.bounds=OrderedBounds(x,z,x,z)
            screen.minimap.lastpos=nil
            if screen.SetHandleLmbUp then screen:SetHandleLmbUp(false) end
        end
        function self:UpdateDraw(x,z)
            if self.dragstart then
                self.draft.bounds=OrderedBounds(self.dragstart.x,self.dragstart.z,x,z)
                self:RefreshBounds()
            end
        end
        function self:EndDraw(x,z)
            if not self.dragstart then return end
            self:UpdateDraw(x,z)
            self.dragstart=nil; self.drawarmed=false
            local b=self.draft.bounds
            if b.x2-b.x1<4 or b.z2-b.z1<4 then
                self.draft.bounds=nil
                self:Message("区域太小，请点击“新建区域”后拖出更大的范围")
            elseif b.x2-b.x1>MAX_SIDE or b.z2-b.z1>MAX_SIDE then
                self.draft.bounds=nil
                self:Message("单边最多 160，请缩小后重新框选")
            else
                self:Message("区域已框选，勾选机器人并点击“应用工作区域”")
            end
            self:Refresh()
        end
        function self:SetMode(mode)
            if MODE_NAMES[mode] then self.draft.mode=mode; self:Refresh() end
        end
        function self:ToggleRobot(id)
            if self.selected[id] then self.selected[id]=nil
            elseif Count(self.selected)>=16 then self:Message("每个区域最多分配 16 台机器人"); return
            else self.selected[id]=true end
            for _,robot in ipairs(self.state.robots) do
                if robot.id==id then self:Message(RobotDescription(robot)); break end
            end
            self:Refresh()
        end
        function self:SelectAll()
            self.selected={}
            for i,robot in ipairs(self.state.robots) do
                if i>16 then break end
                self.selected[robot.id]=true
            end
            if #self.state.robots>16 then self:Message("已选前 16 台；可翻页调整选择") end
            self:Refresh()
        end
        function self:SelectZone(id)
            for _,zone in ipairs(self.state.zones) do
                if zone.id==id then
                    self.draft={id=zone.id,label=zone.label,mode=zone.mode,bounds=CopyBounds(zone.bounds)}
                    self.selected={}
                    for _,guid in ipairs(zone.robots or {}) do self.selected[guid]=true end
                    self.drawarmed=false; self.dragstart=nil
                    self:Message("已选区域；修改工作或机器人后点击应用")
                    self:Refresh()
                    return
                end
            end
        end
        function self:Apply()
            if not self.draft.bounds then self:Message("请先点击“新建区域”并在地图上框选"); return false end
            local robots={}
            for id in pairs(self.selected) do robots[#robots+1]=id end
            table.sort(robots)
            if #robots==0 then self:Message("请至少勾选一台机器人"); return false end
            return self:Send({op="save",id=self.draft.id,bounds=self.draft.bounds,mode=self.draft.mode,robots=robots,label=self.draft.label})
        end
        function self:ZoneOperation(op)
            if not self.draft.id then self:Message("请先点击下方已有区域"); return false end
            return self:Send({op=op,id=self.draft.id})
        end
        function self:Pause() return self:ZoneOperation("pause") end
        function self:Resume() return self:ZoneOperation("resume") end
        function self:Delete() return self:ZoneOperation("delete") end
        function self:SetState(state)
            self.state={robots=type(state.robots)=="table" and state.robots or {},zones=type(state.zones)=="table" and state.zones or {}}
            -- An already in-flight query can arrive before an apply response.
            -- Only the mutation response has a non-empty message.
            local waspending=self.pending and type(state.message)=="string" and state.message~=""
            if waspending then self.pending=false end
            if waspending then
                -- Follow the saved area after creating it, so pause/delete work immediately.
                if not self.draft.id and self.draft.bounds then
                    local b=self.draft.bounds
                    for _,zone in ipairs(self.state.zones) do
                        local z=zone.bounds
                        if z and math.abs(z.x1-b.x1)<.1 and math.abs(z.z1-b.z1)<.1
                            and math.abs(z.x2-b.x2)<.1 and math.abs(z.z2-b.z2)<.1 then
                            self.draft.id=zone.id; self.draft.label=zone.label
                        end
                    end
                elseif self.draft.id then
                    local exists=false
                    for _,zone in ipairs(self.state.zones) do if zone.id==self.draft.id then exists=true; break end end
                    if not exists then self.draft={mode=self.draft.mode or "farm"}; self.selected={} end
                end
            end
            -- Drop unloaded/deleted robots from the editable selection.
            local known={}
            for _,robot in ipairs(self.state.robots) do known[robot.id]=true end
            for id in pairs(self.selected) do if not known[id] then self.selected[id]=nil end end
            self:Refresh()
            if type(state.message)=="string" and state.message~="" then self:Message(state.message) end
        end
        function self:RefreshBounds()
            local b=self.draft.bounds
            if b then
                self.boundslabel:SetString(string.format("%s  %.0f × %.0f（最大 160 × 160）",self.draft.id and "区域 #"..self.draft.id or "新区域",b.x2-b.x1,b.z2-b.z1))
            else self.boundslabel:SetString(self.drawarmed and "等待拖拽框选…" or "尚未选择工作区域") end
        end
        function self:Refresh()
            self:RefreshBounds()
            for mode,button in pairs(self.modebuttons) do
                button.image:SetTint(mode==self.draft.mode and .22 or .14,mode==self.draft.mode and .44 or .20,mode==self.draft.mode and .31 or .22,1)
                ButtonText(button,(mode==self.draft.mode and "✓ " or "")..MODE_NAMES[mode])
            end
            self.robotheading:SetString("2  勾选机器人（"..Count(self.selected).." 台）")
            self.robotpage=math.min(self.robotpage,math.max(1,math.ceil(#self.state.robots/ROBOTS_PER_PAGE)))
            self.robotpage_label:SetString(self.robotpage.." / "..math.max(1,math.ceil(#self.state.robots/ROBOTS_PER_PAGE)))
            for i,button in ipairs(self.robotbuttons) do
                local robot=self.state.robots[(self.robotpage-1)*ROBOTS_PER_PAGE+i]
                if robot then
                    button:Show()
                    ButtonText(button,(self.selected[robot.id] and "✓ " or "")..RobotLabel(robot))
                    button.image:SetTint(self.selected[robot.id] and .22 or .14,self.selected[robot.id] and .40 or .20,.24,1)
                    button:SetHoverText(RobotDescription(robot),{font=G.UIFONT,size=18,offset_y=26})
                else button:Hide() end
            end
            ButtonText(self.applybutton,self.pending and "正在应用…" or self.draft.id and "更新区域 #"..self.draft.id or "应用工作区域")
            self.zonepage=math.min(self.zonepage,math.max(1,math.ceil(#self.state.zones/ZONES_PER_PAGE)))
            self.zonepage_label:SetString(self.zonepage.." / "..math.max(1,math.ceil(#self.state.zones/ZONES_PER_PAGE)))
            for i,button in ipairs(self.zonebuttons) do
                local zone=self.state.zones[(self.zonepage-1)*ZONES_PER_PAGE+i]
                if zone then
                    button:Show()
                    ButtonText(button,(self.draft.id==zone.id and "› " or "")..ShortLabel(zone.label,"区域 #"..zone.id,9).." · "..(MODE_NAMES[zone.mode] or "综合").." · "..#(zone.robots or {}).."台"..(zone.paused and " 暂停" or ""))
                else button:Hide() end
            end
        end
        function self:Layout()
            local w,h=G.TheSim:GetScreenSize()
            self.w,self.h=w,h
            self.scale=math.min(w/1280,h/720,1.5)
            self.root:SetPosition(12*self.scale,h-12*self.scale)
            self.root:SetScale(self.scale)
            self.overlay:SetPosition(w/2,h/2)
        end
        function self:Cursor()
            local pos=G.TheInput:GetScreenPosition()
            return pos.x,pos.y
        end
        function self:HitPanel(x,y)
            x,y=(x-12*self.scale)/self.scale,(y-(self.h-12*self.scale))/self.scale
            if self.open then return x>=0 and x<=WIDTH and y<=0 and y>=-HEIGHT end
            return x>=0 and x<=176 and y<=-1 and y>=-45
        end
        function self:HitButton(x,y)
            x,y=(x-12*self.scale)/self.scale,(y-(self.h-12*self.scale))/self.scale
            for _,button in ipairs(self.buttons) do
                if button:IsVisible() then
                    local r=button.wr_rect
                    if math.abs(x-r.x)<=r.w/2 and math.abs(y-r.y)<=r.h/2 then return button end
                end
            end
        end
        function self:WorldAtCursor()
            local x,y=self:Cursor()
            local wx,wz=screen.minimap:MapPosToWorldPos(2*x/self.w-1,2*y/self.h-1,0)
            return wx,wz
        end
        function self:RobotPosition(robot)
            local x,z=robot.x,robot.z
            local ent=G.Ents[robot.id]
            if ent and ent.Transform and ent:IsValid() then local y; x,y,z=ent.Transform:GetWorldPosition() end
            return x,z
        end
        function self:HitRobot(x,y)
            local closest, distance=nil,14*14
            for _,robot in ipairs(self.state.robots) do
                local wx,wz=self:RobotPosition(robot)
                if type(wx)=="number" and type(wz)=="number" then
                    local px,py=self:WorldToWidget(wx,wz)
                    local dx,dy=x-(px+self.w/2),y-(py+self.h/2)
                    local dsq=dx*dx+dy*dy
                    if dsq<distance then closest,distance=robot.id,dsq end
                end
            end
            return closest
        end
        function self:HandleControl(control,down)
            if self.open and (self.drawarmed or self.dragstart) and control==G.CONTROL_CANCEL then
                if not down then
                    self.drawarmed=false; self.dragstart=nil; self.capture=nil; self.draft.bounds=nil
                    self:Message("已取消框选，仍可拖动和缩放地图"); self:Refresh()
                end
                return true
            end
            if control==G.CONTROL_ACCEPT or control==G.CONTROL_PRIMARY then
                local x,y=self:Cursor()
                if down then
                    if self:HitPanel(x,y) then
                        self.capture="panel"; self.pressed=self:HitButton(x,y)
                        screen.minimap.lastpos=nil
                        return true
                    elseif self.open and self.drawarmed then
                        self.capture="draw"; self:BeginDraw(self:WorldAtCursor()); return true
                    elseif self.open then
                        local robot=self:HitRobot(x,y)
                        if robot then self.capture="robot"; self.pressedrobot=robot; return true end
                    end
                elseif self.capture then
                    local capture,pressed=self.capture,self.pressed
                    self.capture=nil; self.pressed=nil; screen.minimap.lastpos=nil
                    if capture=="panel" then
                        if pressed and self:HitButton(x,y)==pressed then pressed.wr_click() end
                    elseif capture=="draw" then self:EndDraw(self:WorldAtCursor())
                    elseif capture=="robot" and self:HitRobot(x,y)==self.pressedrobot then self:ToggleRobot(self.pressedrobot) end
                    self.pressedrobot=nil
                    return true
                elseif self:HitPanel(x,y) then return true end
            end
            if self.open and (control==G.CONTROL_SECONDARY) and (self.drawarmed or self.dragstart) then
                if not down then self.drawarmed=false; self.dragstart=nil; self.capture=nil; self.draft.bounds=nil; self:Refresh() end
                return true
            end
            return false
        end
        function self:BlocksMapDrag()
            local x,y=self:Cursor()
            return self.capture~=nil or (self.open and self.drawarmed) or self:HitPanel(x,y)
        end
        local function NewZoneVisual()
            local visual={lines={}}
            for i=1,4 do visual.lines[i]=Fill(self.overlay,0,0,1,1,{1,1,1,.9}) end
            visual.label=Label(self.overlay,"",0,0,17)
            return visual
        end
        function self:WorldToWidget(x,z)
            local mx,my=screen.minimap:WorldPosToMapPos(x,z,0)
            return mx*self.w*.5,my*self.h*.5
        end
        function self:DrawZone(visual,bounds,text,colour,selected)
            if not bounds then
                for _,line in ipairs(visual.lines) do line:Hide() end
                visual.label:Hide(); return
            end
            local x1,y1=self:WorldToWidget(bounds.x1,bounds.z1)
            local x2,y2=self:WorldToWidget(bounds.x2,bounds.z1)
            local x3,y3=self:WorldToWidget(bounds.x2,bounds.z2)
            local x4,y4=self:WorldToWidget(bounds.x1,bounds.z2)
            local corners={{x1,y1},{x2,y2},{x3,y3},{x4,y4}}
            for i,line in ipairs(visual.lines) do
                local a,b=corners[i],corners[i%4+1]
                local dx,dy=b[1]-a[1],b[2]-a[2]
                line:SetPosition((a[1]+b[1])/2,(a[2]+b[2])/2)
                line:SetSize(math.sqrt(dx*dx+dy*dy),selected and 3 or 2)
                line:SetRotation(-math.atan2(dy,dx)*180/math.pi)
                line:SetTint(colour[1],colour[2],colour[3],selected and 1 or .7)
                line:Show()
            end
            visual.label:SetPosition((x1+x3)/2,math.max(y1,y2,y3,y4)+13)
            visual.label:SetString(text)
            visual.label:SetColour(colour[1],colour[2],colour[3],1)
            visual.label:Show()
        end
        function self:DrawOverlay()
            for i,zone in ipairs(self.state.zones) do
                self.zonevisuals[i]=self.zonevisuals[i] or NewZoneVisual()
                if self.draft.id==zone.id then
                    self:DrawZone(self.zonevisuals[i])
                else
                    self:DrawZone(self.zonevisuals[i],zone.bounds,ShortLabel(zone.label,"区域 #"..zone.id,14).." · "..(MODE_NAMES[zone.mode] or "综合"),MODE_COLOURS[zone.mode] or MODE_COLOURS.auto,false)
                end
            end
            for i=#self.state.zones+1,#self.zonevisuals do self:DrawZone(self.zonevisuals[i]) end
            self.draftvisual=self.draftvisual or NewZoneVisual()
            local draftlabel=self.dragstart and "拖动框选中"
                or self.draft.id and ShortLabel(self.draft.label,"区域 #"..self.draft.id,14).." · "..(MODE_NAMES[self.draft.mode] or "综合")
                or "待应用区域"
            self:DrawZone(self.draftvisual,self.draft.bounds,draftlabel,{1,.92,.47},true)
            for i,robot in ipairs(self.state.robots) do
                local visual=self.robotvisuals[i]
                if not visual then
                    visual={dot=Fill(self.overlay,0,0,9,9,{.8,1,.85,1}),label=Label(self.overlay,"",0,0,16)}
                    self.robotvisuals[i]=visual
                end
                -- Use replicated entities when present; server snapshots cover farther loaded bots.
                local x,z=self:RobotPosition(robot)
                if type(x)=="number" and type(z)=="number" then
                    local px,py=self:WorldToWidget(x,z)
                    visual.dot:SetPosition(px,py); visual.dot:SetSize(self.selected[robot.id] and 12 or 8,self.selected[robot.id] and 12 or 8)
                    if robot.broken then visual.dot:SetTint(1,.35,.28,1)
                    elseif robot.paused or robot.sleeping then visual.dot:SetTint(.7,.7,.68,1)
                    else visual.dot:SetTint(.42,1,.68,1) end
                    visual.label:SetPosition(px,py-15); visual.label:SetString(RobotLabel(robot))
                    visual.dot:Show(); visual.label:Show()
                else visual.dot:Hide(); visual.label:Hide() end
            end
            for i=#self.state.robots+1,#self.robotvisuals do self.robotvisuals[i].dot:Hide(); self.robotvisuals[i].label:Hide() end
        end
        function self:Update(dt)
            local w,h=G.TheSim:GetScreenSize()
            if w~=self.w or h~=self.h then self:Layout() end
            if not self.open then return end
            if self.dragstart then self:UpdateDraw(self:WorldAtCursor()) end
            self:DrawOverlay()
            self.elapsed=self.elapsed+dt
            if self.elapsed>=4 and not self.pending then self.elapsed=0; self:Query() end
            if self.pending then
                self.pendingtime=(self.pendingtime or 0)+dt
                if self.pendingtime>8 then self.pending=false; self:Refresh(); self:Message("服务器尚未响应；请刷新后确认区域状态") end
            end
        end

        local original_control=screen.OnControl
        screen.OnControl=function(map,control,down)
            if self:HandleControl(control,down) then return true end
            return original_control(map,control,down)
        end
        local original_mouse=screen.OnMouseButton
        screen.OnMouseButton=function(map,button,down,x,y)
            if self:HitPanel(x,y) or self.capture or (self.open and self.drawarmed) then return true end
            return original_mouse(map,button,down,x,y)
        end
        local original_mapupdate=screen.minimap.OnUpdate
        screen.minimap.OnUpdate=function(map,dt)
            if self:BlocksMapDrag() then map.lastpos=nil; return end
            return original_mapupdate(map,dt)
        end
        local original_update=screen.OnUpdate
        screen.OnUpdate=function(map,dt)
            -- Prevent camera panning/zooming changing the projection mid-stroke.
            if not self.dragstart then original_update(map,dt) end
            self:Update(dt)
        end
        local original_destroy=screen.OnDestroy
        screen.OnDestroy=function(map,...)
            if active==self then active=nil end
            return original_destroy(map,...)
        end
        self:Layout(); self:Refresh()
    end
    env.AddClassPostConstruct("screens/mapscreen",Build)
end
