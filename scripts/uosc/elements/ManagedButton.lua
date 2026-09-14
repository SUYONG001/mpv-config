-- ==============================================================================
-- ManagedButton.lua — 托管按钮组件
-- ==============================================================================
-- 功能概述：
--   1. 继承自 Button，但状态由外部脚本通过 buttons 模块管理
--   2. 外部脚本可以动态更新按钮的图标、激活状态、徽章、命令、工具提示等
--   3. 支持外部脚本控制按钮的显隐（hide 属性）
--   4. 典型应用场景：由外部脚本（如播放列表管理器）提供的上下文按钮
-- ==============================================================================
-- 设计模式：
--   这是一个"状态外部化"的按钮——按钮本身不维护自己的状态，
--   所有状态变化由外部脚本通过 buttons:set() 或 set-button 消息推送。
--   按钮通过 buttons:subscribe() 订阅更新，实现解耦。
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Button
local Button = require('elements/Button')

-- ==============================================================================
-- 类型定义 (Type Alias)
-- ==============================================================================

---@alias ManagedButtonProps {name: string; anchor_id?: string; render_order?: number; hide?: boolean}
-- ManagedButtonProps 字段说明：
--   name         : 按钮名称（用于从 buttons 模块查找对应的数据）
--   anchor_id    : 所属锚点元素的 ID
--   render_order : 渲染顺序
--   hide         : 初始是否隐藏（可由外部脚本控制）

-- ==============================================================================
-- ManagedButton 类定义
-- 继承自 Button
-- ==============================================================================

---@class ManagedButton : Button
local ManagedButton = class(Button)

-- 构造函数
---@param id string
---@param props ManagedButtonProps
function ManagedButton:new(id, props) return Class.new(self, id, props) --[[@as ManagedButton]] end

-- ==============================================================================
-- 初始化函数 (init)
-- ==============================================================================

---@param id string
---@param props ManagedButtonProps
function ManagedButton:init(id, props)
    ---@type string | table | nil 按钮点击时要执行的命令
    self.command = nil
    ---@type boolean 是否隐藏（由外部脚本控制）
    self.hide = nil
    ---@type fun(hide: boolean) | nil 显隐变化时的回调
    self.on_hide = nil

    -- 调用父类 Button 的初始化
    -- on_click 回调中执行 self.command（由外部脚本动态设置）
    Button.init(self, id, table_assign({}, props, {
        on_click = function()
            execute_command(self.command)
        end
    }))

    -- 从 buttons 模块获取初始数据并更新自身
    self:update(buttons:get(props.name))

    -- 订阅 buttons 模块的更新通知
    -- 当外部脚本通过 buttons:set() 更新数据时，自动调用 update()
    self:register_disposer(buttons:subscribe(props.name, function(data)
        self:update(data)
    end))
end

-- ==============================================================================
-- 更新函数 (update)
-- 由 buttons 模块推送的数据驱动，更新按钮的所有属性
-- ==============================================================================

---@param data ButtonData 来自 buttons 模块的数据
function ManagedButton:update(data)
    -- 记录更新前的隐藏状态（用于触发 on_hide 回调）
    local hide_before = self.hide

    -- 从 data 中提取所有可更新属性
    for _, prop in ipairs({'icon', 'active', 'badge', 'command', 'tooltip', 'hide'}) do
        self[prop] = data[prop]
    end

    -- 是否有 command 决定按钮是否可点击
    self.is_clickable = self.command ~= nil

    -- 如果隐藏状态发生变化且注册了 on_hide 回调，触发之
    if self.hide ~= hide_before and self.on_hide then
        self.on_hide(self.hide)
    end
end

return ManagedButton