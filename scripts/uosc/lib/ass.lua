-- ==============================================================================
-- ass.lua — ASS 绘图扩展模块
-- ==============================================================================
-- 功能概述：
--   1. 为 assdraw.ass_new() 返回的对象添加一组便捷的 ASS 绘图方法
--   2. 支持绘制矩形、圆形、图标、文本、工具提示、时间戳、纹理、旋转动画、平滑曲线等
--   3. 统一处理透明度、颜色、边框、裁剪、圆角等 ASS 标签
--   4. 所有方法均直接扩展 assdraw 对象的元表，无需创建新对象
-- ==============================================================================
-- 设计特点：
--   - 所有方法都遵循 mpv 的 ASS 渲染规范
--   - 自动处理坐标缩放和文字测量
--   - 工具提示支持智能防溢出翻转
--   - 时间戳每个数字独立定位（用于等宽显示）
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- [[ ASSDRAW EXTENSIONS ]]

-- 获取 assdraw.ass_new() 返回对象的元表（用于扩展方法）
local ass_mt = getmetatable(assdraw.ass_new())

-- ==============================================================================
-- 1. 透明度辅助函数 (opacity)
-- 生成 ASS 透明度标签，支持主透明度、边框透明度、阴影透明度
-- ==============================================================================

-- Opacity.
---@param self table|nil 若为 nil，只返回标签字符串而不修改对象
---@param opacity number|{primary?: number; border?: number, shadow?: number, main?: number} 透明度值或表
---@param fraction? number 可选乘数，用于进一步调整透明度
---@return string|nil
function ass_mt.opacity(self, opacity, fraction)
    fraction = fraction ~= nil and fraction or 1

    -- 如果是数字，转为表 {main = opacity}
    opacity = type(opacity) == 'table' and opacity or {main = opacity}

    local text = ''

    -- 主透明度（\alpha）
    if opacity.main then
        text = text .. string.format('\\alpha&H%X&', opacity_to_alpha(opacity.main * fraction))
    end

    -- 主色透明度（\1a）
    if opacity.primary then
        text = text .. string.format('\\1a&H%X&', opacity_to_alpha(opacity.primary * fraction))
    end

    -- 边框透明度（\3a）
    if opacity.border then
        text = text .. string.format('\\3a&H%X&', opacity_to_alpha(opacity.border * fraction))
    end

    -- 阴影透明度（\4a）
    if opacity.shadow then
        text = text .. string.format('\\4a&H%X&', opacity_to_alpha(opacity.shadow * fraction))
    end

    if self == nil then
        -- 只返回标签字符串
        return text
    elseif text ~= '' then
        -- 追加到当前 ASS 文本
        self.text = self.text .. '{' .. text .. '}'
    end
end

-- ==============================================================================
-- 2. 图标绘制 (icon)
-- 使用 Material Icons 字体绘制图标
-- ==============================================================================

-- Icon.
---@param x number
---@param y number
---@param size number
---@param name string 图标名称（Material Icons 字符）
---@param opts? {color?: string; border?: number; border_color?: string; opacity?: number; clip?: string; align?: number}
function ass_mt:icon(x, y, size, name, opts)
    opts = opts or {}
    -- 设置字体为 Material Icons，禁用粗体
    opts.font, opts.size, opts.bold = 'MaterialIconsRound-Regular', size, false
    -- 调用 txt 方法绘制（默认居中对齐 5）
    self:txt(x, y, opts.align or 5, name, opts)
end

-- ==============================================================================
-- 3. 文本绘制 (txt)
-- 最基础的文本绘制方法，支持各种 ASS 标签
-- ==============================================================================

-- Text.
-- Named `txt` because `ass.text` is a value.
---@param x number
---@param y number
---@param align number ASS 对齐方式（1~9，类似小键盘）
---@param value string|number
---@param opts {size: number; font?: string; color?: string; bold?: boolean; italic?: boolean; border?: number; border_color?: string; shadow?: number; shadow_color?: string; rotate?: number; wrap?: number; opacity?: number|{primary?: number; border?: number, shadow?: number, main?: number}; clip?: string}
function ass_mt:txt(x, y, align, value, opts)
    local border_size = opts.border or 0
    local shadow_size = opts.shadow or 0

    -- 基础标签：位置、重置样式、对齐、模糊
    local tags = '\\pos(' .. x .. ',' .. y .. ')\\rDefault\\an' .. align .. '\\blur0'

    -- 字体
    tags = tags .. '\\fn' .. (opts.font or config.font)

    -- 字号
    tags = tags .. '\\fs' .. opts.size

    -- 粗体（如果 opts.bold 为 true，或者未指定且全局 font_bold 为 true）
    if opts.bold or (opts.bold == nil and options.font_bold) then
        tags = tags .. '\\b1'
    end

    -- 斜体
    if opts.italic then tags = tags .. '\\i1' end

    -- 旋转
    if opts.rotate then tags = tags .. '\\frz' .. opts.rotate end

    -- 换行模式
    if opts.wrap then tags = tags .. '\\q' .. opts.wrap end

    -- 边框厚度
    tags = tags .. '\\bord' .. border_size

    -- 阴影厚度
    tags = tags .. '\\shad' .. shadow_size

    -- 颜色
    tags = tags .. '\\1c&H' .. (opts.color or bgt)
    if border_size > 0 then
        tags = tags .. '\\3c&H' .. (opts.border_color or bg)
    end
    if shadow_size > 0 then
        tags = tags .. '\\4c&H' .. (opts.shadow_color or bg)
    end

    -- 透明度
    if opts.opacity then
        tags = tags .. self.opacity(nil, opts.opacity)
    end

    -- 裁剪
    if opts.clip then
        tags = tags .. opts.clip
    end

    -- 创建新事件并追加标签和文本
    self:new_event()
    self.text = self.text .. '{' .. tags .. '}' .. value
end

-- ==============================================================================
-- 4. 工具提示 (tooltip)
-- 智能工具提示，自动翻转方向防止超出屏幕
-- ==============================================================================

-- Tooltip.
---@param element Rect 参考矩形（如按钮或进度条区域）
---@param value string|number 提示文本
---@param opts? {size?: number; align?: number; offset?: number; bold?: boolean; italic?: boolean; width_overwrite?: number, margin?: number; responsive?: boolean; lines?: integer, timestamp?: boolean; invert_colors?: boolean}
function ass_mt:tooltip(element, value, opts)
    if value == '' then return end

    opts = opts or {}
    opts.size = opts.size or round(16 * state.scale)
    opts.border = options.text_border * state.scale
    opts.border_color = opts.invert_colors and fg or bg
    opts.margin = opts.margin or round(10 * state.scale)
    opts.lines = opts.lines or 1
    opts.color = opts.invert_colors and bg or fg

    local offset = opts.offset or 2
    local padding_y = round(opts.size / 6)
    local padding_x = round(opts.size / 3)

    -- 计算工具提示的宽高
    local width = (opts.width_overwrite or text_width(value, opts)) + padding_x * 2
    local height = opts.size * opts.lines + 2 * padding_y
    local width_half, height_half = width / 2, height / 2

    local margin = opts.margin + Elements:v('window_border', 'size', 0)
    local align = opts.align or 8  -- 默认 8（上方居中）

    local x, y = 0, 0 -- 工具提示的中心坐标

    -- ============================================================
    -- 智能翻转：当空间不足时，翻转对齐方向
    -- ============================================================
    if opts.responsive ~= false then
        if align == 8 then
            -- 上方空间不足 → 翻转到下方
            if element.ay - offset - height < margin then align = 2 end
        elseif align == 2 then
            -- 下方空间不足 → 翻转到上方
            if element.by + offset + height > display.height - margin then align = 8 end
        elseif align == 6 then
            -- 右侧空间不足 → 翻转到左侧
            if element.bx + offset + width > display.width - margin then align = 4 end
        elseif align == 4 then
            -- 左侧空间不足 → 翻转到右侧
            if element.ax - offset - width < margin then align = 6 end
        end
    end

    -- ============================================================
    -- 根据对齐方式计算中心坐标
    -- ============================================================
    if align == 8 or align == 2 then
        -- 上方/下方对齐：X 在元素水平范围内居中，Y 在元素上方/下方
        x = clamp(
            margin + width_half,
            element.ax + (element.bx - element.ax) / 2,
            display.width - margin - width_half
        )
        y = align == 8 and element.ay - offset - height_half or element.by + offset + height_half
    else
        -- 左侧/右侧对齐：X 在元素左侧/右侧，Y 在元素垂直范围内居中
        x = align == 6 and element.bx + offset + width_half or element.ax - offset - width_half
        y = clamp(
            margin + height_half,
            element.ay + (element.by - element.ay) / 2,
            display.height - margin - height_half
        )
    end

    -- ============================================================
    -- 绘制工具提示
    -- ============================================================
    local ax, ay, bx, by = round(x - width_half), round(y - height_half), round(x + width_half), round(y + height_half)

    -- 背景矩形
    self:rect(ax, ay, bx, by, {
        color = opts.invert_colors and fg or bg,
        opacity = config.opacity.tooltip,
        radius = state.radius,
    })

    -- 文本（如果是时间戳格式，使用 timestamp 方法）
    local func = opts.timestamp and self.timestamp or self.txt
    func(self, x, y, 5, tostring(value), opts)

    -- 返回锚点坐标（用于后续定位）
    return {ax = element.ax, ay = ay, bx = element.bx, by = by}
end

-- ==============================================================================
-- 5. 时间戳绘制 (timestamp)
-- 每个数字独立定位，所有数字占据相同宽度（类似等宽字体）
-- ==============================================================================

-- Timestamp with each digit positioned as if it was replaced with 0
---@param x number
---@param y number
---@param align number
---@param timestamp string
---@param opts {size: number; opacity?: number|{primary?: number; border?: number, shadow?: number, main?: number}}
function ass_mt:timestamp(x, y, align, timestamp, opts)
    -- 计算每个数字的宽度（基于 '0' 的宽度）
    local widths, width_total = {}, 0
    local zero_rep = timestamp_zero_rep(timestamp)  -- 将时间戳所有数字替换为 '0'
    for i = 1, #zero_rep do
        local width = text_width(zero_rep:sub(i, i), opts)
        widths[i] = width
        width_total = width_total + width
    end

    -- 根据对齐方式调整起始 X 和 Y
    local mod_align = align % 3
    if mod_align == 0 then
        x = x - width_total
    elseif mod_align == 2 then
        x = x - width_total / 2
    end
    if align < 4 then
        y = y - opts.size / 2
    elseif align > 6 then
        y = y + opts.size / 2
    end

    -- ============================================================
    -- 第一层：主文字（带主透明度）
    -- ============================================================
    local opacity = opts.opacity
    local primary_opacity
    if type(opacity) == 'table' then
        opts.opacity = {main = opacity.main, border = opacity.border, shadow = opacity.shadow, primary = 0}
        primary_opacity = opacity.primary or opacity.main
    else
        opts.opacity = {main = opacity, primary = 0}
        primary_opacity = opacity
    end

    for i, width in ipairs(widths) do
        self:txt(x + width / 2, y, 5, timestamp:sub(i, i), opts)
        x = x + width
    end

    -- ============================================================
    -- 第二层：高亮（每个数字独立高亮，透明度为 primary_opacity）
    -- 将主透明度设为 0，primary 透明度设为指定值
    -- ============================================================
    x = x - width_total  -- 重置 X
    opts.opacity = {main = 0, primary = primary_opacity or 1}

    for i, width in ipairs(widths) do
        self:txt(x + width / 2, y, 5, timestamp:sub(i, i), opts)
        x = x + width
    end

    -- 恢复 opacity
    opts.opacity = opacity
end

-- ==============================================================================
-- 6. 矩形绘制 (rect)
-- 支持圆角、边框、裁剪
-- ==============================================================================

-- Rectangle.
---@param ax number
---@param ay number
---@param bx number
---@param by number
---@param opts? {color?: string; border?: number; border_color?: string; opacity?: number|{primary?: number; border?: number, shadow?: number, main?: number}; clip?: string, radius?: number}
function ass_mt:rect(ax, ay, bx, by, opts)
    opts = opts or {}
    local border_size = opts.border or 0

    local tags = '\\pos(0,0)\\rDefault\\an7\\blur0'

    -- 边框
    tags = tags .. '\\bord' .. border_size

    -- 颜色
    tags = tags .. '\\1c&H' .. (opts.color or fg)
    if border_size > 0 then
        tags = tags .. '\\3c&H' .. (opts.border_color or bg)
    end

    -- 透明度
    if opts.opacity then
        tags = tags .. self.opacity(nil, opts.opacity)
    end

    -- 裁剪
    if opts.clip then
        tags = tags .. opts.clip
    end

    -- 创建新事件并绘制
    self:new_event()
    self.text = self.text .. '{' .. tags .. '}'
    self:draw_start()

    if opts.radius and opts.radius > 0 then
        -- 圆角矩形
        self:round_rect_cw(ax, ay, bx, by, opts.radius)
    else
        -- 普通矩形
        self:rect_cw(ax, ay, bx, by)
    end

    self:draw_stop()
end

-- ==============================================================================
-- 7. 圆形绘制 (circle)
-- 实际上是调用 rect 并设置半径
-- ==============================================================================

-- Circle.
---@param x number
---@param y number
---@param radius number
---@param opts? {color?: string; border?: number; border_color?: string; opacity?: number; clip?: string}
function ass_mt:circle(x, y, radius, opts)
    opts = opts or {}
    opts.radius = radius
    self:rect(x - radius, y - radius, x + radius, y + radius, opts)
end

-- ==============================================================================
-- 8. 纹理绘制 (texture)
-- 使用字体纹理平铺填充区域
-- ==============================================================================

-- Texture.
---@param ax number
---@param ay number
---@param bx number
---@param by number
---@param char string 纹理字体字符（'a' 或 'b'）
---@param opts {size?: number; color: string; opacity?: number; clip?: string; anchor_x?: number, anchor_y?: number}
function ass_mt:texture(ax, ay, bx, by, char, opts)
    opts = opts or {}
    local anchor_x, anchor_y = opts.anchor_x or ax, opts.anchor_y or ay
    local clip = opts.clip or ('\\clip(' .. ax .. ',' .. ay .. ',' .. bx .. ',' .. by .. ')')
    local tile_size, opacity = opts.size or 100, opts.opacity or 0.2

    -- 计算起始平铺偏移
    local x, y = ax - (ax - anchor_x) % tile_size, ay - (ay - anchor_y) % tile_size

    -- 计算需要平铺的行列数
    local width, height = bx - x, by - y
    local line = string.rep(char, math.ceil(width / tile_size))
    local lines = ''
    for i = 1, math.ceil(height / tile_size), 1 do
        lines = lines .. (lines == '' and '' or '\\N') .. line
    end

    -- 使用 txt 方法绘制所有纹理字符
    self:txt(
        x, y, 7, lines,
        {font = 'uosc_textures', size = tile_size, color = opts.color, bold = false, opacity = opacity, clip = clip}
    )
end

-- ==============================================================================
-- 9. 旋转加载动画 (spinner)
-- 绘制一个自动旋转的图标
-- ==============================================================================

-- Rotating spinner icon.
---@param x number
---@param y number
---@param size number
---@param opts? {color?: string; opacity?: number; clip?: string; border?: number; border_color?: string;}
function ass_mt:spinner(x, y, size, opts)
    opts = opts or {}
    -- 根据渲染时间计算旋转角度（每秒旋转 1.75 圈）
    opts.rotate = (state.render_last_time * 1.75 % 1) * -360
    opts.color = opts.color or fg
    self:icon(x, y, size, 'autorenew', opts)
    -- 请求继续渲染（以持续更新旋转角度）
    request_render()
end

-- ==============================================================================
-- 10. 平滑曲线绘制 (smooth_curve)
-- 从贝塞尔段绘制平滑曲线（用于热力图等）
-- ==============================================================================

-- Renders a smooth curve from Bezier segments.
---@param ax number
---@param ay number
---@param bx number
---@param by number
---@param points number[] 扁平点表（归一化 0~1）：起始点 + 贝塞尔控制点对 + 终点...
---@param opts? {color?: string; border?: number; border_color?: string; opacity?: number|{primary?: number; border?: number, shadow?: number, main?: number}; clip?: string}
function ass_mt:smooth_curve(ax, ay, bx, by, points, opts)
    if not points or #points < 8 then return end

    opts = opts or {}
    local border_size = opts.border or 0

    local tags = '\\pos(0,0)\\rDefault\\an7\\blur0'

    -- 边框
    tags = tags .. '\\bord' .. border_size

    -- 颜色
    tags = tags .. '\\1c&H' .. (opts.color or fg)
    if border_size > 0 then
        tags = tags .. '\\3c&H' .. (opts.border_color or bg)
    end

    -- 透明度
    if opts.opacity then
        tags = tags .. self.opacity(nil, opts.opacity)
    end

    -- 裁剪
    if opts.clip then
        tags = tags .. opts.clip
    end

    -- 创建新事件
    self:new_event()
    self.text = self.text .. '{' .. tags .. '}'
    self:draw_start()

    -- 缩放归一化坐标到目标矩形
    local width, height = bx - ax, by - ay
    local function scale(x, y)
        return ax + x * width, ay + y * height
    end

    -- 移动到起始点
    local x0, y0 = scale(points[1], points[2])
    self:move_to(x0, y0)

    -- 遍历所有贝塞尔段（每组 6 个值：cp1x, cp1y, cp2x, cp2y, px, py）
    local max = math.floor((#points - 2) / 6) * 6 + 2
    for i = 3, max, 6 do
        local x1, y1 = scale(points[i],   points[i+1])
        local x2, y2 = scale(points[i+2], points[i+3])
        local x3, y3 = scale(points[i+4], points[i+5])
        self:bezier_curve(x1, y1, x2, y2, x3, y3)
    end

    self:draw_stop()
end