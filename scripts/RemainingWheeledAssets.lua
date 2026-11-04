-- Existing delivered MDLs only. Measurements use indexed LOD0 vertices AFTER the full orientation.
-- Asset paths are complete literals relative to assets/ (the engine resource root).
local V=Vector3
---@type table<string,table>
local vehicles={
    skateboard={
        model="model/934e58868cf545449203049b00c3445a/Meshes/934e58868cf545449203049b00c3445a.mdl",
        material="model/934e58868cf545449203049b00c3445a/Materials/934e58868cf545449203049b00c3445a_00_tripo_material_25d9de97-8c29-40c6-af1b-5b110f1d362b.xml",
        diffuse="model/934e58868cf545449203049b00c3445a/Textures/934e58868cf545449203049b00c3445a_00_D.jpg",
        normal="model/934e58868cf545449203049b00c3445a/Textures/934e58868cf545449203049b00c3445a_00_N.png",
        -- Principal deck frame; the duplicate intersecting board/four wheels are excluded by original-face selection only.
        orientation=Quaternion(-.10188119,.68305934,-.20876699,.69243520),rotation=-90,
        sourceSubset=true,sourceBounds=BoundingBox(V(-.18015138,-.18356871,-.57097238),V(.20130983,.04658664,.53457741)),
        targetSize=V(.55206735,.33309089,1.6),targetLength=1.6,
        measuredSize=V(.99951172,.64697266,.42138670),
        label="滑板",class="mixed",resources={},delivered=true,articulated=true,
        cockpit={localOffset=V(0,1.42,-.20),pitch=12,fov=78,
            grip=V(.22,1.06,.32),dash=V(0,1.08,.57),dashSize=Vector2(.30,.10),
            seatHeight=.46,torsoTilt=12,accent=Color(.95,.18,.40),dashboardAngle=-18},
    },
    sled={
        model="model/b14f68eb5e3845e89159579e5bf20ffd/Meshes/b14f68eb5e3845e89159579e5bf20ffd.mdl",
        material="model/b14f68eb5e3845e89159579e5bf20ffd/Materials/b14f68eb5e3845e89159579e5bf20ffd_00_tripo_material_33579349-53bc-4f93-a013-be787b3b092b.xml",
        diffuse="model/b14f68eb5e3845e89159579e5bf20ffd/Textures/b14f68eb5e3845e89159579e5bf20ffd_00_D.jpg",
        normal="model/b14f68eb5e3845e89159579e5bf20ffd/Textures/b14f68eb5e3845e89159579e5bf20ffd_00_N.png",
        orientation=Quaternion(0,180,0),rotation=180,
        targetSize=V(1.3493405,.9351734,2.7),targetLength=2.7,
        measuredSize=V(.49951172,.34619141,.99951172),
        label="雪橇",class="mixed",resources={},delivered=true,articulated=true,
        cockpit={localOffset=V(0,1.24,-.24),pitch=8,fov=76,
            grip=V(.29,.91,.37),dash=V(0,.99,.70),dashSize=Vector2(.40,.12),
            seatHeight=.49,torsoTilt=14,accent=Color(.18,.70,.92),dashboardAngle=-16},
    },
    cart={
        model="model/239058c144ed4c728d968452a32346ba/Meshes/239058c144ed4c728d968452a32346ba.mdl",
        material="model/239058c144ed4c728d968452a32346ba/Materials/239058c144ed4c728d968452a32346ba_00_tripo_material_54b96e64-285d-4c33-baf7-b76b6597741f.xml",
        diffuse="model/239058c144ed4c728d968452a32346ba/Textures/239058c144ed4c728d968452a32346ba_00_D.jpg",
        normal="model/239058c144ed4c728d968452a32346ba/Textures/239058c144ed4c728d968452a32346ba_00_N.png",
        orientation=Quaternion(0,-90,0),rotation=-90,
        targetSize=V(1.1308256,1.7947240,1.8),targetLength=1.8,
        measuredSize=V(.99951172,.99658203,.62792969),
        label="购物车",class="mixed",resources={},delivered=true,articulated=true,
        -- Eye is behind and ABOVE the original push handle/basket rim (1.795m), not inside the wire basket.
        cockpit={localOffset=V(0,2.08,-1.02),pitch=8,fov=80,
            grip=V(.40,1.74,-.80),dash=V(0,1.83,-.13),dashSize=Vector2(.36,.11),
            seatHeight=1.43,torsoTilt=8,accent=Color(.93,.58,.10),dashboardAngle=-16},
    },
}
return vehicles
