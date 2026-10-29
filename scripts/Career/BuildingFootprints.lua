-- Offline LOD0 triangle clipping metadata. No startup triangle traversal on mobile.
-- Source MDLs measured by UrhoXCLI model-info; clipped at ground..3.2m for current scales.
-- Each strip encloses *all* clipped triangle X extents AND fills the solid building interior.
-- This is conservative low-wall footprint, not exact mesh collision or arbitrary shrink.
local Footprints={}
Footprints.STRIPS=24
Footprints.HEIGHT=3.2
local specs={
    c531d52ef7284ea8ae32f415bfe4b98e={size={.798828125,.9980469346046448,.833984375},height=18,
        zmin=-.4169921875,zmax=.4169921875,
        rows={false,{-.3926324,.3562500},{-.3959129,.3702908},{-.3964516,.3708651},
            {-.3969904,.3714395},{-.3975291,.3720139},{-.3980679,.3725882},{-.3986066,.3731626},
            {-.3991454,.3737370},{-.3994141,.3740235},{-.3994141,.3740235},{-.3994141,.3740235},
            {-.3994141,.3740235},{-.3994141,.3740235},{-.3994141,.3740235},{-.3992101,.3740235},
            {-.3984655,.3740235},{-.3977208,.3740235},{-.3969762,.3740235},{-.3962316,.3740235},
            {-.3954869,.3740235},{-.3947423,.3740235},{-.3939977,.3740235},{-.3865154,.3596396}}},
    -- This model really contains a continuous low plinth across almost its entire bbox.
    -- Do NOT shrink it to the narrower upper shopfront just because that looks walkable.
    ["94b007f45c784751825b3e1b8e1e624a"]={size={.755859375,.9980469048023224,.763671875},height=18,
        zmin=-.3818359076976776,zmax=.3818359673023224,full={-.3779297,.3759766}},
    ["863a459ef93647c88fe260263a9b2a1d"]={size={.517578125,.9980469048023224,.931640625},height=20,
        zmin=-.4658202826976776,zmax=.4658203423023224,regular={-.2509766,.2509766},wide={-.2587891,.2587891}},
}
local memo={}
---@param model Model
---@param scale number
---@return table[]
function Footprints.ForModel(model,scale)
    local key=model.name..":"..string.format("%.9f",scale)
    if memo[key] then return memo[key] end
    local bounds=model.boundingBox
    local stem=model.name:match("([^/]+)%.mdl$")
    local spec=specs[stem or ""]
    local valid=spec and math.abs(bounds.size.x-spec.size[1])<1e-6
        and math.abs(bounds.size.y-spec.size[2])<1e-6 and math.abs(bounds.size.z-spec.size[3])<1e-6
        and math.abs(bounds.size.y*scale-spec.height)<.001
    local result={}
    if valid then
        local step=(spec.zmax-spec.zmin)/Footprints.STRIPS
        for i=1,Footprints.STRIPS do
            local row=spec.full or spec.regular and (i==10 and spec.wide or spec.regular) or spec.rows[i]
            if row then
                result[#result+1]={x1=(row[1]-bounds.center.x)*scale-.05,x2=(row[2]-bounds.center.x)*scale+.05,
                    z1=(spec.zmin+(i-1)*step-bounds.center.z)*scale-.05,
                    z2=(spec.zmin+i*step-bounds.center.z)*scale+.05}
            end
        end
    end
    if #result==0 then
        -- Unknown/replaced mesh/scale fails closed. Never silently erase walls.
        result={{x1=-bounds.size.x*scale/2-.05,x2=bounds.size.x*scale/2+.05,
            z1=-bounds.size.z*scale/2-.05,z2=bounds.size.z*scale/2+.05}}
        print("[City footprint] metadata mismatch; safe bbox fallback: "..model.name)
    end
    -- Merge identical adjacent strips; sources with a full low plinth need only one box.
    local merged={}
    for _,rect in ipairs(result) do
        local last=merged[#merged]
        if last and last.x1==rect.x1 and last.x2==rect.x2 and rect.z1<=last.z2 then last.z2=rect.z2
        else merged[#merged+1]=rect end
    end
    memo[key]=merged
    print(string.format("[City footprint] %s / %d low-wall strips",model.name,#merged))
    return merged
end

-- Exact for current cardinal building yaw. Non-cardinal future yaw stays conservatively enclosed.
function Footprints.WorldRect(rect,x,z,yaw)
    local a=math.rad(yaw)
    local cs,sn=math.cos(a),math.sin(a)
    local cx,cz=(rect.x1+rect.x2)/2,(rect.z1+rect.z2)/2
    local wx,wz=x+cx*cs+cz*sn,z-cx*sn+cz*cs
    local hx,hz=(rect.x2-rect.x1)/2,(rect.z2-rect.z1)/2
    local ex,ez=math.abs(cs)*hx+math.abs(sn)*hz,math.abs(sn)*hx+math.abs(cs)*hz
    return {x1=wx-ex,x2=wx+ex,z1=wz-ez,z2=wz+ez}
end
return Footprints
