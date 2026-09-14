-- ==============================================================================
-- Volume.lua — 音量控制组件
-- ==============================================================================
-- 功能概述：
--   1. 在屏幕左侧或右侧显示一个垂直的音量滑块
--   2. 支持鼠标拖拽调节音量（自动吸附到步进值）
--   3. 支持鼠标滚轮调节音量
--   4. 显示当前音量数值（在滑块上浮动显示）
--   5. 底部有静音按钮，点击切换静音状态
--   6. 右键点击滑块区域可重置音量为 100% 并取消静音
--   7. 当音量超过 100% 时（volume_max > 100），滑块底部显示"凸起"指示器
--   8. 无音频轨道的文件显示禁用条纹
-- ==============================================================================
-- 设计特点：
--   - 滑块路径包含 nudge（凸起）效果，用于指示音量超过 100% 的区域
--   - 音量数值在滑块前景和背景之间切换颜色，确保始终可读
--   - 静音按钮图标根据音量状态变化（满/低/静音）
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- ==============================================================================
-- 第一部分：VolumeSlider（音量滑块）
-- ==============================================================================

---@class VolumeSlider : Element
local VolumeSlider = class(Element)

-- ==============================================================================
-- 构造函数与初始化
-- ==============================================================================

---@param props? ElementProps
function VolumeSlider:new(props) return Class.new(self, props) --[[@as VolumeSlider]] end

function VolumeSlider:init(props)
    -- 调用父类 Element 的初始化
    Element.init(self, 'volume_slider', props)

    -- 是否正在拖拽
    self.pressed = false

    -- nudge（凸起）相关：当 volume_max > 100 时，滑块底部显示一个凸起指示器
    self.nudge_y = 0          -- 凸起位置的 Y 坐标
    self.nudge_size = 0       -- 凸起的大小
    self.draw_nudge = false   -- 是否绘制凸起
    self.spacing = 0          -- 音量数值与滑块底部的间距

    -- 边框厚度
    self.border_size = 0

    -- 更新尺寸
    self:update_dimensions()
end

-- ==============================================================================
-- 尺寸更新 (update_dimensions)
-- ==============================================================================

function VolumeSlider:update_dimensions()
    self.border_size = math.max(0, round(options.volume_border * state.scale))
end

-- ==============================================================================
-- 可见度计算 (get_visibility)
-- 继承自父容器 Volume 的可见度
-- ==============================================================================

function VolumeSlider:get_visibility()
    return Elements.volume:get_visibility(self)
end

-- ==============================================================================
-- 设置音量 (set_volume)
-- 将音量吸附到 volume_step 的倍数
-- ==============================================================================

---@param volume number 目标音量（0~volume_max）
function VolumeSlider:set_volume(volume)
    -- 吸附到最近的步进值
    volume = round(volume / options.volume_step) * options.volume_step

    -- 如果音量没有变化，不执行任何操作
    if state.volume == volume then
        return
    end

    -- 限制范围并应用
    mp.commandv('set', 'volume', clamp(0, volume, state.volume_max))
end

-- ==============================================================================
-- 根据鼠标位置设置音量 (set_from_cursor)
-- ==============================================================================

function VolumeSlider:set_from_cursor()
    -- 计算鼠标在滑块中的位置比例（从上到下）
    -- 鼠标越靠上，音量越大
    local volume_fraction = (self.by - cursor.y - self.border_size) / (self.by - self.ay - self.border_size)
    self:set_volume(volume_fraction * state.volume_max)
end

-- ==============================================================================
-- 事件回调
-- ==============================================================================

function VolumeSlider:on_display() self:update_dimensions() end
function VolumeSlider:on_options() self:update_dimensions() end

-- ==============================================================================
-- 坐标更新 (on_coordinates)
-- 当滑块坐标变化时，计算凸起位置等参数
-- ==============================================================================

function VolumeSlider:on_coordinates()
    -- 需要有效的 volume_max
    if type(state.volume_max) ~= 'number' or state.volume_max <= 0 then
        return
    end

    local width = self.bx - self.ax

    -- 计算 100% 音量在滑块中的 Y 位置
    -- 如果 volume_max > 100，100% 以上的部分就是"凸起"区域
    self.nudge_y = self.by - round((self.by - self.ay) * (100 / state.volume_max))

    -- 凸起大小约为滑块宽度的 18%
    self.nudge_size = round(width * 0.18)

    -- 只有滑块高度 > 凸起位置时才有凸起（即 volume_max > 100）
    self.draw_nudge = self.ay < self.nudge_y

    -- 音量数值与滑块底部的间距
    self.spacing = round(width * 0.2)
end

-- ==============================================================================
-- 鼠标事件处理
-- ==============================================================================

-- 全局鼠标移动：拖拽时实时更新音量
function VolumeSlider:on_global_mouse_move()
    if self.pressed then
        self:set_from_cursor()
    end
end

-- 滚轮向上：增加音量
function VolumeSlider:handle_wheel_up()
    self:set_volume(state.volume + options.volume_step)
end

-- 滚轮向下：减小音量
function VolumeSlider:handle_wheel_down()
    self:set_volume(state.volume - options.volume_step)
end

-- ==============================================================================
-- 渲染函数 (render)
-- 绘制音量滑块的完整视觉界面
-- ==============================================================================

function VolumeSlider:render()
    local visibility = self:get_visibility()
    local ax, ay, bx, by = self.ax, self.ay, self.bx, self.by
    local width, height = bx - ax, by - ay

    if width <= 0 or height <= 0 or visibility <= 0 then
        return
    end

    -- ============================================================
    -- 注册鼠标事件区域
    -- ============================================================
    cursor:zone('primary_down', self, function()
        self.pressed = true
        self:set_from_cursor()
        cursor:once('primary_up', function()
            self.pressed = false
        end)
    end)

    cursor:zone('wheel_down', self, function()
        self:handle_wheel_down()
    end)

    cursor:zone('wheel_up', self, function()
        self:handle_wheel_up()
    end)

    local ass = assdraw.ass_new()

    -- ============================================================
    -- 凸起参数
    -- ============================================================
    local nudge_y, nudge_size = self.draw_nudge and self.nudge_y or -math.huge, self.nudge_size

    -- 音量在滑块中的 Y 位置（从上到下，音量越大位置越靠上）
    local volume_y = self.ay + self.border_size +
        ((height - (self.border_size * 2)) * (1 - math.min(state.volume / state.volume_max, 1)))

    -- ============================================================
    -- 凸起路径生成函数 (create_nudged_path)
    -- 生成一个带凸起的矩形路径，用于绘制滑块背景和前景
    -- ============================================================

    ---@param p number 滑块边缘的内边距
    ---@param r number 圆角半径
    ---@param cy? number 裁剪的 Y 坐标（用于前景）
    function create_nudged_path(p, r, cy)
        cy = cy or ay + p  -- 默认裁剪到底部

        -- 调整坐标（内边距和圆角）
        local ax, bx, by = ax + p, bx - p, by - p
        local d, rh = r * 2, r / 2

        -- 凸起大小（根据内边距调整）
        local nudge_size = ((QUARTER_PI_SIN * (nudge_size - p)) + p) / QUARTER_PI_SIN

        -- 创建路径
        local path = assdraw.ass_new()

        -- 从右下角开始绘制（逆时针方向）
        path:move_to(bx - r, by)
        path:line_to(ax + r, by)

        -- ============================================================
        -- 判断裁剪位置是否在圆角区域内
        -- ============================================================
        if cy > by - d then
            -- 裁剪位置在底部圆角区域内，需要特殊处理
            local subtracted_radius = (d - (cy - (by - d))) / 2
            local xbd = (r - subtracted_radius * 1.35)  -- x 贝塞尔偏移量
            path:bezier_curve(ax + xbd, by, ax + xbd, cy, ax + r, cy)
            path:line_to(bx - r, cy)
            path:bezier_curve(bx - xbd, cy, bx - xbd, by, bx - r, by)
        else
            -- 正常绘制：左下角圆角
            path:bezier_curve(ax + rh, by, ax, by - rh, ax, by - r)

            -- ============================================================
            -- 凸起区域绘制
            -- ============================================================
            local nudge_bottom_y = nudge_y + nudge_size

            if cy + rh <= nudge_bottom_y then
                -- 裁剪位置在凸起区域内
                path:line_to(ax, nudge_bottom_y)

                if cy <= nudge_y then
                    -- 裁剪位置在凸起顶部以上（完整凸起）
                    path:line_to((ax + nudge_size), nudge_y)

                    local nudge_top_y = nudge_y - nudge_size

                    if cy <= nudge_top_y then
                        -- 裁剪位置在凸起顶部以上
                        local r, rh = r, rh
                        if cy > nudge_top_y - r then
                            r = nudge_top_y - cy
                            rh = r / 2
                        end
                        path:line_to(ax, nudge_top_y)
                        path:line_to(ax, cy + r)
                        path:bezier_curve(ax, cy + rh, ax + rh, cy, ax + r, cy)
                        path:line_to(bx - r, cy)
                        path:bezier_curve(bx - rh, cy, bx, cy + rh, bx, cy + r)
                        path:line_to(bx, nudge_top_y)
                    else
                        -- 裁剪位置在凸起内部
                        local triangle_side = cy - nudge_top_y
                        path:line_to((ax + triangle_side), cy)
                        path:line_to((bx - triangle_side), cy)
                    end
                    path:line_to((bx - nudge_size), nudge_y)
                else
                    -- 裁剪位置在凸起底部区域内
                    local triangle_side = nudge_bottom_y - cy
                    path:line_to((ax + triangle_side), cy)
                    path:line_to((bx - triangle_side), cy)
                end
                path:line_to(bx, nudge_bottom_y)
            else
                -- 裁剪位置在凸起下方（正常情况）
                path:line_to(ax, cy + r)
                path:bezier_curve(ax, cy + rh, ax + rh, cy, ax + r, cy)
                path:line_to(bx - r, cy)
                path:bezier_curve(bx - rh, cy, bx, cy + rh, bx, cy + r)
            end

            -- 右上角圆角
            path:line_to(bx, by - r)
            path:bezier_curve(bx, by - rh, bx - rh, by, bx - r, by)
        end

        return path
    end

    -- ============================================================
    -- 生成背景和前景路径
    -- ============================================================
    local bg_path = create_nudged_path(0, state.radius + self.border_size)
    local fg_path = create_nudged_path(self.border_size, state.radius, volume_y)

    -- ============================================================
    -- 绘制背景（灰色）
    -- 使用 iclip 裁剪出前景形状，让背景在前景形状之外显示
    -- ============================================================
    ass:new_event()
    ass:append('{\\rDefault\\an7\\blur0\\bord0\\1c&H' .. bg ..
        '\\iclip(' .. fg_path.scale .. ', ' .. fg_path.text .. ')}')
    ass:opacity(config.opacity.slider, visibility)
    ass:pos(0, 0)
    ass:draw_start()
    ass:append(bg_path.text)
    ass:draw_stop()

    -- ============================================================
    -- 绘制前景（高亮色）
    -- ============================================================
    ass:new_event()
    ass:append('{\\rDefault\\an7\\blur0\\bord0\\1c&H' .. fg .. '}')
    ass:opacity(config.opacity.slider_gauge, visibility)
    ass:pos(0, 0)
    ass:draw_start()
    ass:append(fg_path.text)
    ass:draw_stop()

    -- ============================================================
    -- 绘制音量数值
    -- 根据位置在前景或背景上显示不同颜色
    -- ============================================================
    local volume_string = tostring(round(state.volume * 10) / 10)
    local font_size = round(((width * 0.6) - (#volume_string * (width / 20))) * options.font_scale)

    -- 如果音量位置在数值显示区域上方，使用前景色（高亮）
    if volume_y < self.by - self.spacing then
        ass:txt(self.ax + (width / 2), self.by - self.spacing, 2, volume_string, {
            size = font_size,
            color = fgt,
            opacity = visibility,
            clip = '\\clip(' .. fg_path.scale .. ', ' .. fg_path.text .. ')',
        })
    end

    -- 如果音量位置在数值显示区域下方，使用背景色（阴影）
    if volume_y > self.by - self.spacing - font_size then
        ass:txt(self.ax + (width / 2), self.by - self.spacing, 2, volume_string, {
            size = font_size,
            color = bgt,
            opacity = visibility,
            clip = '\\iclip(' .. fg_path.scale .. ', ' .. fg_path.text .. ')',
        })
    end

    -- ============================================================
    -- 无音频轨道时的禁用条纹
    -- ============================================================
    if not state.has_audio then
        local fg_100_path = create_nudged_path(self.border_size, state.radius)

        local texture_opts = {
            size = 200,
            color = 'ffffff',
            opacity = visibility * 0.1,
            anchor_x = ax,
            clip = '\\clip(' .. fg_100_path.scale .. ',' .. fg_100_path.text .. ')',
        }

        ass:texture(ax, ay, bx, by, 'a', texture_opts)

        texture_opts.color = '000000'
        texture_opts.anchor_x = ax + texture_opts.size / 28
        ass:texture(ax, ay, bx, by, 'a', texture_opts)
    end

    return ass
end

-- ==============================================================================
-- 第二部分：Volume（音量容器）
-- 包含音量滑块和静音按钮
-- ==============================================================================

---@class Volume : Element
local Volume = class(Element)

-- ==============================================================================
-- 构造函数与初始化
-- ==============================================================================

function Volume:new() return Class.new(self) --[[@as Volume]] end

function Volume:init()
    -- 调用父类 Element 的初始化
    -- render_order = 7 表示渲染在控制栏上方
    Element.init(self, 'volume', {render_order = 7})

    self.size = 0       -- 音量控件宽度
    self.mute_ay = 0    -- 静音按钮的 Y 坐标

    -- 创建音量滑块子元素
    self.slider = VolumeSlider:new({
        anchor_id = 'volume',
        render_order = self.render_order
    })

    self:update_dimensions()
end

-- ==============================================================================
-- 销毁 (destroy)
-- ==============================================================================

function Volume:destroy()
    self.slider:destroy()
    Element.destroy(self)
end

-- ==============================================================================
-- 可见度计算 (get_visibility)
-- ==============================================================================

function Volume:get_visibility()
    -- 空闲或没有音频轨道时隐藏
    if not state.is_idle and not state.has_audio then
        return 0
    end

    -- 拖拽时强制显示
    if self.slider.pressed then
        return 1
    end

    -- 时间轴悬停时强制隐藏
    if Elements:maybe('timeline', 'get_is_hovered') then
        return -1
    end

    -- 否则使用父类的可见度计算
    return Element.get_visibility(self)
end

-- ==============================================================================
-- 尺寸更新 (update_dimensions)
-- ==============================================================================

function Volume:update_dimensions()
    -- 音量控件宽度
    self.size = round(options.volume_size * state.scale)

    -- 可用垂直空间（顶栏到底部）
    local min_y = Elements:v('top_bar', 'by') or Elements:v('window_border', 'size', 0)
    local max_y = Elements:v('controls', 'ay') or Elements:v('timeline', 'ay')
        or display.height - Elements:v('window_border', 'size', 0)

    local available_height = max_y - min_y
    local max_height = available_height * 0.8

    -- 滑块高度 = 宽度 × 8（不超过可用空间的 80%）
    local height = round(math.min(self.size * 8, max_height))

    -- 太小则不渲染
    self.enabled = height > self.size * 2

    -- 计算位置（左侧或右侧）
    local margin = (self.size / 2) + Elements:v('window_border', 'size', 0)
    self.ax = round(options.volume == 'left' and margin or display.width - margin - self.size)
    self.ay = min_y + round((available_height - height) / 2)
    self.bx = round(self.ax + self.size)
    self.by = round(self.ay + height)

    -- 静音按钮在底部
    self.mute_ay = self.by - self.size

    -- 更新滑块坐标（滑块在静音按钮上方）
    self.slider.enabled = self.enabled
    self.slider:set_coordinates(self.ax, self.ay, self.bx, self.mute_ay)
end

-- ==============================================================================
-- 事件回调
-- ==============================================================================

function Volume:on_display() self:update_dimensions() end
function Volume:on_prop_border() self:update_dimensions() end
function Volume:on_prop_title_bar() self:update_dimensions() end
function Volume:on_prop_volume_max() self:update_dimensions() end
function Volume:on_controls_reflow() self:update_dimensions() end
function Volume:on_options() self:update_dimensions() end

-- ==============================================================================
-- 渲染函数 (render)
-- 绘制静音按钮（滑块由子元素自行渲染）
-- ==============================================================================

function Volume:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then
        return
    end

    -- ============================================================
    -- 右键点击重置音量（取消静音，设为 100%）
    -- ============================================================
    cursor:zone('secondary_click', self, function()
        mp.set_property_native('mute', false)
        mp.set_property_native('volume', 100)
    end)

    -- ============================================================
    -- 静音按钮（点击切换静音）
    -- ============================================================
    local mute_rect = {
        ax = self.ax,
        ay = self.mute_ay,
        bx = self.bx,
        by = self.by
    }

    cursor:zone('primary_down', mute_rect, function()
        mp.commandv('cycle', 'mute')
    end)

    local ass = assdraw.ass_new()

    local width_half = (mute_rect.bx - mute_rect.ax) / 2
    local height_half = (mute_rect.by - mute_rect.ay) / 2
    local icon_size = math.min(width_half, height_half) * 1.5

    -- ============================================================
    -- 选择图标和偏移量
    -- ============================================================
    local icon_name, horizontal_shift = 'volume_up', 0

    if state.mute then
        -- 静音状态
        icon_name = 'volume_off'
    elseif state.volume <= 0 then
        -- 音量 0%（未静音）
        icon_name, horizontal_shift = 'volume_mute', height_half * 0.25
    elseif state.volume <= 60 then
        -- 低音量
        icon_name, horizontal_shift = 'volume_down', height_half * 0.125
    end

    -- ============================================================
    -- 绘制底层轮廓（阴影效果）
    -- ============================================================
    local underlay_opacity = {main = visibility * 0.3, border = visibility}
    ass:icon(mute_rect.ax + width_half, mute_rect.ay + height_half, icon_size, 'volume_up', {
        border = options.text_border * state.scale,
        opacity = underlay_opacity,
        align = 5,
    })

    -- ============================================================
    -- 绘制实际图标（在底层轮廓之上，略有偏移）
    -- ============================================================
    ass:icon(mute_rect.ax + width_half - horizontal_shift, mute_rect.ay + height_half, icon_size, icon_name, {
        opacity = visibility,
        align = 5,
    })

    return ass
end

return Volume