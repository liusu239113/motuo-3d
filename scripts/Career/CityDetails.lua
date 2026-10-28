-- City detail builder, adapted from scaffold-3d-scene's content/material ownership.
-- Only scenery: no camera, UI, input subscription, player or global lighting changes.
local V = Vector3

---@class CityBatch
---@field geometry CustomGeometry
---@field cx number
---@field cz number
---@field vertices integer

---@class CityDetails
---@field root Node
---@field mats table<string, Material>
---@field batches table<string, CityBatch>
---@field shapes table<string, Model>
---@field meshCount integer
---@field boxes integer
---@field signs integer
---@field trees integer
---@field cylinders integer
---@field font Font
---@field surfaces table[]
---@field surfaceCells table<string, table[]>
local Details = {}
Details.__index = Details

---@param root Node
---@param mats table<string, Material>
---@return CityDetails
function Details.New(root, mats)
    local self = setmetatable({}, Details)
    self:Init(root, mats)
    return self
end

---@param root Node
---@param mats table<string, Material>
function Details:Init(root, mats)
    self.root, self.mats = root, mats
    self.batches, self.shapes, self.surfaces, self.surfaceCells = {}, {}, {}, {}
    self.meshCount, self.boxes, self.signs, self.trees, self.cylinders = 0, 0, 0, 0, 0
    self.font = assert(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), "City: missing sign font")
    self.shapes.cylinder = CylinderGeometry(.5, .5, 1, 12):ToModel()
end

---@param material string
---@param x number
---@param z number
---@return CityBatch
function Details:Batch(material, x, z)
    local gx, gz = math.floor(x / 48), math.floor(z / 48)
    local key = gx .. ":" .. gz .. ":" .. material
    local batch = self.batches[key]
    if batch then return batch end
    local cx, cz = gx * 48 + 24, gz * 48 + 24
    local node = self.root:CreateChild("City48m_" .. key)
    node.position = V(cx, 0, cz)
    local geom = node:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)
    local materialResource = assert(self.mats[material], "City: undefined material " .. material)
    geom:SetMaterial(materialResource)
    geom.castShadows = material ~= "road" and material ~= "paint" and material ~= "yellow" and material ~= "grass"
    geom.shadowDistance = 95
    geom.drawDistance = 460
    batch = {geometry = geom, cx = cx, cz = cz, vertices = 0}
    self.batches[key] = batch
    self.meshCount = self.meshCount + 1
    return batch
end

-- A quad is authored in world metres. Per-face metre UVs avoid stretched 20m wall textures.
---@param material string
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param d Vector3
---@param tile? number
function Details:Quad(material, a, b, c, d, tile)
    local batch = self:Batch(material, (a.x+b.x+c.x+d.x)/4, (a.z+b.z+c.z+d.z)/4)
    local g = batch.geometry
    local normal = (b-a):CrossProduct(c-a):Normalized()
    local origin = V(batch.cx, 0, batch.cz)
    local scale = tile or .5
    local function vertex(p)
        g:DefineVertex(p-origin)
        g:DefineNormal(normal)
        if math.abs(normal.y) > .6 then g:DefineTexCoord(Vector2(p.x*scale,p.z*scale))
        elseif math.abs(normal.x) > .6 then g:DefineTexCoord(Vector2(p.z*scale,p.y*scale))
        else g:DefineTexCoord(Vector2(p.x*scale,p.y*scale)) end
    end
    vertex(a); vertex(b); vertex(c)
    vertex(c); vertex(b); vertex(d)
    batch.vertices = batch.vertices + 6
end

---@param material string
---@param x number
---@param y number
---@param z number
---@param w number
---@param h number
---@param depth number
---@param yaw? number
function Details:Box(material, x,y,z,w,h,depth,yaw)
    local a = math.rad(yaw or 0)
    local cs, sn = math.cos(a), math.sin(a)
    local function p(px,py,pz) return V(x+px*cs+pz*sn,y+py,z-px*sn+pz*cs) end
    local l,r,b,t,n,f = -w*.5,w*.5,-h*.5,h*.5,-depth*.5,depth*.5
    self:Quad(material,p(l,b,n),p(l,t,n),p(r,b,n),p(r,t,n))
    self:Quad(material,p(r,b,f),p(r,t,f),p(l,b,f),p(l,t,f))
    self:Quad(material,p(l,b,f),p(l,t,f),p(l,b,n),p(l,t,n))
    self:Quad(material,p(r,b,n),p(r,t,n),p(r,b,f),p(r,t,f))
    self:Quad(material,p(l,t,n),p(l,t,f),p(r,t,n),p(r,t,f))
    self:Quad(material,p(l,b,f),p(l,b,n),p(r,b,f),p(r,b,n))
    self.boxes = self.boxes + 1
end

---@param material string
---@param x number
---@param z number
---@param w number
---@param d number
---@param y? number
function Details:Ground(material,x,z,w,d,y)
    local yy = y or .05
    -- 视觉地面与查询共用同一份矩形，标线只是贴花，不额外垫高鞋底和轮胎。
    if material~="paint" and material~="yellow" then
        local surface={x=x,z=z,w=w,d=d,y=yy}
        self.surfaces[#self.surfaces+1]=surface
        -- 16m格只筛候选，最终仍按真实矩形判断，不做高度量化或插值。
        for gx=math.floor((x-w/2)/16),math.floor((x+w/2)/16) do
            for gz=math.floor((z-d/2)/16),math.floor((z+d/2)/16) do
                local key=gx..":"..gz
                local list=self.surfaceCells[key] or {}
                list[#list+1]=surface
                self.surfaceCells[key]=list
            end
        end
    end
    self:Quad(material,V(x-w/2,yy,z-d/2),V(x-w/2,yy,z+d/2),V(x+w/2,yy,z-d/2),V(x+w/2,yy,z+d/2))
end

function Details:Surface(x,z)
    local height=0
    local candidates=self.surfaceCells[math.floor(x/16)..":"..math.floor(z/16)]
    if not candidates then return height end
    for _,s in ipairs(candidates) do
        if math.abs(x-s.x)<=s.w/2 and math.abs(z-s.z)<=s.d/2 then
            height=math.max(height,s.y)
        end
    end
    return height
end

---@param mat string
---@param a Vector3
---@param b Vector3
---@param diameter number
function Details:Bar(mat,a,b,diameter)
    local delta = b-a
    local node = self.root:CreateChild("CityMetalTube")
    node.position = (a+b)*.5
    node.rotation = Quaternion(Vector3.UP, delta:Normalized())
    node.scale = V(diameter,delta:Length(),diameter)
    local draw = node:CreateComponent("StaticModel")
    draw.model = self.shapes.cylinder
    draw.material = self.mats[mat]
    draw.castShadows = true
    draw.shadowDistance,draw.drawDistance = 65,260
    self.cylinders = self.cylinders + 1
end

---@param text string
---@param x number
---@param y number
---@param z number
---@param yaw number
---@param height number
---@param color? Color
function Details:Sign(text,x,y,z,yaw,height,color)
    local node = self.root:CreateChild("CitySign_"..text)
    node.position = V(x,y,z)
    node.rotation = Quaternion(0,yaw,0)
    -- Text3D uses 1/128 metre per font pixel. A 64px font is 0.5m before scaling.
    node:SetScale(height*2)
    local label = node:CreateComponent("Text3D")
    assert(label:SetFont(self.font,64),"City: Text3D font rejected")
    label.text = text
    label:SetAlignment(HA_CENTER,VA_CENTER)
    label.textAlignment = HA_CENTER
    label.color = color or Color(.92,.89,.77)
    label.faceCameraMode = FC_NONE
    label.fixedScreenSize = false
    label.drawDistance = 110
    label.castShadows = false
    self.signs = self.signs + 1
end

-- Window recess + sill + frame + divided reflective glass; not a single painted wall.
---@param x number
---@param y number
---@param z number
---@param yaw number
---@param w number
---@param h number
---@param warm boolean
function Details:Window(x,y,z,yaw,w,h,warm)
    local a=math.rad(yaw)
    local function box(mat,px,py,pz,sx,sy,sz)
        self:Box(mat,x+px*math.cos(a)+pz*math.sin(a),y+py,z-px*math.sin(a)+pz*math.cos(a),sx,sy,sz,yaw)
    end
    box("recess",0,0,.03,w+.22,h+.22,.12)
    box(warm and "windowWarm" or "glass",0,0,-.055,w,h,.045)
    for _,side in ipairs({-1,1}) do
        box("trim",side*(w/2+.025),0,-.115,.065,h+.14,.12)
        box("trim",0,side*(h/2+.025),-.115,w+.15,.065,.12)
    end
    box("frame",0,0,-.14,.055,h,.07)
    box("frame",0,-h*.13,-.14,w,.045,.07)
    box("stone",0,-h/2-.11,-.17,w+.35,.13,.35)
end

-- Old flats: balconies actually protrude 1.25m and carry metal balusters / AC compressors.
---@param x number
---@param y number
---@param z number
---@param yaw number
---@param ac boolean
function Details:Balcony(x,y,z,yaw,ac)
    local angle=math.rad(yaw)
    local function box(mat,px,py,pz,w,h,d)
        self:Box(mat,x+px*math.cos(angle)+pz*math.sin(angle),y+py,z-px*math.sin(angle)+pz*math.cos(angle),w,h,d,yaw)
    end
    box("concrete",0,-1.03,-.58,3.1,.18,1.35)
    box("metal",0,-.03,-1.19,3.0,.065,.07)
    box("metal",0,-.76,-1.19,3.0,.065,.07)
    for i=-5,5 do box("metal",i*.28,-.40,-1.19,.035,.82,.035) end
    for _,side in ipairs({-1,1}) do
        box("metal",side*1.45,-.03,-.60,.055,.055,1.25)
        box("metal",side*1.45,-.43,-.93,.045,.86,.045)
    end
    if ac then
        box("trim",1.85,-.35,-.42,.80,.58,.42)
        box("recess",1.85,-.35,-.65,.56,.42,.025)
        for i=-2,2 do box("metal",1.85,-.35+i*.075,-.67,.55,.022,.035) end
        box("metal",1.85,-.70,-.35,.90,.055,.55)
    else
        box("wood",-.83,-.75,-.86,.55,.35,.30)
        box("foliage",-.83,-.47,-.86,.65,.24,.42)
    end
end

---@param x number
---@param z number
---@param yaw number
function Details:Bench(x,z,yaw)
    local a=math.rad(yaw)
    local function box(mat,px,py,pz,w,h,d)
        self:Box(mat,x+px*math.cos(a)+pz*math.sin(a),py,z-px*math.sin(a)+pz*math.cos(a),w,h,d,yaw)
    end
    for i=1,5 do box("wood",0,.52,-.30+i*.12,2.3,.075,.095) end
    for i=1,3 do box("wood",0,.73+i*.14,.37,2.3,.105,.07) end
    for _,side in ipairs({-1,1}) do
        box("metal",side*.88,.30,0,.11,.60,.60)
        box("metal",side*.88,.79,.34,.07,.70,.07)
        box("metal",side*1.02,.74,.03,.065,.065,.62)
    end
end

---@param x number
---@param z number
---@param yaw number
function Details:Lamp(x,z,yaw)
    local a=math.rad(yaw)
    local dx,dz=math.sin(a),math.cos(a)
    self:Box("metal",x,.18,z,.44,.26,.44)
    self:Bar("metal",V(x,.24,z),V(x,6.2,z),.13)
    self:Bar("metal",V(x,6.13,z),V(x+dx*1.25,6.35,z+dz*1.25),.09)
    self:Box("metal",x+dx*1.25,6.33,z+dz*1.25,.42,.13,1.05,yaw)
    self:Box("lamp",x+dx*1.25,6.25,z+dz*1.25,.32,.035,.88,yaw)
end

function Details:Finish()
    local vertices=0
    for _,batch in pairs(self.batches) do
        assert(batch.geometry:GenerateTangents(),"City: tangent generation failed")
        batch.geometry:Commit()
        vertices=vertices+batch.vertices
    end
    return {batches=self.meshCount,boxes=self.boxes,signs=self.signs,trees=self.trees,cylinders=self.cylinders,triangles=vertices/3}
end

return Details
