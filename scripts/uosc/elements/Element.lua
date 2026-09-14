-- ==============================================================================
-- Element.lua — UI 元素基类
-- ==============================================================================
-- 功能概述：
--   1. 这是 uosc 框架中所有 UI 元素的基类
--   2. 定义了坐标管理、可见度计算、动画、事件绑定等通用功能
--   3. 所有 UI 组件（Button、Controls、Menu、Timeline 等）都继承自此基类
--   4. 提供闪动（flash）、补间动画（tween）、属性观察、快捷键绑定等能力
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 类型定义 (Type Alias)
-- ==============================================================================

---@alias ElementProps {enabled?: boolean; render_order?: number; ax?: number; ay?: number; bx?: number; by?: number; ignores_curtain?: boolean; anchor_id?: string;}
-- ElementProps 字段说明：
--   enabled         : 是否启用（false 表示不渲染也不接收事件）
--   render_order    : 渲染顺序（数值越小越靠底层）
--   ax, ay, bx, by  : 元素边界坐标（左上角 ax, ay 到右下角 bx, by）
--   ignores_curtain : 是否忽略幕布（true 表示幕布打开时仍显示）
--   anchor_id       : 所属锚点元素的 ID（继承其可见性）

-- ==============================================================================
-- Element 基类定义
-- 所有 UI 元素都继承自此类
-- ==============================================================================

---@class Element : Class
local Element = class()

-- ==============================================================================
-- 构造函数与初始化 (init)
-- ==============================================================================

---@param id string 元素唯一标识符
---@param props? ElementProps 属性表（可选）
function Element:init(id, props)
    -- 基础属性
    self.id = id                      -- 元素 ID
    self.render_order = 1             -- 渲染顺序（默认 1，子类可覆盖）
    -- `false` 表示元素不渲染，也不接收事件
    self.enabled = true

    -- 元素坐标（边界矩形）
    self.ax, self.ay, self.bx, self.by = 0, 0, 0, 0

    -- 相对接近度（0 到 1）：
    --   0 = 鼠标在 `proximity_max`（远）范围之外
    --   1 = 鼠标在 `proximity_min`（近）范围之内
    self.proximity = 0
    -- 原始接近度（像素距离）
    self.proximity_raw = math.huge

    ---@type number 0-1 强制最小可见度（用于切换元素的永久显隐）
    self.min_visibility = 0
    ---@type number 0-1 强制可见度值（用于闪动、淡出等动画）
    self.forced_visibility = nil

    ---@type boolean 幕布打开时是否仍然显示此元素
    self.ignores_curtain = false
    ---@type nil|string 所属锚点元素的 ID（继承其可见性）
    self.anchor_id = nil

    ---@type fun()[] 销毁时调用的清理函数列表（disposers）
    self._disposers = {}
    ---@type table<string,table<string, boolean>> 命名空间的快捷键绑定表
    self._key_bindings = {}

    -- 如果传入了 props，合并到 self
    if props then table_assign(self, props) end

    -- ============================================================
    -- 闪动计时器
    -- 当元素闪动时，强制可见度设为 1，然后逐渐恢复
    -- ============================================================
    self._flash_out_timer = mp.add_timeout(options.flash_duration / 1000, function()
        local function getTo() return self.proximity end
        local function onTweenEnd() self.forced_visibility = nil end

        if self.enabled then
            -- 从当前可见度渐变到接近度对应的值
            self:tween_property('forced_visibility', self:get_visibility(), getTo, onTweenEnd)
        else
            onTweenEnd()
        end
    end)
    -- 初始状态为停止（kill），由 flash() 方法激活
    self._flash_out_timer:kill()

    -- 将自身注册到 Elements 管理器
    Elements:add(self)
end

-- ==============================================================================
-- 销毁与清理 (destroy / dispose)
-- ==============================================================================

-- 销毁元素：清理资源、移除快捷键、从 Elements 管理器移除
function Element:destroy()
    self:dispose()             -- 调用所有清理函数
    self.destroyed = true      -- 标记为已销毁
    self:remove_key_bindings() -- 移除所有快捷键绑定
    Elements:remove(self)      -- 从 Elements 管理器移除
end

-- 调用所有注册的清理函数（disposers）
-- 通常用于取消 mpv 事件监听和属性观察
function Element:dispose()
    for _, disposer in ipairs(self._disposers) do
        disposer()
    end
end

-- ==============================================================================
-- 接近度管理 (Proximity)
-- ==============================================================================

-- 重置接近度（鼠标不在范围内）
function Element:reset_proximity()
    self.proximity = 0
    self.proximity_raw = math.huge
end

-- 设置元素坐标
---@param ax number 左上角 X
---@param ay number 左上角 Y
---@param bx number 右下角 X
---@param by number 右下角 Y
function Element:set_coordinates(ax, ay, bx, by)
    self.ax, self.ay, self.bx, self.by = ax, ay, bx, by
    -- 更新所有元素的接近度
    Elements:update_proximities()
    -- 如果有 on_coordinates 回调，触发它
    self:maybe('on_coordinates')
end

-- 更新元素的接近度（由 Elements 管理器调用）
function Element:update_proximity()
    if cursor.hidden then
        -- 鼠标隐藏时，重置接近度
        self:reset_proximity()
    else
        -- 计算鼠标到元素矩形的距离
        local range = options.proximity_out - options.proximity_in
        self.proximity_raw = get_point_to_rectangle_proximity(cursor, self)
        -- 将距离映射为 0~1 的接近度
        -- 距离 <= proximity_in 时接近度为 1
        -- 距离 >= proximity_out 时接近度为 0
        self.proximity = 1 - (clamp(0, self.proximity_raw - options.proximity_in, range) / range)
    end
end

-- ==============================================================================
-- 常驻显示判断 (is_persistent)
-- 检查元素是否应该无视鼠标接近度而常驻显示
-- ==============================================================================

function Element:is_persistent()
    local persist = config[self.id .. '_persistency']
    if not persist then return false end

    return (
        -- 音频文件且配置了 audio
        (persist.audio and state.is_audio)
        -- 暂停状态且配置了 paused
        -- 特殊处理：如果正在拖拽时间轴，暂停时不常驻（避免干扰拖拽）
        or (
            persist.paused and state.pause
            and (not Elements.timeline or not Elements.timeline.pressed or Elements.timeline.pressed.pause)
        )
        -- 视频文件且配置了 video
        or (persist.video and state.is_video)
        -- 图片文件且配置了 image
        or (persist.image and state.is_image)
        -- 空闲状态且配置了 idle
        or (persist.idle and state.is_idle)
        -- 窗口模式且配置了 windowed
        or (persist.windowed and not state.fullormaxed)
        -- 全屏/最大化模式且配置了 fullscreen
        or (persist.fullscreen and state.fullormaxed)
    )
end

-- ==============================================================================
-- 可见度计算 (get_visibility)
-- 综合多种因素计算元素的最终可见度（0~1）
-- ==============================================================================

function Element:get_visibility()
    -- 如果幕布可见且元素不忽略幕布，且元素渲染顺序低于幕布，则不可见
    local min_order = (Elements.curtain.opacity > 0 and not self.ignores_curtain)
        and Elements.curtain.render_order
        or 0
    if self.render_order < min_order then return 0 end

    -- 如果元素配置了常驻显示，完全可见
    if self:is_persistent() then return 1 end

    -- 如果强制可见度被设置，取强制可见度和最小可见度的最大值
    if self.forced_visibility then
        return math.max(self.forced_visibility, self.min_visibility)
    end

    -- 锚点继承：如果锚点返回 -1，表示所有附属元素强制隐藏
    local anchor = self.anchor_id and Elements[self.anchor_id]
    local anchor_visibility = anchor and anchor:get_visibility() or 0

    -- 如果锚点强制隐藏（-1），则不可见
    -- 否则取接近度、锚点可见度、最小可见度的最大值
    return anchor_visibility == -1
        and 0
        or math.max(self.proximity, anchor_visibility, self.min_visibility)
end

-- ==============================================================================
-- 方法调用辅助 (maybe)
-- 如果方法存在则调用它
-- ==============================================================================

-- Call method if it exists
function Element:maybe(name, ...)
    if self[name] then
        return self[name](self, ...)
    end
end

-- ==============================================================================
-- 补间动画 (Tween)
-- 用于平滑过渡属性的值
-- ==============================================================================

-- 附加一个补间动画到此元素
---@param from number 起始值
---@param to number|fun():number 结束值（或返回结束值的函数）
---@param setter fun(value: number) 设置值的回调函数
---@param duration_or_callback? number|fun() 持续时间（毫秒）或回调函数
---@param callback? fun() 动画结束或被终止时的回调
function Element:tween(from, to, setter, duration_or_callback, callback)
    -- 停止正在进行的动画
    self:tween_stop()

    -- 如果元素未启用，不创建动画
    self._kill_tween = self.enabled and tween(
        from, to, setter, duration_or_callback,
        function()
            self._kill_tween = nil
            if callback then callback() end
        end
    )
end

-- 检查是否有正在进行的补间动画
function Element:is_tweening()
    return self and self._kill_tween
end

-- 停止正在进行的补间动画
function Element:tween_stop()
    self:maybe('_kill_tween')
end

-- 补间动画的便捷方法：直接对元素属性进行动画
---@param prop string 属性名
---@param from number 起始值
---@param to number|fun():number 结束值（或返回结束值的函数）
---@param duration_or_callback? number|fun() 持续时间（毫秒）或回调函数
---@param callback? fun() 动画结束或被终止时的回调
function Element:tween_property(prop, from, to, duration_or_callback, callback)
    self:tween(from, to, function(value) self[prop] = value end, duration_or_callback, callback)
end

-- ==============================================================================
-- 事件触发 (trigger)
-- 触发元素的事件（调用 on_xxx 方法）
-- ==============================================================================

---@param name string 事件名（会触发 on_ 前缀的方法）
function Element:trigger(name, ...)
    local result = self:maybe('on_' .. name, ...)
    request_render()
    return result
end

-- ==============================================================================
-- 闪动效果 (flash)
-- 短暂地将元素变为完全可见，然后淡出
-- 用于可视化快捷键触发的音量/时间轴变化
-- ==============================================================================

function Element:flash()
    -- 条件：元素启用、闪动持续时间 > 0、接近度小于 1（未完全显示）或闪动计时器正在运行
    if self.enabled and options.flash_duration > 0 and (self.proximity < 1 or self._flash_out_timer:is_enabled()) then
        self:tween_stop()
        self.forced_visibility = 1    -- 强制完全可见
        request_render()

        -- 重新启动闪动计时器
        self._flash_out_timer.timeout = options.flash_duration / 1000
        self._flash_out_timer:kill()
        self._flash_out_timer:resume()
    end
end

-- ==============================================================================
-- 资源管理与清理 (Disposers)
-- 注册在元素销毁时自动调用的清理函数
-- ==============================================================================

-- 注册一个清理函数（在元素销毁时调用）
---@param disposer fun()
function Element:register_disposer(disposer)
    if not itable_index_of(self._disposers, disposer) then
        self._disposers[#self._disposers + 1] = disposer
    end
end

-- 注册 mpv 事件（自动管理清理）
---@param event string 事件名
---@param callback fun() 回调函数
function Element:register_mp_event(event, callback)
    mp.register_event(event, callback)
    self:register_disposer(function() mp.unregister_event(callback) end)
end

-- 观察 mpv 属性（自动管理清理）
---@param name string 属性名
---@param type_or_callback string|fun(name: string, value: any) 属性类型或回调函数
---@param callback_maybe nil|fun(name: string, value: any) 回调函数（如果第一个参数是类型字符串）
function Element:observe_mp_property(name, type_or_callback, callback_maybe)
    local callback = type(type_or_callback) == 'function' and type_or_callback or callback_maybe
    local prop_type = type(type_or_callback) == 'string' and type_or_callback or 'native'
    mp.observe_property(name, prop_type, callback)
    self:register_disposer(function() mp.unobserve_property(callback) end)
end

-- ==============================================================================
-- 快捷键绑定 (Key Bindings)
-- 支持命名空间，便于管理
-- ==============================================================================

-- 添加一个快捷键绑定（生命周期与元素绑定）
---@param key string mpv 按键标识符
---@param fnFlags fun()|string|table<fun()|string> 回调函数，或 {callback, flags} 元组
---@param namespace? string 快捷键命名空间（默认为 '_'）
function Element:add_key_binding(key, fnFlags, namespace)
    local name = self.id .. '-' .. key
    local isTuple = type(fnFlags) == 'table'
    local fn = (isTuple and fnFlags[1] or fnFlags)
    local flags = isTuple and fnFlags[2] or nil
    namespace = namespace or '_'

    -- 在命名空间中记录此绑定
    local names = self._key_bindings[namespace]
    if not names then
        names = {}
        self._key_bindings[namespace] = names
    end
    names[name] = true

    -- 如果 fn 是字符串，将其视为方法名，包装为闭包
    if type(fn) == 'string' then
        fn = self:create_action(fn)
    end

    mp.add_forced_key_binding(key, name, fn, flags)
end

-- 移除快捷键绑定
---@param namespace? string 要移除的命名空间（不传则移除所有）
function Element:remove_key_bindings(namespace)
    local namespaces = namespace and {namespace} or table_keys(self._key_bindings)

    for _, namespace in ipairs(namespaces) do
        local names = self._key_bindings[namespace]
        if names then
            for name, _ in pairs(names) do
                mp.remove_key_binding(name)
            end
            self._key_bindings[namespace] = nil
        end
    end
end

-- 检查是否存在快捷键绑定
---@param namespace? string 只检查指定命名空间
function Element:has_keybindings(namespace)
    if namespace then
        return self._key_bindings[namespace] ~= nil
    else
        return #table_keys(self._key_bindings) > 0
    end
end

-- ==============================================================================
-- 生命周期检查 (is_alive)
-- 供子类覆盖扩展
-- ==============================================================================

-- 检查元素是否未被销毁
-- 子类可覆盖此方法添加更多检查（如菜单是否正在关闭等）
function Element:is_alive()
    return not self.destroyed
end

-- ==============================================================================
-- 回调包装器 (create_action)
-- 确保回调在元素已销毁时不会执行
-- ==============================================================================

-- 将函数包装为安全的回调：如果元素已销毁则跳过执行
---@param fn fun(...)|string 函数或当前类的方法名
function Element:create_action(fn)
    -- 如果 fn 是字符串，视为方法名
    if type(fn) == 'string' then
        local method = fn
        fn = function(...)
            self[method](self, ...)
        end
    end

    -- 返回包装后的函数
    return function(...)
        if self:is_alive() then
            fn(...)
        end
    end
end

return Element