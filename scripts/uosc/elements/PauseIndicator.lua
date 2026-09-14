-- ==============================================================================
-- PauseIndicator.lua — 暂停指示器组件
-- ==============================================================================
-- 功能概述：
--   1. 在播放/暂停切换时，在屏幕中央显示一个大的暂停/播放图标
--   2. 支持两种模式：'flash'（闪动后消失）和 'static'（常驻显示）
--   3. 暂停时显示暂停图标，播放时显示播放图标
--   4. 支持淡出背景遮罩，提升视觉层次感
--   5. 图标大小随透明度变化（淡出时略微放大，产生呼吸感）
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- ==============================================================================
-- PauseIndicator 类定义
-- 继承自 Element，用于显示播放/暂停状态图标
-- ==============================================================================

---@class PauseIndicator : Element
local PauseIndicator = class(Element)

-- ==============================================================================
-- 构造函数
-- ==============================================================================

function PauseIndicator:new() return Class.new(self) --[[@as PauseIndicator]] end

-- ==============================================================================
-- 初始化 (init)
-- ==============================================================================

function PauseIndicator:init()
    -- 调用父类 Element 的初始化
    -- 参数：'pause_indicator' 是元素 ID
    -- render_order = 3 表示渲染顺序靠前
    Element.init(self, 'pause_indicator', {render_order = 3})

    -- 忽略幕布（curtain）：即使幕布打开，暂停指示器也显示
    self.ignores_curtain = true

    -- 当前是否处于暂停状态（从 state 读取初始值）
    self.paused = state.pause

    -- 当前透明度（0 = 完全透明，1 = 完全不透明）
    self.opacity = 0

    -- 是否正在淡出（用于区分暂停时的背景遮罩）
    self.fadeout = false

    -- 初始化配置选项
    self:init_options()
end

-- ==============================================================================
-- 配置初始化 (init_options)
-- 根据用户配置决定指示器的行为模式
-- ==============================================================================

function PauseIndicator:init_options()
    -- 基础图标透明度：
    --   flash 模式：透明度为 1（完全显示然后消失）
    --   static 模式：透明度为 0.8（常驻显示，略透明避免遮挡画面）
    self.base_icon_opacity = options.pause_indicator == 'flash' and 1 or 0.8

    -- 保存当前模式
    self.type = options.pause_indicator

    -- 立即响应当前的暂停状态
    self:on_prop_pause()
end

-- ==============================================================================
-- 闪动效果 (flash)
-- 暂停时图标闪动出现，然后自动淡出
-- ==============================================================================

function PauseIndicator:flash()
    -- 不能等待 pause 属性事件监听器来设置 paused 状态，
    -- 因为当这个函数在快捷键绑定中被调用时（如 cycle pause 后立即调用 flash-pause-indicator），
    -- pause 事件触发不够快，指示器会使用旧的图标渲染。
    -- 因此这里直接从 mpv 读取最新状态。
    self.paused = mp.get_property_native('pause')

    -- 重置状态：不淡出，透明度设为 1
    self.fadeout = false
    self.opacity = 1

    -- 从 1 渐变到 0，持续 300 毫秒（淡出动画）
    self:tween_property('opacity', 1, 0, 300)
end

-- ==============================================================================
-- 决定显隐 (decide)
-- 静态模式下，根据暂停状态决定是否显示指示器
-- ==============================================================================

-- 决定静态指示器是否可见
function PauseIndicator:decide()
    -- 直接从 mpv 读取暂停状态（见 flash() 中的说明）
    self.paused = mp.get_property_native('pause')

    -- 如果暂停：显示并淡入（fadeout = true 表示显示背景遮罩）
    -- 如果播放：隐藏
    self.fadeout = self.paused
    self.opacity = self.paused and 1 or 0

    request_render()

    -- Workaround: 修复 mpv Windows 构建中的一个竞态条件 bug，
    -- 该 bug 导致暂停时 OSD 更新被忽略。
    -- 测试中 0.03 秒仍会丢失渲染，0.04 秒正常，
    -- 为了安全多加 10ms。
    mp.add_timeout(0.05, function()
        osd:update()
    end)
end

-- ==============================================================================
-- 属性观察者 (on_prop_pause)
-- 监听暂停状态变化
-- ==============================================================================

function PauseIndicator:on_prop_pause()
    -- 如果时间轴正在被拖拽，不更新指示器（避免干扰拖拽体验）
    if Elements:v('timeline', 'pressed') then
        return
    end

    if options.pause_indicator == 'flash' then
        -- 闪动模式：只有状态真正变化时才触发闪动
        if self.paused ~= state.pause then
            self:flash()
        end
    elseif options.pause_indicator == 'static' then
        -- 静态模式：直接决定显示状态
        self:decide()
    end
end

-- ==============================================================================
-- 配置变化回调 (on_options)
-- 当用户修改配置时重新初始化
-- ==============================================================================

function PauseIndicator:on_options()
    self:init_options()
    -- 如果切换到 flash 模式，重置透明度为 0（隐藏）
    if self.type == 'flash' then
        self.opacity = 0
    end
end

-- ==============================================================================
-- 渲染函数 (render)
-- 绘制暂停指示器的背景遮罩和图标
-- ==============================================================================

function PauseIndicator:render()
    -- 透明度为 0 时不绘制
    if self.opacity == 0 then
        return
    end

    local ass = assdraw.ass_new()

    -- ============================================================
    -- 背景遮罩（仅当 fadeout = true 时绘制）
    -- 在暂停时显示一个半透明黑色背景，突出图标
    -- ============================================================
    if self.fadeout then
        ass:rect(0, 0, display.width, display.height, {
            color = bg,
            opacity = self.opacity * 0.3,  -- 30% 透明度
        })
    end

    -- ============================================================
    -- 图标
    -- 尺寸：暂停时稍大（20%），播放时稍小（15%）
    -- 淡出过程中图标会略微放大，产生呼吸感
    -- ============================================================
    local size = round(math.min(display.width, display.height) * (self.fadeout and 0.20 or 0.15))
    size = size + size * (1 - self.opacity)  -- 透明度越低，图标越大

    if self.paused then
        -- 暂停图标（双竖线）
        ass:icon(display.width / 2, display.height / 2, size, 'pause', {
            border = 1,
            opacity = self.base_icon_opacity * self.opacity,
        })
    else
        -- 播放图标（三角形），略大（×1.2）
        ass:icon(display.width / 2, display.height / 2, size * 1.2, 'play_arrow', {
            border = 1,
            opacity = self.base_icon_opacity * self.opacity,
        })
    end

    return ass
end

return PauseIndicator