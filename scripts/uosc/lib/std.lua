-- ==============================================================================
-- std.lua — Lua 标准库扩展工具集
-- ==============================================================================
-- 功能概述：
--   1. 提供 Lua 标准库中缺失的通用工具函数
--   2. 包含数值处理（round、clamp）、字符串处理（trim、split、正则转义）
--   3. 包含表操作（查找、过滤、映射、合并、切片）
--   4. 包含简单的面向对象系统（Class 基类与 class() 工厂函数）
--   5. 包含环形缓冲区（CircularBuffer）数据结构
--   6. 包含快捷键结构（Shortcut）的创建函数
--   7. 包含缓动函数（ease_out_quart、ease_out_sext）用于动画
-- ==============================================================================
-- 设计特点：
--   - 所有函数均为无状态（stateless），不依赖外部状态
--   - 采用防御性编程，对 nil 和边界情况有良好处理
--   - 函数命名以 itable_* 前缀区分普通表操作
--   - 类型注解完整，支持 IDE 自动补全
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 类型定义 (Type Aliases)
-- ==============================================================================

---@alias Shortcut {id: string; key: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean}
-- Shortcut 字段说明：
--   id        : 唯一标识符（由 modifiers 和 key 组合而成，如 "ctrl+alt+t"）
--   key       : 基础按键名（如 "t"、"enter"、"mbtn_left"）
--   modifiers : 修饰键字符串（如 "ctrl+alt"，多个修饰键用 + 连接）
--   alt/ctrl/shift : 布尔值，表示该修饰键是否被按下

-- ==============================================================================
-- 2. 数值处理函数
-- ==============================================================================

-- 四舍五入：将数值四舍五入到最接近的整数
-- 原理：+0.5 后向下取整，等价于标准四舍五入
---@param number number
---@return integer
function round(number)
    return math.floor(number + 0.5)
end

-- 数值钳制：将值限制在 [min, max] 区间内
-- 如果 value < min 返回 min；如果 value > max 返回 max；否则返回 value 本身
---@param min number
---@param value number
---@param max number
---@return number
function clamp(min, value, max)
    return math.max(min, math.min(value, max))
end

-- ==============================================================================
-- 3. 颜色序列化 (serialize_rgba)
-- 将 RRGGBB 或 RRGGBBAA 格式的颜色字符串解析为 {color, opacity} 表
-- 输出 color 为 BGR 格式（ASS 绘图使用的格式），opacity 为 0~1 的浮点数
-- ==============================================================================

-- 示例：
--   serialize_rgba("FF3399")   → {color = "9933FF", opacity = 1}
--   serialize_rgba("FF339980") → {color = "9933FF", opacity = 0.5}
---@param rgba string `rrggbb` 或 `rrggbbaa` 格式的十六进制颜色字符串
---@return {color: string, opacity: number}
function serialize_rgba(rgba)
    -- 提取透明度字节（第 7-8 位），如果不存在则默认为 "ff"（完全不透明）
    local a = rgba:sub(7, 8)
    return {
        -- 将 RGB 转换为 BGR 顺序（ASS 绘图要求）
        color = rgba:sub(5, 6) .. rgba:sub(3, 4) .. rgba:sub(1, 2),
        -- 透明度：将十六进制值转换为 0~1 的浮点数
        opacity = clamp(0, tonumber(#a == 2 and a or 'ff', 16) / 255, 1),
    }
end

-- ==============================================================================
-- 4. 字符串处理函数
-- ==============================================================================

-- 去除字符串首尾的空白字符（空格、制表符、换行等）
---@param str string
---@return string
function trim(str)
    return str:match('^%s*(.-)%s*$')
end

-- 去除字符串末尾的指定字符（连续移除）
-- 例如 trim_end("hello///", "/") → "hello"
---@param str string
---@param char string 要移除的字符（只取第一个字节）
---@return string
function trim_end(str, char)
    local char, end_i = char:byte(), 0
    -- 从末尾向前扫描，找到第一个不是 char 的位置
    for i = #str, 1, -1 do
        if str:byte(i) ~= char then
            end_i = i
            break
        end
    end
    return str:sub(1, end_i)
end

-- 按指定模式分割字符串为数组
-- 与 string:split() 不同，此函数保留分隔符之间的空字符串
-- 例如 split("a,b,c", ",") → {"a", "b", "c"}
-- 例如 split("a,,c", ",") → {"a", "", "c"}
---@param str string
---@param pattern string 分隔符模式（Lua 模式字符串）
---@return string[]
function split(str, pattern)
    local list = {}
    local full_pattern = '(.-)' .. pattern
    local last_end = 1
    local start_index, end_index, capture = str:find(full_pattern, 1)

    while start_index do
        list[#list + 1] = capture
        last_end = end_index + 1
        start_index, end_index, capture = str:find(full_pattern, last_end)
    end

    -- 处理最后一个分隔符之后的剩余部分
    if last_end <= (#str + 1) then
        capture = str:sub(last_end)
        list[#list + 1] = capture
    end

    return list
end

-- 逗号分割工具：处理配置项和消息输入中常见的逗号分隔列表
-- 支持三种输入类型：nil → {}，字符串 → 按逗号分割，字符串数组 → 原样返回
-- 空字符串或纯空白字符串 → {}
---@param input string|string[]|nil
---@return string[]
function comma_split(input)
    if not input then return {} end
    if type(input) == 'table' then return itable_map(input, tostring) end
    local str = tostring(input)
    -- 如果全是空白字符，返回空表；否则按逗号分割（忽略逗号前后的空格）
    return str:match('^%s*$') and {} or split(str, ' *, *')
end

-- 查找子串在字符串中最后一次出现的位置
-- 若未找到则返回 nil
-- 例如 string_last_index_of("hello world", "l") → 10（第二个 l 的位置）
---@param str string
---@param sub string
---@return integer|nil
function string_last_index_of(str, sub)
    local sub_length = #sub
    for i = #str, 1, -1 do
        for j = 1, sub_length do
            if str:byte(i + j - 1) ~= sub:byte(j) then break end
            if j == sub_length then return i end
        end
    end
end

-- 生成不区分大小写的匹配模式
-- 用于字符串替换时忽略大小写
-- 例如 anycase("foo") → "[fF][oO][oO]"
---@param str string
---@return string
function anycase(str)
    return string.gsub(str, '%a', function(c)
        return string.format('[%s%s]', c:lower(), c:upper())
    end)
end

-- 转义正则表达式中的特殊字符
-- 使字符串可以安全地用于 Lua 模式匹配中的 literal 匹配
-- 转义字符：() . + - * ? [ ] ^ $ %
---@param value string
---@return string
function regexp_escape(value)
    return string.gsub(value, '[%(%)%.%+%-%*%?%[%]%^%$%%]', '%%%1')
end

-- ==============================================================================
-- 5. 表操作函数 (Table Utilities)
-- 命名约定：itable_* 前缀表示这些函数操作的是数组表（列表）
-- ==============================================================================

-- 查找元素在数组中的索引（线性搜索）
-- 如果未找到返回 nil，找到则返回索引（1-based）
---@param itable table
---@param value any
---@return integer|nil
function itable_index_of(itable, value)
    for index = 1, #itable do
        if itable[index] == value then return index end
    end
end

-- 检查数组中是否包含某元素（调用 itable_index_of 判断）
---@param itable table
---@param value any
---@return boolean
function itable_has(itable, value)
    return itable_index_of(itable, value) ~= nil
end

-- 在数组中查找满足条件的元素
-- 支持从指定位置开始/结束搜索，支持反向搜索
-- 返回：索引和值（若找到），否则返回 nil, nil
---@param itable table
---@param compare fun(value: any, index: number): boolean|integer|string|nil
---@param from? number 起始索引，默认为 1
---@param to? number 结束索引，默认为 #itable
---@return number|nil index
---@return any|nil value
function itable_find(itable, compare, from, to)
    from, to = from or 1, to or #itable
    -- 根据 from 和 to 的大小决定遍历方向
    for index = from, to, from < to and 1 or -1 do
        if index > 0 and index <= #itable and compare(itable[index], index) then
            return index, itable[index]
        end
    end
end

-- 过滤数组：保留 decider 返回 true 的元素
-- 返回一个新数组，原数组不变
---@param itable table
---@param decider fun(value: any, index: number): boolean|integer|string|nil
---@return table
function itable_filter(itable, decider)
    local filtered = {}
    for index, value in ipairs(itable) do
        if decider(value, index) then filtered[#filtered + 1] = value end
    end
    return filtered
end

-- 从数组中删除指定值的元素（删除所有匹配项）
-- 直接修改原数组，返回修改后的数组
---@param itable table
---@param value any
---@return table
function itable_delete_value(itable, value)
    for index = 1, #itable, 1 do
        if itable[index] == value then table.remove(itable, index) end
    end
    return itable
end

-- 映射数组：对每个元素应用 transformer 函数，返回新数组
-- 新数组与旧数组长度相同，每个元素是 transformer 的返回值
---@param itable table
---@param transformer fun(value: any, index: number) : any
---@return table
function itable_map(itable, transformer)
    local result = {}
    for index, value in ipairs(itable) do
        result[index] = transformer(value, index)
    end
    return result
end

-- 数组切片：提取 [start_pos, end_pos] 范围内的元素
-- 支持负索引（从末尾计数）：-1 表示最后一个元素
---@param itable table
---@param start_pos? integer 默认为 1
---@param end_pos? integer 默认为 #itable
---@return table
function itable_slice(itable, start_pos, end_pos)
    start_pos = start_pos and start_pos or 1
    end_pos = end_pos and end_pos or #itable

    -- 负索引处理：-1 → #itable，-2 → #itable-1
    if end_pos < 0 then end_pos = #itable + end_pos + 1 end
    if start_pos < 0 then start_pos = #itable + start_pos + 1 end

    local new_table = {}
    for index, value in ipairs(itable) do
        if index >= start_pos and index <= end_pos then
            new_table[#new_table + 1] = value
        end
    end
    return new_table
end

-- 连接多个数组为一个数组
-- 支持 nil 参数（自动跳过）
-- 返回一个新数组，原数组不变
---@generic T
---@param ...T[]|nil
---@return T[]
function itable_join(...)
    local args, result = {...}, {}
    for i = 1, select('#', ...) do
        if args[i] then
            for _, value in ipairs(args[i]) do
                result[#result + 1] = value
            end
        end
    end
    return result
end

-- 追加一个数组的所有元素到目标数组
-- 直接修改 target 数组，不返回新数组
---@param target any[]
---@param source any[]
function itable_append(target, source)
    for _, value in ipairs(source) do
        target[#target + 1] = value
    end
    return target
end

-- 清空数组：将所有元素置为 nil
-- 注意：只是将元素置 nil，表本身仍然存在
---@param itable table
function itable_clear(itable)
    for i = #itable, 1, -1 do
        itable[i] = nil
    end
end

-- ==============================================================================
-- 6. 表操作函数 (Table Utilities) — 哈希表专用
-- ==============================================================================

-- 返回哈希表的所有键（keys）
---@generic T
---@param input table<T, any>
---@return T[]
function table_keys(input)
    local keys = {}
    for key, _ in pairs(input) do
        keys[#keys + 1] = key
    end
    return keys
end

-- 返回哈希表的所有值（values）
---@generic T
---@param input table<any, T>
---@return T[]
function table_values(input)
    local values = {}
    for _, value in pairs(input) do
        values[#values + 1] = value
    end
    return values
end

-- ==============================================================================
-- 7. 表合并与复制函数
-- ==============================================================================

-- 将一个或多个源表的所有键值对合并到目标表
-- 后面的源表会覆盖前面同名的键
-- 直接修改目标表，返回目标表
---@generic T: table<any, any>
---@param target T
---@param ... T|nil
---@return T
function table_assign(target, ...)
    local args = {...}
    for i = 1, select('#', ...) do
        if type(args[i]) == 'table' then
            for key, value in pairs(args[i]) do
                target[key] = value
            end
        end
    end
    return target
end

-- 选择性地从源表复制指定属性到目标表
-- 只复制 props 列表中指定的键
---@generic T: table<any, any>
---@param target T
---@param source T
---@param props string[]
---@return T
function table_assign_props(target, source, props)
    for _, name in ipairs(props) do
        target[name] = source[name]
    end
    return target
end

-- 从源表复制属性到目标表，但排除 props 集合中的键
-- 即：只复制 props 中不存在的键
---@generic T: table<any, any>
---@param target T
---@param source T
---@param props table<string, boolean>
---@return T
function table_assign_exclude(target, source, props)
    for key, value in pairs(source) do
        if not props[key] then
            target[key] = value
        end
    end
    return target
end

-- 复制表（浅拷贝）——等价于 table_assign({}, input)
-- 保留泛型类型信息
---@generic T: table<any, any>
---@param input T
---@return T
function table_copy(input)
    return table_assign({}, input)
end

-- ==============================================================================
-- 8. 集合工具函数
-- ==============================================================================

-- 将数组转换为集合（set），即 {value: true}
-- 用于快速判重和成员测试
---@param values any[]
---@return table<any, boolean>
function create_set(values)
    local result = {}
    for _, value in ipairs(values) do
        result[value] = true
    end
    return result
end

-- ==============================================================================
-- 9. 键值对列表序列化
-- ==============================================================================

-- 将 "key1=value1,key2=value2" 格式的字符串解析为 {key1 = value1, key2 = value2}
-- 支持自定义值清洗函数
-- 例如 serialize_key_value_list("foo=1,bar=2") → {foo = "1", bar = "2"}
---@generic T: any
---@param input string
---@param value_sanitizer? fun(value: string, key: string): T 值清洗函数，默认为原样返回
---@return table<string, T>
function serialize_key_value_list(input, value_sanitizer)
    local result, sanitize = {}, value_sanitizer or function(value) return value end
    for _, key_value_pair in ipairs(comma_split(input)) do
        -- 匹配格式：键名 = 值（键名由字母、数字、下划线组成，值由字母、数字、小数点组成）
        local key, value = key_value_pair:match('^([%w_]+)=([%w%.]+)$')
        if key and value then
            result[key] = sanitize(value, key)
        end
    end
    return result
end

-- ==============================================================================
-- 10. 快捷键创建函数 (Shortcut)
-- ==============================================================================

-- 创建快捷键对象（Shortcut）
-- 支持 key 参数包含修饰键（如 "ctrl+t"），也支持单独传入 modifiers 参数
-- 返回的 Shortcut 包含 id（唯一标识）、key、modifiers、alt/ctrl/shift 布尔值
---@param key string 按键名，或 "modifiers+key" 组合
---@param modifiers? string 修饰键（如 "ctrl"、"alt+shift"）
---@return Shortcut
function create_shortcut(key, modifiers)
    key = key:lower()

    -- 如果 key 中本身包含 +，从中提取修饰键部分
    local last_plus_in_key = string_last_index_of(key, '+')
    if last_plus_in_key then
        modifiers = string.sub(key, 1, last_plus_in_key - 1)
        key = string.sub(key, last_plus_in_key + 1)
    end

    local id_parts, modifiers_set
    if modifiers then
        -- 多个修饰键按字母排序，保证 id 的一致性
        id_parts = split(modifiers:lower(), '+')
        table.sort(id_parts, function(a, b) return a < b end)
        modifiers_set = create_set(id_parts)
        modifiers = table.concat(id_parts, '+')
    else
        id_parts, modifiers, modifiers_set = {}, nil, {}
    end
    id_parts[#id_parts + 1] = key

    -- 返回 Shortcut 表，同时将 alt/ctrl/shift 作为字段直接暴露
    return table_assign(
        {id = table.concat(id_parts, '+'), key = key, modifiers = modifiers},
        modifiers_set
    )
end

-- ==============================================================================
-- 11. 缓动函数 (Easing Functions)
-- 用于动画中的平滑过渡
-- ==============================================================================

-- 缓出四次方：ease_out_quart
-- 曲线：先快后慢，在接近终点时减速
-- 公式：1 - (1 - t)^4
---@param x number 0~1 之间的进度值
---@return number 缓动后的值（0~1）
function ease_out_quart(x)
    return 1 - ((1 - x) ^ 4)
end

-- 缓出六次方：ease_out_sext
-- 比 ease_out_quart 更"柔和"，减速更明显
-- 公式：1 - (1 - t)^6
---@param x number 0~1 之间的进度值
---@return number 缓动后的值（0~1）
function ease_out_sext(x)
    return 1 - ((1 - x) ^ 6)
end

-- ==============================================================================
-- 12. 简单类系统 (Class System)
-- 采用元表（metatable）实现面向对象
-- 所有类继承自 Class，支持 new() 和 init() 构造模式
-- ==============================================================================

---@class Class
Class = {}

-- 创建一个新实例
-- 流程：创建空对象 → 设置元表（__index = self）→ 调用 init() → 返回对象
function Class:new(...)
    local object = setmetatable({}, {__index = self})
    object:init(...)
    return object
end

-- 构造函数（子类应覆盖此方法）
function Class:init(...) end

-- 销毁函数（子类应覆盖此方法，用于清理资源）
function Class:destroy() end

-- 类工厂函数：创建一个继承自 parent 的新类
-- 如果 parent 为 nil，则继承自 Class
---@param parent? Class 父类，默认为 Class
---@return Class
function class(parent)
    return setmetatable({}, {__index = parent or Class})
end

-- ==============================================================================
-- 13. 环形缓冲区 (CircularBuffer)
-- 一种固定大小的队列，当缓冲区满时，新数据会覆盖最旧的数据
-- 常用于存储鼠标位置历史、速度计算等场景
-- ==============================================================================

---@class CircularBuffer<T> : Class
---@field max_size integer 最大容量
---@field pos integer 当前写入位置（循环索引）
---@field data table 存储数据的数组
CircularBuffer = class()

-- 创建一个新的环形缓冲区
---@param max_size integer 最大容量
---@return CircularBuffer
function CircularBuffer:new(max_size)
    return Class.new(self, max_size) --[[@as CircularBuffer]]
end

-- 构造函数
function CircularBuffer:init(max_size)
    self.max_size = max_size
    self.pos = 0
    self.data = {}
end

-- 插入一个元素
-- 如果缓冲区已满，覆盖最旧的元素
function CircularBuffer:insert(item)
    self.pos = self.pos % self.max_size + 1
    self.data[self.pos] = item
end

-- 获取第 i 个元素（1-based，按插入顺序）
-- 如果 i > #data，返回 nil
function CircularBuffer:get(i)
    if i > #self.data then return nil end
    -- (pos + i - 1) % #data + 1 计算实际的数组索引
    return self.data[(self.pos + i - 1) % #self.data + 1]
end

-- 迭代器：按插入顺序遍历所有元素
local function iter(self, i)
    if i == #self.data then return nil end
    i = i + 1
    return i, self:get(i)
end

function CircularBuffer:iter()
    return iter, self, 0
end

-- 迭代器：按插入顺序的逆序遍历所有元素（从最新到最旧）
local function iter_rev(self, i)
    if i == 1 then return nil end
    i = i - 1
    return i, self:get(i)
end

function CircularBuffer:iter_rev()
    return iter_rev, self, #self.data + 1
end

-- 返回最新插入的元素（head）
function CircularBuffer:head()
    return self.data[self.pos]
end

-- 返回最旧的元素（tail）
function CircularBuffer:tail()
    if #self.data < 1 then return nil end
    return self.data[self.pos % #self.data + 1]
end

-- 清空缓冲区
function CircularBuffer:clear()
    itable_clear(self.data)
    self.pos = 0
end

-- ==============================================================================
-- 导出：所有函数均为全局函数，在 Lua 环境中直接可用
-- 本文件不返回任何值，所有函数均通过全局作用域暴露
-- ==============================================================================