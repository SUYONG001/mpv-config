-- ==============================================================================
-- BufferingIndicator.lua — 缓冲指示器组件
-- ==============================================================================
-- 功能概述：
--   1. 检测 mpv 的缓冲状态（缓存欠载 / 缓冲进度 < 100%）
--   2. 在画面中央显示一个半透明背景 + 旋转的加载动画（spinner）
--   3. 当缓冲恢复或播放暂停时自动隐藏
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element，所有 UI 组件都继承自它
local Element = require('elements/Element')

---@class BufferingIndicator : Element
-- BufferingIndicator 类继承自 Element，用于在缓冲时显示指示器
local BufferingIndicator = class(Element)

-- 构造函数：创建一个新的 BufferingIndicator 实例
function BufferingIndicator:new() return Class.new(self) --[[@as BufferingIndicator]] end

-- ==============================================================================
-- 初始化函数 (init)
-- ==============================================================================
function BufferingIndicator:init()
    -- 调用父类 Element 的初始化
    -- 参数：'buffering_indicator' 是元素 ID
    -- {ignores_curtain = true, render_order = 2} 表示：
    --   - ignores_curtain = true  → 即使幕布（curtain）打开，也显示此元素
    --   - render_order = 2        → 渲染顺序为 2（数字越小越靠底层）
    Element.init(self, 'buffering_indicator', {ignores_curtain = true, render_order = 2})

    -- 初始状态为禁用（不显示）
    self.enabled = false
    -- 根据当前状态决定是否启用
    self:decide_enabled()
end

-- ==============================================================================
-- 核心逻辑：决定缓冲指示器是否应该显示 (decide_enabled)
-- ==============================================================================
function BufferingIndicator:decide_enabled()
    -- 判断是否存在缓冲欠载（cache_underrun）或缓冲进度 < 100%
    -- cache_buffering 表示缓冲进度百分比，< 100 表示还未缓冲完成
    local cache = state.cache_underrun or (state.cache_buffering and state.cache_buffering < 100)

    -- 判断播放器是否处于空闲状态且未到达文件末尾
    -- core_idle = true 表示播放器核心处于空闲（解码器暂停）
    -- eof_reached = false 表示尚未到达文件末尾
    local player = state.core_idle and not state.eof_reached

    -- 如果当前是启用状态，检查是否需要关闭
    if self.enabled then
        -- 如果播放器不处于空闲状态，或者暂停且没有缓冲需求，则关闭指示器
        if not player or (state.pause and not cache) then
            self.enabled = false
        end
    -- 如果当前是禁用状态，检查是否需要开启
    elseif player and cache and state.uncached_ranges then
        -- 条件：播放器空闲 + 正在缓冲 + 存在未缓存的范围
        self.enabled = true
    end
    -- 注意：state.uncached_ranges 由 mpv 的 demuxer-cache-state 属性提供，
    -- 表示当前还有哪些时间段尚未缓存
end

-- ==============================================================================
-- 属性观察者（Observers）
-- 当这些 mpv 属性变化时，触发 decide_enabled 重新决策
-- ==============================================================================

-- 暂停状态变化
function BufferingIndicator:on_prop_pause() self:decide_enabled() end
-- 播放器核心空闲状态变化
function BufferingIndicator:on_prop_core_idle() self:decide_enabled() end
-- 是否到达文件末尾
function BufferingIndicator:on_prop_eof_reached() self:decide_enabled() end
-- 未缓存的范围变化（流媒体拖动时）
function BufferingIndicator:on_prop_uncached_ranges() self:decide_enabled() end
-- 缓冲进度变化（0~100）
function BufferingIndicator:on_prop_cache_buffering() self:decide_enabled() end
-- 是否发生缓存欠载（数据读取速度跟不上播放速度）
function BufferingIndicator:on_prop_cache_underrun() self:decide_enabled() end

-- ==============================================================================
-- 渲染函数 (render)
-- 返回一个 ASS 绘图对象，包含背景遮罩和旋转的加载动画
-- ==============================================================================
function BufferingIndicator:render()
    -- 创建 ASS 绘图对象
    local ass = assdraw.ass_new()

    -- 绘制全屏半透明背景遮罩
    -- config.opacity.buffering_indicator 从 uosc.conf 的 opacity 配置中读取
    ass:rect(0, 0, display.width, display.height, {color = bg, opacity = config.opacity.buffering_indicator})

    -- 计算 spinner（旋转加载图标）的大小
    -- 取 30 + 屏幕短边的 1/10，保证在不同分辨率下都有合适的尺寸
    local size = round(30 + math.min(display.width, display.height) / 10)

    -- 如果菜单（menu）正在显示，降低指示器透明度（避免视觉干扰）
    local opacity = (Elements.menu and Elements.menu:is_alive()) and 0.3 or 0.8

    -- 在屏幕中央绘制旋转的 spinner 图标
    -- 颜色为前景色（fg），透明度为计算后的 opacity
    ass:spinner(display.width / 2, display.height / 2, size, {color = fg, opacity = opacity})

    -- 返回 ASS 对象，由上层渲染引擎统一提交到 OSD
    return ass
end

-- 返回 BufferingIndicator 类，供其他模块 require 使用
return BufferingIndicator