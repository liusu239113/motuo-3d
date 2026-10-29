-- Collision adapter only: immutable WorldData cells + City local rectangles +
-- Traffic shell snapshots + independent parking. No streamed visual dependency.
local C=require("Career.FootprintCollision")
local F=require("Career.VehicleFootprints")
local World=require("Career.WorldData")
local Housing=require("Career.HousingData")
local Environment=require("Career.CityEnvironment")
local Q={}
local function rect(o) return C.Box(o.x1,o.z1,o.x2,o.z2) end
local function boundsOverlap(shape,o,dx,dz)
    return math.max(shape.x2,shape.x2+dx)+C.SKIN>o.x1 and math.min(shape.x1,shape.x1+dx)-C.SKIN<o.x2
        and math.max(shape.z2,shape.z2+dz)+C.SKIN>o.z1 and math.min(shape.z1,shape.z1+dz)-C.SKIN<o.z2
end
local function collect(city,shape,dx,dz,mode,height,ignoreId,staticOnly)
    local result={}
    local function add(o)
        if boundsOverlap(shape,o,dx,dz) then result[#result+1]=rect(o) end
    end
    if city.space~="city" then
        local home=assert(Housing.Get(city.space))
        for _,o in ipairs(city.interior.obstacles[city.space]) do add(o) end
        -- Solid walls immediately outside the room's exact clear floor extents.
        add({x1=-home.width/2-10,x2=-home.width/2,z1=-home.depth/2-10,z2=home.depth/2+10})
        add({x1=home.width/2,x2=home.width/2+10,z1=-home.depth/2-10,z2=home.depth/2+10})
        add({z1=-home.depth/2-10,z2=-home.depth/2,x1=-home.width/2-10,x2=home.width/2+10})
        add({z1=home.depth/2,z2=home.depth/2+10,x1=-home.width/2-10,x2=home.width/2+10})
        return result
    end
    for _,o in ipairs(city.obstacles) do add(o) end
    local x1,x2=math.min(shape.x1,shape.x1+dx),math.max(shape.x2,shape.x2+dx)
    local z1,z2=math.min(shape.z1,shape.z1+dz),math.max(shape.z2,shape.z2+dz)
    if x1< -World.OLD_LIMIT or x2>World.OLD_LIMIT or z1< -World.OLD_LIMIT or z2>World.OLD_LIMIT then
        for ix=math.floor((x1-32)/World.CELL),math.floor((x2+32)/World.CELL) do
            for iz=math.floor((z1-32)/World.CELL),math.floor((z2+32)/World.CELL) do
                for _,o in ipairs(World.DescribeCell(ix,iz).obstacles) do
                    if height<(o.y2 or math.huge) and height+1.8>(o.y1 or -math.huge) then add(o) end
                end
            end
        end
    end
    -- Bridges are analytic WorldData objects, not in cell.obstacles. Ground
    -- traffic passes under the deck but cannot pass through the solid ramps.
    for _,d in ipairs(World.Districts) do if d.bridge then
        local bx,bz=d.x,d.z+96
        if x2>bx-26 and x1<bx+26 and z2>bz-68 and z1<bz+4 then
            local cx,cz=(shape.x1+shape.x2)/2,(shape.z1+shape.z2)/2
            local ground=World.Surface(cx,cz,"vehicle",0)
            local deck=World.Surface(cx,cz,"walk",height)
            local onDeck=mode=="walk" and deck>ground+.01 and math.abs(deck-height)<=.65
            if not onDeck then
                for _,side in ipairs({-1,1}) do
                    local enter=mode=="walk" and height<=.65 and cz<=bz-64+.65
                        and x1>=bx+side*20-2 and x2<=bx+side*20+2
                    if not enter then add({x1=bx+side*20-2,x2=bx+side*20+2,z1=bz-64,z2=bz-2}) end
                end
            end
            if height<3 then for _,side in ipairs({-1,1}) do add({x1=bx+side*14-.6,x2=bx+side*14+.6,z1=bz-.6,z2=bz+.6}) end end
        end
    end end
    local terrainY=Environment.Surface((shape.x1+shape.x2)/2,(shape.z1+shape.z2)/2)
    if staticOnly or mode=="walk" and height>1 and terrainY==nil then return result end
    if city.traffic and city.traffic.active then city.traffic:CollisionShapes(result,shape,dx,dz) end
    local actor=city.actor
    if actor then
        local function park(id,x,z,yaw)
            if id~=ignoreId then
                local localShape=F.Get(id)
                if math.abs(x-(shape.x1+shape.x2)/2)<localShape.reach+(shape.x2-shape.x1)/2+math.abs(dx)+1
                    and math.abs(z-(shape.z1+shape.z2)/2)<localShape.reach+(shape.z2-shape.z1)/2+math.abs(dz)+1 then
                    result[#result+1]=C.Pose(localShape,x,z,yaw)
                end
            end
        end
        if not actor.mounted then park(actor.vehicleId,actor.bikeX,actor.bikeZ,actor.bikeYaw) end
        for id,p in pairs(actor.parking) do if id~=actor.vehicleId then park(id,p.x,p.z,p.yaw) end end
    end
    if city.crowd then
        for _,p in ipairs(city.crowd:GetBlockers()) do
            if math.abs((p.height or 0)-height)<1.8 then result[#result+1]=C.Circle(p.x,p.z,p.radius) end
        end
    end
    if city.deliveryPeople then
        for _,p in ipairs(city.deliveryPeople.people) do
            if p.active or p.hold>0 then result[#result+1]=C.Circle(p.x,p.z,.4) end
        end
    end
    return result
end
function Q.ShapeFree(city,shape,x,z,yaw,mode,height,ignoreId,staticOnly)
    local posed=C.Pose(shape,x,z,yaw)
    if posed.x1< -World.LIMIT or posed.x2>World.LIMIT or posed.z1< -World.LIMIT or posed.z2>World.LIMIT then return false end
    -- Preserve World bridge edge support / walk-height semantics, not its square
    -- expansion for ordinary walls. The walking footprint really is a circle.
    if city.space=="city" and mode=="walk" and (height or 0)>.65 and Environment.Surface(x,z)==nil then
        if not World.IsFree(x,z,shape.parts[1].radius or 0,mode,height) then return false end
    end
    for _,other in ipairs(collect(city,posed,0,0,mode or "vehicle",height or 0,ignoreId,staticOnly)) do
        if not C.Free(posed,other,C.SKIN) then return false end
    end
    return true
end
function Q.Move(city,x,z,dx,dz,shape,yaw,mode,height,ignoreId,staticOnly)
    local blocked=false
    -- Continuous cast in each bounded displacement, followed by contact-normal
    -- sliding. No X/Z axis bias: oblique car flanks are smooth at any yaw.
    local count=math.max(1,math.ceil(math.sqrt(dx*dx+dz*dz)/.10))
    for _=1,count do
        local rx,rz=dx/count,dz/count
        for _=1,4 do
            if rx*rx+rz*rz<1e-16 then break end
            local posed=C.Pose(shape,x,z,yaw)
            local best,nx,nz=1,0,0
            for _,other in ipairs(collect(city,posed,rx,rz,mode or "vehicle",height or 0,ignoreId,staticOnly)) do
                local t,hx,hz=C.Sweep(posed,other,rx,rz)
                if t and t<best then best,nx,nz=t,hx,hz end
            end
            -- World boundary uses shape extents, never the diagonal radius.
            for _,edge in ipairs({{rx,World.LIMIT-posed.x2,1,0},{-rx,World.LIMIT+posed.x1,-1,0},
                {rz,World.LIMIT-posed.z2,0,1},{-rz,World.LIMIT+posed.z1,0,-1}}) do
                if edge[1]>0 and edge[2]/edge[1]<best then best=math.max(0,edge[2]/edge[1]);nx,nz=-edge[3],-edge[4] end
            end
            local fraction=math.max(0,best-1e-7)
            local tx,tz=x+rx*fraction,z+rz*fraction
            if city.space=="city" and mode=="walk" and (height or 0)>.65 and Environment.Surface(tx,tz)==nil
                and not World.IsFree(tx,tz,shape.parts[1].radius or 0,mode,height) then blocked=true;break end
            x,z=tx,tz
            if best>=1 then break end
            blocked=true
            local leftX,leftZ=rx*(1-best),rz*(1-best)
            local inward=math.min(0,leftX*nx+leftZ*nz)
            rx,rz=leftX-inward*nx,leftZ-inward*nz
        end
    end
    return x,z,blocked
end
function Q.Find(city,x,z,shape,yaw,mode,height,ignoreId)
    if Q.ShapeFree(city,shape,x,z,yaw,mode,height,ignoreId) then return x,z end
    for ring=1,100 do
        local distance=ring*.25
        for i=1,32 do
            local a=i*math.pi/16
            local px,pz=x+math.sin(a)*distance,z+math.cos(a)*distance
            if Q.ShapeFree(city,shape,px,pz,yaw,mode,height,ignoreId) then return px,pz end
        end
    end
    error("No collision-free nearby restore position; refusing invisible vehicle overlap")
end
function Q.SegmentFree(city,ax,az,bx,bz,r,mode,height)
    local shape=C.Circle(0,0,r)
    if not Q.ShapeFree(city,shape,ax,az,0,mode,height,nil,true) then return false end
    local x,z,blocked=Q.Move(city,ax,az,bx-ax,bz-az,shape,0,mode,height,nil,true)
    return not blocked and math.abs(x-bx)+math.abs(z-bz)<.0001
end
return Q
