-- 住房实景验收：资金与读写均为内存桩，生产门口/床边/出门入口实际执行。
local Store=require("Career.Store")
local Data=require("Career.HousingData")
local Progress=require("Career.Progression")
local Property=require("Career.Property")
local HousingActions=require("Career.HousingActions")
local Config=require("Career.Config")
local Delivery=require("Career.Delivery")
local Checks={}
local function clickText(view,text)
    local UI=require("urhox-libs/UI")
    local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
    local function find(widget)
        if widget.props.text==text and widget.props.onClick then return widget end
        for _,child in ipairs(widget:GetChildren()) do local found=find(child); if found then return found end end
    end
    UI.Layout()
    local widget=assert(find(view.dialogBody),"缺少确认按钮："..text)
    local r=widget:GetAbsoluteLayout()
    local scale=UI.GetScale()
    local data={pointerId=780001,pointerType="touch",x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left}
    UI.HandlePointerEvent(PointerEvent.new("PointerDown",data))
    UI.HandlePointerEvent(PointerEvent.new("PointerUp",data))
end
local function walk(actor,x,z)
    for _=1,300 do
        local dx,dz=x-actor.x,z-actor.z
        local len=math.sqrt(dx*dx+dz*dz)
        if len<.12 then actor:Update(.1,{walkX=0,walkY=0},0); return end
        actor:Update(.05,{walkX=dx/len,walkY=dz/len},0)
    end
    error("室内通道被家具挡住")
end
-- 无场景/无UI依赖的隔离事务测试；只用内存文件表，禁止真实File及云接口。
function Checks.RunProperty()
    local files={}
    local failWrite=false
    local writes=0
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~="table" then return a==b end
        for k,v in pairs(a) do if not same(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end
        return true
    end
    local function grant(cents,key)
        assert(Store.Transaction(function(p) return Store.ApplyCash(p,cents,"test_fixture",key) end))
    end
    local function unchanged(before,text,count)
        assert(same(before,Store.Get()),"失败或重复操作改变了内存存档")
        assert(files[Config.SAVE_PATH]==text and writes==count,"失败或重复操作不应写入新档")
    end
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text)
            if failWrite then return false,"房产验收模拟写失败" end
            writes=writes+1; files[path]=text; return true
        end,
        cloud={Set=function() error("房产验收禁止调用云保存") end,Get=function() error("房产验收禁止读取云档") end},
    },function()
        assert(Store.NewCareer())
        assert(next(Store.Get().ownedHomes)==nil)
        local legacy=Store.Get()
        legacy.ownedHomes=nil; legacy.accommodation="apartment"
        legacy.flags.stayed_room=true; legacy.flags.stayed_apartment=true; legacy.flags.roomStory=true
        files[Config.SAVE_PATH]=cjson.encode(legacy)
        local legacyText,count=files[Config.SAVE_PATH],writes
        local normalized=Store.Normalize(legacy)
        assert(legacy.ownedHomes==nil and next(normalized.ownedHomes)==nil,"迁移不修改输入、不凭租住赠房")
        assert(Store.Load() and next(Store.Get().ownedHomes)==nil)
        assert(files[Config.SAVE_PATH]==legacyText and writes==count,"旧档读取不应自动覆写文件")
        assert(Property.NightlyCost(Store.Get(),"apartment")==15000)
        local before=Store.Get()
        assert(not Progress.BuyHome("hostel") and not Progress.BuyHome("unknown"))
        unchanged(before,legacyText,count)
        -- 非法已有字段拒绝，不把false/字符串/未知房型静默清空成合法产权。
        for _,invalid in ipairs({false,"room",{hostel=true},{unknown=true},{room="true"},{room=true}}) do
            local bad=Store.Normalize(legacy) --[[@as table]]
            bad.ownedHomes=invalid
            local text=cjson.encode(bad); files[Config.SAVE_PATH]=text
            assert(not Store.Load() and files[Config.SAVE_PATH]==text,"非法产权必须拒绝且保留原文件")
        end
        files[Config.SAVE_PATH]=legacyText; assert(Store.Load())
        for _,id in ipairs({"room","apartment"}) do
            assert(Store.NewCareer())
            local home=assert(Data.Get(id))
            local price=assert(home.buyPriceCents)
            -- 比最低购房门槛少1分也不能买；保留生活费不允许负余额。
            grant(price+Property.LIVING_RESERVE_CENTS-5001,"test:home-threshold")
            assert(Progress.SetHousing(id))
            before=Store.Get(); local text=files[Config.SAVE_PATH]; count=writes
            assert(not Property.CanBuy(before,id) and not Progress.BuyHome(id))
            unchanged(before,text,count)
            grant(1,"test:home-one-cent")
            before=Store.Get(); text=files[Config.SAVE_PATH]; count=writes
            assert(Property.CanBuy(before,id))
            failWrite=true; assert(not Progress.BuyHome(id)); failWrite=false
            unchanged(before,text,count)
            local refreshes,notices=0,0
            local action={view={Notice=function() notices=notices+1 end},
                RefreshPhone=function() refreshes=refreshes+1 end,Refresh=function() refreshes=refreshes+1 end}
            assert(HousingActions.BuyHome(action --[[@as CareerHousingActions]],id),"生产Action必须经购买事务")
            local bought=Store.Get()
            assert(bought.cashCents==Property.LIVING_RESERVE_CENTS and bought.ownedHomes[id])
            assert(bought.accommodation==before.accommodation and same(bought.position,before.position),"购买不自动搬家")
            assert(#bought.ledger==#before.ledger+1 and bought.financialKeys[Property.PurchaseKey(id)])
            local entry=bought.ledger[#bought.ledger]
            assert(entry.deltaCents==-price and entry.deltaCents%1==0 and entry.kind=="home_purchase")
            assert(refreshes==2 and notices==1)
            assert(Store.Load() and Property.Owns(Store.Get(),id),"产权必须从本地档恢复")
            before=Store.Get(); text=files[Config.SAVE_PATH]; count=writes
            assert(not Progress.BuyHome(id) and not HousingActions.BuyHome(action --[[@as CareerHousingActions]],id))
            unchanged(before,text,count)
            local query=assert(Property.Get(before,id))
            assert(query.owned and query.nightlyCents==0 and query.buyPriceCents==price and not query.canBuy)
            local value=assert(Property.Value(before,id))
            assert(value.currentWeekSavingsCents==home.price*7 and value.passiveIncomeCents==0
                and value.energyAfterRest==home.energy,"产权只免对应房费，不制造被动收入/额外体力")
            assert(#Property.List(before)==2 and not Property.Owns(before,"hostel"))
            assert(Property.NightlyCost(before,id=="room" and "apartment" or "room")>0,"产权只免对应住房费用")
            query.owned=false; assert(Property.Owns(Store.Get(),id),"查询快照不能改产权")
            failWrite=true; assert(not Store.Rest(id)); failWrite=false
            unchanged(before,text,count)
            assert(Store.Rest(id))
            local rested=Store.Get()
            assert(rested.cashCents==before.cashCents and rested.day==before.day+1 and #rested.ledger==#before.ledger)
            assert(rested.ownedHomes[id] and rested.flags["stayed_"..id] and not rested.financialKeys["lodging:"..before.day])
            assert(Store.Rest(id) and Store.Get().cashCents==before.cashCents,"连续自住仍免房费")
            -- 旅舍依然按晚扣款，未购买另一套房仍按晚收费。
            local cash=Store.Get().cashCents
            assert(Store.Rest("hostel") and Store.Get().cashCents==cash-3000)
            cash=Store.Get().cashCents
            local other=id=="room" and "apartment" or "room"
            assert(Store.Rest(other) and Store.Get().cashCents==cash-assert(Data.Get(other)).price)
            assert(Store.Pay(Store.Get().cashCents,"test_fixture","test:home-empty-wallet"))
            assert(Progress.SetHousing(id) and Store.Rest(id) and Store.Get().cashCents==0,"有产权后零现金也能选择自住和过夜")
        end
        -- 周排班分别检查两套产权房、未购房和旅舍，严格保留代表班次门槛。
        for _,scenario in ipairs({{id="room",owned=true},{id="apartment",owned=true},{id="room",owned=false},{id="hostel",owned=false}}) do
            assert(Store.NewCareer()); grant(30000000,"test:home-week-capital")
            for _=1,10 do
                local offer=assert(Delivery.GetOffer()); assert(Delivery.Accept(offer.id))
                local pickup,dropoff=Config.points[offer.pickupId],Config.points[offer.dropoffId]
                assert(Delivery.Pickup(offer.id,pickup.x,pickup.z))
                assert(Delivery.Deliver(offer.id,dropoff.x,dropoff.z))
            end
            if scenario.owned then assert(Progress.BuyHome(scenario.id)) end
            assert(Progress.SetHousing(scenario.id))
            assert(Store.Transaction(function(p)
                p.day=10; p.activeSeconds=900; p.hunger=80; p.energy=80; p.flags.firstRest=true; return true
            end))
            before=Store.Get(); local text=files[Config.SAVE_PATH]; count=writes
            failWrite=true; assert(not Progress.WorkWeek()); failWrite=false
            unchanged(before,text,count)
            assert(Progress.WorkWeek())
            local after=Store.Get()
            local costs=17600+30*240+Property.NightlyCost(before,scenario.id)*7
            assert(after.cashCents==before.cashCents+240*580-costs and after.lastDaySummary.expenseCents==costs)
            assert(after.simulatedOrders==240,"亲送资格不能抵扣未来7天单量")
            assert(after.day==17 and (not scenario.owned or after.ownedHomes[scenario.id]))
            assert(not Progress.WorkWeek(),"自有房不能绕过周排班防连点")
        end
        print("[房产事务验收通过] 旧档无赠房/非法产权拒绝/两套游戏定价买断/生活费1分边界/保存失败全回滚/产权重载/复购不扣款/对应自住免房费/旅舍与他房照付/周排班产权免房费")
    end)
    return true
end
function Checks.Run(session)
    local UI=require("urhox-libs/UI")
    Checks.RunProperty()
    local files={}
    local fail=false
    local a=assert(session.actor)
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) if fail then return false,"住房验收模拟写失败" end; files[path]=text; return true end},function()
        assert(Store.NewCareer())
        assert(Store.Transaction(function(p) p.phase="working"; return Store.ApplyCash(p,100000,"test_fixture","test:housing") end))
        assert(not session:EnterHousing("hostel"),"远程不能进房")
        for _,home in ipairs(Data.List) do if home.width then
            assert(Progress.SetHousing(home.id))
            a.mounted=false; a.visuals:SetMounted(false)
            a:Teleport(home.x,home.z,0); session.view:ShowGame()
            local cash,day=Store.Get().cashCents,Store.Get().day
            fail=true; assert(not session:EnterHousing(home.id)); fail=false
            assert(session.space=="city" and Store.Get().cashCents==cash,"进屋保存失败不能切场")
            local bx,bz=a.bikeX,a.bikeZ
            assert(session:EnterHousing(home.id))
            assert(Store.Get().cashCents==cash and session.space==home.id and not a.visuals.bikeNode.enabled)
            assert(not session.sun.enabled and not session.moon.enabled,"室内必须关闭城市日月方向光")
            require("Career.MapPhoneChecks").OpenLegacy(session.view,session:State(),Delivery.GetOffer(),Delivery.GetActive())
            local map=assert(session.view.phoneContent:FindById("career-phone-map"))
            require("Career.PhoneKit").LayoutTree(session.view.phoneArea)
            assert(session.view.phoneContent:ShowWidget(map),"室内兼容地图必须切到实际所在页")
            require("Career.PhoneKit").LayoutTree(session.view.phoneArea)
            map:Update(0)
            local viewport=map:GetChildren()[1]
            local layout=viewport:GetLayout()
            local player=assert(map:FindById("career-phone-map-player"))
            local scale=math.min(layout.w,layout.h)/30000
            assert(player.props.visible~=false and math.abs(player.props.left-(layout.w/2+home.x*scale))<.001
                and math.abs(player.props.top-(layout.h/2-home.z*scale))<.001,"室内全城地图必须标记城市入口，不能拿房间局部坐标当城市位置")
            session.view:ClosePhone()
            assert(not session:Allowed("breakfast"),"室内不能用城市坐标远程吃饭")
            session.view.actions.mount(); assert(not a.mounted)
            local bedX,bedZ=Data.Bed(home.id)
            walk(a,bedX,bedZ)
            assert(Store.SetPosition(session:PositionSnapshot()) and Store.Save() and Store.Load())
            session:RestorePosition()
            assert(session.space==home.id and math.abs(a.x-bedX)<.2 and a.bikeX==bx and a.bikeZ==bz,"室内读档必须恢复人物而不召车")
            local wallX,wallZ=session.city:Move(0,0,100,0,.32)
            assert(wallX<home.width/2 and session.city:IsFree(wallX,wallZ,.32),"室内外墙不可穿透")
            assert(not Progress.SetHousing("park"),"室内不能直接换房导致位置不匹配")
            assert(not session:LeaveHousing(),"床边不能远程出门")
            assert(Delivery.Accept())
            session:SleepHousing()
            assert(Store.Get().cashCents==cash and Store.Get().day==day,"带单不能睡觉")
            assert(Store.Transaction(function(p) p.activeOrders={}; return true end))
            session:SleepHousing(); clickText(session.view,"先不睡")
            assert(Store.Get().cashCents==cash and Store.Get().day==day,"取消住宿不能收费")
            fail=true
            session:SleepHousing(); clickText(session.view,"支付并休息")
            fail=false
            assert(Store.Get().cashCents==cash and Store.Get().day==day,"房费写失败必须回滚")
            session:SleepHousing(); clickText(session.view,"支付并休息")
            assert(Store.Get().cashCents==cash-home.price and Store.Get().day==day+1 and Store.Get().flags["stayed_"..home.id])
            assert(Store.Get().position.space==home.id)
            clickText(session.view,"收拾好，继续生活")
            local ex,ez=Data.Exit(home.id); walk(a,ex,ez)
            fail=true; assert(not session:LeaveHousing()); fail=false
            assert(session.space==home.id,"出门保存失败必须留在室内")
            assert(session:LeaveHousing())
            assert(a.bikeX==bx and a.bikeZ==bz and a.visuals.bikeNode.enabled,"进出屋不可改变停车坐标")
            assert(Store.Load() and Store.Get().position.space=="city")
        end end
        -- 旧v1档缺space仍可加载；未知空间拒绝，坏档不被静默覆盖。
        local p=Store.Get(); p.position.space=nil
        files[require("Career.Config").SAVE_PATH]=cjson.encode(p)
        assert(Store.Load()); session:RestorePosition(); assert(session.space=="city")
        p.position.space="unknown-room"
        files[require("Career.Config").SAVE_PATH]=cjson.encode(p)
        assert(not Store.Load())
        print("[生涯住房验收通过] 三种独立室内/实际步行到床/真实触摸确认/取消零收费/每晚准确扣款/带单拒绝/进出存档失败回滚/室内重载/停车不变/旧v1兼容")
    end)
    session:RestorePosition(); session.view:ClosePhone(); session.view:ShowGame(); session:Refresh()
    session:UpdateEnvironment(22)
    assert(session.sun.brightness==0 and session.moon.brightness>0,"夜间太阳应熄灭，由朝向地面的月光兜底")
    for _,light in ipairs(session.city.nightLights) do assert(light.enabled and not light.castShadows) end
    session.city:SetSpace("hostel"); session.city:SetSpace("city"); session.city:UpdateLights(12)
    for _,light in ipairs(session.city.nightLights) do assert(not light.enabled,"白天出屋不能因递归启用节点而误开路灯") end
    session:UpdateEnvironment(12)
    assert(session.sun.brightness>0 and session.moon.brightness==0,"白天不叠加月光")
    session:UpdateEnvironment(Store.Get().time)
    print("[夜间路灯验收通过] 夜间太阳熄灭/月光补足道路/路灯无阴影/白天出屋路灯仍关闭/室内地图显示城市入口")
end
function Checks.Shot(session,id)
    local home=assert(Data.Get(id))
    assert(Store.Transaction(function(p)
        p.phase="working"; p.activeOrders={}; p.accommodation=id
        return Store.ApplyCash(p,100000,"test_fixture","test:housing-shot")
    end))
    local a=session.actor
    a.mounted=false; a.visuals:SetMounted(false); a:Teleport(home.x,home.z,0)
    assert(session:EnterHousing(id))
    walk(a,0,0)
    session.yaw,session.pitch=0,18
    session.camera:SetMode("indoor"); session.camera:Update(2,a.node,0,18)
    session:Refresh()
    session.view:ShowDialog("住房实拍","冻结状态",{}); session.view.overlay:SetVisible(false)
end
function Checks.NightShot(session)
    assert(Store.Transaction(function(p) p.phase="working"; p.time=22; return true end))
    session:ApplySpace("city")
    local a=session.actor
    a.mounted=false; a.visuals:SetMounted(false); a:Teleport(-109,-61,0)
    session:UpdateEnvironment(22)
    session.yaw,session.pitch=0,12
    session.camera:SetMode("normal"); session.camera:Update(2,a.node,0,12)
    session:Refresh()
    session.view:ShowDialog("夜间实拍","冻结状态",{}); session.view.overlay:SetVisible(false)
end
return Checks
