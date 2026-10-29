-- 仅显式测试Session可调用；验收生产actions与真实触摸确认，不构造场景或反复Ensure世界。
-- 所有读写先嵌套切到内存Store，明确禁云；成功/异常均finally恢复原Store与角色/Session。
local Store=require("Career.Store")
local Delivery=require("Career.Delivery")
local Config=require("Career.Config")
local Events=require("Career.Engagements")
local Team=require("Career.Team")
local UI=require("urhox-libs/UI")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Checks={}
local function clickText(view,text)
    local function find(widget)
        if widget.props.text==text and widget.props.onClick then return widget end
        for _,child in ipairs(widget:GetChildren()) do
            local found=find(child)
            if found then return found end
        end
    end
    UI.Layout()
    local widget=assert(find(view.dialogBody),"缺少生产确认按钮："..text)
    local r=widget:GetAbsoluteLayout()
    assert(r.w>0 and r.h>0,"确认按钮必须有真实布局")
    local scale=UI.GetScale()
    local data={pointerId=790101,pointerType="touch",x=(r.x+r.w/2)*scale,
        y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left}
    UI.HandlePointerEvent(PointerEvent.new("PointerDown",data))
    UI.HandlePointerEvent(PointerEvent.new("PointerUp",data))
end
local function firstRow()
    local state=Events.State(Store.Get())
    assert(state.valid,state.error)
    return assert(state.list[1])
end
local function delivery()
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
    local from,to=Config.points[offer.pickupId],Config.points[offer.dropoffId]
    assert(Delivery.Pickup(offer.id,from.x,from.z,{riding=false,speed=0}))
    assert(Delivery.Deliver(offer.id,to.x,to.z,{riding=false,speed=0}))
    return offer
end
---@param session CareerSession
---@return boolean
function Checks.Run(session)
    assert(session.options and session.options.test==true,"StoryChecks只允许options.test的隔离Session")
    local actor=assert(session.actor)
    local view=session.view
    assert(not view.blocked and view.phonePage=="","请在非弹窗、非手机的测试游戏态调用")
    local old={position=session:PositionSnapshot(),space=session.space,cityX=session.cityX,cityZ=session.cityZ,
        cityYaw=session.cityYaw,yaw=session.yaw,pitch=session.pitch,waypoint=session.waypoint,
        online=session.online,running=session.running,speed=actor.speed,steer=actor.steer,reverseHold=actor.reverseHold,
        notice=view.notice.props.text,noticeTime=view.noticeTime}
    local files={}
    local cloudCalls=0
    local restore=Store.UseTestStorage({
        read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text; return true end,
        cloud={Get=function() cloudCalls=cloudCalls+1; error("StoryChecks禁止云读取") end,
            Set=function() cloudCalls=cloudCalls+1; error("StoryChecks禁止云写入") end},
    })
    local passed,failure=pcall(function()
        assert(Store.NewCareer())
        session.running=true; session.online=false
        if session.space~="city" then session:ApplySpace("city") end
        actor.mounted=false; actor.visuals:SetMounted(false)
        view:ClosePhone(); view:ShowGame()
        local function at(id)
            local point=assert(Config.points[id])
            actor:Teleport(point.x,point.z,0)
            actor.speed=0
        end
        delivery() -- 真实教学只解锁站长，不直接写tutorialCompleted。
        at("bridge")
        local revision=Store.Get().revision
        view.actions.acceptEngagement("breakfast_shift")
        assert(not firstRow().accepted and Store.Get().revision==revision and not view.blocked,
            "手机action远程接取应导航提示，不得接取或打开确认")
        assert(session.waypoint=="breakfast")
        at("breakfast")
        view.actions.acceptEngagement("breakfast_shift")
        assert(view.blocked and not firstRow().accepted)
        clickText(view,"稍后再来")
        assert(not view.blocked and not firstRow().accepted and Store.Get().revision==revision,
            "取消委托确认不能写入实例")
        view.actions.acceptEngagement("breakfast_shift")
        at("bridge") -- 打开确认后移动，回调必须重新获取现场而非复用弹窗前ctx。
        clickText(view,"接受现场委托")
        assert(not firstRow().accepted,"确认时已离开现场必须拒绝")
        at("breakfast")
        view.actions.acceptEngagement("breakfast_shift"); clickText(view,"接受现场委托")
        assert(firstRow().accepted and not view.blocked)
        local acceptedRevision=Store.Get().revision
        view.actions.acceptEngagement("breakfast_shift"); clickText(view,"接受现场委托")
        assert(Store.Get().revision==acceptedRevision,"反复确认不能重置委托或订单水位")
        local eligible=0
        for _=1,32 do
            local order=delivery()
            if order.pickupId=="breakfast" then eligible=eligible+1 end
            if eligible==3 then break end
        end
        assert(eligible==3 and firstRow().canClaim)
        at("bridge")
        local cash=Store.Get().cashCents
        view.actions.claimEngagement(firstRow().instanceId)
        assert(not firstRow().claimed and Store.Get().cashCents==cash,"手机action不能远程领奖")
        at("breakfast")
        view.actions.claimEngagement(firstRow().instanceId)
        assert(firstRow().claimed and Store.Get().cashCents==cash+1500)
        local claimedRevision=Store.Get().revision
        view.actions.claimEngagement(firstRow().instanceId)
        assert(Store.Get().revision==claimedRevision and Store.Get().cashCents==cash+1500,
            "重复Session领奖不得重复奖金/信件")

        -- 仅资格fixture；签合同必须走Session action + 真触摸 + Team.Sign生产入口。
        assert(Store.Transaction(function(p)
            p.ownedMotorcycles.sport=true; p.flags.firstMotorcycle=true; p.flags.professional=true
            p.career={starts=0,wins=0,points=9,season=1,pending=false,team="私人车手"}
            p.position.x=Config.points.bridge.x; p.position.z=Config.points.bridge.z
            return true
        end))
        local teamId=Team.Offers(Store.Get())[1].id
        at("bridge")
        view.actions.signTeam(teamId)
        assert(not Team.Status(Store.Get()).signed and not view.blocked,"远程签约不得打开可确认合同")
        at("dealer")
        view.actions.signTeam(teamId); clickText(view,"暂不签约")
        assert(not Team.Status(Store.Get()).signed and Store.Get().position.x==Config.points.bridge.x,
            "取消车队签约不能生成合同或提前同步位置")
        view.actions.signTeam(teamId)
        at("bridge"); clickText(view,"确认签约")
        assert(not Team.Status(Store.Get()).signed,"确认时离开车行必须再次拒绝")
        at("dealer")
        assert(Store.Get().position.x==Config.points.bridge.x,"fixture应保留桥下旧位置以验证snapshot桥接")
        local signCash=Store.Get().cashCents
        view.actions.signTeam(teamId); clickText(view,"确认签约")
        local signed=Store.Get()
        assert(Team.Status(signed).signed and signed.cashCents==signCash,
            "Session确认应经生产Team.Sign签约，签字不发钱")
        assert(signed.position.x==actor.x and signed.position.z==actor.z and signed.position.mounted==false,
            "Session.SignTeam必须把实时PositionSnapshot桥接给仅检查存档位置的Team.Sign")
        local signedRevision=signed.revision
        view.actions.signTeam(teamId); clickText(view,"确认签约")
        assert(Store.Get().revision==signedRevision and Store.Get().cashCents==signCash,"重复确认不重签、不赠款")
        at("bridge"); view.actions.claimTeam()
        assert(Store.Get().cashCents==signCash and Store.Get().teamContract.round==1,"远程ClaimTeam不能领奖")
        at("dealer"); view.actions.claimTeam()
        assert(Store.Get().cashCents==signCash and Store.Get().teamContract.round==1,
            "Session.ClaimTeam应调用生产Team.Claim并拒绝未履约合同")
        assert(cloudCalls==0)
        print("[剧情UI入口验收通过] 生产Session actions/真实触摸取消确认/确认时现场重检/一次委托奖信/车队取消零副作用/签约位置snapshot桥接/未履约拒奖/内存禁云")
    end)
    -- finally：不调用RestorePosition（避免读取真实档或反复Ensure大世界）。
    local cleaned,cleanupFailure=pcall(function()
        view:ClosePhone(); view:ShowGame()
        session.space=old.space
        if session.city.space~=old.space then session:ApplySpace(old.space) end
        actor.mounted=old.position.mounted
        actor:RestoreVehicles(old.position)
        actor.visuals:SetMounted(actor.mounted)
        actor:Teleport(old.position.x,old.position.z,old.position.yaw,old.position.groundHeight)
        actor.speed=old.speed; actor.steer=old.steer; actor.reverseHold=old.reverseHold
        session.cityX,session.cityZ,session.cityYaw=old.cityX,old.cityZ,old.cityYaw
        session.yaw,session.pitch,session.waypoint=old.yaw,old.pitch,old.waypoint
        session.online,session.running=old.online,old.running
    end)
    restore() -- 清理或测试失败也必须恢复外层测试Store，绝不触碰玩家真实档。
    local refreshed,refreshFailure=pcall(function()
        session:Refresh()
        view.notice:SetText(old.notice or ""); view.noticeTime=old.noticeTime
    end)
    if not passed then error(failure,0) end
    if not cleaned then error(cleanupFailure,0) end
    if not refreshed then error(refreshFailure,0) end
    return true
end
return Checks
