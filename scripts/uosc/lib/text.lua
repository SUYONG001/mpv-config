-- ==============================================================================
-- text.lua — 文本测量与处理引擎
-- ==============================================================================
-- 功能概述：
--   1. 提供 UTF-8 字符迭代器（utf8_iter）和长度计算
--   2. 提供精确的文本宽度测量（基于 mpv OSD 渲染引擎的 compute_bounds）
--   3. 支持字符级宽度测量：区分零宽字符、等宽 CJK 字符、普通拉丁字符
--   4. 提供文本换行功能（wrap_text），按目标宽度自动折行
--   5. 提供搜索高亮功能（highlight_match），标记匹配字符的位置
--   6. 提供时间戳宽度计算（timestamp_width），用于等宽时间显示
--   7. 提供字符串段边界查找（find_string_segment_bound），用于按词/按段移动光标
--   8. 提供罗马化匹配位置获取（get_roman_match_positions），用于非拉丁文字的搜索高亮
-- ==============================================================================
-- 设计特点：
--   - 使用 mpv OSD 的 compute_bounds 进行精确测量
--   - 带三级缓存机制（字符级、文本级、时间戳级），避免重复测量
--   - 支持零宽字符检测（使用 Unicode 区块表）
--   - 支持 CJK 等宽字符统一处理（所有中文字符等宽）
--   - 支持罗马化匹配高亮（用于非拉丁文字的搜索）
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. Unicode 区块定义 (CodePointRange)
-- 用于判断字符的宽度属性
-- 参考：https://en.wikipedia.org/wiki/Unicode_block
-- ==============================================================================

---@alias CodePointRange {[1]: integer, [2]: integer}

-- 零宽字符区块：这些字符在渲染时宽度为 0
-- 包括控制字符（C0/C1）、零宽空格、方向标记、组合符号等
---@type CodePointRange[]
local zero_width_blocks = {
    {0x0000,  0x001F}, -- C0 控制字符
    {0x007F,  0x009F}, -- Delete + C1 控制字符
    {0x034F,  0x034F}, -- combining grapheme joiner（组合字素连接符）
    {0x061C,  0x061C}, -- Arabic Letter 强方向字符
    {0x200B,  0x200F}, -- {零宽空格, 零宽非连接符, 零宽连接符, 左→右标记, 右→左标记}
    {0x2028,  0x202E}, -- {行分隔符, 段落分隔符, 嵌入标记, 覆盖标记, 弹出格式化, 覆盖}
    {0x2060,  0x2060}, -- word joiner（词连接符）
    {0x2066,  0x2069}, -- {左→右隔离, 右→左隔离, 首强隔离, 弹出隔离}
    {0xFEFF,  0xFEFF}, -- zero-width non-breaking space（零宽不换行空格）
    -- 组合符号（附加到其他字符上方/下方的修饰符号）
    -- 参考：https://en.wikipedia.org/wiki/Combining_character
    {0x0300,  0x036F}, -- Combining Diacritical Marks
    {0x1AB0,  0x1AFF}, -- Combining Diacritical Marks Extended
    {0x1DC0,  0x1DFF}, -- Combining Diacritical Marks Supplement
    {0x20D0,  0x20FF}, -- Combining Diacritical Marks for Symbols
    {0xFE20,  0xFE2F}, -- Combining Half Marks
    -- 埃及象形文字格式控制和速记格式控制
    {0x13430, 0x1345F}, -- Egyptian Hieroglyph Format Controls
    {0x1BCA0, 0x1BCAF}, -- Shorthand Format Controls
    -- 间距修饰字母（不确定如何处理，保留此区块）
    -- 参考：https://en.wikipedia.org/wiki/Spacing_Modifier_Letters
    {0x02B0,  0x02FF}, -- Spacing Modifier Letters
}

-- 等宽字符区块：这些字符的宽度与第一个字符相同
-- 主要包括 CJK 统一表意文字（中文、日文、韩文）
---@type CodePointRange[]
local same_width_blocks = {
    {0x3400,  0x4DBF}, -- CJK Unified Ideographs Extension A
    {0x4E00,  0x9FFF}, -- CJK Unified Ideographs（最常用的中文/日文/韩文字符）
    {0x20000, 0x2A6DF}, -- CJK Unified Ideographs Extension B
    {0x2A700, 0x2B73F}, -- CJK Unified Ideographs Extension C
    {0x2B740, 0x2B81F}, -- CJK Unified Ideographs Extension D
    {0x2B820, 0x2CEAF}, -- CJK Unified Ideographs Extension E
    {0x2CEB0, 0x2EBEF}, -- CJK Unified Ideographs Extension F
    {0x2F800, 0x2FA1F}, -- CJK Compatibility Ideographs Supplement
    {0x30000, 0x3134F}, -- CJK Unified Ideographs Extension G
    {0x31350, 0x323AF}, -- CJK Unified Ideographs Extension H
}

-- 拉丁字符宽度与高度的比例（用于估算文本宽度）
-- 当 OSD 测量不可用时作为回退值
local width_length_ratio = 0.5

-- ==============================================================================
-- 2. OSD 尺寸缓存
-- ==============================================================================

---@type integer, integer
local osd_width, osd_height = 100, 100

-- ==============================================================================
-- 3. UTF-8 字符处理函数
-- ==============================================================================

-- 获取 UTF-8 字符的字节数（从第 i 个字节开始）
-- 根据首字节的高位判断：
--   0xxx → 1 字节，110x → 2 字节，1110 → 3 字节，1111 → 4 字节
---@param str string
---@param i integer?
---@return integer
local function utf8_char_bytes(str, i)
    local char_byte = str:byte(i)
    local max_bytes = #str - i + 1
    if char_byte < 0xC0 then
        return math.min(max_bytes, 1)
    elseif char_byte < 0xE0 then
        return math.min(max_bytes, 2)
    elseif char_byte < 0xF0 then
        return math.min(max_bytes, 3)
    elseif char_byte < 0xF8 then
        return math.min(max_bytes, 4)
    else
        return math.min(max_bytes, 1)
    end
end

-- UTF-8 字符迭代器
-- 遍历字符串中的每个 Unicode 字符（而非字节）
-- 用法：for pos, char in utf8_iter(str) do ... end
---@param str string
---@return fun(): integer?, string?
function utf8_iter(str)
    local byte_start = 1
    return function()
        local start = byte_start
        if #str < start then return nil end
        local byte_count = utf8_char_bytes(str, start)
        byte_start = start + byte_count
        return start, str:sub(start, start + byte_count - 1)
    end
end

-- 计算 UTF-8 字符串的字符数（而非字节数）
---@param str string
---@return number
function utf8_length(str)
    local str_length = 0
    for _, _ in utf8_iter(str) do
        str_length = str_length + 1
    end
    return str_length
end

-- 获取当前字符之后的下一个字符的起始字节位置
-- 若已到达末尾，返回 #str
---@param str string
---@param i integer 当前字符的起始字节位置
---@return integer
function utf8_next(str, i)
    if i >= #str then return #str end
    local len = utf8_char_bytes(str, i + 1)
    return math.min(i + len, #str)
end

-- 获取当前字符之前的上一个字符的起始字节位置
-- 若已在开头，返回 0
---@param str string
---@param i integer 当前字符的起始字节位置
---@return integer
function utf8_prev(str, i)
    if i <= 0 then return 0 end
    local pos = 1
    local last_valid = 0
    while pos <= #str do
        local len = utf8_char_bytes(str, pos)
        if pos > i then break end
        last_valid = pos - 1
        pos = pos + len
    end
    return last_valid
end

-- 将字符位置（第几个字符）转换为字节位置（第几个字节）
-- 用于在需要字节索引的场景中定位
---@param str string
---@param char_pos integer
---@return integer
function utf8_charpos_to_bytepos(str, char_pos)
    local byte_pos = 1
    local current_char = 1
    local str_len = #str
    while byte_pos <= str_len and current_char < char_pos do
        local char_len = utf8_char_bytes(str, byte_pos)
        byte_pos = byte_pos + char_len
        current_char = current_char + 1
    end
    return byte_pos
end

-- 从 UTF-8 字符中提取 Unicode 码点（code point）
---@param str string
---@param i integer 字符起始字节位置
---@return integer
local function utf8_to_unicode(str, i)
    local byte_count = utf8_char_bytes(str, i)
    local char_byte = str:byte(i)
    local unicode = char_byte

    if byte_count ~= 1 then
        -- 移除首字节中的标志位（1110xxx → 保留后 4 位）
        local shift = 2 ^ (8 - byte_count)
        char_byte = char_byte - math.floor(0xFF / shift) * shift
        unicode = char_byte * (2 ^ 6) ^ (byte_count - 1)
    end

    -- 处理后续字节（每个字节取低 6 位）
    for j = 2, byte_count do
        char_byte = str:byte(i + j - 1) - 0x80
        unicode = unicode + char_byte * (2 ^ 6) ^ (byte_count - j)
    end

    return round(unicode)
end

-- 将 Unicode 码点转换为 UTF-8 字符串
---@param unicode integer
---@return string?
local function unicode_to_utf8(unicode)
    if unicode < 0x80 then
        return string.char(unicode)
    else
        local byte_count
        if unicode < 0x800 then
            byte_count = 2
        elseif unicode < 0x10000 then
            byte_count = 3
        elseif unicode < 0x110000 then
            byte_count = 4
        else
            return nil  -- 码点超出 Unicode 范围
        end

        local res = {}
        local shift = 2 ^ 6
        local after_shift = unicode

        -- 从最低位开始提取 6 位一组
        for _ = byte_count, 2, -1 do
            local before_shift = after_shift
            after_shift = math.floor(before_shift / shift)
            table.insert(res, 1, before_shift - after_shift * shift + 0x80)
        end

        -- 首字节：添加标志位
        shift = 2 ^ (8 - byte_count)
        table.insert(res, 1, after_shift + math.floor(0xFF / shift) * shift)

        ---@diagnostic disable-next-line: deprecated
        return string.char(unpack(res))
    end
end

-- ==============================================================================
-- 4. OSD 测量引擎
-- 使用 mpv 的 OSD 渲染器精确测量文本尺寸
-- ==============================================================================

-- 更新 OSD 分辨率缓存
-- 只有当传入有效的宽高时才更新
---@param width integer
---@param height integer
local function update_osd_resolution(width, height)
    if width > 0 and height > 0 then
        osd_width, osd_height = width, height
    end
end

-- 监听 OSD 尺寸变化
mp.observe_property('osd-dimensions', 'native', function(_, dim)
    if dim then update_osd_resolution(dim.w, dim.h) end
end)

-- 测量 ASS 文本的边界框
-- 使用隐藏的 OSD 图层进行测量，不影响实际显示
local measure_bounds
do
    local text_osd = mp.create_osd_overlay('ass-events')
    text_osd.compute_bounds, text_osd.hidden = true, true

    ---@param ass_text string
    ---@return integer, integer, integer, integer 边界框：x0, y0, x1, y1
    measure_bounds = function(ass_text)
        update_osd_resolution(mp.get_osd_size())
        text_osd.res_x, text_osd.res_y = osd_width, osd_height
        text_osd.data = ass_text
        local res = text_osd:update()
        return res.x0, res.y0, res.x1, res.y1
    end
end

-- ==============================================================================
-- 5. 规范化文本宽度测量
-- 将文本宽度归一化到字号为 1 时的宽度
-- ==============================================================================

local normalized_text_width
do
    ---@type {wrap: integer; bold: boolean; italic: boolean, rotate: number; size: number}
    local bounds_opts = {wrap = 2, bold = false, italic = false, rotate = 0, size = 0}

    -- 测量文本宽度，并归一化到字号 1
    -- text 必须是 ASS 安全的（已转义）
    -- horizontal = true 表示水平测量，false 表示垂直测量（旋转 90°）
    ---@param text string
    ---@param size number 字号
    ---@param bold boolean
    ---@param italic boolean
    ---@param horizontal boolean
    ---@return number, integer 归一化宽度，测量时使用的屏幕尺寸
    normalized_text_width = function(text, size, bold, italic, horizontal)
        bounds_opts.bold, bounds_opts.italic, bounds_opts.rotate = bold, italic, horizontal and 0 or -90
        local x1, y1 = nil, nil

        -- 从较大的字号开始，逐步缩小直到文本能完整显示在 OSD 内
        -- 防止文本被裁剪导致测量不准确
        size = size / 0.8
        local repetitions_left = 5
        repeat
            size = size * 0.8
            bounds_opts.size = size
            local ass = assdraw.ass_new()
            ass:txt(0, 0, horizontal and 7 or 1, text, bounds_opts)
            _, _, x1, y1 = measure_bounds(ass.text)
            repetitions_left = repetitions_left - 1
        until (x1 and x1 < osd_width and y1 < osd_height) or repetitions_left == 0

        -- 如果最终仍被裁剪，宽度记为 0
        local width = (repetitions_left == 0 and not x1) and 0 or (horizontal and x1 or y1)
        return width / size, horizontal and osd_width or osd_height
    end
end

-- ==============================================================================
-- 6. 字符长度估算（回退方案）
-- 当 OSD 测量不可用时，基于字节数估算字符宽度
-- 2 字节以上字符（中文等）算 2 单位长度，拉丁字符算 1 单位
-- ==============================================================================

---@param char string
---@return number
local function char_length(char)
    return #char > 2 and 2 or 1
end

-- 基于字符长度估算字符串长度
---@param text string
---@return number
local function text_length(text)
    if not text or text == '' then return 0 end
    local text_length = 0
    for _, char in utf8_iter(tostring(text)) do
        text_length = text_length + char_length(char)
    end
    return text_length
end

-- ==============================================================================
-- 7. 屏幕适配：计算最佳字号和方向
-- 使文本尽可能填满屏幕，以获得最精确的测量结果
-- ==============================================================================

---@param text string
---@return number, boolean 最佳字号，是否水平显示
local function fit_on_screen(text)
    local estimated_width = text_length(text) * width_length_ratio
    if osd_width >= osd_height then
        return math.min(osd_width / estimated_width, osd_height), true
    else
        return math.min(osd_height / estimated_width, osd_width), false
    end
end

-- ==============================================================================
-- 8. 缓存辅助函数
-- ==============================================================================

-- 获取缓存的下一级阶段
---@param cache {[any]: table}
---@param value any
local function get_cache_stage(cache, value)
    local stage = cache[value]
    if not stage then
        stage = {}
        cache[value] = stage
    end
    return stage
end

-- 判断是否需要重新测量
-- 如果之前测量的屏幕尺寸与当前足够接近（误差 < 10%），则复用缓存
---@param px integer
---@return boolean
local function no_remeasure_required(px)
    return px >= 800 or (px * 1.1 >= osd_width and px * 1.1 >= osd_height)
end

-- ==============================================================================
-- 9. 字符宽度测量 (character_width)
-- 核心函数：测量单个字符的宽度（归一化到字号 1）
-- 支持缓存、零宽字符检测、等宽 CJK 字符统一处理
-- ==============================================================================

local character_width
do
    ---@type {[boolean]: {[string]: {[1]: number, [2]: integer}}}
    local char_width_cache = {}

    ---@param char string
    ---@param bold boolean
    ---@return number, integer 归一化宽度，测量时使用的屏幕尺寸
    character_width = function(char, bold)
        ---@type {[string]: {[1]: number, [2]: integer}}
        local char_widths = get_cache_stage(char_width_cache, bold)
        local width_px = char_widths[char]

        -- 缓存命中且分辨率足够 → 直接返回
        if width_px and no_remeasure_required(width_px[2]) then
            return width_px[1], width_px[2]
        end

        -- 检测零宽字符
        local unicode = utf8_to_unicode(char, 1)
        for _, block in ipairs(zero_width_blocks) do
            if unicode >= block[1] and unicode <= block[2] then
                char_widths[char] = {0, math.huge}
                return 0, math.huge
            end
        end

        -- 检测等宽字符（CJK）：用区块的第一个字符代替测量
        local measured_char = nil
        for _, block in ipairs(same_width_blocks) do
            if unicode >= block[1] and unicode <= block[2] then
                measured_char = unicode_to_utf8(block[1])
                width_px = char_widths[measured_char]
                if width_px and no_remeasure_required(width_px[2]) then
                    char_widths[char] = width_px
                    return width_px[1], width_px[2]
                end
                break
            end
        end

        if not measured_char then measured_char = char end

        -- 实际测量
        -- 宽字符（中文等）重复次数减半
        local char_count = 10 / char_length(char)
        local max_size, horizontal = fit_on_screen(measured_char:rep(char_count))
        local size = math.min(max_size * 0.9, 50)
        char_count = math.min(math.floor(char_count * max_size / size * 0.8), 100)

        -- 添加包围字符防止 OSD 裁剪边缘
        local enclosing_char, enclosing_width, next_char_count = '|', 0, char_count
        if measured_char == enclosing_char then
            enclosing_char = ''
        else
            enclosing_width = 2 * character_width(enclosing_char, bold)
        end

        local width_ratio, width, px = nil, nil, nil
        repeat
            char_count = next_char_count
            local str = enclosing_char .. measured_char:rep(char_count) .. enclosing_char
            width, px = normalized_text_width(str, size, bold, false, horizontal)
            width = width - enclosing_width
            width_ratio = width * size / (horizontal and osd_width or osd_height)
            -- 迭代调整字符数量直到比例合理
            next_char_count = math.min(math.floor(char_count / width_ratio * 0.9), 100)
        until width_ratio < 0.05 or width_ratio > 0.5 or char_count == next_char_count

        width = width / char_count

        -- 存入缓存
        width_px = {width, px}
        if char ~= measured_char then
            char_widths[measured_char] = width_px
        end
        char_widths[char] = width_px
        return width, px
    end
end

-- ==============================================================================
-- 10. 基于字符的文本宽度计算 (character_based_width)
-- 逐字符累加宽度，用于非精确测量场景
-- ==============================================================================

---@param text string|number
---@param bold boolean
---@return number, integer 总宽度，最小屏幕尺寸
local function character_based_width(text, bold)
    local max_width = 0
    local min_px = math.huge

    for line in tostring(text):gmatch('([^\n]*)\n?') do
        local total_width = 0
        for _, char in utf8_iter(line) do
            local width, px = character_width(char, bold)
            total_width = total_width + width
            if px < min_px then min_px = px end
        end
        if total_width > max_width then max_width = total_width end
    end

    return max_width, min_px
end

-- ==============================================================================
-- 11. 整段文本宽度测量 (whole_text_width)
-- 将整个文本作为整体测量，更精确但更耗时
-- ==============================================================================

---@param text string|number
---@param bold boolean
---@param italic boolean
---@return number, integer
local function whole_text_width(text, bold, italic)
    text = tostring(text)
    local size, horizontal = fit_on_screen(text)
    return normalized_text_width(ass_escape(text), size * 0.9, bold, italic, horizontal)
end

-- ==============================================================================
-- 12. 字号与斜体偏移辅助
-- ==============================================================================

---@param opts {size: number; italic?: boolean}
---@return number, number 字号缩放因子，斜体偏移量
local function opts_factor_offset(opts)
    return opts.size, opts.italic and opts.size * 0.2 or 0
end

---@param width number 归一化宽度
---@param opts {size: number; italic?: boolean}
---@return number 实际宽度
local function normalized_to_real(width, opts)
    local factor, offset = opts_factor_offset(opts)
    return factor * width + offset
end

-- ==============================================================================
-- 13. 主入口：text_width
-- 对外暴露的文本宽度测量函数
-- ==============================================================================

do
    ---@type {[boolean]: {[boolean]: {[string|number]: {[1]: number, [2]: integer}}}} | {[boolean]: {[string|number]: {[1]: number, [2]: integer}}}
    local width_cache = {}

    -- 测量文本宽度
    -- 如果 config.refine.text_width 为 true，使用整体测量（更精确）
    -- 否则使用逐字符测量（更快）
    ---@param text string|number
    ---@param opts {size: number; bold?: boolean; italic?: boolean}
    ---@return number
    function text_width(text, opts)
        if not text or text == '' then return 0 end

        ---@type boolean, boolean
        local bold, italic = opts.bold or options.font_bold, opts.italic or false

        if not config.refine.text_width then
            -- 快速模式：逐字符测量
            ---@type {[string|number]: {[1]: number, [2]: integer}}
            local text_width = get_cache_stage(width_cache, bold)
            local width_px = text_width[text]
            if width_px and no_remeasure_required(width_px[2]) then
                return normalized_to_real(width_px[1], opts)
            end

            local width, px = character_based_width(text, bold)
            width_cache[bold][text] = {width, px}
            return normalized_to_real(width, opts)
        else
            -- 精确模式：整体测量
            ---@type {[string|number]: {[1]: number, [2]: integer}}
            local text_width = get_cache_stage(get_cache_stage(width_cache, bold), italic)
            local width_px = text_width[text]
            if width_px and no_remeasure_required(width_px[2]) then
                return width_px[1] * opts.size
            end

            local width, px = whole_text_width(text, bold, italic)
            width_cache[bold][italic][text] = {width, px}
            return width * opts.size
        end
    end
end

-- ==============================================================================
-- 14. 时间戳宽度计算
-- 将时间戳中的数字替换为 '0' 后测量宽度
-- 实现等宽显示：每个数字占据相同的宽度
-- ==============================================================================

do
    ---@type {[string]: string}
    local cache = {}

    -- 清空时间戳缓存（在 time_precision 变化时调用）
    function timestamp_zero_rep_clear_cache()
        cache = {}
    end

    -- 将时间戳中的所有数字替换为 '0'
    ---@param timestamp string
    ---@return string
    function timestamp_zero_rep(timestamp)
        local substitute = cache[#timestamp]
        if not substitute then
            substitute = timestamp:gsub('%d', '0')
            cache[#timestamp] = substitute
        end
        return substitute
    end

    -- 获取时间戳的等宽宽度
    ---@param timestamp string
    ---@param opts {size: number; bold?: boolean; italic?: boolean}
    ---@return number
    function timestamp_width(timestamp, opts)
        return text_width(timestamp_zero_rep(timestamp), opts)
    end
end

-- ==============================================================================
-- 15. 文本换行 (wrap_text)
-- 在目标宽度内自动换行，优先在空格/标点处断开
-- ==============================================================================

do
    local wrap_at_chars = {' ', '　', '-', '–'}      -- 可换行字符
    local remove_when_wrap = {' ', '　'}             -- 换行时移除的字符

    -- 在目标行长度处换行
    -- target_line_length 以"字符数"为单位（非像素）
    ---@param text string
    ---@param opts {size: number; bold?: boolean; italic?: boolean}
    ---@param target_line_length number 目标行长度（字符数）
    ---@return string, integer 换行后的文本，行数
    function wrap_text(text, opts, target_line_length)
        local target_line_width = target_line_length * width_length_ratio * opts.size
        local bold, scale_factor, scale_offset = opts.bold or false, opts_factor_offset(opts)
        local wrap_at_chars, remove_when_wrap = wrap_at_chars, remove_when_wrap

        local lines = {}

        for _, text_line in ipairs(split(text, '\n')) do
            local line_width = scale_offset
            local line_start = 1
            local before_end = nil
            local before_width = scale_offset
            local before_line_start = 0
            local before_removed_width = 0

            for char_start, char in utf8_iter(text_line) do
                local char_end = char_start + #char - 1
                local char_width = character_width(char, bold) * scale_factor
                line_width = line_width + char_width

                -- 遇到可换行字符或行尾
                if (char_end == #text_line) or itable_has(wrap_at_chars, char) then
                    local remove = itable_has(remove_when_wrap, char)
                    local line_width_after_remove = line_width - (remove and char_width or 0)

                    if line_width_after_remove < target_line_width then
                        -- 未超过目标宽度：继续扩展
                        before_end = remove and char_start - 1 or char_end
                        before_width = line_width_after_remove
                        before_line_start = char_end + 1
                        before_removed_width = remove and char_width or 0
                    else
                        -- 超过目标宽度：在之前的最佳位置断开
                        -- 比较在当前字符处断开与在之前最佳位置断开哪个更接近目标
                        if (target_line_width - before_width) <
                            (line_width_after_remove - target_line_width) then
                            -- 之前位置更接近 → 在之前位置断开
                            lines[#lines + 1] = text_line:sub(line_start, before_end)
                            line_start = before_line_start
                            line_width = line_width - before_width - before_removed_width + scale_offset
                        else
                            -- 当前位置更接近 → 在当前位置断开
                            lines[#lines + 1] = text_line:sub(line_start, remove and char_start - 1 or char_end)
                            line_start = char_end + 1
                            line_width = scale_offset
                        end
                        before_end = line_start
                        before_width = scale_offset
                    end
                end
            end

            -- 处理剩余部分
            if #text_line >= line_start then
                lines[#lines + 1] = text_line:sub(line_start)
            elseif text_line == '' then
                lines[#lines + 1] = ''
            end
        end

        return table.concat(lines, '\n'), #lines
    end
end

-- ==============================================================================
-- 16. 首字母提取 (initials)
-- 提取每个单词的首字符，用于缩写匹配
-- ==============================================================================

do
    local word_separators = create_set({
        ' ', '　', '\t', '-', '–', '_', ',', '.', '+', '&', '(', ')', '[', ']',
        '{', '}', '<', '>', '/', '\\', '（', '）', '【', '】', '；', '：',
        '《', '》', '“', '”', '‘', '’', '？', '！',
    })

    ---@param str string
    ---@return string[]
    function initials(str)
        local initials, is_word_start, word_separators = {}, true, word_separators
        for _, char in utf8_iter(str) do
            if word_separators[char] then
                is_word_start = true
            elseif is_word_start then
                initials[#initials + 1] = char
                is_word_start = false
            end
        end
        return initials
    end
end

-- ==============================================================================
-- 17. 字符串段边界查找 (find_string_segment_bound)
-- 按词/按段移动光标时使用
-- 返回当前词/段的起始或结束位置
-- direction: 1=向前（查找段尾），-1=向后（查找段首）
-- ==============================================================================

---@param str string 要搜索的字符串
---@param cursor number 当前光标位置（字节索引）
---@param direction number `1` 向前搜索，`-1` 向后搜索
---@return integer
function find_string_segment_bound(str, cursor, direction)
    if #str < 2 then return #str end
    cursor = math.max(1, math.min(cursor, #str))
    local head, tail = string.sub(str, 1, cursor), string.sub(str, cursor + 1)

    if direction < 0 then
        -- 向后查找段首：匹配连续同类字符
        local word_pat, other_pat = '[^%c%s%p]+$', '[%c%s%p]+$'
        local pat = head:sub(#head):match(word_pat) and word_pat or other_pat
        local segment = head:match(pat) or ''

        -- 如果只有一个字符，扩展到前面的异类字符
        if segment and #segment == 1 then
            local match = head:sub(1, #head - #segment):match(pat == word_pat and other_pat or word_pat)
            segment = (match or '') .. segment
        end
        return cursor - #segment + 1
    else
        -- 向前查找段尾
        local word_pat, other_pat = '^[^%c%s%p]+', '^[%c%s%p]+'
        local pat = tail:sub(1, 1):match(word_pat) and word_pat or other_pat
        local segment = tail:match(pat) or ''

        if segment and #segment == 1 then
            local match = tail:sub(#segment):match(pat == word_pat and other_pat or word_pat)
            segment = segment .. (match or '')
        end
        return cursor + #segment
    end
end

-- ==============================================================================
-- 18. 搜索高亮 (highlight_match)
-- 在文本中高亮匹配的字符位置
-- ==============================================================================

-- 在文本中高亮匹配的字符
-- 返回 ASS 安全的字符串，匹配部分用高亮颜色包围
---@param text string
---@param byte_positions number[] 匹配字符的字节位置列表
---@param font_color string 普通文字颜色（BGR HEX）
---@param bold boolean 是否使用粗体
---@return string
function highlight_match(text, byte_positions, font_color, bold)
    if not byte_positions or #byte_positions == 0 then
        return ass_escape(text)
    end

    table.sort(byte_positions)
    local start_tag = '{\\c&H' .. config.color.match .. '&\\b' .. (bold and '1' or '0') .. '}'
    local end_tag   = '{\\c&H' .. font_color .. '&}'

    local result = {}
    local pos_set = {}
    for _, p in ipairs(byte_positions) do
        pos_set[p] = true
    end

    local i = 1
    local len = #text
    while i <= len do
        if pos_set[i] then
            table.insert(result, start_tag)
            local char_len = utf8_char_bytes(text, i)
            table.insert(result, ass_escape(text:sub(i, i + char_len - 1)))
            table.insert(result, end_tag)
            i = i + char_len
        else
            local char_len = utf8_char_bytes(text, i)
            table.insert(result, ass_escape(text:sub(i, i + char_len - 1)))
            i = i + char_len
        end
    end

    return table.concat(result)
end

-- ==============================================================================
-- 19. 罗马化匹配位置获取 (get_roman_match_positions)
-- 用于非拉丁文字（中文、日文、韩文）的搜索高亮
-- 根据罗马化后的匹配位置，反推原始文本中的字符位置
-- ==============================================================================

-- mode: "initial"（首字母匹配）或 "ligature"（连字匹配）
---@param title string 原始标题
---@param query string 搜索词（已罗马化）
---@param mode string 匹配模式：'initial' 或 'ligature'
---@param roman string[] 罗马化后的字符列表
---@return number[]|nil 匹配字符的字节位置列表
function get_roman_match_positions(title, query, mode, roman)
    local romans = {}
    local char_ranges = {}
    local total_len = 0

    -- 构建罗马化字符串和字符范围映射
    for _, char in ipairs(roman) do
        local part = (mode == "initial") and char:sub(1, 1) or char
        part = part:lower()
        romans[#romans + 1] = part
        char_ranges[#char_ranges + 1] = {total_len + 1, total_len + #part}
        total_len = total_len + #part
    end

    local full_roman = table.concat(romans)
    local s, e = full_roman:find(query, 1, true)
    if not s then return nil end

    -- 将罗马化匹配位置映射回原始字符位置
    local byte_positions = {}
    for i, range in ipairs(char_ranges) do
        local rs, re = range[1], range[2]
        if not (re < s or rs > e) then
            byte_positions[#byte_positions + 1] = utf8_charpos_to_bytepos(title, i)
        end
    end

    return byte_positions
end

-- ==============================================================================
-- 导出：所有函数均为全局函数，在 Lua 环境中直接可用
-- 本文件不返回任何值，所有函数均通过全局作用域暴露
-- ==============================================================================