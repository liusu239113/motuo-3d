-- 房产纯业务查询：不读档、不写档、不调用云；所有价格均为游戏固定价，非现实房价。
local Housing=require("Career.HousingData")
local Property={}
Property.LIVING_RESERVE_CENTS=200000 -- 买断后至少留下2000元生活周转金。
Property.PRICE_NOTE="游戏内固定定价，非现实房价；买断后永久拥有，对应住处免每晚房费。"

---@param p CareerProfile
function Property.Normalize(p)
    -- 只补缺省字段；住宿选择、stayed/剧情旗标都不是产权凭证。非法字段留给Validate拒绝。
    if p.ownedHomes==nil then p.ownedHomes={} end
end
---@param p CareerProfile
---@param id string
---@return boolean
function Property.Owns(p,id)
    local home=Housing.Get(id)
    return home~=nil and home.buyPriceCents~=nil and type(p.ownedHomes)=="table" and p.ownedHomes[id]==true
end
---@param p CareerProfile
---@param id string
---@return integer
function Property.NightlyCost(p,id)
    local home=Housing.Get(id)
    if not home or Property.Owns(p,id) then return 0 end
    return home.price
end
---@param id string
---@return string
function Property.PurchaseKey(id) return "home:purchase:"..id end
---@param p CareerProfile
---@param id string
---@return boolean, string?
function Property.CanBuy(p,id)
    local home=Housing.Get(id)
    if not home or not home.buyPriceCents then return false,"此住处不出售产权；旅舍仍按晚住宿" end
    if Property.Owns(p,id) then return false,"已经拥有此房产，不会重复扣款" end
    if p.financialKeys[Property.PurchaseKey(id)] then return false,"此房产已有购买流水，请核对产权存档" end
    local reserve=math.max(Property.LIVING_RESERVE_CENTS,p.reserveCents or 0)
    if p.cashCents-home.buyPriceCents<reserve then
        return false,string.format("买断需%.2f元，购后还须保留至少%.2f元生活费（游戏定价，非现实房价）",home.buyPriceCents/100,reserve/100)
    end
    return true
end
-- 收藏与免租价值都可查：只免对应住处房费，不生租金/被动现金，不增大体力上限。
---@param p CareerProfile
---@param id string
---@return table?
function Property.Value(p,id)
    local home=Housing.Get(id)
    if not home then return nil end
    local owned=Property.Owns(p,id)
    local saving=home.buyPriceCents and home.price or 0
    return {id=id,owned=owned,selected=p.accommodation==id,energyAfterRest=home.energy,
        rentalNightlyCents=home.price,nightlyCents=Property.NightlyCost(p,id),
        potentialNightlySavingsCents=saving,potentialWeekSavingsCents=saving*7,
        currentWeekSavingsCents=owned and p.accommodation==id and saving*7 or 0,
        rentEquivalentNights=home.buyPriceCents and home.price>0 and math.ceil(home.buyPriceCents/home.price) or nil,
        passiveIncomeCents=0,collectionAsset=home.buyPriceCents~=nil,
        detail=home.buyPriceCents and "买断是长期收藏与稳定落脚点：只免这套住处每晚房费，休息恢复与同房型租住一致；不出租、不生利息或被动收入，也不替代饭钱、整备与训练预算。"
            or home.price==0 and "免费落脚点仍可正常休息；不需要买房才能继续配送、排班或买首车。"
            or "旅舍按晚收费，不出售产权；可先租住体验，不必为成长强行购房。"}
end
-- 返回独立展示快照；selected与owned分别表示今晚选择和永久产权，不混为一谈。
---@class CareerPropertyInfo
---@field id string
---@field name string
---@field point string
---@field owned boolean
---@field selected boolean
---@field purchasable boolean
---@field buyPriceCents? integer
---@field nightlyCents integer 实际当晚房费；有对应产权则为0
---@field rentalNightlyCents integer 未买断时的每晚租住价
---@field reserveCents integer 购买后必须保留的生活费
---@field canBuy boolean
---@field reason? string 不可购买的业务原因
---@field priceNote string 游戏定价免责声明与买断说明
---@param p CareerProfile
---@param id string
---@return CareerPropertyInfo?
function Property.Get(p,id)
    local home=Housing.Get(id)
    if not home then return nil end
    local canBuy,reason=Property.CanBuy(p,id)
    return {id=id,name=home.name,point=home.point,owned=Property.Owns(p,id),selected=p.accommodation==id,
        purchasable=home.buyPriceCents~=nil,buyPriceCents=home.buyPriceCents,
        nightlyCents=Property.NightlyCost(p,id),rentalNightlyCents=home.price,
        reserveCents=math.max(Property.LIVING_RESERVE_CENTS,p.reserveCents or 0),
        canBuy=canBuy,reason=reason,priceNote=Property.PRICE_NOTE}
end
---@param p CareerProfile
---@return CareerPropertyInfo[]
function Property.List(p)
    local result={}
    for _,home in ipairs(Housing.List) do
        if home.buyPriceCents then result[#result+1]=assert(Property.Get(p,home.id)) end
    end
    return result
end
---@param p CareerProfile
---@return boolean, string?
function Property.Validate(p)
    if type(p.ownedHomes)~="table" then return false,"房产产权字段无效" end
    for id,owned in pairs(p.ownedHomes) do
        local home=type(id)=="string" and Housing.Get(id) or nil
        if not home or not home.buyPriceCents or type(owned)~="boolean" then return false,"房产产权或房型无效" end
    end
    if type(p.financialKeys)~="table" or type(p.ledger)~="table" then return false,"房产流水字段无效" end
    for _,home in ipairs(Housing.List) do
        if home.buyPriceCents then
            local key=Property.PurchaseKey(home.id)
            local owned=p.ownedHomes[home.id]==true
            if owned~=(p.financialKeys[key]==true) then return false,"房产产权与买断流水不一致" end
            if owned then
                local found=false
                for _,entry in ipairs(p.ledger) do
                    if type(entry)=="table" and entry.id==key then
                        if entry.kind~="home_purchase" or entry.deltaCents~=-home.buyPriceCents then
                            return false,"房产买断金额或流水类型无效"
                        end
                        found=true
                    end
                end
                if not found then return false,"房产产权缺少买断流水" end
            end
        end
    end
    return true
end
return Property
