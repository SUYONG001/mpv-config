-- ==============================================================================
-- Button.lua — 基础按钮组件
-- ==============================================================================
-- 功能概述：
--   1. 这是 uosc 框架中最基础的按钮 UI 组件
--   2. 支持图标、徽章（badge）、工具提示（tooltip）、激活状态等
--   3. 支持点击回调，并自动处理鼠标悬停和点击交互
--   4. 其他按钮类（CycleButton、ManagedButton 等）都继承自此组件
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- ==============================================================================
-- 类型定义 (Type Alias)
-- 用于 IDE 类型提示，方便开发时自动补全
-- ==============================================================================

---@alias ButtonProps {icon: string; on_click?: function; is_clickable?: boolean; anchor_id?: string; active?: boolean; badge?: string|number; foreground?: string; background?: string; tooltip?: string}
-- ButtonProps 说明：
--   icon        : 按钮图标名称（Material Icons）
--   on_click    : 点击按钮时的回调函数
--   is_clickable: 是否可点击（默认为 true）
--   anchor_id   : 所属锚点元素的 ID（用于继承可见性）
--   active      : 是否处于激活状态（高亮显示）
--   badge       : 角标内容（数字或字符串）
--   foreground  : 前景色（自定义，默认使用全局 fg）
--   background  : 背景色（自定义，默认使用全局 bg）
--   tooltip     : 鼠标悬停时显示的工具提示文字

-- ==============================================================================
-- Button 类定义
-- 继承自 Element，是所有按钮组件的基础
-- ==============================================================================

---@class Button : Element
local Button = class(Element)

-- 构造函数：创建一个新的 Button 实例
---@param id string
---@param props ButtonProps
function Button:new(id, props) return Class.new(self, id, props) --[[@as Button]] end

-- ==============================================================================
-- 初始化函数 (init)
-- ==============================================================================
---@param id string
---@param props ButtonProps
function Button:init(id, props)
    -- 从 props 中提取属性，并设置默认值
    self.icon = props.icon                         -- 图标名称
    self.active = props.active                     -- 是否激活
    self.tooltip = props.tooltip                   -- 工具提示
    self.badge = props.badge                       -- 角标内容
    self.foreground = props.foreground or fg       -- 前景色（默认使用全局前景色）
    self.background = props.background or bg       -- 背景色（默认使用全局背景色）
    self.is_clickable = true                       -- 默认可点击
    ---@type fun()|nil
    self.on_click = props.on_click                 -- 点击回调

    -- 调用父类 Element 的初始化
    Element.init(self, id, props)
end

-- ==============================================================================
-- 坐标更新回调 (on_coordinates)
-- 当按钮的坐标发生变化时，计算字体大小
-- ==============================================================================
function Button:on_coordinates()
    -- 字体大小 = 按钮高度的 70%（保证图标在按钮内居中且比例协调）
    self.font_size = round((self.by - self.ay) * 0.7)
end

-- ==============================================================================
-- 点击处理 (handle_cursor_click)
-- 由鼠标点击事件触发，执行点击回调
-- ==============================================================================
function Button:handle_cursor_click()
    -- 如果没有点击回调或不可点击，则直接返回
    if not self.on_click or not self.is_clickable then return end

    -- 将回调延迟到下一帧执行，避免在事件分发过程中产生竞态条件
    -- 例如：回调函数可能会在元素栈末尾添加一个新菜单，而该菜单会捕获
    -- 当前正在处理的点击事件，然后立即关闭自身。
    mp.add_timeout(0.01, self.on_click)
end

-- ==============================================================================
-- 渲染函数 (render)
-- 返回一个 ASS 绘图对象，包含按钮的完整视觉呈现
-- ==============================================================================
function Button:render()
    -- 获取按钮的可见度（0~1 之间的值）
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    -- 在按钮区域注册鼠标左键点击事件
    cursor:zone('primary_down', self, function() self:handle_cursor_click() end)

    -- 创建 ASS 绘图对象
    local ass = assdraw.ass_new()

    -- 判断按钮是否可点击（有回调函数）
    local is_clickable = self.is_clickable and self.on_click ~= nil
    -- 判断鼠标是否悬停在按钮上
    local is_hover = self.proximity_raw <= 0

    -- 确定前景色和背景色（激活状态下颜色互换）
    local foreground = self.active and self.background or self.foreground
    local background = self.active and self.foreground or self.background
    -- 背景透明度（激活状态下完全不透明，否则使用控制栏透明度配置）
    local background_opacity = self.active and 1 or config.opacity.controls

    -- 如果鼠标悬停且按钮可点击，但背景透明度小于 0.3，强制提升到 0.3
    -- 确保悬停时有足够的视觉反馈
    if is_hover and is_clickable and background_opacity < 0.3 then
        background_opacity = 0.3
    end

    -- ============================================================
    -- 绘制背景
    -- ============================================================
    if background_opacity > 0 then
        -- 根据激活状态和悬停状态决定背景颜色
        -- 激活或未悬停时使用背景色，悬停且未激活时使用前景色（反色高亮）
        local color = (self.active or not is_hover) and background or foreground
        ass:rect(self.ax, self.ay, self.bx, self.by, {
            color = color,
            radius = state.radius,  -- 圆角半径
            opacity = visibility * background_opacity,
        })
    end

    -- ============================================================
    -- 鼠标悬停时显示工具提示
    -- ============================================================
    if is_hover and self.tooltip then
        ass:tooltip(self, self.tooltip)
    end

    -- ============================================================
    -- 绘制角标 (Badge)
    -- ============================================================
    local icon_clip  -- 用于裁剪图标的剪裁路径（角标会遮挡图标的一部分）

    if self.badge then
        local badge_font_size = self.font_size * 0.6
        local badge_opts = {size = badge_font_size, color = background, opacity = visibility}
        local badge_width = text_width(self.badge, badge_opts)
        local width = math.ceil(badge_width + (badge_font_size / 7) * 2)
        local height = math.ceil(badge_font_size * 0.93)

        -- 角标定位在按钮的右下角
        local bx, by = self.bx - 1, self.by - 1

        -- 角标背景（圆形/圆角矩形）
        ass:rect(bx - width, by - height, bx, by, {
            color = foreground,
            radius = state.radius,
            opacity = visibility,
            border = self.active and 0 or 1,  -- 激活状态下无边框
            border_color = background,
        })

        -- 角标文字
        ass:txt(bx - width / 2, by - height / 2, 5, self.badge, badge_opts)

        -- 生成图标剪裁路径（让图标在角标区域被裁剪掉，避免重叠）
        local clip_border = math.max(self.font_size / 20, 1)
        local clip_path = assdraw.ass_new()
        clip_path:round_rect_cw(
            math.floor((bx - width) - clip_border),
            math.floor((by - height) - clip_border),
            bx, by, 3
        )
        icon_clip = '\\iclip(' .. clip_path.scale .. ', ' .. clip_path.text .. ')'
    end

    -- ============================================================
    -- 绘制图标
    -- ============================================================
    local x = round(self.ax + (self.bx - self.ax) / 2)
    local y = round(self.ay + (self.by - self.ay) / 2)

    ass:icon(x, y, self.font_size, self.icon, {
        color = foreground,
        -- 激活状态下无边框，否则使用配置的边框厚度
        border = self.active and 0 or options.text_border * state.scale,
        border_color = background,
        opacity = visibility,
        clip = icon_clip,  -- 如果有角标，裁剪图标被遮挡的部分
    })

    return ass
end

-- 返回 Button 类，供其他模块 require 使用
return Button