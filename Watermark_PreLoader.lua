-- Watermark_PreLoader.lua  (v10)
return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local isMobile   = UIS.TouchEnabled and not UIS.KeyboardEnabled

    local function lerp(a,b,t) return a+(b-a)*t end
    local function rand(a,b)   return a+math.random()*(b-a) end
    local function clamp(v,a,b) return math.max(a,math.min(b,v)) end

    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ResetOnSpawn=false; g.DisplayOrder=9998
        g.IgnoreGuiInset=true; g.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
        local ok
        if gethui then ok=pcall(function() g.Parent=gethui() end) end
        if not ok or not g.Parent then ok=pcall(function() g.Parent=game:GetService("CoreGui") end) end
        if not ok or not g.Parent then g.Parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end
        return g
    end



    function MacLib:Watermark(cfg)
        cfg=cfg or {}
        local titleText    = cfg.Title         or "Watermark"
        local showFPS      = cfg.ShowFPS       ~= false
        local showTime     = cfg.ShowTime      ~= false
        local dragEnabled_ = cfg.Drag          ~= nil and cfg.Drag or (not isMobile)
        local pColor1      = cfg.ParticleColor1 or Color3.fromRGB(72,138,255)
        local pColor2      = cfg.ParticleColor2 or Color3.fromRGB(140,90,255)
        local pCount       = cfg.ParticleCount  or 9
        local pConnDist    = cfg.ConnectDist    or 58
        local pYOffset     = cfg.ParticleYOffset or 0   -- debug Y correction
        local pSpeedNear   = 18
        local pSpeedFar    = 5
        local orbitEnabled = cfg.OrbitEnabled  ~= false   -- outline orbit
        local orbitSegs    = cfg.OrbitSegments  or 32
        local logoCount    = cfg.LogoDotCount   or 10
        local planeMode    = cfg.PlaneMode      or false  -- 3D plane animation

        local posX,posY=134,22
        if cfg.Position then
            if typeof(cfg.Position)=="UDim2" then posX=cfg.Position.X.Offset;posY=cfg.Position.Y.Offset
            elseif typeof(cfg.Position)=="Vector2" then posX=cfg.Position.X;posY=cfg.Position.Y end
        end

        -- ── GUI root ──────────────────────────────────────────────────
        local gui=GetGui(); gui.Name="MacLibWatermark"

        local anchor=Instance.new("Frame")
        anchor.Name="WmAnchor"; anchor.BackgroundTransparency=1
        anchor.BorderSizePixel=0; anchor.AutomaticSize=Enum.AutomaticSize.XY
        anchor.AnchorPoint=Vector2.new(0,0)
        anchor.Position=UDim2.fromOffset(posX,posY); anchor.Parent=gui

        local uiScale=Instance.new("UIScale"); uiScale.Scale=0.80; uiScale.Parent=anchor

        local row=Instance.new("Frame")
        row.Name="Row"; row.BackgroundTransparency=1; row.BorderSizePixel=0
        row.AutomaticSize=Enum.AutomaticSize.XY; row.Parent=anchor
        local rl=Instance.new("UIListLayout")
        rl.FillDirection=Enum.FillDirection.Horizontal
        rl.VerticalAlignment=Enum.VerticalAlignment.Center
        rl.SortOrder=Enum.SortOrder.LayoutOrder
        rl.Padding=UDim.new(0,5); rl.Parent=row

        -- tokens
        local BAR_H=26; local LOGO_SZ=32; local SEG_SZ=13
        local TXT_SZ=12; local ICON_SZ=12; local PAD_X=10
        local FT=Font.new("rbxasset://fonts/families/GothamSSm.json",Enum.FontWeight.SemiBold)
        local FB=Font.new("rbxasset://fonts/families/GothamSSm.json",Enum.FontWeight.Medium)
        local C_DARK=Color3.fromRGB(12,12,19); local C_CHIP=Color3.fromRGB(10,10,16)
        local C_STR=Color3.fromRGB(42,42,62); local C_TM=Color3.fromRGB(215,215,230)
        local C_MU=Color3.fromRGB(130,130,155); local BG_T=0.28

        -- chip factory
        local chipOrd=0; local allChips={}
        local function makeChip(o)
            chipOrd+=1; o=o or {}; local h=o.h or BAR_H
            local f=Instance.new("Frame")
            f.Name="Chip"..chipOrd; f.BackgroundColor3=o.bg or C_CHIP
            f.BackgroundTransparency=BG_T; f.BorderSizePixel=0
            f.LayoutOrder=chipOrd; f.ClipsDescendants=true
            if o.fixedW then f.AutomaticSize=Enum.AutomaticSize.None; f.Size=UDim2.fromOffset(o.fixedW,h)
            else f.AutomaticSize=Enum.AutomaticSize.X; f.Size=UDim2.fromOffset(0,h) end
            f.Parent=row
            local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,o.radius or 7); c.Parent=f
            local st=nil
            if o.stroke then st=Instance.new("UIStroke"); st.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
                st.Color=C_STR; st.Transparency=0; st.Thickness=1; st.Parent=f end
            if o.padX~=false then
                local p=Instance.new("UIPadding")
                p.PaddingLeft=UDim.new(0,o.padX or PAD_X); p.PaddingRight=UDim.new(0,o.padX or PAD_X); p.Parent=f end
            local e={frame=f,stroke=st,labels={},images={}}; table.insert(allChips,e); return e
        end

        -- ── Logo chip ──────────────────────────────────────────────
        local logoEntry=makeChip({bg=C_DARK,fixedW=LOGO_SZ,h=LOGO_SZ,radius=9,stroke=false,padX=false})
        local logoHolder=Instance.new("Frame")
        logoHolder.Name="LogoHolder"; logoHolder.AnchorPoint=Vector2.new(0.5,0.5)
        logoHolder.Position=UDim2.new(0.5,0,0.5,0); logoHolder.Size=UDim2.fromOffset(SEG_SZ,SEG_SZ)
        logoHolder.BackgroundTransparency=1; logoHolder.BorderSizePixel=0; logoHolder.Parent=logoEntry.frame

        local DOT_SZ=3; local logoSegs={}
        local logoAngleTg=0; local logoAngleSm=0

        local function buildLogoDots(n)
            for _,s in ipairs(logoSegs) do s.dot:Destroy() end; logoSegs={}
            for i=1,n do
                local dot=Instance.new("Frame")
                dot.Size=UDim2.fromOffset(DOT_SZ,DOT_SZ); dot.AnchorPoint=Vector2.new(0.5,0.5)
                dot.Position=UDim2.new(0.5,0,0.5,0); dot.BackgroundColor3=pColor1
                dot.BackgroundTransparency=0.2; dot.BorderSizePixel=0; dot.ZIndex=3; dot.Parent=logoHolder
                Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)
                table.insert(logoSegs,{dot=dot,idx=i})
            end
        end
        buildLogoDots(logoCount)

        -- ── Title chip ─────────────────────────────────────────────
        local titleEntry=makeChip({bg=C_DARK,stroke=true})
        local titleLbl=Instance.new("TextLabel")
        titleLbl.FontFace=FT; titleLbl.TextSize=TXT_SZ; titleLbl.TextColor3=C_TM
        titleLbl.BackgroundTransparency=1; titleLbl.BorderSizePixel=0
        titleLbl.AutomaticSize=Enum.AutomaticSize.X; titleLbl.Size=UDim2.fromOffset(0,BAR_H)
        titleLbl.TextXAlignment=Enum.TextXAlignment.Left; titleLbl.Text=titleText
        titleLbl.ZIndex=3; titleLbl.Parent=titleEntry.frame
        table.insert(titleEntry.labels,titleLbl)
        local accentLine=Instance.new("Frame")
        accentLine.Name="AL"; accentLine.BackgroundColor3=pColor1
        accentLine.BackgroundTransparency=0; accentLine.BorderSizePixel=0
        accentLine.ZIndex=6; accentLine.Size=UDim2.fromOffset(40,1)
        accentLine.Position=UDim2.fromOffset(0,BAR_H-3); accentLine.Parent=titleEntry.frame

        -- ── FPS chip ───────────────────────────────────────────────
        local fpsEntry,fpsLbl
        if showFPS then
            fpsEntry=makeChip({fixedW=76,stroke=true,padX=false})
            local inn=Instance.new("Frame"); inn.BackgroundTransparency=1; inn.BorderSizePixel=0
            inn.AnchorPoint=Vector2.new(0.5,0.5); inn.Position=UDim2.new(0.5,0,0.5,0)
            inn.AutomaticSize=Enum.AutomaticSize.XY; inn.Parent=fpsEntry.frame
            local il=Instance.new("UIListLayout"); il.FillDirection=Enum.FillDirection.Horizontal
            il.VerticalAlignment=Enum.VerticalAlignment.Center; il.Padding=UDim.new(0,4); il.Parent=inn
            local ic=Instance.new("ImageLabel"); ic.Image="rbxassetid://102994395432803"
            ic.Size=UDim2.fromOffset(ICON_SZ,ICON_SZ); ic.BackgroundTransparency=1
            ic.BorderSizePixel=0; ic.ZIndex=3; ic.Parent=inn; table.insert(fpsEntry.images,ic)
            fpsLbl=Instance.new("TextLabel"); fpsLbl.FontFace=FB; fpsLbl.TextSize=TXT_SZ
            fpsLbl.TextColor3=C_MU; fpsLbl.BackgroundTransparency=1; fpsLbl.BorderSizePixel=0
            fpsLbl.AutomaticSize=Enum.AutomaticSize.X; fpsLbl.Size=UDim2.fromOffset(0,BAR_H)
            fpsLbl.TextXAlignment=Enum.TextXAlignment.Center; fpsLbl.Text="--"
            fpsLbl.ZIndex=3; fpsLbl.Parent=inn; table.insert(fpsEntry.labels,fpsLbl)
        end

        -- ── Time chip ──────────────────────────────────────────────
        local timeEntry,timeLbl
        if showTime then
            timeEntry=makeChip({fixedW=90,stroke=true,padX=false})
            local inn=Instance.new("Frame"); inn.BackgroundTransparency=1; inn.BorderSizePixel=0
            inn.AnchorPoint=Vector2.new(0.5,0.5); inn.Position=UDim2.new(0.5,0,0.5,0)
            inn.AutomaticSize=Enum.AutomaticSize.XY; inn.Parent=timeEntry.frame
            local il=Instance.new("UIListLayout"); il.FillDirection=Enum.FillDirection.Horizontal
            il.VerticalAlignment=Enum.VerticalAlignment.Center; il.Padding=UDim.new(0,4); il.Parent=inn
            local ic=Instance.new("ImageLabel"); ic.Image="rbxassetid://17824308575"
            ic.Size=UDim2.fromOffset(ICON_SZ,ICON_SZ); ic.BackgroundTransparency=1
            ic.BorderSizePixel=0; ic.ZIndex=3; ic.Parent=inn; table.insert(timeEntry.images,ic)
            timeLbl=Instance.new("TextLabel"); timeLbl.FontFace=FB; timeLbl.TextSize=TXT_SZ
            timeLbl.TextColor3=C_MU; timeLbl.BackgroundTransparency=1; timeLbl.BorderSizePixel=0
            timeLbl.AutomaticSize=Enum.AutomaticSize.XY; timeLbl.Size=UDim2.fromOffset(0,BAR_H)
            timeLbl.TextXAlignment=Enum.TextXAlignment.Center; timeLbl.Text="00:00"
            timeLbl.ZIndex=3; timeLbl.Parent=inn; table.insert(timeEntry.labels,timeLbl)
        end

        -- ══════════════════════════════════════════════════════════════
        -- DRAWING (particles + orbit lines)
        -- Drawing.Transparency: 0=invisible, 1=opaque
        -- Drawing.Position: screen pixels (matches AbsolutePosition exactly)
        --
        -- PARTICLE POSITION FIX:
        -- We read AbsolutePosition ONCE after init and store it.
        -- On each tick we re-read and detect drift (drag movement).
        -- When bounds move we TRANSLATE particles instead of clamping,
        -- which prevents them bunching at edges.
        -- ══════════════════════════════════════════════════════════════
        local drawObjs={}
        local function D(t) local d=Drawing.new(t); d.Visible=true; table.insert(drawObjs,d); return d end

        local globalTime=0; local globalT=0

        local function getCol(t,z)
            local r=math.round(lerp(pColor1.R*255,pColor2.R*255,t))
            local g=math.round(lerp(pColor1.G*255,pColor2.G*255,t))
            local b=math.round(lerp(pColor1.B*255,pColor2.B*255,t))
            local br=lerp(0.75,1.0,z)
            return Color3.fromRGB(clamp(math.round(r*br),0,255),clamp(math.round(g*br),0,255),clamp(math.round(b*br),0,255))
        end

        -- ── Orbit (outline ring around logo) ───────────────────────
        local orbitLines={}
        local orbitAngleTg=0; local orbitAngleSm=0
        if orbitEnabled then
            for i=1,orbitSegs do
                local l=D("Line"); l.Thickness=0.8; l.Color=Color3.fromRGB(90,150,255)
                l.Transparency=0; l.ZIndex=7; orbitLines[i]=l
            end
        end

        -- ── Particle systems ───────────────────────────────────────
        local function buildSys(n)
            local pts={}
            for i=1,n do
                local p={x=0,y=0,vx=0,vy=0,z=rand(0,1),ph=rand(0,math.pi*2),dot=D("Circle")}
                p.dot.Filled=true; p.dot.Color=pColor1; p.dot.Radius=1
                p.dot.Transparency=0; p.dot.NumSides=12; p.dot.ZIndex=9; pts[i]=p
            end
            local lines={}
            for i=1,n do lines[i]={}
                for j=i+1,n do
                    local l=D("Line"); l.Thickness=1; l.Color=pColor1; l.Transparency=0; l.ZIndex=8; lines[i][j]=l
                end
            end
            return {pts=pts,lines=lines,ready=false,n=n,bx=0,by=0,bw=0,bh=0}
        end

        local function initSys(sys,ax,ay,aw,ah)
            for _,p in ipairs(sys.pts) do
                p.x=rand(ax+6,ax+aw-6); p.y=rand(ay+4,ay+ah-4)
                local spd=lerp(pSpeedFar,pSpeedNear,p.z)
                local a=rand(0,math.pi*2); p.vx=math.cos(a)*spd; p.vy=math.sin(a)*spd
            end
            sys.ready=true; sys.bx=ax; sys.by=ay; sys.bw=aw; sys.bh=ah
        end

        local function tickSys(sys,dt,ax,ay,aw,ah,gA)
            if not sys.ready then return end
            -- TRANSLATE on boundary move (smooth drag follow)
            local dx=ax-sys.bx; local dy=ay-sys.by
            if math.abs(dx)>0.5 or math.abs(dy)>0.5 then
                for _,p in ipairs(sys.pts) do p.x+=dx; p.y+=dy end
                sys.bx=ax; sys.by=ay; sys.bw=aw; sys.bh=ah
            end
            local pts=sys.pts
            for _,p in ipairs(pts) do
                p.x+=p.vx*dt; p.y+=p.vy*dt
                -- elastic bounce (not hard clamp)
                local m=3
                if p.x<ax+m    then p.x=ax+m;    p.vx= math.abs(p.vx)+rand(0,1) end
                if p.x>ax+aw-m then p.x=ax+aw-m; p.vx=-(math.abs(p.vx)+rand(0,1)) end
                if p.y<ay+m    then p.y=ay+m;    p.vy= math.abs(p.vy)+rand(0,1) end
                if p.y>ay+ah-m then p.y=ay+ah-m; p.vy=-(math.abs(p.vy)+rand(0,1)) end
                -- speed regulation
                local tspd=lerp(pSpeedFar,pSpeedNear,p.z)*(0.88+0.12*math.sin(globalTime*1.1+p.ph))
                local cs=math.sqrt(p.vx^2+p.vy^2)
                if cs>0.1 then local sc=lerp(1,tspd/cs,dt*3); p.vx*=sc; p.vy*=sc end

                local r=lerp(0.8,2.2,p.z)*(0.88+0.12*math.sin(globalTime*1.8+p.ph))
                local pT=(globalT+p.ph/(math.pi*2)*0.3)%1
                p.dot.Position=Vector2.new(p.x, p.y+pYOffset)
                p.dot.Radius=r; p.dot.Transparency=lerp(0.18,0.60,p.z)*gA
                p.dot.Color=getCol(pT,p.z)
            end
            for i=1,#pts do for j=i+1,#pts do
                local pi,pj=pts[i],pts[j]
                local dist=math.sqrt((pi.x-pj.x)^2+(pi.y-pj.y)^2)
                local l=sys.lines[i][j]
                if dist<pConnDist then
                    local prx=1-dist/pConnDist; local avgZ=(pi.z+pj.z)*0.5
                    l.From=Vector2.new(pi.x,pi.y+pYOffset); l.To=Vector2.new(pj.x,pj.y+pYOffset)
                    l.Transparency=lerp(0.05,0.35,prx)*lerp(0.35,1,avgZ)*gA
                    l.Thickness=lerp(0.4,1.2,avgZ); l.Color=getCol(globalT,avgZ)
                else l.Transparency=0 end
            end end
        end

        local entryToSys={}
        entryToSys[titleEntry]=buildSys(pCount)
        if fpsEntry  then entryToSys[fpsEntry] =buildSys(pCount) end
        if timeEntry then entryToSys[timeEntry]=buildSys(pCount) end

        -- Deferred init: poll until AbsoluteSize is valid
        task.spawn(function()
            for attempt=1,60 do
                task.wait(0.05)
                local all=true
                for entry,sys in pairs(entryToSys) do
                    if not sys.ready then
                        local ap=entry.frame.AbsolutePosition
                        local as=entry.frame.AbsoluteSize
                        if as.X>8 and as.Y>4 then
                            initSys(sys,ap.X,ap.Y,as.X,as.Y)
                        else all=false end
                    end
                end
                if all then break end
            end
        end)

        -- ── Spring animation ───────────────────────────────────────
        local springP=0; local springV=0; local targetA=1
        local SK=120; local SD=17

        -- Position spring (shared for drag AND preset moves)
        local curX=posX; local curY=posY
        local tgtX=posX; local tgtY=posY
        local POS_K=200; local POS_D=22  -- slightly overdamped for fast settle

        local isDragging=false
        local dragSMouse=Vector2.new(0,0); local dragSAnchor=Vector2.new(posX,posY)
        local dragInputConns={}

        local accentPh=0
        local FPS_N=30; local fpsBuf=table.create(FPS_N,1/60); local fpsBufI=1
        local fpsTimer=0; local lastMin=-1

        local function applyProgress(p)
            uiScale.Scale=lerp(0.80,1.0,p)
            local bgT=lerp(1,BG_T,p); local txtT=lerp(1,0,p); local strT=lerp(1,0,p)
            for _,e in ipairs(allChips) do
                e.frame.BackgroundTransparency=bgT
                if e.stroke then e.stroke.Transparency=strT end
                for _,l in ipairs(e.labels) do l.TextTransparency=txtT end
                for _,i in ipairs(e.images) do i.ImageTransparency=txtT end
            end
            for _,s in ipairs(logoSegs) do s.dot.BackgroundTransparency=lerp(1,0.15,p) end
            accentLine.BackgroundTransparency=lerp(1,0,p)
            if p<0.02 then for _,d in ipairs(drawObjs) do d.Transparency=0 end end
        end

        local conns={}

        -- RenderStepped: logo + orbit (smooth 60fps)
        table.insert(conns,RunService.RenderStepped:Connect(function(dt)
            local n=#logoSegs
            if n==0 then return end
            -- logo smooth rotation
            logoAngleTg+=dt*22
            logoAngleSm+=( logoAngleTg-logoAngleSm)*(1-math.exp(-dt*9))
            -- orbit smooth (opposite direction, slower)
            orbitAngleTg-=dt*12
            orbitAngleSm+=(orbitAngleTg-orbitAngleSm)*(1-math.exp(-dt*8))

            local pulse=0.88+0.12*math.sin(globalTime*1.4)

            for i,s in ipairs(logoSegs) do
                local base=math.rad((i-1)*(360/n))+math.rad(logoAngleSm)
                local r=SEG_SZ/2*pulse
                local dx,dy
                if planeMode then
                    -- 3D plane: dots oscillate in Z giving depth illusion
                    local tilt=math.sin(globalTime*0.7+(i-1)*(math.pi*2/n))*0.45
                    dx=math.cos(base)*r
                    dy=math.sin(base)*r*(1-math.abs(tilt)*0.6)
                    -- size varies with depth
                    local scale=0.7+0.3*(1-math.abs(tilt))
                    s.dot.Size=UDim2.fromOffset(math.round(DOT_SZ*scale+0.5),math.round(DOT_SZ*scale+0.5))
                    s.dot.BackgroundTransparency=lerp(0.15,0.55,math.abs(tilt))
                else
                    dx=math.cos(base)*r; dy=math.sin(base)*r
                    s.dot.Size=UDim2.fromOffset(DOT_SZ,DOT_SZ)
                end
                s.dot.Position=UDim2.new(0.5,math.round(dx),0.5,math.round(dy))
                s.dot.BackgroundColor3=getCol((globalT+(i-1)/n*0.25)%1,(i-1)/n)
            end

            -- orbit ring (Drawing) — needs screen coords of logoHolder
            if orbitEnabled and #orbitLines>0 then
                local lh=logoHolder
                local ap=lh.AbsolutePosition; local as=lh.AbsoluteSize
                local cx=ap.X+as.X/2; local cy=ap.Y+as.Y/2
                -- orbit radius = a bit larger than SEG_SZ/2
                local OR=SEG_SZ/2+5
                local seg=#orbitLines
                for i=1,seg do
                    local a1=math.rad((i-1)*(360/seg))+math.rad(orbitAngleSm*0.5)
                    local a2=math.rad(i*(360/seg))+math.rad(orbitAngleSm*0.5)
                    local l=orbitLines[i]
                    l.From=Vector2.new(cx+math.cos(a1)*OR, cy+math.sin(a1)*OR+pYOffset)
                    l.To  =Vector2.new(cx+math.cos(a2)*OR, cy+math.sin(a2)*OR+pYOffset)
                    l.Transparency=lerp(0.12,0.28,springP)
                    l.Color=getCol((globalT+i/seg*0.15)%1,0.5)
                end
            end
        end))

        -- Heartbeat: spring, particles, fps, time
        table.insert(conns,RunService.Heartbeat:Connect(function(dt)
            globalTime+=dt
            globalT=(math.sin(globalTime*0.39)+1)*0.5

            -- alpha spring
            local af=SK*(targetA-springP)-SD*springV
            springV+=af*dt; springP=clamp(springP+springV*dt,0,1)
            if math.abs(springP-targetA)<0.003 and math.abs(springV)<0.003 then springP=targetA;springV=0 end
            applyProgress(springP); gui.Enabled=springP>0.008

            -- position spring (drives drag AND preset teleports)
            local pxf=POS_K*(tgtX-curX)-POS_D*math.sqrt(POS_K)*(curX-tgtX)*0   -- simplified
            -- use critically-damped lerp for position (feels snappy but smooth)
            curX=lerp(curX,tgtX,clamp(dt*DRAG_SPRING,0,1))
            curY=lerp(curY,tgtY,clamp(dt*DRAG_SPRING,0,1))
            anchor.Position=UDim2.fromOffset(math.round(curX),math.round(curY))

            -- accent underline
            accentPh=(accentPh+dt*0.6)%(math.pi*2)
            accentLine.BackgroundColor3=getCol((math.sin(accentPh)+1)*0.5,0.5)
            local ts=titleLbl.AbsoluteSize
            if ts.X>0 then accentLine.Size=UDim2.fromOffset(ts.X,1); accentLine.Position=UDim2.fromOffset(0,BAR_H-3) end

            -- particles
            if springP>0.03 then
                for entry,sys in pairs(entryToSys) do
                    if sys.ready then
                        local ap=entry.frame.AbsolutePosition; local as=entry.frame.AbsoluteSize
                        if as.X>8 then tickSys(sys,dt,ap.X,ap.Y,as.X,as.Y,springP) end
                    end
                end
            end

            -- FPS
            if fpsLbl then
                fpsBuf[fpsBufI]=dt; fpsBufI=(fpsBufI%FPS_N)+1; fpsTimer+=dt
                if fpsTimer>=0.25 then fpsTimer=0
                    local s=0 for i=1,FPS_N do s+=fpsBuf[i] end
                    fpsLbl.Text=tostring(s>0 and math.round(FPS_N/s) or 0) end
            end
            if timeLbl then
                local now=os.time(); local cm=math.floor(now/60)
                if cm~=lastMin then lastMin=cm
                    timeLbl.Text=string.format("%02d:%02d",math.floor(now/3600)%24,cm%60) end
            end
        end))

        -- Drag input
        local DRAG_SPRING=18   -- referenced in heartbeat above
        local function setupDrag()
            local function gmp() local m=UIS:GetMouseLocation(); return Vector2.new(m.X,m.Y) end
            table.insert(dragInputConns,row.InputBegan:Connect(function(inp)
                if not dragEnabled_ then return end
                if inp.UserInputType==Enum.UserInputType.MouseButton1 or inp.UserInputType==Enum.UserInputType.Touch then
                    isDragging=true; dragSMouse=gmp(); dragSAnchor=Vector2.new(tgtX,tgtY) end
            end))
            table.insert(dragInputConns,UIS.InputChanged:Connect(function(inp)
                if not isDragging or not dragEnabled_ then return end
                if inp.UserInputType==Enum.UserInputType.MouseMovement or inp.UserInputType==Enum.UserInputType.Touch then
                    local c=gmp(); tgtX=dragSAnchor.X+(c.X-dragSMouse.X); tgtY=dragSAnchor.Y+(c.Y-dragSMouse.Y) end
            end))
            table.insert(dragInputConns,UIS.InputEnded:Connect(function(inp)
                if inp.UserInputType==Enum.UserInputType.MouseButton1 or inp.UserInputType==Enum.UserInputType.Touch then isDragging=false end
            end))
        end
        setupDrag()
        applyProgress(0); targetA=1

        -- ── Position helpers (all animated via spring) ─────────────
        local MARGIN=22
        local function setPos(x,y) tgtX=x; tgtY=y end
        local function waitSetPos(fn)
            task.spawn(function() task.wait(0.05); fn() end)
        end

        local function rebuildParticles(n,cd)
            for _,d in ipairs(drawObjs) do
                -- only remove particle dots/lines, not orbit
                pcall(function() d:Remove() end)
            end
            drawObjs={}
            -- rebuild orbit lines
            if orbitEnabled then
                for i=1,orbitSegs do
                    local l=D("Line"); l.Thickness=0.8; l.Color=Color3.fromRGB(90,150,255)
                    l.Transparency=0; l.ZIndex=7; orbitLines[i]=l
                end
            end
            pCount=n; pConnDist=cd or pConnDist
            entryToSys={}
            entryToSys[titleEntry]=buildSys(n)
            if fpsEntry  then entryToSys[fpsEntry] =buildSys(n) end
            if timeEntry then entryToSys[timeEntry]=buildSys(n) end
            task.spawn(function()
                for _=1,60 do task.wait(0.05)
                    local all=true
                    for entry,sys in pairs(entryToSys) do
                        if not sys.ready then
                            local ap=entry.frame.AbsolutePosition; local as=entry.frame.AbsoluteSize
                            if as.X>8 then initSys(sys,ap.X,ap.Y,as.X,as.Y) else all=false end
                        end
                    end
                    if all then break end
                end
            end)
        end

        -- ── Public API ─────────────────────────────────────────────
        local WM={}
        function WM:Show()      targetA=1 end
        function WM:Hide()      targetA=0 end
        function WM:Toggle()    if targetA>0.5 then self:Hide() else self:Show() end end
        function WM:IsVisible() return targetA>0.5 end
        function WM:SetTitle(t) titleText=t; titleLbl.Text=t end
        function WM:SetPosition(pos)
            if typeof(pos)=="UDim2" then setPos(pos.X.Offset,pos.Y.Offset)
            elseif typeof(pos)=="Vector2" then setPos(pos.X,pos.Y) end
        end
        function WM:MoveTopLeft()
            waitSetPos(function() setPos(134,MARGIN) end)
        end
        function WM:MoveTopRight()
            waitSetPos(function()
                local vp=workspace.CurrentCamera.ViewportSize
                setPos(vp.X-row.AbsoluteSize.X-MARGIN, 30)
            end)
        end
        function WM:MoveBottomLeft()
            waitSetPos(function()
                local vp=workspace.CurrentCamera.ViewportSize
                setPos(120, vp.Y-row.AbsoluteSize.Y-MARGIN)
            end)
        end
        function WM:SetDrag(state)
            dragEnabled_=state
            if not state then
                isDragging=false
                self:MoveTopRight()
            end
        end
        function WM:IsDragEnabled() return dragEnabled_ end
        function WM:SetParticleColors(c1,c2)
            if c1 then pColor1=c1 end; if c2 then pColor2=c2 end
        end
        function WM:SetParticleCount(n,cd) rebuildParticles(math.clamp(math.round(n),2,30),cd) end
        function WM:SetConnectDist(d)  pConnDist=d end
        function WM:SetParticleSpeed(nr,fr) if nr then pSpeedNear=nr end; if fr then pSpeedFar=fr end end
        function WM:SetParticleYOffset(v) pYOffset=v end
        function WM:SetOrbitEnabled(v)
            orbitEnabled=v
            for _,l in ipairs(orbitLines) do l.Transparency=0 end
        end
        function WM:SetOrbitSegments(n)
            orbitSegs=n
            for _,l in ipairs(orbitLines) do pcall(function() l:Remove() end) end
            orbitLines={}
            if orbitEnabled then
                for i=1,n do
                    local l=D("Line"); l.Thickness=0.8; l.Color=Color3.fromRGB(90,150,255)
                    l.Transparency=0; l.ZIndex=7; orbitLines[i]=l
                end
            end
        end
        function WM:SetLogoDotCount(n)
            logoCount=n; buildLogoDots(n)
        end
        function WM:SetPlaneMode(v) planeMode=v end
        function WM:Destroy()
            for _,c in ipairs(conns) do c:Disconnect() end
            for _,c in ipairs(dragInputConns) do c:Disconnect() end
            for _,d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            gui:Destroy()
        end
        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
