-- XZ collision geometry, metres; no engine objects, physics world or save state.
-- Top view (+Z up):         narrow gap g
--   static wall | <----------------------> | car shell polygon
--               |    .--walker--.         |   /--------\
--               |    | r = .32 |          |  /          \
--               |    '--------'          |  |            |
--               |     +mirror+           |  |            |
--               |     | bike | ->        |  \----------/
--               |     |+box+ |           |
-- The walker stays a TRUE circle (rounded corners). Riding/parking is a union
-- of oriented model hulls + delivery box + mirrors, never its enclosing disc.
-- Broad bounds only prune; every narrow query uses the actual circle/polygon.
-- Sweeps are continuous (SAT for polygon pairs, rounded edge/vertex casts for
-- circle/polygon); tangent motion is free, inward contact stops then slides.
local C={}
C.SKIN=.004 -- four millimetres, not a gameplay-sized inflated vehicle radius
local EPS=1e-9
local function dot(x,z,nx,nz) return x*nx+z*nz end
local function cross(a,b,c) return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x) end

function C.Hull(points)
    table.sort(points,function(a,b) return a.x<b.x or a.x==b.x and a.z<b.z end)
    local unique={}
    for _,p in ipairs(points) do
        local q=unique[#unique]
        if not q or math.abs(q.x-p.x)+math.abs(q.z-p.z)>EPS then unique[#unique+1]={x=p.x,z=p.z} end
    end
    if #unique<3 then return {} end
    local low,high={},{}
    for _,p in ipairs(unique) do
        while #low>=2 and cross(low[#low-1],low[#low],p)<=EPS do table.remove(low) end
        low[#low+1]=p
    end
    for i=#unique,1,-1 do
        local p=unique[i]
        while #high>=2 and cross(high[#high-1],high[#high],p)<=EPS do table.remove(high) end
        high[#high+1]=p
    end
    table.remove(low); table.remove(high)
    for _,p in ipairs(high) do low[#low+1]=p end
    return low -- counter-clockwise in numeric XZ
end
function C.Shape(parts)
    local s={parts=parts,x1=math.huge,x2=-math.huge,z1=math.huge,z2=-math.huge,reach=0}
    for _,p in ipairs(parts) do
        if p.radius then
            s.x1=math.min(s.x1,p.x-p.radius); s.x2=math.max(s.x2,p.x+p.radius)
            s.z1=math.min(s.z1,p.z-p.radius); s.z2=math.max(s.z2,p.z+p.radius)
            s.reach=math.max(s.reach,math.sqrt(p.x*p.x+p.z*p.z)+p.radius)
        else
            for _,v in ipairs(p.points) do
                s.x1=math.min(s.x1,v.x); s.x2=math.max(s.x2,v.x)
                s.z1=math.min(s.z1,v.z); s.z2=math.max(s.z2,v.z)
                s.reach=math.max(s.reach,math.sqrt(v.x*v.x+v.z*v.z))
            end
        end
    end
    return s
end
function C.Circle(x,z,r) return C.Shape({{x=x,z=z,radius=r}}) end
function C.Box(x1,z1,x2,z2)
    return C.Shape({{points={{x=x1,z=z1},{x=x2,z=z1},{x=x2,z=z2},{x=x1,z=z2}}}})
end
function C.Pose(shape,x,z,yaw)
    local a=math.rad(yaw or 0)
    local cs,sn=math.cos(a),math.sin(a)
    local function point(p) return {x=x+p.x*cs+p.z*sn,z=z-p.x*sn+p.z*cs} end
    local parts={}
    for _,p in ipairs(shape.parts) do
        if p.radius then
            local q=point(p); q.radius=p.radius; parts[#parts+1]=q
        else
            local vertices={}
            for _,v in ipairs(p.points) do vertices[#vertices+1]=point(v) end
            parts[#parts+1]={points=vertices}
        end
    end
    return C.Shape(parts)
end
local function edges(poly,callback)
    for i,a in ipairs(poly.points) do
        local b=poly.points[i%#poly.points+1]
        local dx,dz=b.x-a.x,b.z-a.z
        local length=math.sqrt(dx*dx+dz*dz)
        if length>EPS then callback(dz/length,-dx/length,a,b,length) end -- outward
    end
end
local function project(p,nx,nz)
    if p.radius then
        local d=dot(p.x,p.z,nx,nz)
        return d-p.radius,d+p.radius
    end
    local lo,hi=math.huge,-math.huge
    for _,v in ipairs(p.points) do
        local d=dot(v.x,v.z,nx,nz); lo=math.min(lo,d); hi=math.max(hi,d)
    end
    return lo,hi
end
local function circlePoly(circle,poly,pad)
    local inside=true
    local best=math.huge
    edges(poly,function(nx,nz,a,b,length)
        if dot(circle.x-a.x,circle.z-a.z,nx,nz)>0 then inside=false end
        local t=math.max(0,math.min(1,((circle.x-a.x)*(b.x-a.x)+(circle.z-a.z)*(b.z-a.z))/(length*length)))
        best=math.min(best,(circle.x-a.x-(b.x-a.x)*t)^2+(circle.z-a.z-(b.z-a.z)*t)^2)
    end)
    return not inside and best>=(circle.radius+pad)^2-EPS
end
local function partFree(a,b,pad)
    if a.radius and b.radius then return (a.x-b.x)^2+(a.z-b.z)^2>=(a.radius+b.radius+pad)^2-EPS end
    if a.radius then return circlePoly(a,b,pad) end
    if b.radius then return circlePoly(b,a,pad) end
    local separate=false
    local function axis(nx,nz)
        local al,ah=project(a,nx,nz); local bl,bh=project(b,nx,nz)
        if ah+pad<=bl+EPS or bh+pad<=al+EPS then separate=true end
    end
    edges(a,axis); edges(b,axis)
    return separate
end
function C.Free(a,b,pad)
    pad=pad or 0
    if a.x2+pad<=b.x1 or b.x2+pad<=a.x1 or a.z2+pad<=b.z1 or b.z2+pad<=a.z1 then return true end
    for _,pa in ipairs(a.parts) do for _,pb in ipairs(b.parts) do if not partFree(pa,pb,pad) then return false end end end
    return true
end
local function circleCast(a,b,dx,dz,radius)
    local px,pz=a.x-b.x,a.z-b.z
    local speed2=dx*dx+dz*dz
    local toward=dot(px,pz,dx,dz)
    if toward>=-EPS or speed2<EPS then return nil end
    local distance2=px*px+pz*pz
    local determinant=toward*toward-speed2*(distance2-radius*radius)
    if determinant<=EPS then return nil end -- grazing is not an inward contact
    local t=math.max(0,(-toward-math.sqrt(determinant))/speed2)
    if t>1 then return nil end
    local nx,nz=px+dx*t,pz+dz*t
    local length=math.sqrt(nx*nx+nz*nz)
    if length<EPS then return 0,-dx/math.sqrt(speed2),-dz/math.sqrt(speed2) end
    return t,nx/length,nz/length
end
local function circlePolyCast(circle,poly,dx,dz,pad)
    local best,nx,nz=2,0,0
    local radius=circle.radius+pad
    edges(poly,function(ex,ez,a,b,length)
        local velocity=dot(dx,dz,ex,ez)
        if velocity< -EPS then
            local distance=dot(circle.x-a.x,circle.z-a.z,ex,ez)-radius
            local t=math.max(0,-distance/velocity)
            if t<=1 then
                local px,pz=circle.x+dx*t-ex*radius,circle.z+dz*t-ez*radius
                local along=((px-a.x)*(b.x-a.x)+(pz-a.z)*(b.z-a.z))/length
                if along>=-EPS and along<=length+EPS and distance>=-1e-7 and t<best then best,nx,nz=t,ex,ez end
            end
        end
        local t,vx,vz=circleCast(circle,a,dx,dz,radius)
        if t and t<best then best,nx,nz=t,vx,vz end
    end)
    if best<=1 then return best,nx,nz end
    return nil
end
local function polyCast(a,b,dx,dz,pad)
    local enter,leave,nx,nz=0,1,0,0
    local separated=false
    local function axis(ax,az)
        if separated then return end
        local al,ah=project(a,ax,az); local bl,bh=project(b,ax,az)
        local velocity=dot(dx,dz,ax,az)
        if math.abs(velocity)<EPS then
            if ah+pad<=bl+EPS or bh+pad<=al+EPS then separated=true end
            return
        end
        local first,last=(bl-ah-pad)/velocity,(bh-al+pad)/velocity
        local normal= -1
        if first>last then first,last=last,first; normal=1 end
        if first>=enter then enter,nx,nz=first,ax*normal,az*normal end
        leave=math.min(leave,last)
        if enter>=leave-EPS then separated=true end
    end
    edges(a,axis); edges(b,axis)
    if separated or leave<=EPS or enter>1 or dot(dx,dz,nx,nz)>=-EPS then return nil end
    return math.max(0,enter),nx,nz
end
function C.Sweep(a,b,dx,dz,pad)
    pad=pad or C.SKIN
    if math.max(a.x2,a.x2+dx)+pad<b.x1 or math.min(a.x1,a.x1+dx)-pad>b.x2
        or math.max(a.z2,a.z2+dz)+pad<b.z1 or math.min(a.z1,a.z1+dz)-pad>b.z2 then return nil end
    local best,nx,nz=2,0,0
    for _,pa in ipairs(a.parts) do for _,pb in ipairs(b.parts) do
        local t,vx,vz
        if pa.radius and pb.radius then t,vx,vz=circleCast(pa,pb,dx,dz,pa.radius+pb.radius+pad)
        elseif pa.radius then t,vx,vz=circlePolyCast(pa,pb,dx,dz,pad)
        elseif pb.radius then
            local hit,hx,hz=circlePolyCast(pb,pa,-dx,-dz,pad)
            t,vx,vz=hit,hx and -hx,hz and -hz
        else t,vx,vz=polyCast(pa,pb,dx,dz,pad) end
        if t and t<best then best,nx,nz=t,vx,vz end
    end end
    if best<=1 then return best,nx,nz end
    return nil
end
return C
