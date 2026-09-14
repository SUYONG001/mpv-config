-- ==============================================================================
-- Elements.lua — UI 元素管理器
-- ==============================================================================
-- 功能概述：
--   1. 这是 uosc 框架中所有 UI 元素的核心管理器
--   2. 负责元素的注册（add）、移除（remove）和生命周期管理
--   3. 统一更新所有元素的鼠标接近度（update_proximities）
--   4. 提供批量操作：切换显隐（toggle）、设置最小可见度（set_min_visibility）、闪动（flash）
--   5. 事件分发：向所有元素广播事件（trigger）或仅向接近鼠标的元素分发（proximity_trigger）
--   6. 提供便捷的查询接口：获取元素属性（v）、调用元素方法（maybe）
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- Elements 表定义
-- 既是管理器对象，也直接作为元素容器（通过 `Elements[id]` 直接访问元素）
-- ==============================================================================

local Elements = {_all = {}}
-- `_all` 存储所有已注册元素的数组（按渲染顺序排序）
-- Elements 本身也作为哈希表，通过 `Elements[id]` 直接访问元素

-- ==============================================================================
-- 元素注册 (add)
-- 向管理器注册一个新元素
-- ==============================================================================

---@param element Element 要注册的元素实例
function Elements:add(element)
    -- 元素必须有 ID
    if not element.id then
        msg.error('attempt to add element without "id" property')
        return
    end

    -- 如果已存在同 ID 的元素，先移除旧的
    if self:has(element.id) then
        Elements:remove(element.id)
    end

    -- 添加到数组和哈希表
    self._all[#self._all + 1] = element
    self[element.id] = element

    -- 按渲染顺序排序（render_order 数值越小越靠底层）
    table.sort(self._all, function(a, b) return a.render_order < b.render_order end)

    -- 请求重新渲染
    request_render()
end

-- ==============================================================================
-- 元素移除 (remove)
-- 从管理器中移除一个元素
-- ==============================================================================

function Elements:remove(idOrElement)
    if not idOrElement then return end

    -- 支持传入元素 ID 或元素对象
    local id = type(idOrElement) == 'table' and idOrElement.id or idOrElement
    local element = Elements[id]

    if element then
        -- 如果元素尚未销毁，先销毁它
        if not element.destroyed then
            element:destroy()
        end
        -- 禁用元素（防止后续事件）
        element.enabled = false

        -- 从数组中移除
        self._all = itable_delete_value(self._all, self[id])
        -- 从哈希表中移除
        self[id] = nil

        request_render()
    end
end

-- ==============================================================================
-- 更新所有元素的鼠标接近度 (update_proximities)
-- 遍历所有元素，计算鼠标到每个元素的距离，并触发进入/离开事件
-- ==============================================================================

function Elements:update_proximities()
    -- 获取幕布的渲染顺序（幕布打开时，低于幕布的元素被禁用）
    local curtain_render_order = Elements.curtain.opacity > 0 and Elements.curtain.render_order or 0

    -- 记录进入/离开的元素列表（避免在遍历过程中修改）
    local mouse_leave_elements = {}
    local mouse_enter_elements = {}

    -- 计算所有元素的接近度
    for _, element in self:ipairs() do
        if element.enabled then
            local previous_proximity_raw = element.proximity_raw

            -- 如果幕布打开，所有渲染顺序低于幕布的元素被禁用接近度
            if not element.ignores_curtain and element.render_order < curtain_render_order then
                element:reset_proximity()
            else
                element:update_proximity()
            end

            -- 检测鼠标进入/离开事件
            if element.proximity_raw <= 0 then
                -- 鼠标进入元素区域（之前在外面）
                if previous_proximity_raw > 0 then
                    mouse_enter_elements[#mouse_enter_elements + 1] = element
                end
            else
                -- 鼠标离开元素区域（之前在里面）
                if previous_proximity_raw <= 0 then
                    mouse_leave_elements[#mouse_leave_elements + 1] = element
                end
            end
        end
    end

    -- 触发事件（先触发离开，再触发进入）
    for _, element in ipairs(mouse_leave_elements) do
        element:trigger('mouse_leave')
    end
    for _, element in ipairs(mouse_enter_elements) do
        element:trigger('mouse_enter')
    end
end

-- ==============================================================================
-- 切换元素的可见度 (toggle)
-- 将指定元素的最小可见度在 0 和 1 之间切换
-- ==============================================================================

---@param ids string[] 要切换的元素 ID 列表
function Elements:toggle(ids)
    -- 检查是否有元素当前是不可见状态（min_visibility != 1）
    -- 如果有，说明需要"开启"（设为 1），否则"关闭"（设为 0）
    local has_invisible = itable_find(ids, function(id)
        return Elements[id] and Elements[id].enabled and (Elements[id].min_visibility or 0) ~= 1
    end)

    -- 设置最小可见度（有不可见的元素则设为 1，否则设为 0）
    self:set_min_visibility(has_invisible and 1 or 0, ids)

    -- 如果是要关闭（设为 0），重置元素的接近度
    -- 必须在 set_min_visibility 之后执行，因为 set_min_visibility 使用了接近度作为动画起点
    if not has_invisible then
        for _, id in ipairs(ids) do
            if Elements[id] then
                Elements[id]:reset_proximity()
            end
        end
    end
end

-- ==============================================================================
-- 设置元素的最小可见度 (set_min_visibility)
-- 使用动画将指定元素的最小可见度过渡到目标值
-- ==============================================================================

---@param visibility number 0-1 浮点数（目标最小可见度）
---@param ids string[] 要设置的元素 ID 列表
function Elements:set_min_visibility(visibility, ids)
    for _, id in ipairs(ids) do
        local element = Elements[id]
        if element then
            -- 从当前可见度开始动画到目标值
            local from = math.max(0, element:get_visibility())
            element:tween_property('min_visibility', from, visibility)
        end
    end
end

-- ==============================================================================
-- 闪动元素 (flash)
-- 让指定元素短暂闪烁（通常用于反馈操作）
-- ==============================================================================

---@param ids string[] 要闪动的元素 ID 列表
function Elements:flash(ids)
    -- 过滤出存在的元素
    local elements = itable_filter(self._all, function(element)
        return itable_has(ids, element.id)
    end)

    -- 触发每个元素的闪动
    for _, element in ipairs(elements) do
        element:flash()
    end

    -- 特殊处理：'progress' 是 timeline 的状态，不是独立元素
    if itable_has(ids, 'progress') and not itable_has(ids, 'timeline') then
        Elements:maybe('timeline', 'flash_progress')
    end
end

-- ==============================================================================
-- 事件触发 (trigger)
-- 向所有元素广播事件
-- ==============================================================================

---@param name string 事件名（会触发元素的 on_xxx 方法）
function Elements:trigger(name, ...)
    for _, element in self:ipairs() do
        element:trigger(name, ...)
    end
end

-- ==============================================================================
-- 接近度事件触发 (proximity_trigger)
-- 根据鼠标接近度触发事件，只有鼠标悬停的元素才会收到事件
-- ==============================================================================

-- 触发两个事件：`name` 和 `global_name`，取决于元素与鼠标的接近度
-- 禁用状态的元素不会收到事件
---@param name string 事件名
function Elements:proximity_trigger(name, ...)
    -- 从数组末尾开始遍历（上层元素优先）
    for i = #self._all, 1, -1 do
        local element = self._all[i]

        if element.enabled then
            -- 如果鼠标在元素内，触发普通事件
            if element.proximity_raw <= 0 then
                if element:trigger(name, ...) == 'stop_propagation' then
                    break
                end
            end

            -- 触发全局事件（无论鼠标是否在元素内，只要元素可见）
            if element:trigger('global_' .. name, ...) == 'stop_propagation' then
                break
            end
        end
    end
end

-- ==============================================================================
-- 查询辅助方法
-- ==============================================================================

-- 获取元素属性（带默认值）
---@param id string 元素 ID
---@param prop string 属性名
---@param fallback any 默认值
function Elements:v(id, prop, fallback)
    if self[id] and self[id].enabled and self[id][prop] ~= nil then
        return self[id][prop]
    end
    return fallback
end

-- 调用元素的方法（如果元素存在）
---@param id string 元素 ID
---@param method string 方法名
function Elements:maybe(id, method, ...)
    if self[id] then
        return self[id]:maybe(method, ...)
    end
end

-- 检查元素是否存在
function Elements:has(id)
    return self[id] ~= nil
end

-- 返回元素的迭代器
function Elements:ipairs()
    return ipairs(self._all)
end

return Elements