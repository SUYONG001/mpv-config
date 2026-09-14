-- ==============================================================================
-- Curtain.lua — 幕布组件
-- ==============================================================================
-- 功能概述：
--   1. 在屏幕上层绘制一个半透明的背景遮罩（幕布）
--   2. 当菜单、更新器等弹出面板显示时，幕布自动淡入
--   3. 当所有依赖幕布的元素关闭后，幕布自动淡出
--   4. 采用引用计数机制管理显示状态
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

---@class Curtain : Element
local Curtain = class(Element)

-- ==============================================================================
-- 构造函数与初始化
-- ==============================================================================

function Curtain:new() return Class.new(self) --[[@as Curtain]] end

function Curtain:init()
    -- 调用父类 Element 的初始化
    -- 参数：'curtain' 是元素 ID，render_order = 999（很高的值，确保渲染在顶层）
    -- 这样幕布会覆盖在所有其他 UI 元素之上
    Element.init(self, 'curtain', {render_order = 999})

    -- 当前透明度（0 = 完全透明，1 = 完全不透明）
    self.opacity = 0
    ---@type string[] 依赖此幕布的元素 ID 列表（引用计数）
    self.dependents = {}
end

-- ==============================================================================
-- 注册与注销 (register / unregister)
-- 使用引用计数控制幕布的显示与隐藏
-- ==============================================================================

---@param id string 依赖此幕布的元素 ID
function Curtain:register(id)
    -- 将新依赖者添加到列表
    self.dependents[#self.dependents + 1] = id

    -- 如果这是第一个注册者，幕布淡入（透明度 0 → 1）
    if #self.dependents == 1 then
        self:tween_property('opacity', self.opacity, 1)
    end
end

---@param id string 取消依赖此幕布的元素 ID
function Curtain:unregister(id)
    -- 从依赖者列表中移除该 ID
    self.dependents = itable_filter(self.dependents, function(item) return item ~= id end)

    -- 如果没有任何依赖者了，幕布淡出（透明度 1 → 0）
    if #self.dependents == 0 then
        self:tween_property('opacity', self.opacity, 0)
    end
end

-- ==============================================================================
-- 渲染函数 (render)
-- 根据当前透明度绘制全屏半透明遮罩
-- ==============================================================================

function Curtain:render()
    -- 如果透明度为 0，或者配置中幕布透明度为 0，则不绘制
    if self.opacity == 0 or config.opacity.curtain == 0 then return end

    local ass = assdraw.ass_new()

    -- 绘制全屏矩形遮罩
    -- 颜色：从 config.color.curtain 读取（默认 #111111 深灰色）
    -- 透明度：config.opacity.curtain * self.opacity
    --   - config.opacity.curtain：用户在 uosc.conf 中配置的幕布透明度（默认 0.8）
    --   - self.opacity：幕布当前的动画透明度（0~1）
    ass:rect(0, 0, display.width, display.height, {
        color = config.color.curtain,
        opacity = config.opacity.curtain * self.opacity,
    })

    return ass
end

return Curtain