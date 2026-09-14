-- ==============================================================================
-- utils.lua — 通用工具函数集（依赖 UI 状态）
-- ==============================================================================
-- 功能概述：
--   1. 字符串排序：Windows 自然排序（StrCmpLogicalW），其他平台使用 Lua 字母数字排序
--   2. 补间动画：tween() 实现属性平滑过渡
--   3. 几何计算：点到矩形距离、射线到矩形距离、Catmull-Rom → Bezier 转换
--   4. 模板展开：提取 mpv 属性模板中的属性名
--   5. ASS 文本转义：ass_escape() 防止文本被解析为 ASS 标签
--   6. 时间格式化：format_time() 支持精度控制
--   7. 透明度转换：opacity_to_alpha() 将 0~1 透明度转为 ASS Alpha 值
--   8. 路径操作：join_path、is_absolute、normalize_path、is_protocol 等
--   9. 文件系统：read_directory、get_adjacent_files、delete_file
--  10. 导航逻辑：navigate_directory、navigate_playlist、navigate_item
--  11. 章节处理：normalize_chapters、serialize_chapters、serialize_chapter_ranges
--  12. 键盘绑定查询：find_active_keybindings、keybind_to_human
--  13. 轨道加载：load_track
--  14. ziggy 调用：call_ziggy、call_ziggy_async（剪贴板操作等）
--  15. 剪贴板操作：get_clipboard、set_clipboard
--  16. YouTube 热力图加载：load_youtube_heatmap
--  17. 渲染调度：render()、request_render()
-- ==============================================================================
-- 设计特点：
--   - 路径操作支持 Windows/Linux/macOS 三平台
--   - 自然排序在 Windows 上使用 WinAPI（StrCmpLogicalW），其他平台使用 Lua 实现
--   - 随机播放（shuffle）使用历史记录防重复，保证 80% 内容不重复
--   - 章节范围支持 SponsorBlock 格式识别（segment start/end）
--   - 补间动画使用指数衰减算法，自动适配渲染帧率
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 类型定义 (Type Aliases)
-- ==============================================================================

---@alias Point {x: number; y: number}
---@alias Rect {ax: number, ay: number, bx: number, by: number, window_drag?: boolean}
---@alias Circle {point: Point, r: number, window_drag?: boolean}
---@alias Hitbox Rect|Circle
---@alias ComplexBindingInfo {event: 'down' | 'repeat' | 'up' | 'press'; is_mouse: boolean; canceled: boolean; key_name?: string; key_text?: string;}

-- ==============================================================================
-- 2. 字符串排序 (String Sorting)
-- 支持 Windows 自然排序（StrCmpLogicalW），其他平台使用 Lua 字母数字排序
-- ==============================================================================

do
    -- ================================================================
    -- Windows 平台：使用 WinAPI 的 StrCmpLogicalW 实现自然排序
    -- 参考：https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-strcmplogicalw
    -- 代码来源：https://github.com/mpvnet-player/mpv.net/issues/575#issuecomment-1817413401
    -- ================================================================
    local winapi = nil

    -- 仅在 Windows 平台且启用了 refine.sorting 时加载 WinAPI
    if state.platform == 'windows' and config.refine.sorting then
        -- is_ffi_loaded 为 false 通常表示 mpv 构建时未包含 LuaJIT
        local is_ffi_loaded, ffi = pcall(require, 'ffi')

        if is_ffi_loaded then
            winapi = {
                ffi = ffi,
                C = ffi.C,
                CP_UTF8 = 65001,
                shlwapi = ffi.load('shlwapi'),
            }

            -- FFI 声明（来自 thumbfast，Mozilla Public License 2.0）
            ffi.cdef [[
                int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr,
                int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
                int __stdcall StrCmpLogicalW(wchar_t *psz1, wchar_t *psz2);
            ]]

            -- UTF-8 → UTF-16 转换函数
            winapi.utf8_to_wide = function(utf8_str)
                if utf8_str then
                    local utf16_len = winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, utf8_str, -1, nil, 0)
                    if utf16_len > 0 then
                        local utf16_str = winapi.ffi.new('wchar_t[?]', utf16_len)
                        if winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, utf8_str, -1, utf16_str, utf16_len) > 0 then
                            return utf16_str
                        end
                    end
                end
                return ''
            end
        end
    end

    -- ================================================================
    -- Lua 实现的字母数字自然排序（跨平台回退方案）
    -- 算法来源：http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua
    -- ================================================================
    -- 辅助函数：将数字部分填充零以保持对齐
    local function padnum(n, d)
        return #d > 0 and ('%03d%s%.12f'):format(#n, n, tonumber(d) / (10 ^ #d))
            or ('%03d%s'):format(#n, n)
    end

    -- Lua 实现的自然排序
    local function sort_lua(strings)
        local tuples = {}
        for i, f in ipairs(strings) do
            -- 将字符串中的数字提取并填充，生成排序键
            tuples[i] = {f:lower():gsub('0*(%d+)%.?(%d*)', padnum), f}
        end
        table.sort(tuples, function(a, b)
            return a[1] == b[1] and #b[2] < #a[2] or a[1] < b[1]
        end)
        for i, tuple in ipairs(tuples) do
            strings[i] = tuple[2]
        end
        return strings
    end

    -- 对外暴露的排序函数
    -- 在 Windows 上优先使用 WinAPI（更精确），否则使用 Lua 实现
    ---@param strings string[]
    function sort_strings(strings)
        if winapi then
            -- 使用 Windows 原生自然排序 API
            table.sort(strings, function(a, b)
                return winapi.shlwapi.StrCmpLogicalW(winapi.utf8_to_wide(a), winapi.utf8_to_wide(b)) == -1
            end)
        else
            sort_lua(strings)
        end
    end
end

-- ==============================================================================
-- 3. 补间动画 (Tween)
-- 在两个数值之间创建平滑过渡动画
-- ==============================================================================

-- 创建插值动画，从 from 渐变到 to
-- 使用指数衰减算法，自动适配渲染帧率
-- 支持两种调用方式：
--   1. tween(from, to, setter, duration, callback)
--   2. tween(from, to, setter, callback)  → 使用默认 duration
---@param from number 起始值
---@param to number|fun():number 结束值（或返回结束值的函数，用于动态目标）
---@param setter fun(value: number) 每帧更新时的回调函数
---@param duration_or_callback? number|fun() 持续时间（毫秒）或回调函数
---@param callback? fun() 动画结束或被终止时的回调
---@return fun() 返回一个可提前终止动画的函数
function tween(from, to, setter, duration_or_callback, callback)
    local duration = duration_or_callback
    if type(duration_or_callback) == 'function' then
        callback = duration_or_callback
    end
    if type(duration) ~= 'number' then
        duration = options.animation_duration
    end

    local current, done, timeout = from, false, nil
    local get_to = type(to) == 'function' and to or function() return to --[[@as number]] end

    -- 计算截止阈值：当距离小于 1% 时认为动画结束
    local distance = math.abs(get_to() - current)
    local cutoff = distance * 0.01
    -- 根据帧率计算需要多少帧完成动画
    local target_ticks = (math.max(duration, 1) / (state.render_delay * 1000))
    -- 每帧的衰减系数（指数衰减）
    local decay = 1 - ((cutoff / distance) ^ (1 / target_ticks))

    -- 完成动画：设置最终值并调用回调
    local function finish()
        if not done then
            setter(get_to())
            done = true
            timeout:kill()
            if callback then callback() end
            request_render()
        end
    end

    -- 每帧更新：当前值向目标值逼近
    local function tick()
        local to = get_to()
        current = current + ((to - current) * decay)
        local is_end = math.abs(to - current) <= cutoff
        if is_end then
            finish()
        else
            setter(current)
            timeout:resume()   -- 继续下一帧
            request_render()
        end
    end

    timeout = mp.add_timeout(state.render_delay, tick)
    if cutoff > 0 then
        tick()   -- 立即执行第一帧
    else
        finish() -- 距离为 0，直接完成
    end

    return finish  -- 返回终止函数（可提前结束动画）
end

-- ==============================================================================
-- 4. 几何计算函数
-- ==============================================================================

-- 计算点到矩形的有符号距离
-- 负值表示点在矩形内部，正值表示在外部
---@param point Point
---@param rect Rect
---@return number
function get_point_to_rectangle_proximity(point, rect)
    local dx = math.max(rect.ax - point.x, point.x - rect.bx)
    local dy = math.max(rect.ay - point.y, point.y - rect.by)
    local distance = math.sqrt(math.max(0, dx)^2 + math.max(0, dy)^2)
    -- 如果点在矩形内部，dx 和 dy 均为负值，distance 为 0，返回负值表示深度
    return distance + math.min(0, math.max(dx, dy))
end

-- 计算两点之间的欧几里得距离
---@param point_a Point
---@param point_b Point
---@return number
function get_point_to_point_proximity(point_a, point_b)
    local dx, dy = point_a.x - point_b.x, point_a.y - point_b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- 检测点是否与碰撞箱（矩形或圆形）碰撞
---@param point Point
---@param hitbox Hitbox
---@return boolean
function point_collides_with(point, hitbox)
    return (hitbox.r and get_point_to_point_proximity(point, hitbox.point) <= hitbox.r) or
        (not hitbox.r and get_point_to_rectangle_proximity(point, hitbox --[[@as Rect]]) <= 0)
end

-- 计算两条线段的交点
-- 使用参数化方法：uA 和 uB 分别表示在线段上的位置（0~1）
-- 返回交点坐标 (x, y)，若不相交则返回 nil, nil
---@param lax number 线段1 起点 X
---@param lay number 线段1 起点 Y
---@param lbx number 线段1 终点 X
---@param lby number 线段1 终点 Y
---@param max number 线段2 起点 X
---@param may number 线段2 起点 Y
---@param mbx number 线段2 终点 X
---@param mby number 线段2 终点 Y
---@return number|nil, number|nil
function get_line_to_line_intersection(lax, lay, lbx, lby, max, may, mbx, mby)
    -- 计算两条直线的方向参数
    local uA = ((mbx - max) * (lay - may) - (mby - may) * (lax - max)) /
        ((mby - may) * (lbx - lax) - (mbx - max) * (lby - lay))
    local uB = ((lbx - lax) * (lay - may) - (lby - lay) * (lax - max)) /
        ((mby - may) * (lbx - lax) - (mbx - max) * (lby - lay))

    -- 如果 uA 和 uB 都在 [0, 1] 范围内，说明两条线段相交
    if uA >= 0 and uA <= 1 and uB >= 0 and uB <= 1 then
        return lax + (uA * (lbx - lax)), lay + (uA * (lby - lay))
    end

    return nil, nil
end

-- 计算从射线起点到线段的最短距离
-- 射线由 (rax, ray) 出发，指向 (rbx, rby)
---@param rax number 射线起点 X
---@param ray number 射线起点 Y
---@param rbx number 射线终点 X
---@param rby number 射线终点 Y
---@param lax number 线段起点 X
---@param lay number 线段起点 Y
---@param lbx number 线段终点 X
---@param lby number 线段终点 Y
---@return number|nil
function get_ray_to_line_distance(rax, ray, rbx, rby, lax, lay, lbx, lby)
    local x, y = get_line_to_line_intersection(rax, ray, rbx, rby, lax, lay, lbx, lby)
    if x then
        return math.sqrt((rax - x) ^ 2 + (ray - y) ^ 2)
    end
    return nil
end

-- 计算从射线起点到矩形的最短距离
-- 若射线起点在矩形内部，返回 0
---@param ax number 射线起点 X
---@param ay number 射线起点 Y
---@param bx number 射线终点 X
---@param by number 射线终点 Y
---@param rect Rect
---@return number|nil
function get_ray_to_rectangle_distance(ax, ay, bx, by, rect)
    -- 如果射线起点在矩形内部，距离为 0
    if ax >= rect.ax and ax <= rect.bx and ay >= rect.ay and ay <= rect.by then
        return 0
    end

    local closest = nil

    local function updateDistance(distance)
        if distance and (not closest or distance < closest) then
            closest = distance
        end
    end

    -- 分别检测射线与矩形四条边的距离
    updateDistance(get_ray_to_line_distance(ax, ay, bx, by, rect.ax, rect.ay, rect.bx, rect.ay))
    updateDistance(get_ray_to_line_distance(ax, ay, bx, by, rect.bx, rect.ay, rect.bx, rect.by))
    updateDistance(get_ray_to_line_distance(ax, ay, bx, by, rect.ax, rect.by, rect.bx, rect.by))
    updateDistance(get_ray_to_line_distance(ax, ay, bx, by, rect.ax, rect.ay, rect.ax, rect.by))

    return closest
end

-- ==============================================================================
-- 5. 贝塞尔曲线转换 (points_to_bezier)
-- 将 Catmull-Rom 样条点转换为贝塞尔曲线控制点
-- 用于热力图等平滑曲线绘制
-- 输入：扁平点表 {x1, y1, x2, y2, ...}
-- 输出：扁平贝塞尔控制点表 {起点x, 起点y, cp1x, cp1y, cp2x, cp2y, 终点x, 终点y, ...}
-- ==============================================================================

---@param points number[] 扁平点表
---@return number[] 扁平贝塞尔控制点表
function points_to_bezier(points)
    if not points or #points < 4 then return {} end

    -- Catmull-Rom → Bezier 转换函数
    -- 将四个 Catmull-Rom 控制点转换为两个 Bezier 控制点
    local function catmullrom_to_bezier(p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y)
        local cp1x = p1x + (p2x - p0x) / 6
        local cp1y = p1y + (p2y - p0y) / 6
        local cp2x = p2x - (p3x - p1x) / 6
        local cp2y = p2y - (p3y - p1y) / 6
        return cp1x, cp1y, cp2x, cp2y
    end

    -- 从扁平表中提取第 i 个点的 x, y
    local function get_xy(i)
        return points[i * 2 - 1], points[i * 2]
    end

    local curve = {points[1], points[2]}  -- 起始点
    local xy_pairs = #points / 2          -- 点的数量

    -- 对每对相邻点生成一个 Bezier 段
    for i = 1, xy_pairs - 1 do
        -- 取相邻的 4 个点（边界处重复端点）
        local p0x, p0y = get_xy(math.max(i - 1, 1))
        local p1x, p1y = get_xy(i)
        local p2x, p2y = get_xy(i + 1)
        local p3x, p3y = get_xy(math.min(i + 2, xy_pairs))
        local cp1x, cp1y, cp2x, cp2y = catmullrom_to_bezier(p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y)
        local n = #curve
        curve[n + 1], curve[n + 2], curve[n + 3], curve[n + 4], curve[n + 5], curve[n + 6] =
            cp1x, cp1y, cp2x, cp2y, p2x, p2y
    end

    return curve
end

-- ==============================================================================
-- 6. 属性模板展开辅助 (get_expansion_props)
-- 提取模板字符串中引用的所有 mpv 属性名
-- 例如 "${media-title}" → {["media-title"] = true}
-- ==============================================================================

---@param str string
---@param res? { [string] : boolean }
---@return { [string] : boolean }
function get_expansion_props(str, res)
    res = res or {}
    -- 匹配 ${...} 格式的模板
    for str in str:gmatch('%$(%b{})') do
        -- 解析模板内部：支持 {?!?=?属性名:?默认值} 格式
        local name, str = str:match('^{[?!]?=?([^:]+):?(.*)}$')
        if name then
            -- 如果有 == 比较符，取比较符之前的部分作为属性名
            local s = name:find('==') or nil
            if s then name = name:sub(0, s - 1) end
            res[name] = true
            -- 递归处理嵌套模板
            if str and str ~= '' then
                get_expansion_props(str, res)
            end
        end
    end
    return res
end

-- ==============================================================================
-- 7. ASS 文本转义 (ass_escape)
-- 将普通文本转换为 ASS 安全字符串，防止被解析为 ASS 标签
-- ==============================================================================

-- ASS 中 \ 用于转义，但如果不跟可识别字符则原样输出，
-- 所以用零宽不换行空格（ZWNBSP，U+FEFF）来转义反斜杠
---@param str string
---@return string
function ass_escape(str)
    -- 转义反斜杠
    str = str:gsub('\\', '\\\239\187\191')
    -- 转义花括号（ASS 标签分隔符）
    str = str:gsub('{', '\\{')
    str = str:gsub('}', '\\}')
    -- 转义换行符（添加 ZWNBSP 防止 ASS 压缩连续换行）
    str = str:gsub('\n', '\239\187\191\\N')
    -- 转义行首空格（防止 ASS 自动去除行首空格）
    str = str:gsub('\\N ', '\\N\\h')
    str = str:gsub('^ ', '\\h')
    return str
end

-- ==============================================================================
-- 8. 时间格式化 (format_time)
-- 根据 time_precision 格式化时间显示
-- ==============================================================================

---@param seconds number
---@param max_seconds number|nil 最大时间（用于决定是否显示小时位）
---@return string
function format_time(seconds, max_seconds)
    local human = mp.format_time(seconds)

    -- 添加小数精度（time_precision 控制小数位数）
    if options.time_precision > 0 then
        local formatted = string.format('%.' .. options.time_precision .. 'f', math.abs(seconds) % 1)
        human = human .. '.' .. string.sub(formatted, 3)
    end

    -- 如果最大时间小于 60 秒，去掉 "00:" 前缀；小于 3600 秒去掉小时位
    if max_seconds then
        local trim_length = (max_seconds < 60 and 7 or (max_seconds < 3600 and 4 or 0))
        if trim_length > 0 then
            local has_minus = seconds < 0
            human = string.sub(human, trim_length + (has_minus and 1 or 0))
            if has_minus then human = '-' .. human end
        end
    end

    return human
end

-- ==============================================================================
-- 9. 透明度转 ASS Alpha (opacity_to_alpha)
-- 0~1 透明度 → ASS 的十六进制 Alpha 值
-- ASS 中 0x00 = 不透明，0xFF = 完全透明
-- ==============================================================================

---@param opacity number 0~1
---@return integer 0~255
function opacity_to_alpha(opacity)
    return 255 - math.ceil(255 * opacity)
end

-- ==============================================================================
-- 10. 路径分隔符 (path_separator)
-- 根据操作系统返回正确的路径分隔符
-- ==============================================================================

path_separator = (function()
    local os_separator = state.platform == 'windows' and '\\' or '/'

    -- 返回适合给定路径的分隔符
    -- UNC 路径（\\server\share）使用反斜杠
    ---@param path string
    ---@return string
    return function(path)
        return path:sub(1, 2) == '\\\\' and '\\' or os_separator
    end
end)()

-- ==============================================================================
-- 11. 路径操作函数
-- ==============================================================================

-- 拼接两个路径（自动处理分隔符）
---@param p1 string
---@param p2 string
---@return string
function join_path(p1, p2)
    local p1, separator = trim_trailing_separator(p1)
    -- 防止盘符后添加多余分隔符（C:\foo → C:\foo）
    return p1:sub(#p1) == separator and p1 .. p2 or p1 .. separator .. p2
end

-- 判断路径是否为绝对路径
---@param path string
---@return boolean
function is_absolute(path)
    if path:sub(1, 2) == '\\\\' then
        return true  -- Windows UNC 路径
    elseif state.platform == 'windows' then
        return path:find('^%a+:') ~= nil  -- Windows 盘符（如 C:）
    else
        return path:sub(1, 1) == '/'  -- Unix 绝对路径
    end
end

-- 确保路径是绝对路径
---@param path string
---@return string
function ensure_absolute(path)
    if is_absolute(path) then return path end
    return join_path(state.cwd, path)
end

-- 去除末尾的分隔符
---@param path string
---@return string path, string trimmed_separator_type
function trim_trailing_separator(path)
    local separator = path_separator(path)
    path = trim_end(path, separator)
    -- Windows 盘符（如 C:）需要保留末尾反斜杠
    if state.platform == 'windows' then
        if path:sub(#path) == ':' then path = path .. '\\' end
    else
        -- Unix 根目录处理
        if path == '' then path = '/' end
    end
    return path, separator
end

-- 轻量级路径规范化：确保绝对路径 + 去除末尾分隔符
-- 用于性能敏感的场景
---@param path string
---@return string
function normalize_path_lite(path)
    if not path or is_protocol(path) then return path end
    path = trim_trailing_separator(ensure_absolute(path))
    return path
end

-- 完整路径规范化：绝对路径 + 去除末尾分隔符 + 分隔符归一化 + 去重
---@param path string
---@return string
function normalize_path(path)
    if not path or is_protocol(path) then return path end

    path = ensure_absolute(path)
    local is_unc = path:sub(1, 2) == '\\\\'

    -- 分隔符归一化：Windows 下将 / 转为 \
    if state.platform == 'windows' or is_unc then
        path = path:gsub('/', '\\')
    end
    path = trim_trailing_separator(path)

    -- 去重路径分隔符
    if is_unc then
        -- UNC 路径：保留双反斜杠开头，但去除连续的反斜杠
        path = path:gsub('(.\\)\\+', '%1')
    elseif state.platform == 'windows' then
        path = path:gsub('\\\\+', '\\')
    else
        path = path:gsub('//+', '/')
    end

    return path
end

-- 判断路径是否为网络协议（如 http://、https://、ftp:// 等）
---@param path string
---@return boolean
function is_protocol(path)
    return type(path) == 'string' and (
        path:find('^%a[%w.+-]-://') ~= nil or
        path:find('^%a[%w.+-]-:%?') ~= nil
    )
end

-- 检查文件扩展名是否在指定列表中
---@param path string
---@param extensions string[] 小写扩展名列表（不含点）
---@return boolean
function has_any_extension(path, extensions)
    local path_last_dot_index = string_last_index_of(path, '.')
    if not path_last_dot_index then return false end
    local path_extension = path:sub(path_last_dot_index + 1):lower()
    for _, extension in ipairs(extensions) do
        if path_extension == extension then return true end
    end
    return false
end

-- ==============================================================================
-- 12. 命令执行辅助 (execute_command)
-- 执行 mpv 命令（支持字符串或数组形式）
-- 返回布尔值表示是否执行了命令
-- ==============================================================================

---@param command string | string[] | nil | any
---@return boolean executed
function execute_command(command)
    local command_type = type(command)
    if command_type == 'string' then
        mp.command(command)
        return true
    elseif command_type == 'table' and #command > 0 then
        mp.command_native(command)
        return true
    end
    return false
end

-- ==============================================================================
-- 13. 路径序列化 (serialize_path)
-- 将路径拆分为语义部件：目录名、文件名、扩展名等
-- ==============================================================================

---@param path string
---@return nil|{path: string; is_root: boolean; dirname?: string; basename: string; filename: string; extension?: string;}
function serialize_path(path)
    if not path or is_protocol(path) then return end

    local normal_path = normalize_path_lite(path)
    local dirname, basename = utils.split_path(normal_path)

    -- 如果 basename 为空，说明路径是根目录
    if basename == '' then
        basename, dirname = dirname:sub(1, #dirname - 1), nil
    end

    local dot_i = string_last_index_of(basename, '.')

    return {
        path = normal_path,
        is_root = dirname == nil,
        dirname = dirname,
        basename = basename,
        filename = dot_i and basename:sub(1, dot_i - 1) or basename,
        extension = dot_i and basename:sub(dot_i + 1) or nil,
    }
end

-- ==============================================================================
-- 14. 系统文件过滤
-- 用于文件浏览时隐藏系统文件/文件夹
-- ==============================================================================

local system_files = create_set({
    '$RECYCLE.BIN', '$Recycle.Bin', '$SysReset', '$WinREAgent',
    '.sys', 'pagefile.sys', 'hiberfil.sys', 'config.sys',
    'swapfile.sys', 'Thumbs.db', 'desktop.ini',
})

-- ==============================================================================
-- 15. 读取目录内容 (read_directory)
-- 返回文件列表和目录列表，支持扩展名过滤和隐藏文件控制
-- ==============================================================================

---@param path string
---@param opts? {types?: string[], hidden?: boolean}
---@return string[] files
---@return string[] directories
---@return string|nil error
function read_directory(path, opts)
    opts = opts or {}
    local items, error = utils.readdir(path, 'all')
    local files, directories = {}, {}

    if not items then
        return files, directories, 'Reading directory "' .. path .. '" failed. Error: ' .. utils.to_string(error)
    end

    for _, item in ipairs(items) do
        -- 跳过 . 和 ..，跳过系统文件，根据 hidden 选项决定是否跳过隐藏文件
        if item ~= '.' and item ~= '..' and not system_files[item] and (opts.hidden or item:sub(1, 1) ~= '.') then
            local info = utils.file_info(join_path(path, item))
            if info then
                if info.is_file then
                    -- 文件：检查扩展名是否匹配
                    if not opts.types or has_any_extension(item, opts.types) then
                        files[#files + 1] = item
                    end
                else
                    directories[#directories + 1] = item
                end
            end
        end
    end

    return files, directories
end

-- ==============================================================================
-- 16. 获取相邻文件 (get_adjacent_files)
-- 获取同一目录下的所有媒体文件，并返回当前文件在列表中的位置
-- ==============================================================================

---@param file_path string
---@param opts? {types?: string[], hidden?: boolean}
---@return table|nil paths, number|nil current_index
function get_adjacent_files(file_path, opts)
    opts = opts or {}
    local current_meta = serialize_path(file_path)
    if not current_meta then return end

    local files, _dirs, error = read_directory(current_meta.dirname, {hidden = opts.hidden})
    if error then
        msg.error(error)
        return
    end

    sort_strings(files)

    local current_file_index
    local paths = {}

    for _, file in ipairs(files) do
        local is_current_file = current_meta.basename == file
        if is_current_file or not opts.types or has_any_extension(file, opts.types) then
            paths[#paths + 1] = join_path(current_meta.dirname, file)
            if is_current_file then current_file_index = #paths end
        end
    end

    if not current_file_index then return end
    return paths, current_file_index
end

-- ==============================================================================
-- 17. 导航决策 (decide_navigation_in_list)
-- 在列表中进行导航（支持循环、随机播放）
-- ==============================================================================

-- 在列表中导航，delta=1 前进，delta=-1 后退
-- 支持循环播放（loop-playlist）和随机播放（shuffle）
---@param paths table
---@param current_index number
---@param delta number 1 或 -1
---@return number|nil next_index, any|nil next_path
function decide_navigation_in_list(paths, current_index, delta)
    if #paths < 2 then return end
    delta = delta < 0 and -1 or 1

    -- ============================================================
    -- 随机播放模式
    -- 使用历史记录防止重复：已播放的路径从候选池中移除，
    -- 直到至少 80% 的列表已被播放
    -- ============================================================
    if state.shuffle then
        -- 初始化随机播放历史
        state.shuffle_history = state.shuffle_history or {
            pos = #state.history,                    -- 当前位置
            paths = itable_slice(state.history),    -- 已播放路径列表
        }
        state.shuffle_history.pos = state.shuffle_history.pos + delta

        -- 检查历史中是否有对应的路径
        local history_path = state.shuffle_history.paths[state.shuffle_history.pos]
        local next_index = history_path and itable_index_of(paths, history_path)
        if next_index then
            return next_index, history_path
        end

        -- 如果历史中没有，调整位置
        if delta < 0 then
            state.shuffle_history.pos = state.shuffle_history.pos - delta
        else
            state.shuffle_history.pos = math.min(state.shuffle_history.pos, #state.shuffle_history.paths + 1)
        end

        -- 从候选池中移除最近播放的 80% 的路径
        local trimmed_history = itable_slice(state.history, -math.floor(#paths * 0.8))
        local shuffle_pool = {}

        for index, value in ipairs(paths) do
            if not itable_has(trimmed_history, value) then
                shuffle_pool[#shuffle_pool + 1] = index
            end
        end

        -- 从候选池中随机选择
        math.randomseed(os.time())
        local next_index = shuffle_pool[math.random(#shuffle_pool)]
        local next_path = paths[next_index]
        table.insert(state.shuffle_history.paths, state.shuffle_history.pos, next_path)
        return next_index, next_path
    end

    -- ============================================================
    -- 普通模式（支持循环播放）
    -- ============================================================
    local new_index = current_index + delta
    if mp.get_property_native('loop-playlist') then
        -- 循环播放：超出边界时绕回
        if new_index > #paths then
            new_index = new_index % #paths
        elseif new_index < 1 then
            new_index = #paths - new_index
        end
    elseif new_index < 1 or new_index > #paths then
        return  -- 不循环时，超出边界则停止
    end

    return new_index, paths[new_index]
end

-- ==============================================================================
-- 18. 导航目录/播放列表
-- ==============================================================================

-- 在目录中导航（delta=1 下一个，-1 上一个）
---@param delta number
---@return boolean
function navigate_directory(delta)
    if not state.path or is_protocol(state.path) then return false end
    local paths, current_index = get_adjacent_files(state.path, {
        types = config.types.load,
        hidden = options.show_hidden_files,
    })
    if paths and current_index then
        local _, path = decide_navigation_in_list(paths, current_index, delta)
        if path then
            mp.commandv('loadfile', path)
            return true
        end
    end
    return false
end

-- 在播放列表中导航
---@param delta number
---@return boolean
function navigate_playlist(delta)
    local playlist, pos = mp.get_property_native('playlist'), mp.get_property_native('playlist-pos-1')
    if playlist and #playlist > 1 and pos then
        local paths = itable_map(playlist, function(item) return normalize_path(item.filename) end)
        local index = decide_navigation_in_list(paths, pos, delta)
        if index then
            mp.commandv('playlist-play-index', index - 1)
            return true
        end
    end
    return false
end

-- 通用导航：有播放列表时在播放列表中导航，否则在目录中导航
---@param delta number
---@return boolean
function navigate_item(delta)
    if state.has_playlist then
        return navigate_playlist(delta)
    else
        return navigate_directory(delta)
    end
end

-- ==============================================================================
-- 19. 删除文件 (delete_file)
-- 支持回收站（Windows 使用 PowerShell，Linux/macOS 使用 trash 命令）
-- ==============================================================================

-- Windows 下不能用 os.remove() 处理 Unicode 路径，
-- 所以使用 subprocess 调用系统命令
---@param path string
---@return table result
function delete_file(path)
    local args
    if state.platform == 'windows' then
        if options.use_trash then
            -- Windows 回收站：使用 PowerShell 调用 .NET API
            local ps_code = [[
                Add-Type -AssemblyName Microsoft.VisualBasic
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('__path__', 'OnlyErrorDialogs', 'SendToRecycleBin')
            ]]
            -- 转义路径中的特殊字符
            local escaped_path = string.gsub(path, "'", "''")
            escaped_path = string.gsub(escaped_path, '’', '’’')
            escaped_path = string.gsub(escaped_path, '%%', '%%%%')
            ps_code = string.gsub(ps_code, '__path__', escaped_path)
            args = {'powershell', '-NoProfile', '-Command', ps_code}
        else
            args = {'cmd', '/C', 'del', path}
        end
    else
        if options.use_trash then
            -- Linux/macOS：需要先安装 trash-cli 或 trash
            args = {'trash', path}
        else
            args = {'rm', path}
        end
    end

    return mp.command_native({
        name = 'subprocess',
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    })
end

-- 删除当前文件并导航到相邻文件
---@param delta number
function delete_file_navigate(delta)
    local path, playlist_pos = state.path, state.playlist_pos
    local is_local_file = path and not is_protocol(path)

    -- 先导航到相邻文件（或停止播放）
    if navigate_item(delta) then
        if state.has_playlist then
            mp.commandv('playlist-remove', playlist_pos - 1)
        end
    else
        mp.command('stop')
    end

    -- 删除原文件
    if is_local_file then
        -- 如果打开文件菜单正在显示，从菜单中移除该项
        if Menu:is_open('open-file') then
            Elements:maybe('menu', 'delete_value', path)
        end
        if path then delete_file(path) end
    end
end

-- ==============================================================================
-- 20. 章节处理
-- ==============================================================================

-- 规范化章节：按时间排序，补充标题
---@param chapters table|nil
---@return table
function normalize_chapters(chapters)
    if not chapters then return {} end
    -- 按时间排序
    table.sort(chapters, function(a, b) return a.time < b.time end)
    -- 确保每个章节有标题
    for index, chapter in ipairs(chapters) do
        local chapter_number = chapter.title and string.match(chapter.title, '^Chapter (%d+)$')
        if chapter_number then
            chapter.title = t('Chapter %s', tonumber(chapter_number))
        end
        chapter.title = chapter.title ~= '(unnamed)' and chapter.title ~= '' and chapter.title or t('Chapter %s', index)
        chapter.lowercase_title = chapter.title:lower()
    end
    return chapters
end

-- 序列化章节：添加换行标题、宽度信息
---@param chapters table
---@return table|nil
function serialize_chapters(chapters)
    chapters = normalize_chapters(chapters)
    if not chapters then return end
    -- 使用字号 1 作为基准，渲染时再缩放
    local opts = {size = 1, bold = true}
    for index, chapter in ipairs(chapters) do
        chapter.index = index
        chapter.title_wrapped, chapter.title_lines = wrap_text(chapter.title, opts, 25)
        chapter.title_wrapped_width = text_width(chapter.title_wrapped, opts)
        chapter.title_wrapped = ass_escape(chapter.title_wrapped)
    end
    return chapters
end

-- 序列化章节范围：识别 OP/ED/广告等
---@param normalized_chapters table
---@return table chapters, table ranges
function serialize_chapter_ranges(normalized_chapters)
    local ranges = {}

    -- 简单范围定义（OP/ED/Intro/Outro）
    local simple_ranges = {
        {
            name = 'openings',
            patterns = {
                '^op ', '^op$', ' op$',
                '^opening$', ' opening$',
            },
            requires_next_chapter = true,
        },
        {
            name = 'intros',
            patterns = {
                '^intro$', ' intro$',
                '^avant$', '^prologue$',
            },
            requires_next_chapter = true,
        },
        {
            name = 'endings',
            patterns = {
                '^ed ', '^ed$', ' ed$',
                '^ending ', '^ending$', ' ending$',
            },
        },
        {
            name = 'outros',
            patterns = {
                '^outro$', ' outro$',
                '^closing$', '^closing ',
                '^preview$', '^pv$',
            },
        },
    }
    local sponsor_ranges = {}

    -- 扩展用户自定义模式
    for _, meta in ipairs(simple_ranges) do
        local alt_patterns = config.chapter_ranges[meta.name] and config.chapter_ranges[meta.name].patterns
        if alt_patterns then
            meta.patterns = itable_join(meta.patterns, alt_patterns)
        end
    end

    -- 复制章节列表（避免修改原始数据）
    local chapters = {}
    for i, normalized in ipairs(normalized_chapters) do
        chapters[i] = table_assign({}, normalized)
    end

    -- 识别章节范围
    for i, chapter in ipairs(chapters) do
        -- 简单范围匹配
        for _, meta in ipairs(simple_ranges) do
            if config.chapter_ranges[meta.name] then
                local match = itable_find(meta.patterns, function(p)
                    return chapter.lowercase_title:find(p)
                end)
                if match then
                    local next_chapter = chapters[i + 1]
                    if next_chapter or not meta.requires_next_chapter then
                        ranges[#ranges + 1] = table_assign({
                            start = chapter.time,
                            ['end'] = next_chapter and next_chapter.time or math.huge,
                        }, config.chapter_ranges[meta.name])
                    end
                end
            end
        end

        -- SponsorBlock 广告段识别
        if config.chapter_ranges.ads then
            -- 格式：segment start (ID)
            local id = chapter.lowercase_title:match('segment start *%(([%w]%w-)%)')
            if id then
                -- 查找对应的 segment end
                for j = i + 1, #chapters, 1 do
                    local end_chapter = chapters[j]
                    local end_match = end_chapter.lowercase_title:match('segment end *%(' .. id .. '%)')
                    if end_match then
                        local range = table_assign({
                            start_chapter = chapter,
                            end_chapter = end_chapter,
                            start = chapter.time,
                            ['end'] = end_chapter.time,
                        }, config.chapter_ranges.ads)
                        ranges[#ranges + 1] = range
                        sponsor_ranges[#sponsor_ranges + 1] = range
                        end_chapter.is_end_only = true
                        break
                    end
                end
            -- 格式：SponsorBlock: 或 sponsors
            elseif not chapter.is_end_only and
                (chapter.lowercase_title:find('%[sponsorblock%]:') or
                 chapter.lowercase_title:find('^sponsors?')) then
                local next_chapter = chapters[i + 1]
                ranges[#ranges + 1] = table_assign({
                    start = chapter.time,
                    ['end'] = next_chapter and next_chapter.time or math.huge,
                }, config.chapter_ranges.ads)
            end
        end
    end

    -- 修复重叠的 SponsorBlock 段
    for index, range in ipairs(sponsor_ranges) do
        local next_range = sponsor_ranges[index + 1]
        if next_range then
            local delta = next_range.start - range['end']
            if delta < 0 then
                -- 重叠：取中间点分割
                local mid_point = range['end'] + delta / 2
                range['end'], range.end_chapter.time = mid_point - 0.01, mid_point - 0.01
                next_range.start, next_range.start_chapter.time = mid_point, mid_point
            end
        end
    end

    table.sort(chapters, function(a, b) return a.time < b.time end)
    return chapters, ranges
end

-- ==============================================================================
-- 21. 键盘绑定查询 (find_active_keybindings)
-- 查询当前激活的 mpv 键盘绑定
-- ==============================================================================

---@param key string|nil 如果提供，只返回该键的绑定；否则返回所有绑定
---@return {[string]: table}|table
function find_active_keybindings(key)
    local bindings = mp.get_property_native('input-bindings', {})
    local active_map = {}
    local active_table = {}

    for _, bind in pairs(bindings) do
        -- 只考虑优先级 >= 0 且不属于 uosc 自身的绑定
        if bind.owner ~= 'uosc' and bind.priority >= 0 and (not key or bind.key == key) and (
                not active_map[bind.key]
                or (active_map[bind.key].is_weak and not bind.is_weak)
                or (bind.is_weak == active_map[bind.key].is_weak and bind.priority > active_map[bind.key].priority)
            ) then
            active_table[#active_table + 1] = bind
            active_map[bind.key] = bind
        end
    end

    return key and active_map[key] or active_table
end

-- ==============================================================================
-- 22. 快捷键可读化 (keybind_to_human)
-- 将 mpv 按键名转换为人类可读形式
-- ==============================================================================

do
    -- 替换规则：SHARP → #，#$ → 空
    local key_subs = {{'^#$', ''}, {anycase('sharp'), '#'}}

    ---@param keybind string
    ---@return string
    function keybind_to_human(keybind)
        for _, sub in ipairs(key_subs) do
            keybind = string.gsub(keybind, sub[1], sub[2])
        end
        return keybind
    end
end

-- ==============================================================================
-- 23. 加载外部轨道 (load_track)
-- 加载音轨/字幕轨/视频轨文件
-- ==============================================================================

---@param type 'sub'|'audio'|'video'
---@param path string
function load_track(type, path)
    mp.commandv(type .. '-add', path, 'cached')
    -- 如果加载的是字幕轨，自动启用字幕显示
    if type == 'sub' then
        mp.commandv('set', 'sub-visibility', 'yes')
    end
end

-- ==============================================================================
-- 24. ziggy 调用
-- ziggy 是 uosc 的辅助工具（剪贴板操作等）
-- 同步调用
-- ==============================================================================

---@param args (string|number)[]
---@return string|nil error
---@return table data
function call_ziggy(args)
    local result = mp.command_native({
        name = 'subprocess',
        capture_stderr = true,
        capture_stdout = true,
        playback_only = false,
        args = itable_join({config.ziggy_path}, args),
    })

    if result.status ~= 0 then
        return 'Calling ziggy failed. Exit code ' .. result.status .. ': ' .. result.stdout .. result.stderr, {}
    end

    local data = utils.parse_json(result.stdout)
    if not data then
        return 'Ziggy response error. Couldn\'t parse json: ' .. result.stdout, {}
    elseif data.error then
        return 'Ziggy error: ' .. data.message, {}
    else
        return nil, data
    end
end

-- 异步调用
---@param args (string|number)[]
---@param callback fun(error: string|nil, data: table)
---@return fun() abort 返回一个可中止请求的函数
function call_ziggy_async(args, callback)
    local abort_signal = mp.command_native_async({
        name = 'subprocess',
        capture_stderr = true,
        capture_stdout = true,
        playback_only = false,
        args = itable_join({config.ziggy_path}, args),
    }, function(success, result, error)
        if not success or not result or result.status ~= 0 then
            local exit_code = (result and result.status or 'unknown')
            local message = error or (result and result.stdout .. result.stderr) or ''
            callback('Calling ziggy failed. Exit code: ' .. exit_code .. ' Error: ' .. message, {})
            return
        end

        local json = result and type(result.stdout) == 'string' and result.stdout or ''
        local data = utils.parse_json(json)
        if not data then
            callback('Ziggy response error. Couldn\'t parse json: ' .. json, {})
        elseif data.error then
            callback('Ziggy error: ' .. data.message, {})
        else
            return callback(nil, data)
        end
    end)

    return function()
        mp.abort_async_command(abort_signal)
    end
end

-- ==============================================================================
-- 25. 剪贴板操作 (get_clipboard / set_clipboard)
-- ==============================================================================

-- 获取剪贴板内容
---@return string|nil
function get_clipboard()
    -- 优先使用 mpv 原生的 clipboard/text 属性
    local data, err = mp.get_property('clipboard/text')
    if data then
        return data
    end
    -- 如果原生不支持，通过 ziggy 获取
    if err and err ~= 'property not found' and err ~= 'property unavailable' then
        mp.commandv('show-text', 'Get clipboard error: ' .. err)
        return nil
    end

    local err, data = call_ziggy({'get-clipboard'})
    if err then
        mp.commandv('show-text', 'Get clipboard error. See console for details.')
        msg.error(err)
    end
    return data and data.payload
end

-- 设置剪贴板内容
---@param payload any
---@return string|nil payload 被复制的内容
function set_clipboard(payload)
    payload = tostring(payload)

    -- 优先使用 mpv 原生方式
    local success, err = mp.set_property('clipboard/text', payload)
    if success then
        mp.commandv('show-text', t('Copied to clipboard') .. ': ' .. payload, 3000)
        return payload
    end
    if err and err ~= 'property not found' and err ~= 'property unavailable' then
        mp.commandv('show-text', 'Set clipboard error: ' .. err)
        return nil
    end

    -- 原生不支持，通过 ziggy 设置
    local err, data = call_ziggy({'set-clipboard', payload})
    if err then
        mp.commandv('show-text', 'Set clipboard error. See console for details.')
        msg.error(err)
    else
        mp.commandv('show-text', t('Copied to clipboard') .. ': ' .. payload, 3000)
    end
    return data and data.payload
end

-- ==============================================================================
-- 26. YouTube 热力图加载 (load_youtube_heatmap)
-- 从 ytdl 结果中提取热力图数据并归一化
-- ==============================================================================

---@return number[]|nil 归一化的贝塞尔点表（0~1）
function load_youtube_heatmap()
    if not state.path or not is_protocol(state.path) then return end
    -- 仅匹配 YouTube 链接
    if not (
        state.path:match('^https?://%w+%.youtube%.com/') or
        state.path:match('^https?://youtube%.com/') or
        state.path:match('^https?://youtu%.be/')
    ) then return end

    -- 从 mpv 的 user-data 中读取 ytdl 结果
    local r = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result')
    local ytdl_result = r and utils.parse_json(r.stdout)
    if ytdl_result and ytdl_result.heatmap then
        local data = ytdl_result.heatmap
        local max_val = 0
        local vid_length = data[#data].end_time

        -- 找最大值用于归一化
        for _, seg in ipairs(data) do
            max_val = math.max(max_val, seg.value)
        end

        -- 归一化到 0~1
        local is_above = options.timeline_heatmap == 'above'
        local min_height, graph_height = 4, is_above and 40 or options.timeline_size
        local max_norm_y = 1 - (min_height / graph_height)
        local norm = {0, 1}  -- 起始锚点

        for _, seg in ipairs(data) do
            local center_time = (seg.start_time + seg.end_time) / 2
            local norm_x = center_time / vid_length
            local norm_y = math.min(max_norm_y, 1 - (seg.value / max_val))
            norm[#norm + 1], norm[#norm + 2] = norm_x, norm_y
        end

        -- 结束锚点
        local last_y = math.min(max_norm_y, 1 - (data[#data].value / max_val))
        norm[#norm + 1], norm[#norm + 2] = 1, last_y
        norm[#norm + 1], norm[#norm + 2] = 1, 1

        -- 转换为贝塞尔曲线
        return points_to_bezier(norm)
    end
end

-- ==============================================================================
-- 27. 渲染引擎 (render / request_render)
-- ==============================================================================

-- 核心渲染函数：遍历所有 UI 元素，生成 ASS 并提交到 OSD
function render()
    if not display.initialized then return end
    state.render_last_time = mp.get_time()

    cursor:clear_zones()

    local ass = assdraw.ass_new()

    -- 空闲指示器（idle 状态时显示）
    if state.is_idle and not Manager.disabled.idle_indicator then
        local smaller_side = math.min(display.width, display.height)
        local center_x, center_y, icon_size = display.width / 2, display.height / 2, math.max(smaller_side / 4, 56)
        ass:icon(center_x, center_y - icon_size / 4, icon_size, 'not_started', {
            color = fg, opacity = config.opacity.idle_indicator,
        })
        ass:txt(center_x, center_y + icon_size / 2, 8, t('Drop files or URLs to play here'), {
            size = icon_size / 4, color = fg, opacity = config.opacity.idle_indicator,
        })
    end

    -- 音频指示器（纯音频文件时显示）
    if state.is_audio and not state.has_image and not Manager.disabled.audio_indicator
        and not (state.pause and options.pause_indicator == 'static') then
        local smaller_side = math.min(display.width, display.height)
        ass:icon(display.width / 2, display.height / 2, smaller_side / 4, 'graphic_eq', {
            color = fg, opacity = config.opacity.audio_indicator,
        })
    end

    -- 渲染所有 UI 元素
    for _, element in Elements:ipairs() do
        if element.enabled then
            local result = element:maybe('render')
            if result then
                ass:new_event()
                ass:merge(result)
            end
        end
    end

    -- 更新鼠标按键绑定状态
    cursor:decide_keybinds()

    -- 如果 OSD 内容与上次相同，跳过更新
    if osd.res_x == display.width and osd.res_y == display.height and osd.data == ass.text then
        return
    end

    -- 提交到 OSD
    osd.res_x = display.width
    osd.res_y = display.height
    osd.data = ass.text
    osd.z = 2000
    osd:update()

    update_margins()
end

-- 请求渲染：在下一帧执行 render()
-- 使用限速机制防止过于频繁的渲染
state.render_timer = mp.add_timeout(0, render)
state.render_timer:kill()

function request_render()
    if state.render_timer:is_enabled() then return end
    local timeout = math.max(0, state.render_delay - (mp.get_time() - state.render_last_time))
    state.render_timer.timeout = timeout
    state.render_timer:resume()
end

-- ==============================================================================
-- 导出：所有函数均为全局函数，在 Lua 环境中直接可用
-- 本文件不返回任何值，所有函数均通过全局作用域暴露
-- ==============================================================================