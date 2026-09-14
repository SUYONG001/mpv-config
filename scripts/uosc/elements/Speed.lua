-- ==============================================================================
-- Speed.lua — 播放速度控制滑块组件
-- ==============================================================================
-- 功能概述：
--   1. 在控制栏中提供一个水平滑块，用于调整播放速度
--   2. 支持鼠标拖拽滑块、滚轮滚动、点击重置三种交互方式
--   3. 显示速度刻度线（notches），帮助用户视觉定位速度值
--   4. 拖拽时速度会吸附到最近的刻度值（步进值由 options.speed_step 控制）
--   5. 支持两种速度调整模式：加法模式（加减）和乘法模式（倍率）
-- ==============================================================================
-- 设计特点：
--   - 刻度线密度：10 条，每条代表 0.1x 的步进
--   - 刻度线高度分三级：每 0.5x 为中刻度，每 1.0x 为大刻度
--   - 拖拽时速度值会实时跟随鼠标位置，并自动吸附到最近的刻度
--   - 中央有倒三角指示器，标记当前速度位置
--   - 右键点击重置速度为 1.0x
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- ==============================================================================
-- 1. 类型定义 (Type Alias)
-- ==============================================================================

---@alias Dragging { start_time: number; start_x: number; distance: number; speed_distance: number; start_speed: number; }
-- 拖拽状态字段说明：
--   start_time     : 拖拽开始时间
--   start_x        : 鼠标起始 X 坐标
--   distance       : 鼠标拖拽总距离（像素）
--   speed_distance : 鼠标拖拽对应的速度变化量
--   start_speed    : 拖拽开始时的速度值

-- ==============================================================================
-- 2. Speed 类定义
-- 继承自 Element，实现播放速度控制滑块
-- ==============================================================================

---@class Speed : Element
local Speed = class(Element)

-- ==============================================================================
-- 3. 构造函数与初始化 (new / init)
-- ==============================================================================

---@param props? ElementProps
function Speed:new(props) return Class.new(self, props) --[[@as Speed]] end

function Speed:init(props)
    -- 调用父类 Element 的初始化
    Element.init(self, 'speed', props)

    self.width = 0           -- 滑块宽度
    self.height = 0          -- 滑块高度
    self.notches = 10        -- 刻度线总数（从中心向两侧各 5 条）
    self.notch_every = 0.1   -- 每个刻度代表的步进值（0.1x）
    ---@type number           -- 刻度线之间的间距（像素）
    self.notch_spacing = nil
    ---@type number           -- 速度文字的字号
    self.font_size = nil
    ---@type Dragging|nil     -- 当前拖拽状态（nil 表示未拖拽）
    self.dragging = nil
end

-- ==============================================================================
-- 4. 可见度计算 (get_visibility)
-- ==============================================================================

function Speed:get_visibility()
    -- 如果时间轴被悬停，强制隐藏速度控件（-1 表示强制隐藏）
    if Elements:maybe('timeline', 'get_is_hovered') then
        return -1
    end
    -- 否则使用父类的可见度计算
    return Element.get_visibility(self)
end

-- ==============================================================================
-- 5. 坐标更新回调 (on_coordinates)
-- 当速度控件的坐标发生变化时，重新计算尺寸和布局参数
-- ==============================================================================

function Speed:on_coordinates()
    self.height = self.by - self.ay
    self.width = self.bx - self.ax

    -- 刻度间距 = 总宽度 / (刻度数 + 1)
    -- 中心位置为一个刻度，左右各 5 个，共 11 个位置，间距为宽度 / 11
    self.notch_spacing = self.width / (self.notches + 1)

    -- 字号 = 高度 × 0.48 × 字体缩放系数
    self.font_size = round(self.height * 0.48 * options.font_scale)
end

-- ==============================================================================
-- 6. 配置变化回调 (on_options)
-- ==============================================================================

function Speed:on_options()
    self:on_coordinates()
end

-- ==============================================================================
-- 7. 速度步进计算 (speed_step)
-- 根据当前速度和方向，计算下一步的值
-- ==============================================================================

---@param speed number 当前速度
---@param up boolean true=加速，false=减速
---@return number 调整后的速度值
function Speed:speed_step(speed, up)
    if options.speed_step_is_factor then
        -- 乘法模式：乘以或除以 speed_step（如 1.0 → 1.1 或 0.9）
        if up then
            return speed * options.speed_step
        else
            return speed * 1 / options.speed_step
        end
    else
        -- 加法模式：增加或减少 speed_step（如 1.0 → 1.1 或 0.9）
        if up then
            return speed + options.speed_step
        else
            return speed - options.speed_step
        end
    end
end

-- ==============================================================================
-- 8. 鼠标按下处理 (handle_cursor_down)
-- 开始拖拽速度滑块
-- ==============================================================================

function Speed:handle_cursor_down()
    -- 停止可能正在进行的动画
    self:tween_stop()

    -- 初始化拖拽状态
    self.dragging = {
        start_time = mp.get_time(),
        start_x = cursor.x,
        distance = 0,
        speed_distance = 0,
        start_speed = state.speed,
    }
end

-- ==============================================================================
-- 9. 鼠标移动处理 (on_global_mouse_move)
-- 拖拽过程中实时更新速度值
-- ==============================================================================

function Speed:on_global_mouse_move()
    if not self.dragging then return end

    -- 计算鼠标拖拽距离（像素）和对应的速度变化量
    self.dragging.distance = cursor.x - self.dragging.start_x
    -- 速度变化量 = -(距离 / 刻度间距) × 刻度步进
    -- 负号是因为：鼠标向右拖拽 → 加速（正方向）
    self.dragging.speed_distance = (-self.dragging.distance / self.notch_spacing * self.notch_every)

    local speed_current = state.speed
    -- 当前拖拽位置对应的理论速度值
    local speed_drag_current = self.dragging.start_speed + self.dragging.speed_distance
    speed_drag_current = clamp(0.01, speed_drag_current, 100)  -- 限制范围 0.01~100
    local drag_dir_up = speed_drag_current > speed_current   -- 判断拖拽方向

    -- 找到最接近理论速度的两个刻度值（上一个和下一个）
    local speed_step_next = speed_current
    local speed_drag_diff = math.abs(speed_drag_current - speed_current)

    -- 向前找到下一个刻度值
    while math.abs(speed_step_next - speed_current) < speed_drag_diff do
        speed_step_next = self:speed_step(speed_step_next, drag_dir_up)
    end

    -- 向后找到一个刻度值
    local speed_step_prev = self:speed_step(speed_step_next, not drag_dir_up)

    -- 比较两个刻度值哪个更接近理论速度，选择更近的那个
    local speed_new = speed_step_prev
    local speed_next_diff = math.abs(speed_drag_current - speed_step_next)
    local speed_prev_diff = math.abs(speed_drag_current - speed_step_prev)
    if speed_next_diff < speed_prev_diff then
        speed_new = speed_step_next
    end

    -- 如果速度发生变化，应用新速度
    if speed_new ~= speed_current then
        mp.set_property_native('speed', speed_new)
    end
end

-- ==============================================================================
-- 10. 鼠标释放处理 (handle_cursor_up / on_global_mouse_leave)
-- 结束拖拽
-- ==============================================================================

function Speed:handle_cursor_up()
    self.dragging = nil
    request_render()
end

function Speed:on_global_mouse_leave()
    -- 鼠标离开窗口时也结束拖拽
    self.dragging = nil
    request_render()
end

-- ==============================================================================
-- 11. 滚轮事件处理 (handle_wheel_up / handle_wheel_down)
-- 使用鼠标滚轮调整速度
-- ==============================================================================

function Speed:handle_wheel_up()
    mp.set_property_native('speed', self:speed_step(state.speed, true))
end

function Speed:handle_wheel_down()
    mp.set_property_native('speed', self:speed_step(state.speed, false))
end

-- ==============================================================================
-- 12. 渲染函数 (render)
-- 绘制速度滑块的完整视觉界面
-- ==============================================================================

function Speed:render()
    local visibility = self:get_visibility()
    -- 拖拽时完全不透明，否则根据可见度
    local opacity = self.dragging and 1 or visibility

    if opacity <= 0 then return end

    -- 注册鼠标事件区域
    cursor:zone('primary_down', self, function()
        self:handle_cursor_down()
        cursor:once('primary_up', function()
            self:handle_cursor_up()
        end)
    end)
    cursor:zone('secondary_click', self, function()
        mp.set_property_native('speed', 1)  -- 右键点击重置为 1.0x
    end)
    cursor:zone('wheel_down', self, function()
        self:handle_wheel_down()
    end)
    cursor:zone('wheel_up', self, function()
        self:handle_wheel_up()
    end)

    local ass = assdraw.ass_new()

    -- ============================================================
    -- 背景
    -- ============================================================
    ass:rect(self.ax, self.ay, self.bx, self.by, {
        color = bg,
        radius = state.radius,
        opacity = opacity * config.opacity.speed,
    })

    -- ============================================================
    -- 计算坐标
    -- ============================================================
    local ax, ay = self.ax, self.ay
    local bx, by = self.bx, ay + self.height
    local half_width = self.width / 2
    local half_x = ax + half_width

    -- ============================================================
    -- 绘制刻度线 (Notches)
    -- 从中心向两侧展开，每条刻度线代表 0.1x 的步进
    -- 大刻度（每隔 1.0x）更高，中刻度（每隔 0.5x）次之，小刻度最低
    -- ============================================================
    local speed_at_center = state.speed
    if self.dragging then
        -- 拖拽时以当前拖拽位置计算刻度
        speed_at_center = self.dragging.start_speed + self.dragging.speed_distance
        speed_at_center = clamp(0.01, speed_at_center, 100)
    end

    -- 找到离中心最近的实际刻度值（四舍五入到 notch_every 的倍数）
    local nearest_notch_speed = round(speed_at_center / self.notch_every) * self.notch_every
    local nearest_notch_x = half_x + (((nearest_notch_speed - speed_at_center) / self.notch_every) * self.notch_spacing)

    -- 刻度高度分层
    local guide_size = math.floor(self.height / 7.5)   -- 底部指示器大小
    local notch_by = by - guide_size
    local notch_ay_big = ay + round(self.font_size * 1.1)      -- 大刻度（1.0x 倍数）
    local notch_ay_medium = notch_ay_big + ((notch_by - notch_ay_big) * 0.2)  -- 中刻度（0.5x 倍数）
    local notch_ay_small = notch_ay_big + ((notch_by - notch_ay_big) * 0.4)   -- 小刻度（0.1x 倍数）

    local from_to_index = math.floor(self.notches / 2)

    -- 从中心向两侧绘制刻度
    for i = -from_to_index, from_to_index do
        local notch_speed = nearest_notch_speed + (i * self.notch_every)

        if notch_speed >= 0 and notch_speed <= 100 then
            local notch_x = nearest_notch_x + (i * self.notch_spacing)
            local notch_thickness = 1
            local notch_ay = notch_ay_small

            -- 大刻度：1.0x 的倍数（如 1.0, 2.0, 3.0...）
            if (notch_speed % (self.notch_every * 10)) < 0.00000001 then
                notch_ay = notch_ay_big
                notch_thickness = 1.5
            -- 中刻度：0.5x 的倍数（如 0.5, 1.5, 2.5...）
            elseif (notch_speed % (self.notch_every * 5)) < 0.00000001 then
                notch_ay = notch_ay_medium
            end

            -- 透明度：越靠近边缘越淡
            local opacity_factor = math.min(1.2 - (math.abs((notch_x - ax - half_width) / half_width)), 1)
            ass:rect(notch_x - notch_thickness, notch_ay, notch_x + notch_thickness, notch_by, {
                color = fg,
                border = 1,
                border_color = bg,
                opacity = opacity_factor * opacity,
            })
        end
    end

    -- ============================================================
    -- 中心倒三角指示器 (Center Guide)
    -- 标记当前速度值在刻度线上的位置
    -- ============================================================
    ass:new_event()
    ass:append('{\\rDefault\\an7\\blur0\\bord1\\shad0\\1c&H' .. fg .. '\\3c&H' .. bg .. '}')
    ass:opacity(opacity)
    ass:pos(0, 0)
    ass:draw_start()
    ass:move_to(half_x, by - 2 - guide_size)
    ass:line_to(half_x + guide_size, by - 2)
    ass:line_to(half_x - guide_size, by - 2)
    ass:draw_stop()

    -- ============================================================
    -- 速度数值显示
    -- 显示当前速度值（如 "1.0x"）
    -- ============================================================
    local speed_text = (round(state.speed * 100) / 100) .. 'x'
    ass:txt(half_x, ay + (notch_ay_big - ay) / 2, 5, speed_text, {
        size = self.font_size,
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = opacity,
    })

    return ass
end

return Speed