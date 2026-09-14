-- ==============================================================================
-- CycleButton.lua — 循环切换按钮组件
-- ==============================================================================
-- 功能概述：
--   1. 继承自 Button，专用于在多个状态之间循环切换
--   2. 支持任意数量的状态（每个状态包含 value、icon、active 属性）
--   3. 点击按钮时自动切换到下一个状态，并更新对应的 mpv 属性
--   4. 自动观察属性变化，同步更新按钮的图标和激活状态
--   5. 支持三种属性来源：mpv 原生属性、uosc 内部状态、外部脚本属性
-- ==============================================================================
-- 典型应用场景：
--   - 循环播放模式（不循环 / 列表循环 / 单文件循环）
--   - 全屏状态（窗口 / 全屏）
--   - 随机播放开关（开 / 关）
--   - 画质切换（1080p / 720p / 480p）
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Button
local Button = require('elements/Button')

-- ==============================================================================
-- 类型定义 (Type Aliases)
-- ==============================================================================

---@alias CycleState {value: any; icon: string; active?: boolean}
-- CycleState 字段说明：
--   value  : 该状态对应的属性值（如 'no', 'inf', 'yes' 等）
--   icon   : 该状态显示的图标名称
--   active : 是否处于激活状态（用于高亮显示）

---@alias CycleButtonProps {prop: string; states: CycleState[]; anchor_id?: string; tooltip?: string}
-- CycleButtonProps 字段说明：
--   prop      : 要控制的属性名（支持 prop@owner 格式）
--   states    : 状态列表（按顺序循环）
--   anchor_id : 所属锚点元素的 ID
--   tooltip   : 鼠标悬停时显示的工具提示

-- ==============================================================================
-- 辅助函数：将 yes/no 字符串转换为布尔值
-- ==============================================================================
local function yes_no_to_boolean(value)
    -- 如果不是字符串，直接返回原值
    if type(value) ~= 'string' then return value end

    local lowercase = trim(value):lower()
    if lowercase == 'yes' or lowercase == 'no' then
        return lowercase == 'yes'
    else
        return value
    end
end

-- ==============================================================================
-- CycleButton 类定义
-- 继承自 Button
-- ==============================================================================

---@class CycleButton : Button
local CycleButton = class(Button)

-- 构造函数
---@param id string
---@param props CycleButtonProps
function CycleButton:new(id, props) return Class.new(self, id, props) --[[@as CycleButton]] end

-- ==============================================================================
-- 初始化函数 (init)
-- ==============================================================================
---@param id string
---@param props CycleButtonProps
function CycleButton:init(id, props)
    -- 检查属性是否属于 uosc 内部状态（如 'shuffle'）
    local is_state_prop = itable_index_of({'shuffle'}, props.prop)

    -- 保存属性名和状态列表
    self.prop = props.prop
    self.states = props.states

    -- 调用父类 Button 的初始化
    Button.init(self, id, props)

    -- ============================================================
    -- 初始状态：默认使用第一个状态
    -- ============================================================
    self.icon = self.states[1].icon
    self.active = self.states[1].active
    self.current_state_index = 1

    -- ============================================================
    -- 点击回调：切换到下一个状态
    -- ============================================================
    self.on_click = function()
        -- 获取下一个状态（循环）
        local new_state = self.states[self.current_state_index + 1] or self.states[1]
        local new_value = new_state.value

        -- 根据属性来源，使用不同的方式设置新值
        if self.owner == 'uosc' then
            -- 属性属于 uosc 配置（options 表）
            if type(options[self.prop]) == 'number' then
                options[self.prop] = tonumber(new_value) or 0
            else
                options[self.prop] = yes_no_to_boolean(new_value)
            end
            -- 触发配置更新
            handle_options({[self.prop] = options[self.prop]})

        elseif self.owner then
            -- 属性属于外部脚本（通过 script-message 通信）
            mp.commandv('script-message-to', self.owner, 'set', self.prop, new_value)

        elseif is_state_prop then
            -- 属性属于 uosc 内部状态（如 shuffle）
            set_state(self.prop, yes_no_to_boolean(new_value))

        else
            -- 属性属于 mpv 原生属性
            mp.set_property(self.prop, new_value)
        end
    end

    -- ============================================================
    -- 属性变化处理函数 (handle_change)
    -- 当属性值变化时，更新按钮的图标和激活状态
    -- ============================================================
    local function handle_change(name, value)
        -- 去除浮点数中多余的小数位（如 '2.00000' → 2）
        -- 这种情况发生在观察 speed 等属性时
        if type(value) == 'string' and string.match(value, '^[%+%-]?%d+%.%d+$') then
            value = tonumber(value)
        end

        -- 将各种类型的值统一转为字符串进行比较
        value = type(value) == 'boolean' and (value and 'yes' or 'no') or tostring(value or '')

        -- 在状态列表中查找匹配当前值的状态
        local index = itable_find(self.states, function(state) return state.value == value end)

        -- 更新当前状态索引、图标和激活状态
        self.current_state_index = index or 1
        self.icon = self.states[self.current_state_index].icon
        self.active = self.states[self.current_state_index].active

        request_render()
    end

    -- ============================================================
    -- 根据属性来源，注册对应的观察者
    -- ============================================================

    -- 解析属性名（支持 prop@owner 格式）
    local prop_parts = split(self.prop, '@')

    if #prop_parts == 2 then
        -- 外部脚本属性：格式为 'prop@owner'
        self.prop, self.owner = prop_parts[1], prop_parts[2]

        if self.owner == 'uosc' then
            -- 属性属于 uosc 配置：观察 options 变化
            self['on_options'] = function()
                handle_change(self.prop, options[self.prop])
            end
            handle_change(self.prop, options[self.prop])

        else
            -- 属性属于其他外部脚本：观察 external 表中的值
            self['on_external_prop_' .. self.prop] = function(_, value)
                handle_change(self.prop, value)
            end
            handle_change(self.prop, external[self.prop])
        end

    elseif is_state_prop then
        -- uosc 内部状态属性（如 shuffle）
        self['on_prop_' .. self.prop] = function(self, value)
            handle_change(self.prop, value)
        end
        handle_change(self.prop, state[self.prop])

    else
        -- mpv 原生属性：使用 mpv 的属性观察机制
        self:observe_mp_property(self.prop, 'string', handle_change)
    end
end

return CycleButton