-- ==============================================================================
-- buttons.lua — 托管按钮状态管理模块
-- ==============================================================================
-- 功能概述：
--   1. 为外部脚本提供托管按钮的数据存储和更新机制
--   2. 采用发布-订阅模式，按钮数据变化时自动通知所有订阅者
--   3. 支持通过 buttons:set() 或 set-button 脚本消息更新按钮状态
--   4. 用于 ManagedButton 组件与外部脚本之间的数据通信
-- ==============================================================================
-- 工作流程：
--   1. 外部脚本调用 buttons:set(name, data) 更新按钮数据
--   2. 或通过 mp.commandv('script-message', 'set-button', name, json_data) 发送更新
--   3. buttons 模块触发 trigger(name)，通知所有订阅者
--   4. ManagedButton 组件收到数据后更新自身 UI
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 类型定义 (Type Aliases)
-- ==============================================================================

---@alias ButtonData {icon: string; active?: boolean; badge?: string; command?: string | string[]; tooltip?: string;}
-- 按钮数据字段说明：
--   icon     : 按钮图标（Material Icons 名称）
--   active   : 是否处于激活状态（高亮显示）
--   badge    : 角标内容（数字或字符串）
--   command  : 点击时执行的 mpv 命令（字符串或字符串数组）
--   tooltip  : 鼠标悬停时显示的工具提示

---@alias ButtonSubscriber fun(data: ButtonData)
-- 订阅者回调函数类型：接收 ButtonData 作为参数

-- ==============================================================================
-- 2. buttons 模块定义
-- ==============================================================================

local buttons = {
    ---@type ButtonData[] 存储所有按钮的数据，以按钮名称为键
    data = {},
    ---@type table<string, ButtonSubscriber[]> 存储所有订阅者，以按钮名称为键
    subscribers = {},
}

-- ==============================================================================
-- 3. 获取按钮数据 (get)
-- 如果按钮不存在，返回一个默认的占位数据
-- ==============================================================================

---@param name string 按钮名称
---@return ButtonData
function buttons:get(name)
    return self.data[name] or {
        icon = 'help_center',
        tooltip = 'Uninitialized button "' .. name .. '"'
    }
end

-- ==============================================================================
-- 4. 订阅按钮更新 (subscribe)
-- 当按钮数据变化时，所有订阅者会收到通知
-- ==============================================================================

---@param name string 要订阅的按钮名称
---@param callback fun(data: ButtonData) 数据变化时的回调函数
---@return fun() 返回一个取消订阅的函数
function buttons:subscribe(name, callback)
    -- 获取或创建该按钮的订阅者池
    local pool = self.subscribers[name]
    if not pool then
        pool = {}
        self.subscribers[name] = pool
    end

    -- 将回调添加到池中
    pool[#pool + 1] = callback

    -- 返回取消订阅的函数
    return function()
        buttons:unsubscribe(name, callback)
    end
end

-- ==============================================================================
-- 5. 取消订阅 (unsubscribe)
-- ==============================================================================

---@param name string 按钮名称
---@param callback? ButtonSubscriber 要移除的回调函数（不传则移除所有订阅者）
function buttons:unsubscribe(name, callback)
    if self.subscribers[name] then
        if callback == nil then
            -- 移除所有订阅者
            self.subscribers[name] = {}
        else
            -- 移除指定的回调
            itable_delete_value(self.subscribers[name], callback)
        end
    end
end

-- ==============================================================================
-- 6. 触发更新 (trigger)
-- 通知所有订阅者按钮数据已变化
-- ==============================================================================

---@param name string 按钮名称
function buttons:trigger(name)
    local pool = self.subscribers[name]
    if pool then
        -- 获取最新的按钮数据
        local data = self:get(name)
        -- 依次调用所有订阅者回调
        for _, callback in ipairs(pool) do
            callback(data)
        end
    end
end

-- ==============================================================================
-- 7. 设置按钮数据 (set)
-- 更新按钮数据并通知所有订阅者
-- ==============================================================================

---@param name string 按钮名称
---@param data ButtonData 新的按钮数据
function buttons:set(name, data)
    -- 存储数据
    buttons.data[name] = data
    -- 触发更新通知
    buttons:trigger(name)
    -- 请求重新渲染
    request_render()
end

-- ==============================================================================
-- 8. 脚本消息处理器 (set-button)
-- 允许外部脚本通过 mpv 的 script-message 机制更新按钮
-- ==============================================================================

mp.register_script_message('set-button', function(name, data)
    -- 验证参数类型
    if type(name) ~= 'string' then
        msg.error('Invalid set-button message parameter: 1st parameter (name) has to be a string.')
        return
    end
    if type(data) ~= 'string' then
        msg.error('Invalid set-button message parameter: 2nd parameter (data) has to be a string.')
        return
    end

    -- 解析 JSON 数据
    local data = utils.parse_json(data)

    -- 验证数据有效性
    if type(data) == 'table' and type(data.icon) == 'string' then
        -- 更新按钮
        buttons:set(name, data)
    end
    -- 如果数据无效，静默忽略
end)

-- ==============================================================================
-- 9. 导出 buttons 模块
-- ==============================================================================

return buttons