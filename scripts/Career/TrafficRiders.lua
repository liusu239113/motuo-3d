-- Two resident rider slots, not another traffic/pedestrian pool. No input, saves,
-- animation clocks or per-frame IK: the existing traffic owns motion and lifetime.
local Assets=require("VehicleAssets")
local Rider=require("Rider")
local Rig=require("Career.Rig")
local Pedestrians=require("Career.Pedestrians")
local Bike=require("Bike")
local F=require("Career.VehicleFootprints")
local Parts=require("Parts")
local V=Vector3

-- Footprint plan, metres, +Z forward (NOT the old truck's 5.4 x 2.76m box):
--                     front tyre
--                .----handlebar----.
--                | hands / elbows  |  real posed skin vertices, all LODs
--                | knees / chassis |  + referenced-triangle vehicle footprint
--                |   rear tyre     |
--                '---cargo box-----'  delivery only, F.CargoPosition
-- The union's symmetric X/Z extents form ONE conservative traffic OBB. Both
-- following/stop-line lengths AND TrafficMotion's id-less box use these extents.
-- This deliberately includes rider knees/boots, not a standing/T-pose bbox, a
-- truck collider, or a separate non-colliding visual. Pitch is Contact.Solve's
-- bounded +/-6 degrees, lean is zero; no unsampled leaning pose escapes the box.
-- Grazing/rotated corners/road ends use the existing <=.10m substeps and SAT.
---@class TrafficRiderVisual
---@field node Node
---@field vehicleId string
---@field kind string
---@field rider Rider
---@field length number
---@field width number
---@field skinBounds BoundingBox
---@field bounds BoundingBox
---@field cargo? Node
---@field body Node
---@field poseSolves integer
---@field materials Material[]
local R={}
R.MOTORCYCLE="sport"
R.DELIVERY="borrowed_ebike"
R.BUDGET=2
local scooterMaterial="model/873a3764f21f49e4b717387160d13d19/Materials/873a3764f21f49e4b717387160d13d19_00_tripo_material_a843f27f-7dc0-48b9-b818-99d319a20274.xml"
local boxMaterial="model/8c4f0f26f9ee4d3eac2eec49a497852f/Materials/8c4f0f26f9ee4d3eac2eec49a497852f_00_tripo_material_da86ec09-2a15-4a63-a371-538bf705b4fa.xml"
R.Resources=Assets.ResourcesFor({R.MOTORCYCLE})
R.ResourceTypes={}
for _,path in ipairs(R.Resources) do R.ResourceTypes[path]=Assets.ResourceTypes[path] end
local function resource(path,kind)
    if not R.ResourceTypes[path] then R.Resources[#R.Resources+1]=path; R.ResourceTypes[path]=kind end
end
-- No import-setting XMLs or unused rider colour palettes in the runtime loader.
for _,pack in ipairs({Rider,Rig}) do
    resource(pack.ModelPath,"Model"); resource(pack.MaterialPath,"Material")
    resource(pack.DiffusePath,"Texture2D"); resource(pack.NormalPath,"Texture2D")
end
resource(F.ScooterModel,"Model"); resource(scooterMaterial,"Material")
resource(F.BoxModel,"Model"); resource(boxMaterial,"Material")
resource("Techniques/DiffNormal.xml","Technique")
resource("Techniques/PBR/PBRNoTexture.xml","Technique")
resource("Models/Sphere.mdl","Model"); resource("Models/Cylinder.mdl","Model")

-- One CPU read at creation; do not retain the full skin buffers or Bone pointers.
-- Returned local bounds are also used by acceptance, independently of rendering.
---@param rider Rider
---@return BoundingBox
function R.SkinBounds(rider)
    ---@type Matrix3x4[]
    local matrices={}
    for i,name in ipairs(rider.boneNames) do
        local bone=rider.model:GetSkeleton():GetBone(name)
        matrices[i]=rider:GetLocalBoneTransform(name)*bone.offsetMatrix
    end
    local bounds=BoundingBox()
    for _,vertices in ipairs(rider:ReadSkinVertices()) do
        for _,vertex in ipairs(vertices) do
            local x,y,z=0,0,0
            for slot=1,4 do
                local p=matrices[vertex.indices[slot]+1]*vertex.position
                local w=vertex.weights[slot]
                x,y,z=x+p.x*w,y+p.y*w,z+p.z*w
            end
            bounds:Merge(V(x,y,z))
        end
    end
    return bounds
end
---@param target BoundingBox
---@param node Node
---@param model Model
local function mergeModel(target,node,model)
    local bb=model.boundingBox
    for _,x in ipairs({bb.min.x,bb.max.x}) do for _,y in ipairs({bb.min.y,bb.max.y}) do
        for _,z in ipairs({bb.min.z,bb.max.z}) do target:Merge(node.transform*V(x,y,z)) end
    end end
end
---@param parent Node
---@param name string
---@param modelPath string
---@param materialPath string
---@param rotation Quaternion
---@param scale number
---@param offset Vector3
---@return Node, Model
local function mesh(parent,name,modelPath,materialPath,rotation,scale,offset)
    local model=assert(cache:GetResource("Model",modelPath),modelPath)
    local node=parent:CreateChild(name)
    node:SetScale(scale);node.rotation=rotation;node.position=offset
    local draw=node:CreateComponent("StaticModel")
    draw.model=model;draw.material=assert(cache:GetResource("Material",materialPath),materialPath)
    draw.castShadows=true
    return node,model
end
---@param parent Node
---@param id string
---@return TrafficRiderVisual
function R.Add(parent,id)
    assert(id==R.MOTORCYCLE or id==R.DELIVERY,"Unsupported resident traffic rider")
    local node=parent:CreateChild("NPC骑行交通_"..id)
    local bounds=BoundingBox()
    ---@type Material[]
    local ownedMaterials={}
    ---@type Rider
    local rider
    ---@type Node
    local body
    ---@type Node?
    local cargo=nil
    if id==R.MOTORCYCLE then
        body=Assets.Add(node,id,nil,"distant")
        local model,rotation,scale,offset=F.AssetTransform(id)
        -- Assets.Add has a nested transformed mesh; use the exact same transform.
        local bb=model.boundingBox
        for _,x in ipairs({bb.min.x,bb.max.x}) do for _,y in ipairs({bb.min.y,bb.max.y}) do
            for _,z in ipairs({bb.min.z,bb.max.z}) do bounds:Merge(rotation*V(x,y,z)*scale+offset) end
        end end
        rider=Rider.New(node,id,Bike.GetCockpit(id).grip)
    else
        local model=assert(cache:GetResource("Model",F.ScooterModel))
        local rotation,scale,offset=F.ScooterTransform(model)
        body=mesh(node,"NPC正式配送电动车",F.ScooterModel,scooterMaterial,rotation,scale,offset)
        local bodyBounds=BoundingBox()
        mergeModel(bodyBounds,body,model)
        -- Diagonal source bbox has empty corners ~2m wide after yaw226.1.
        -- XZ comes from F's referenced triangles below, not those empty corners.
        bounds:Merge(V(0,bodyBounds.min.y,0));bounds:Merge(V(0,bodyBounds.max.y,0))
        local box=assert(cache:GetResource("Model",F.BoxModel))
        local br,bs,bo=F.BoxTransform(box)
        cargo=mesh(node,"NPC独立外卖保温箱",F.BoxModel,boxMaterial,br,bs,bo+F.CargoPosition)
        mergeModel(bounds,cargo,box)
        -- Match ActorVisuals' missing right mirror and cargo support, not a new bike.
        local metal=Parts.Material(.08,.09,.1,.55,.55)
        local mirror=Parts.Material(.45,.57,.62,.1,.85)
        ownedMaterials={metal,mirror}
        -- Parts materials are owned by these drawables; keep handles for disposal.
        Parts.Bar(node,metal,V(.29,1.21,.27),V(.31,1.40,.20),.008)
        Parts.Add(node,"NPC右镜壳","Sphere",metal,F.MirrorCenter,F.MirrorSize,Quaternion(0,F.MirrorYaw,0),true)
        Parts.Add(node,"NPC右镜片","Sphere",mirror,V(.306,1.425,.169),V(.125,.082,.012),Quaternion(0,12,0),false)
        for _,side in ipairs({-1,1}) do Parts.Bar(node,metal,V(side*.2,.68,-.56),V(side*.2,.88,-.91),.015) end
        -- 配送NPC必须与主角使用不同的真实模型，不靠同模型换色伪装。
        local asset=Pedestrians.Specs[2]
        rider=Rig.New(node,{model=asset.model,material=asset.material,diffuse=asset.diffuse,
            normal=asset.normal,height=asset.height,name="NPC配送骑手"})
        local courier=rider --[[@as CareerRig]]
        courier:PoseRide(0)
    end
    rider.model.drawDistance=180;rider.model.shadowDistance=35
    local skin=R.SkinBounds(rider)
    bounds:Merge(skin)
    local footprint=F.Get(id)
    bounds:Merge(V(footprint.x1,bounds.min.y,footprint.z1))
    bounds:Merge(V(footprint.x2,bounds.max.y,footprint.z2))
    -- Include pitch projection conservatively without ever replacing Contact's
    -- real tyre support points. Max rotation is +/-6deg; roll/steer stay fixed.
    local halfWidth=math.max(math.abs(bounds.min.x),math.abs(bounds.max.x))
    local halfLength=math.max(math.abs(bounds.min.z),math.abs(bounds.max.z))
        +math.max(math.abs(bounds.min.y),math.abs(bounds.max.y))*math.sin(math.rad(6))
    ---@type TrafficRiderVisual
    local visual={node=node,vehicleId=id,kind=id==R.DELIVERY and "delivery" or "motorcycle",rider=rider,
        width=2*halfWidth,length=2*halfLength,skinBounds=skin,bounds=bounds,body=body,cargo=cargo,poseSolves=1,materials=ownedMaterials}
    print(string.format("[NPC骑行槽] %s real posed OBB %.3fx%.3fm skinY[%.3f,%.3f]; shared traffic, fixed IK",id,visual.width,visual.length,skin.min.y,skin.max.y))
    return visual
end
---@param visual TrafficRiderVisual?
function R.Dispose(visual)
    if not visual or visual.rider.disposed then return end
    visual.rider:Dispose()
    for _,material in ipairs(visual.materials) do material:Dispose() end
    -- The containing root belongs to Traffic:Dispose.
end
return R
