-- ==============================================================================
-- cursor.lua — 鼠标光标事件管理模块
-- ==============================================================================
-- 功能概述：
--   1. 管理鼠标光标的位置、可见性和移动事件
--   2. 提供 Zone（区域）机制：UI 元素在渲染时注册可点击区域
--   3. 支持左键、右键、滚轮等鼠标事件的触发和转发
--   4. 自动处理光标自动隐藏（在无操作一段时间后）
--   5. 动态管理鼠标按键的键盘绑定组（启用/禁用）
--   6. 支持触摸屏事件（将触摸转换为鼠标事件）
--   7. 计算光标移动速度和方向（用于惯性滚动判断）
-- ==============================================================================
-- 设计特点：
--   - Zone 机制：UI 元素在每次渲染时注册事件区域，事件只触发到最上层区域
--   - 事件转发：未在 UI 层处理的事件会转发给 mpv 的 input.conf 绑定
--   - 拖动拦截：在可拖动元素上按下滑鼠会禁用窗口拖动，防止误操作
--   - 复合事件：支持 click（down + up 在同一个区域内）的合成
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 类型定义 (Type Alias)
-- ==============================================================================

---@alias CursorEventHandler fun(shortcut: Shortcut)
-- 光标事件处理器类型：接收一个 Shortcut 对象作为参数

-- ==============================================================================
-- 2. cursor 表定义（核心状态）
-- ==============================================================================

local cursor = {
    -- 光标位置（默认为无穷大，表示不在窗口内）
    x = math.huge,
    y = math.huge,

    -- 光标是否隐藏
    hidden = true,

    -- 当前移动的累计距离（由 distance_reset_timer 定时重置）
    distance = 0,

    -- 上一次鼠标事件的 hover 状态（用于检测进入/离开）
    last_hover = false,

    -- ============================================================
    -- Zone（区域）列表：在每次渲染时由 UI 元素注册
    -- 每个 zone 包含事件类型、碰撞箱和回调函数
    -- ============================================================
    ---@type {event: string, hitbox: Hitbox; handler: CursorEventHandler}[]
    zones = {},

    -- ============================================================
    -- 全局事件处理器（永久绑定，直到手动取消）
    -- ============================================================
    handlers = {
        primary_down = {},
        primary_up = {},
        secondary_down = {},
        secondary_up = {},
        wheel_down = {},
        wheel_up = {},
        move = {},
    },

    -- 是否已收到第一次真实的鼠标移动事件
    first_real_mouse_move_received = false,

    -- 光标历史记录（最近 10 个位置，用于速度计算）
    history = CircularBuffer:new(10),

    -- 是否仅在全屏时自动隐藏光标
    autohide_fs_only = nil,

    -- ============================================================
    -- 键盘绑定级别
    -- 0: 禁用, 1: 启用, 2: 启用且阻止窗口拖动
    -- ============================================================
    binding_levels = {
        mbtn_left = 0,
        mbtn_left_dbl = 0,
        mbtn_right = 0,
        wheel = 0,
    },

    -- 当前是否正在阻止窗口拖动
    is_dragging_prevented = false,

    -- ============================================================
    -- 事件转发映射：UI 事件 → mpv 按键名
    -- ============================================================
    event_forward_map = {
        primary_down = 'MBTN_LEFT',
        primary_up = 'MBTN_LEFT',
        secondary_down = 'MBTN_RIGHT',
        secondary_up = 'MBTN_RIGHT',
        wheel_down = 'WHEEL_DOWN',
        wheel_up = 'WHEEL_UP',
    },

    -- ============================================================
    -- 事件 → 绑定组名映射
    -- ============================================================
    event_binding_map = {
        primary_down = 'mbtn_left',
        primary_up = 'mbtn_left',
        primary_click = 'mbtn_left',
        secondary_down = 'mbtn_right',
        secondary_up = 'mbtn_right',
        secondary_click = 'mbtn_right',
        wheel_down = 'wheel',
        wheel_up = 'wheel',
    },

    -- ============================================================
    -- 阻止窗口拖拽的事件类型
    -- ============================================================
    window_dragging_blockers = create_set({'primary_click', 'primary_down'}),

    -- ============================================================
    -- 事件传播阻断映射：某些事件会阻止同类型事件的传播
    -- 例如 primary_down 会阻止 primary_click（如果二者在同一个区域）
    -- ============================================================
    event_propagation_blockers = {
        primary_down = 'primary_click',
        primary_click = 'primary_down',
        secondary_down = 'secondary_click',
        secondary_click = 'secondary_down',
    },

    -- ============================================================
    -- 复合事件元信息
    -- 用于将 down + up 组合成 click 事件
    -- ============================================================
    event_meta = {
        primary_down = {is_start = true, trigger_event = 'primary_click'},
        primary_up = {is_end = true, start_event = 'primary_down', trigger_event = 'primary_click'},
        secondary_down = {is_start = true, trigger_event = 'secondary_click'},
        secondary_up = {is_end = true, start_event = 'secondary_down', trigger_event = 'secondary_click'},
    },

    -- ============================================================
    -- 上次事件记录（用于判断 click 是否在同一个区域内）
    -- ============================================================
    ---@type {[string]: {x: number, y: number, time: number, zone_handled: boolean}}
    last_events = {},
}

-- ==============================================================================
-- 3. 自动隐藏计时器
-- 当光标静止一段时间后自动隐藏
-- ==============================================================================

cursor.autohide_timer = mp.add_timeout(1, function() cursor:autohide() end)
cursor.autohide_timer:kill()

-- 监听 mpv 的 cursor-autohide 配置变化
mp.observe_property('cursor-autohide', 'number', function(_, val)
    cursor.autohide_timer.timeout = (val or 1000) / 1000
end)

-- ==============================================================================
-- 4. 距离重置计时器
-- 每 0.2 秒重置一次移动距离（用于判断拖拽和点击）
-- ==============================================================================

cursor.distance_reset_timer = mp.add_timeout(0.2, function()
    cursor.distance = 0
    request_render()
end)
cursor.distance_reset_timer:kill()

-- ==============================================================================
-- 5. Zone 管理
-- ==============================================================================

-- 在每次渲染开始时清空 Zone 列表
-- Called at the beginning of each render
function cursor:clear_zones()
    itable_clear(self.zones)
end

-- 检查光标是否与碰撞箱碰撞
---@param hitbox Hitbox
function cursor:collides_with(hitbox)
    return point_collides_with(self, hitbox)
end

-- 在当前光标位置查找指定事件的 Zone
-- 从最上层（数组末尾）开始查找
---@param event string
function cursor:find_zone(event)
    -- 忽略 move 事件（高频且当前不需要作为 Zone）
    if event == 'move' then
        return
    end

    for i = #self.zones, 1, -1 do
        local zone = self.zones[i]
        local is_blocking_only = zone.event == self.event_propagation_blockers[event]

        -- 匹配事件类型，且光标在碰撞箱内
        if (zone.event == event or is_blocking_only) and self:collides_with(zone.hitbox) then
            -- 如果是阻断事件（如 primary_down 阻止 primary_click），返回 nil
            return not is_blocking_only and zone or nil
        end
    end
end

-- ==============================================================================
-- 6. 注册 Zone (zone)
-- UI 元素在渲染时调用此方法注册可交互区域
-- ==============================================================================

-- 在渲染时定义事件区域。可用事件：
-- - primary_down, primary_up, primary_click, secondary_down, secondary_up, secondary_click, wheel_down, wheel_up
--
-- 注意：
-- - Zones 在每次 render() 开始时被清除，需要重新绑定
-- - 每个事件类型只保留最后一个绑定的 Zone
-- - _click 和 _down 只能选一个，同时绑定只有最后一个生效
-- - primary_down 和 primary_click 会禁用窗口拖拽，可在 hitbox 上设置 window_drag = true 重新启用
-- - 任何禁用拖拽的事件也会隐式禁用光标自动隐藏
-- - move 事件不被视为 Zone（高频事件，目前不需要）
---@param event string
---@param hitbox Hitbox
---@param callback CursorEventHandler
function cursor:zone(event, hitbox, callback)
    self.zones[#self.zones + 1] = {event = event, hitbox = hitbox, handler = callback}
end

-- ==============================================================================
-- 7. 全局事件绑定 (on / off / once)
-- 永久绑定事件处理器，直到手动取消
-- ==============================================================================

-- 绑定一个永久光标事件处理器（直到调用 cursor:off 解绑）
-- _click 事件不能作为全局事件，只能作为 Zone
---@param event string
---@param callback CursorEventHandler
---@return fun() disposer 用于取消绑定的函数
function cursor:on(event, callback)
    if self.handlers[event] and not itable_index_of(self.handlers[event], callback) then
        self.handlers[event][#self.handlers[event] + 1] = callback
        -- 更新键盘绑定状态
        self:decide_keybinds()
    end
    return function()
        self:off(event, callback)
    end
end

-- 取消绑定的光标事件处理器
---@param event string
function cursor:off(event, callback)
    if self.handlers[event] then
        local index = itable_index_of(self.handlers[event], callback)
        if index then
            table.remove(self.handlers[event], index)
            self:decide_keybinds()
        end
    end
end

-- 绑定一个只触发一次的光标事件处理器
---@param event string
function cursor:once(event, callback)
    local function callback_wrap()
        callback()
        self:off(event, callback_wrap)
    end
    return self:on(event, callback_wrap)
end

-- ==============================================================================
-- 8. 事件触发 (trigger)
-- 处理所有鼠标事件的入口
-- ==============================================================================

-- 触发事件
---@param event string
---@param shortcut? Shortcut
function cursor:trigger(event, shortcut)
    local forward, zone_handled = true, false

    -- ============================================================
    -- 调用 Zone 处理器和全局处理器
    -- ============================================================
    local zone = self:find_zone(event)
    local callbacks = self.handlers[event]

    if zone or #callbacks > 0 then
        forward = false  -- 有处理器，不转发给 mpv

        if zone and shortcut then
            zone.handler(shortcut)
            zone_handled = true
        end

        for _, callback in ipairs(callbacks) do
            callback(shortcut)
        end
    end

    -- ============================================================
    -- 处理复合事件（click）
    -- 如果 down 和 up 在同一个区域内，合成 click 事件
    -- ============================================================
    if event ~= 'move' then
        local meta = self.event_meta[event]
        if meta then
            local parent_zone = self:find_zone(meta.trigger_event)
            if parent_zone then
                forward = false  -- 不转发 down 事件（可能会触发 click）
                if meta.is_end then
                    -- up 事件：检查 down 是否在同一区域内
                    local start_event = self.last_events[meta.start_event]
                    if start_event and point_collides_with(start_event, parent_zone.hitbox) and shortcut then
                        parent_zone.handler(create_shortcut('primary_click', shortcut.modifiers))
                    end
                end
            end
        end

        -- ============================================================
        -- 转发未处理的事件到 mpv 的 input.conf
        -- ============================================================
        if forward then
            local forward_name = self.event_forward_map[event]
            local last_down = meta and meta.is_end and self.last_events[meta.start_event]
            local down_zone_handled = last_down and last_down.zone_handled

            if forward_name and not down_zone_handled then
                local active = find_active_keybindings(forward_name)
                if active and active.cmd then
                    local is_wheel = event:find('wheel', 1, true)
                    local is_up = event:sub(-3) == '_up'

                    if active.owner then
                        -- 绑定属于其他脚本：通过 script-message 转发
                        local state = is_wheel and 'pm' or is_up and 'um' or 'dm'
                        local name = active.cmd:sub(active.cmd:find('/') + 1, -1)
                        mp.commandv('script-message-to', active.owner, 'key-binding', name, state, forward_name)
                    elseif is_wheel or is_up then
                        -- input.conf 绑定：直接执行命令
                        mp.command(active.cmd)
                    end
                end
            end
        end
    end

    -- ============================================================
    -- 记录事件（用于判断 click 是否在同一区域）
    -- ============================================================
    local last = self.last_events[event] or {}
    last.x, last.y, last.time, last.zone_handled = self.x, self.y, mp.get_time(), zone_handled
    self.last_events[event] = last

    -- 刷新自动隐藏计时器
    self:queue_autohide()
end

-- ==============================================================================
-- 9. 键盘绑定组管理 (decide_keybinds)
-- 根据当前绑定的处理器动态启用/禁用鼠标按键的绑定组
-- ==============================================================================

function cursor:decide_keybinds()
    local new_levels = {mbtn_left = 0, mbtn_right = 0, wheel = 0}
    self.is_dragging_prevented = false

    -- ============================================================
    -- 检查全局事件处理器
    -- ============================================================
    for name, handlers in ipairs(self.handlers) do
        local binding = self.event_binding_map[name]
        if binding then
            new_levels[binding] = math.max(new_levels[binding], #handlers > 0 and 1 or 0)
        end
    end

    -- ============================================================
    -- 检查 Zones
    -- ============================================================
    for _, zone in ipairs(self.zones) do
        local binding = self.event_binding_map[zone.event]
        if binding and cursor:collides_with(zone.hitbox) then
            -- 计算绑定级别：如果是窗口拖拽阻断事件且 hitbox 未设置 window_drag，则为 2
            local new_level = (self.window_dragging_blockers[zone.event] and zone.hitbox.window_drag ~= true) and 2
                or math.max(new_levels[binding], zone.hitbox.window_drag == false and 2 or 1)

            -- 只有光标在元素上时才允许阻止拖拽
            if new_level > 1 and not cursor:collides_with(zone.hitbox) then
                new_level = 1
            end

            new_levels[binding] = math.max(new_levels[binding], new_level)
            if new_level > 1 then
                self.is_dragging_prevented = true
            end
        end
    end

    -- 窗口拖拽阻止时忽略双击
    new_levels.mbtn_left_dbl = new_levels.mbtn_left == 2 and 2 or 0

    -- ============================================================
    -- 应用新的绑定级别
    -- ============================================================
    for name, level in pairs(new_levels) do
        if level ~= self.binding_levels[name] then
            local flags = level == 1 and 'allow-vo-dragging+allow-hide-cursor' or ''
            mp[(level == 0 and 'disable' or 'enable') .. '_key_bindings'](name, flags)
            self.binding_levels[name] = level
            self:queue_autohide()
        end
    end
end

-- ==============================================================================
-- 10. 光标历史与速度计算
-- ==============================================================================

-- 查找历史样本（用于速度计算）
function cursor:_find_history_sample()
    local time = mp.get_time()
    for _, e in self.history:iter_rev() do
        if time - e.time > 0.1 then
            return e
        end
    end
    return self.history:tail()
end

-- 返回当前速度向量（像素/秒）
---@return Point
function cursor:get_velocity()
    local snap = self:_find_history_sample()
    if snap then
        local x, y, time = self.x - snap.x, self.y - snap.y, mp.get_time()
        local time_diff = time - snap.time
        if time_diff > 0.001 then
            return {x = x / time_diff, y = y / time_diff}
        end
    end
    return {x = 0, y = 0}
end

-- ==============================================================================
-- 11. 光标移动处理 (move)
-- 核心移动逻辑：更新位置、触发事件、处理显隐
-- ==============================================================================

---@param x integer
---@param y integer
function cursor:move(x, y)
    local old_x, old_y = self.x, self.y

    -- Linux 上 mpv 初始鼠标位置为 (0,0)，会错误地显示顶栏
    -- 在收到第一个真实鼠标事件之前，强制光标位置为无穷大
    if not self.first_real_mouse_move_received then
        if x > 0 and y > 0 and x < 99999999 and y < 99999999 then
            self.first_real_mouse_move_received = true
        else
            x, y = math.huge, math.huge
        end
    end

    -- 加 0.5 使光标位于像素中心
    self.x, self.y = x + 0.5, y + 0.5

    if old_x ~= self.x or old_y ~= self.y then
        if self.x == math.huge or self.y == math.huge then
            -- ============================================================
            -- 光标离开窗口
            -- ============================================================
            self.hidden = true
            self.history:clear()

            -- 淡出当前可见的元素
            for _, id in ipairs(config.cursor_leave_fadeout_elements) do
                local element = Elements[id]
                if element then
                    local visibility = element:get_visibility()
                    if visibility > 0 then
                        element:tween_property('forced_visibility', visibility, 0, function()
                            element.forced_visibility = nil
                        end)
                    end
                end
            end

            Elements:update_proximities()
            Elements:trigger('global_mouse_leave')
        else
            -- ============================================================
            -- 光标进入/在窗口内移动
            -- ============================================================
            if self.hidden then
                -- 取消可能的淡出动画
                for _, id in ipairs(config.cursor_leave_fadeout_elements) do
                    if Elements[id] then
                        Elements[id]:tween_stop()
                    end
                end

                self.hidden = false
                Elements:trigger('global_mouse_enter')
            end

            -- ============================================================
            -- 更新移动距离（用于区分点击和拖拽）
            -- 忽略长时间静止后的第一帧（防止窗口缩放导致的大跳变）
            -- ============================================================
            local last = self.last_events.move
            if last and last.x < math.huge and last.y < math.huge and mp.get_time() - last.time < 0.5 then
                self.distance = self.distance + get_point_to_point_proximity(cursor, last)
                cursor.distance_reset_timer:kill()
                cursor.distance_reset_timer:resume()
            end

            Elements:update_proximities()

            -- 更新历史记录
            self.history:insert({x = self.x, y = self.y, time = mp.get_time()})
        end

        -- 触发鼠标移动事件
        Elements:proximity_trigger('mouse_move')
        self:queue_autohide()
    end

    self:trigger('move')
    request_render()
end

-- ==============================================================================
-- 12. 光标离开 (leave)
-- ==============================================================================

function cursor:leave()
    self:move(math.huge, math.huge)
end

-- ==============================================================================
-- 13. 自动隐藏管理
-- ==============================================================================

-- 判断是否允许自动隐藏光标
function cursor:is_autohide_allowed()
    return options.autohide
        and (not self.autohide_fs_only or state.fullscreen)  -- 全屏模式或非仅全屏
        and not self.is_dragging_prevented                   -- 未阻止拖拽
        and not Menu:is_open()                               -- 菜单未打开
end

mp.observe_property('cursor-autohide-fs-only', 'bool', function(_, val)
    cursor.autohide_fs_only = val
end)

-- 自动隐藏光标（静止一段时间后）
function cursor:autohide()
    if self:is_autohide_allowed() then
        self:leave()
        self.autohide_timer:kill()
    end
end

-- 刷新自动隐藏计时器
function cursor:queue_autohide()
    if self:is_autohide_allowed() then
        self.autohide_timer:kill()
        self.autohide_timer:resume()
    end
end

-- ==============================================================================
-- 14. 方向计算 (direction_to_rectangle_distance)
-- 计算光标继续沿当前方向移动，距离达到矩形区域的距离
-- 用于判断鼠标是否正朝着某个 UI 元素移动（如子菜单的智能悬停）
-- ==============================================================================

-- 计算光标沿当前方向到达矩形区域的距离
-- 如果光标没有朝向矩形移动，返回 nil
---@param rect Rect
function cursor:direction_to_rectangle_distance(rect)
    local prev = self:_find_history_sample()
    if not prev then
        return false
    end
    -- 从当前位置沿方向延伸一条极长的射线
    local end_x, end_y = self.x + (self.x - prev.x) * 1e10, self.y + (self.y - prev.y) * 1e10
    return get_ray_to_rectangle_distance(self.x, self.y, end_x, end_y, rect)
end

-- ==============================================================================
-- 15. 事件处理器创建 (create_handler)
-- 创建一个封装了事件触发逻辑的处理器函数
-- ==============================================================================

---@param event string
---@param shortcut Shortcut
---@param cb? fun(shortcut: Shortcut)
function cursor:create_handler(event, shortcut, cb)
    return function()
        if cb then
            cb(shortcut)
        end
        self:trigger(event, shortcut)
    end
end

-- ==============================================================================
-- 16. 鼠标/触摸事件监听器注册
-- ==============================================================================

-- Movement
local function handle_mouse_pos(_, mouse)
    if not mouse then
        return
    end
    if cursor.last_hover and not mouse.hover then
        cursor:leave()
    elseif not (cursor.last_hover == false and mouse.hover == false) then
        -- 过滤重复的鼠标离开事件
        cursor:move(mouse.x, mouse.y)
    end
    cursor.last_hover = mouse.hover
end

-- 触摸事件处理（将触摸转换为鼠标事件）
local function handle_touch_pos(_, touches)
    if not touches then
        return
    end
    local touch = touches[1]
    if touch then
        cursor:move(touch.x, touch.y)
    end
end

mp.observe_property('mouse-pos', 'native', handle_mouse_pos)
mp.observe_property('touch-pos', 'native', handle_touch_pos)

-- ==============================================================================
-- 17. 鼠标按键绑定组
-- 这些绑定组由 decide_keybinds() 动态启用/禁用
-- ==============================================================================

local modifiers = {nil, 'alt', 'alt+ctrl', 'alt+shift', 'alt+ctrl+shift', 'ctrl', 'ctrl+shift', 'shift'}

-- 左键绑定组（包含所有修饰键组合）
local primary_bindings = {}
for i = 1, #modifiers do
    local mods = modifiers[i]
    local mp_name = (mods and mods .. '+' or '') .. 'mbtn_left'
    primary_bindings[#primary_bindings + 1] = {
        mp_name,
        cursor:create_handler('primary_up', create_shortcut('primary_up', mods)),
        cursor:create_handler('primary_down', create_shortcut('primary_down', mods), function(...)
            -- 点击时获取鼠标位置（确保位置最新）
            handle_mouse_pos(nil, mp.get_property_native('mouse-pos'))
        end),
    }
end

mp.set_key_bindings(primary_bindings, 'mbtn_left', 'force')

-- 左键双击（忽略，由 uosc 内部处理）
mp.set_key_bindings({
    {'mbtn_left_dbl', 'ignore'},
}, 'mbtn_left_dbl', 'force')

-- 右键绑定组
mp.set_key_bindings({
    {
        'mbtn_right',
        cursor:create_handler('secondary_up', create_shortcut('secondary_up')),
        cursor:create_handler('secondary_down', create_shortcut('secondary_down')),
    },
}, 'mbtn_right', 'force')

-- 滚轮绑定组
mp.set_key_bindings({
    {'wheel_up', cursor:create_handler('wheel_up', create_shortcut('wheel_up'))},
    {'wheel_down', cursor:create_handler('wheel_down', create_shortcut('wheel_down'))},
}, 'wheel', 'force')

-- ==============================================================================
-- 18. 导出 cursor 模块
-- ==============================================================================

return cursor