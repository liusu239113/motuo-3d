-- 正式赛道资源：只加载资源库MDL/原配贴图，不创建程序化几何或占位回退。
-- 原始尺寸已用 UrhoXCLI model-info 校验；所有缩放均等比，判定反向消费模型尺寸。
local M = {Resources = {}, ResourceTypes = {}}

---@class CourseAssetSpec
---@field model string
---@field materials string[]
---@field height? number
---@field width? number
---@field rotation? number
---@field textures? string[]

---@type table<string, CourseAssetSpec>
M.Assets = {
    cone = {
        model="model/b1a9c6c1-17ff-570b-b138-cc3c56687aca/Meshes/405e39c58b744fb880a9a57077c20f52.mdl",
        materials={"model/b1a9c6c1-17ff-570b-b138-cc3c56687aca/Materials/405e39c58b744fb880a9a57077c20f52_00_tripo_material_647d9e83-f79f-4971-b5da-638a8b2a8a5c.xml"},
        height=1,
        textures={
            "model/b1a9c6c1-17ff-570b-b138-cc3c56687aca/Textures/405e39c58b744fb880a9a57077c20f52_00_D.jpg",
            "model/b1a9c6c1-17ff-570b-b138-cc3c56687aca/Textures/405e39c58b744fb880a9a57077c20f52_00_N.jpg",
        },
    },
    barrier = {
        model="model/e4605b5e-8039-5227-b526-b156e6079809/Meshes/38f72a8b1652444c9fa5d6f56662864d.mdl",
        materials={"model/e4605b5e-8039-5227-b526-b156e6079809/Materials/38f72a8b1652444c9fa5d6f56662864d_00_tripo_material_b1723786-54a8-471c-8e54-5ca76e5b6c83.xml"},
        width=1.8,
        textures={
            "model/e4605b5e-8039-5227-b526-b156e6079809/Textures/38f72a8b1652444c9fa5d6f56662864d_00_D.jpg",
            "model/e4605b5e-8039-5227-b526-b156e6079809/Textures/38f72a8b1652444c9fa5d6f56662864d_00_N.jpg",
        },
    },
    barrel = {
        model="model/01d791df-3e8a-569b-815a-98f265362dfd/Meshes/16ba202f8524403ea1039454396e80e9.mdl",
        materials={"model/01d791df-3e8a-569b-815a-98f265362dfd/Materials/16ba202f8524403ea1039454396e80e9_00_tripo_material_8a4d5cd8-f45e-4766-9ba7-bab9f4b55722.xml"},
        height=1.1,
        textures={
            "model/01d791df-3e8a-569b-815a-98f265362dfd/Textures/16ba202f8524403ea1039454396e80e9_00_D.jpg",
            "model/01d791df-3e8a-569b-815a-98f265362dfd/Textures/16ba202f8524403ea1039454396e80e9_00_N.jpg",
        },
    },
    crate = {model="uuid://AcrtETrXQRNdAJwJjHFTC0zj",materials={"uuid://BZMgKQ65FvgNzgqauakPtC3i"},height=1},
    pendulum = {model="uuid://D7n_6V_rtPwQLt40dZNjA0kR",materials={"uuid://HpOt4UebshHMGRAj_4H_4myd","uuid://A5geaR2uRsC4dxLIpCrZRqjS"}},
    support = {model="uuid://FBr3IdQFvT3mFeVmvX9okC2x",materials={"uuid://HrIh2dtEAc443DDrUiLRBIp_","uuid://D9ZkWSeDQ4blSbR7bs3DCeaH"}},
    chain = {model="uuid://DsZVQVzbVqTJ3CzCGGxMCfC2",materials={"uuid://HpOt4UebshHMGRAj_4H_4myd"}},
    warning = {model="uuid://GIhnKbxaG5H188E6gfht6oDq",materials={"uuid://ABu8UQaYGrrdXFY-GKPOKtVC"},height=.95},
    coin = {model="uuid://HbNZMUix9tNCcOnf8cw8DCxx",materials={"uuid://G5K1oVd2mzbIBfDC8nalwrwk"},width=.6,rotation=90},
}

local function resource(path, kind)
    if not M.ResourceTypes[path] then
        M.Resources[#M.Resources+1]=path
        M.ResourceTypes[path]=kind
    end
end
resource("Techniques/PBR/PBRDiffNormal.xml","Technique")
for _, key in ipairs({"cone","barrier","barrel","crate","pendulum","support","chain","warning","coin"}) do
    local spec=M.Assets[key]
    resource(spec.model,"Model")
    for _, path in ipairs(spec.materials) do resource(path,"Material") end
    for _, path in ipairs(spec.textures or {}) do resource(path,"Texture2D") end
end
-- 官方材质原配D/N明确预热；其余spec/AO/Technique仍沿官方资源引用链加载。
for _, path in ipairs({
    "uuid://GHxCSX91PxRvA5fO0oSDme8W","uuid://HVPhAeYdnCxj_G8YNUgrAwuk",
    "uuid://Ah-0eZdZdDk15PS8nvLpabiI","uuid://AyG9CVoSLiq8UXLR09jQLU9u",
    "uuid://Choa0eyJ9qWoEmbo5gq7SAN5","uuid://Cu8rSQwwWP8QgDuJwC_rAtIq",
    "uuid://Fmhd6fx_TS3yGCsWCxlHEJrH","uuid://EriCsffMirBGZfqhneJ6ue_g",
}) do resource(path,"Texture2D") end

---@param parent Node
---@param key string
---@param name string
---@param scaleOverride? number
---@return Node?, Vector3?, number?
function M.Add(parent,key,name,scaleOverride)
    local spec=M.Assets[key]
    if not spec then print("[CourseAssets] 未知正式资源 "..key);return nil end
    local model=cache:GetResource("Model",spec.model)
    if not model then print("[CourseAssets] 正式模型未就绪 "..spec.model);return nil end
    ---@type Material[]
    local materials={}
    for _,path in ipairs(spec.materials) do
        local mat=cache:GetResource("Material",path)
        if not mat then print("[CourseAssets] 正式材质未就绪 "..path);return nil end
        materials[#materials+1]=mat
    end
    local rotation=Quaternion(spec.rotation or 0,0,0)
    local box=model.boundingBox:Transformed(rotation:RotationMatrix())
    local size,center=box.size,box.center
    local scale=scaleOverride or (spec.height and spec.height/size.y) or (spec.width and spec.width/size.x) or 1
    local node=parent:CreateChild(name)
    local mesh=node:CreateChild("FormalMesh")
    mesh.rotation=rotation
    mesh.scale=Vector3(scale,scale,scale)
    mesh.position=Vector3(-center.x*scale,-box.min.y*scale,-center.z*scale)
    local drawable=mesh:CreateComponent("StaticModel")
    drawable.model=model
    for i,mat in ipairs(materials) do drawable:SetMaterial(i-1,mat) end
    drawable.castShadows=true
    drawable.drawDistance=280
    drawable.shadowDistance=65
    return node,size*scale,scale
end
return M
