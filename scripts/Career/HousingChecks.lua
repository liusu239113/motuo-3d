-- 住房实景验收：资金与读写均为内存桩，生产门口/床边/出门入口实际执行。
local Store=require("Career.Store")
local Data=require("Career.HousingData")
local Progress=require("Career.Progression")
local Delivery=require("Career.Delivery")
local UI=require("urhox-libs/UI")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Checks={}
local function clickText(view,text)
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
function Checks.Run(session)
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
            session:OpenPhone("map")
            local map=assert(session.view.phoneContent:FindById("career-phone-map"))
            local roads=map:GetChildren()[1]
            local children=roads:GetChildren()
            local player=children[#children]
            assert(player.props.left==string.format("%.4f%%",(home.x+180)/360*100)
                and player.props.top==string.format("%.4f%%",(180-home.z)/360*100),"室内手机地图必须标记城市入口，不能拿房间局部坐标当城市位置")
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
