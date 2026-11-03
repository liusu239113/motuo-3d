-- 主体阴影整改的只读状态检查：不改时段/人物/Zone/存档，不代替多场景截图验收。
-- 在隔离测试Session完成BuildWorld后显式调用 require("Career.SubjectVisualChecks").Run(session)。
local Rig=require("Career.Rig")
local Checks={}
local TECHNIQUE="Techniques/PBR/PBRDiffNormal.xml"
local function near(actual,expected,field)
    assert(math.abs(actual-expected)<.00001,string.format("主体材质 %s 数值 %.6f ~= %.6f",field,actual,expected))
end
-- XML四分量通常是Vector4，三分量是Vector3；GetColor不做类型转换，不能拿默认白色作证据。
-- 按真实Variant类型取分量，未知/缺失类型直接失败；数值容差保持不变。
---@param material Material
---@param parameter string
---@param expected number[]
---@param context string
local function components(material,parameter,expected,context)
    local value=material:GetShaderParameter(parameter)
    local kind=value:GetType()
    local field=context.."/"..parameter.." ["..value:GetTypeName().."]"
    local values={}
    if kind==VAR_VECTOR3 then
        local v=value:GetVector3(); values={v.x,v.y,v.z}
    elseif kind==VAR_VECTOR4 then
        local v=value:GetVector4(); values={v.x,v.y,v.z,v.w}
    elseif kind==VAR_COLOR then
        local v=value:GetColor(); values={v.r,v.g,v.b,v.a}
    else
        error("主体材质类型错误 "..field.." value="..value:ToString())
    end
    assert(#values>=#expected,"主体材质分量不足 "..field)
    for i,target in ipairs(expected) do near(values[i],target,field.." component"..i) end
end
---@param material Material
---@param parameter string
---@param expected number
---@param context string
local function scalar(material,parameter,expected,context)
    local value=material:GetShaderParameter(parameter)
    local kind=value:GetType()
    local field=context.."/"..parameter.." ["..value:GetTypeName().."]"
    assert(kind==VAR_FLOAT or kind==VAR_DOUBLE or kind==VAR_INT,"主体材质标量类型错误 "..field)
    near(value:GetFloat(),expected,field)
end
---@param session CareerSession
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "主体视觉检查只允许显式隔离test storage")
    local actor=assert(session.actor)
    ---@type CareerActorVisuals
    local visuals=actor.visuals
    assert(not visuals.disposed and #visuals.ownedMaterials==2,"电动车/软箱必须各有一个私有clone")
    local sources={}
    local count=0
    for _,record in ipairs(visuals.subjectMaterials) do
        local draw,material=record.draw,record.material
        local source=assert(cache:GetResource("Material",record.sourcePath))
        assert(material~=source and draw:GetMaterial()==material,"不能修改缓存材质或只写元数据不应用到主体")
        assert(draw.castShadows,"主体必须继续投影")
        assert(material:GetTechnique(0).name==TECHNIQUE,"主体必须走贴图PBR，不能换unlit")
        assert(material:GetTexture(TU_DIFFUSE) and material:GetTexture(TU_NORMAL),"主体D/N贴图不能丢失")
        local context=record.sourcePath.."/"..draw.node.name
        components(material,"MatDiffColor",{1,1,1,1},context)
        components(material,"MatSpecColor",{.5,.5,.5,1},context)
        scalar(material,"Metallic",record.metallic,context)
        scalar(material,"Roughness",record.roughness,context)
        assert(record.metallic>=0 and record.metallic<=.12 and record.roughness>=.78,"混合主体不能是全金属/镜面")
        components(material,"MatEmissiveColor",{0,0,0},context)
        if record.sourcePath==Rig.MaterialPath then
            assert(material:GetTexture(TU_DIFFUSE)==cache:GetResource("Texture2D",Rig.DiffusePath)
                and material:GetTexture(TU_NORMAL)==cache:GetResource("Texture2D",Rig.NormalPath),"主角须保留真实D/N贴图")
            assert(source:GetTechnique(0).name=="Techniques/DiffNormal.xml","主角缓存源Technique被改动")
            components(source,"MatDiffColor",{.8,.8,.8,1},context.." cached-source")
        else
            assert(material:GetTexture(TU_DIFFUSE)==source:GetTexture(TU_DIFFUSE)
                and material:GetTexture(TU_NORMAL)==source:GetTexture(TU_NORMAL),"电动车/软箱clone必须保留源贴图")
            scalar(source,"Metallic",1,context.." cached-source")
            scalar(source,"Roughness",1,context.." cached-source")
        end
        sources[material]=true
        count=count+1
    end
    assert(sources[visuals.walker.material],"步行主角未应用主体材质")
    local vehicles=0
    for _,entry in pairs(visuals.vehicles) do
        vehicles=vehicles+1
        assert(sources[entry.rider.material],"换车骑手未应用同一主体材质策略")
    end
    assert(count==3+vehicles,"应覆盖车身/软箱/步行主角/所有已装配骑手，且不每帧追加")
    local zone=assert(session.zone)
    local capture=zone.node:GetComponent("SkyLightCapture")
    local report={materials=count,ownedMaterials=#visuals.ownedMaterials,vehicles=vehicles,
        ambientSource=zone.ambientSource,diffuseIntensity=zone.envTextureDiffIntensity,
        specularIntensity=zone.envTextureSpecIntensity,captureSupported=capture and capture.supported or false,
        captureReady=capture and capture.ready or false,visualAccepted=false}
    -- 记录真实来源，不把AMBIENT_PREBAKED下ambientColor当作有效补光证据。
    print(string.format("[主体材质状态] PASS %d材质/2私有车箱clone，ambientSource=%s diffuse=%.3f specular=%.3f capture=%s/%s；非视觉验收",
        count,tostring(report.ambientSource),report.diffuseIntensity,report.specularIntensity,
        tostring(report.captureSupported),tostring(report.captureReady)))
    return report
end
-- 由拥有临时Visuals夹具的调用方在Dispose后显式调用；不碰已销毁引擎指针。
---@param visuals CareerActorVisuals
function Checks.AssertDisposed(visuals)
    assert(visuals.disposed and #visuals.subjectMaterials==0 and #visuals.ownedMaterials==0,
        "主体材质所有权记录在Dispose后必须清空")
    return true
end
return Checks
