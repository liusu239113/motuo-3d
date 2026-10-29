-- 只在主线程已有test内存Session执行；不访问Store/云，不新建全城。
local Walk=require("Career.LocalWalk")
local Pedestrians=require("Career.Pedestrians")
local Outer=require("Career.OuterTraffic")
local Checks={}
local function passed(text) print("[局部通行验收通过] "..text) end
local function legacy(city)
    for i,p in ipairs(Pedestrians.Paths) do
        assert(city:StaticSegmentFree(p[1],p[2],p[3],p[4],.36,"walk",0),"原8条行人基线静态扫掠阻塞："..i)
    end
    assert(#Pedestrians.Paths==8 and Outer.PEOPLE_BUDGET==4,"旧线路/外区池预算被改")
    local freed=0
    for _,b in ipairs(city.buildingFootprints) do
        assert(b.node and b.draw.model and #b.obstacles>0,"缺少真实模型节点/足迹")
        local bounds=b.bounds
        assert(math.abs(bounds.size.y*b.scale-(b.name:find("公寓") and 20 or 18))<.001,"模型真实scale改变")
        local a=math.rad(b.yaw)
        for _,r in ipairs(b.strips) do
            local x,z=(r.x1+r.x2)/2,(r.z1+r.z2)/2
            local wx,wz=b.x+x*math.cos(a)+z*math.sin(a),b.z-x*math.sin(a)+z*math.cos(a)
            assert(not city:StaticFree(wx,wz,.01,"walk",0),"实际低层墙/底座不再阻挡")
        end
        -- 在旧完整bbox内寻找真正释放且有足够人物半径的凹角；不是靠改断言缩半径。
        local sx,sz=bounds.size.x*b.scale,bounds.size.z*b.scale
        for row=0,24 do for col=0,24 do
            local x,z=-sx/2+sx*col/24,-sz/2+sz*row/24
            local wx,wz=b.x+x*math.cos(a)+z*math.sin(a),b.z-x*math.sin(a)+z*math.cos(a)
            if city:StaticFree(wx,wz,.32,"walk",0) then freed=freed+1 end
        end end
    end
    assert(freed>0,"没有验证到原建筑整矩形内的空气处可通")
    passed("真实模型节点/低墙条带仍阻挡，旧bbox空气处人物半径可通；原8path完整扫掠，4人池不变")
end
local function simulate(city,path,radius,car)
    local length=math.sqrt((path[3]-path[1])^2+(path[4]-path[2])^2)
    local ux,uz=(path[3]-path[1])/length,(path[4]-path[2])/length
    local p={path=path,length=length,s=3,x=path[1]+ux*3,z=path[2]+uz*3,radius=.32,
        speed=1.1,direction=1,minOffset=-2.3,maxOffset=2.3}
    Walk.Reset(p)
    local obstacle={x=path[1]+ux*7,z=path[2]+uz*7,radius=radius}
    local blockers=car and {} or {obstacle}
    local cars=car and {{ {x=obstacle.x,z=obstacle.z,yaw=math.deg(math.atan(ux,uz)),length=2,width=1.4,speed=0} }} or {}
    local maxOffset=0
    for _=1,210 do
        local ax,az=p.x,p.z
        Walk.Advance(city,p,.1,blockers,{{p}},cars)
        assert(Walk.SegmentFree(city,p,ax,az,p.x,p.z,blockers,{{p}},cars),"实际绕行一步穿占用物/墙")
        assert(#p.localWalk.points<=3,"局部路点预算越界")
        maxOffset=math.max(maxOffset,math.abs((p.x-path[1])*(-uz)+(p.z-path[2])*ux))
        if p.s>12 and #p.localWalk.points==0 then break end
    end
    assert(p.s>12 and #p.localWalk.points==0 and maxOffset>1,"未绕过静止占用物回原线")
    assert(p.localWalk.plans>=1 and p.localWalk.attempts<=21,"缺少有限重规划预算")
end
function Checks.Run(session)
    assert(session.options.test and type(session.restoreTestStorage)=="function","只允许test内存Session")
    local city=assert(session.city)
    legacy(city)
    simulate(city,Pedestrians.Paths[1],.32,false)
    simulate(city,Pedestrians.Paths[1],.4,false)
    simulate(city,Pedestrians.Paths[1],1.2,false)
    simulate(city,Pedestrians.Paths[1],0,true)
    simulate(city,{700,-8,740,-8},.32,false)
    simulate(city,{700,-8,740,-8},.4,false)
    -- 外区4m人行道有可用侧边时绕人；大车堵满整条窄步道时必须等，不能越车道。
    passed("老街真实静态域绕静止玩家/配送人物/停车圆及车辆OBB后回原线；外区真实静态域绕玩家/配送人物")
    local root=city.root:CreateChild("局部通行检查临时池")
    local testCity=setmetatable({space="city"},{__index=city})
    local pool=Pedestrians.New(root,testCity)
    local ok,message=pcall(function()
        local p=pool.people[1]
        local x,z,phase=p.x,p.z,p.phase
        testCity.space="hostel"; pool:Update(.2,{}); assert(p.x==x and p.z==z and p.phase==phase,"室内未冻结")
        testCity.space="city"; pool:Update(0,{}); pool:Update(-.1,{})
        assert(p.x==x and p.z==z and p.phase==phase,"非法dt未冻结")
        pool:Dispose(); pool:Dispose(); pool:Update(.1,{})
        assert(#pool.people==0 and pool.disposed,"Dispose非幂等/残留路人")
    end)
    pool:Dispose(); root:Dispose()
    assert(ok,message)
    passed("独立临时真实节点池室内/非法dt冻结与Dispose幂等；无Store/云写入")
    return true
end
return Checks
