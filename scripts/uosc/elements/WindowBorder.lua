-- ==============================================================================
-- WindowBorder.lua — 窗口边框组件
-- ==============================================================================
-- 功能概述：
--   1. 在无边框模式下，在窗口边缘绘制一条细边框
--   2. 帮助用户视觉上区分窗口边界（尤其在全屏或深色背景下）
--   3. 仅在特定条件下启用：边框设置有效 + 未全屏/最大化 + 无系统边框
-- ==============================================================================
-- 设计特点：
--   - 使用 iclip（反向裁剪）在窗口边缘绘制细线
--   - 边框厚度由 options.window_border_size 控制
--   - 颜色使用背景色，透明度由 config.opacity.border 控制
--   - render_order = 9999 确保边框在所有其他 UI 元素之上绘制
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- ==============================================================================
-- WindowBorder 类定义
-- 继承自 Element，用于绘制窗口边框
-- ==============================================================================

---@class WindowBorder : Element
local WindowBorder = class(Element)

-- ==============================================================================
-- 构造函数与初始化
-- ==============================================================================

function WindowBorder:new() return Class.new(self) --[[@as WindowBorder]] end

function WindowBorder:init()
    -- 调用父类 Element 的初始化
    -- render_order = 9999（极高的值，确保边框在所有元素之上）
    Element.init(self, 'window_border', {render_order = 9999})

    self.size = 0  -- 边框厚度（像素）

    -- 决定是否启用
    self:decide_enabled()
end

-- ==============================================================================
-- 启用状态判断 (decide_enabled)
-- ==============================================================================

function WindowBorder:decide_enabled()
    -- 启用条件：
    --   1. options.window_border_size > 0（配置了边框厚度）
    --   2. 未全屏/最大化（fullormaxed = false）
    --   3. 无系统边框（border = false）
    self.enabled = options.window_border_size > 0 and not state.fullormaxed and not state.border

    -- 如果启用，边框厚度 = 配置值 × 缩放系数；否则为 0
    self.size = self.enabled and round(options.window_border_size * state.scale) or 0
end

-- ==============================================================================
-- 属性观察者
-- 当相关属性变化时，重新判断启用状态
-- ==============================================================================

function WindowBorder:on_prop_border() self:decide_enabled() end
function WindowBorder:on_prop_title_bar() self:decide_enabled() end
function WindowBorder:on_prop_fullormaxed() self:decide_enabled() end
function WindowBorder:on_options() self:decide_enabled() end

-- ==============================================================================
-- 渲染函数 (render)
-- 使用 iclip（反向裁剪）在窗口边缘绘制边框
-- ==============================================================================

function WindowBorder:render()
    if self.size > 0 then
        local ass = assdraw.ass_new()

        -- iclip（反向裁剪）：只绘制矩形边缘的像素
        -- 参数：左, 上, 右, 下
        -- 效果：只保留矩形边框部分的像素，内部被裁剪掉
        local clip = '\\iclip(' ..
            self.size .. ',' .. self.size .. ',' ..
            (display.width - self.size) .. ',' ..
            (display.height - self.size) .. ')'

        -- 绘制一个比屏幕略大的矩形，使用 iclip 只保留边框部分
        -- color = bg（背景色），opacity = config.opacity.border
        ass:rect(0, 0, display.width + 1, display.height + 1, {
            color = bg,
            clip = clip,
            opacity = config.opacity.border,
        })

        return ass
    end
    -- 如果边框厚度为 0，不绘制任何内容
end

return WindowBorder