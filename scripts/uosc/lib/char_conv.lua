-- ==============================================================================
-- char_conv.lua — 字符罗马化转换模块
-- ==============================================================================
-- 功能概述：
--   1. 将非拉丁文字（中文、日文、韩文等）转换为对应的拉丁字母表示
--   2. 用于菜单搜索时的模糊匹配：用户输入拉丁字母也能匹配到非拉丁文字
--   3. 支持两种转换模式：连字模式（完整词转换）和首字母模式（逐字母转换）
--   4. 从 char-conv/ 目录加载语言映射 JSON 文件
-- ==============================================================================
-- 使用场景：
--   当用户在搜索框中输入 "kurumi" 时，能匹配到日文标题 "胡桃（くるみ）"
--   当用户输入 "sakura" 时，能匹配到中文标题 "樱花"
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 加载文本工具模块（提供 utf8_iter、utf8_length 等函数）
require('lib/text')

-- ==============================================================================
-- 1. 加载罗马化映射数据
-- ==============================================================================

-- 罗马化映射文件所在的目录（char-conv/ 位于 uosc 脚本目录下）
local char_dir = mp.get_script_directory() .. '/char-conv/'
-- 存储所有加载的映射数据
local data = {}

-- 获取当前语言列表（从 uosc.conf 的 languages 配置读取）
local languages = get_languages()

-- 遍历所有语言，尝试加载对应的 JSON 映射文件
-- 文件名格式：语言小写 + .json，如 zh.json（中文）、ja.json（日文）
for _, lang in ipairs(languages) do
    table_assign(data, get_locale_from_json(char_dir .. lang:lower() .. '.json'))
end

-- ==============================================================================
-- 2. 构建罗马化映射表 (romanization)
-- 将 JSON 中每个键对应的所有字符映射到该键（拉丁字母）
-- ==============================================================================

local romanization = {}

-- 构建罗马化映射表
local function get_romanization_table()
    -- 遍历 data 表中所有键值对
    -- 键：拉丁字母（如 'a', 'b', 'ka', 'sa' 等）
    -- 值：一个包含多个字符的字符串（所有映射到该拉丁字母的 Unicode 字符）
    for k, v in pairs(data) do
        -- 遍历值字符串中的每个 Unicode 字符
        for _, char in utf8_iter(v) do
            -- 建立从 Unicode 字符到拉丁字母的映射
            romanization[char] = k
        end
    end
end
get_romanization_table()

-- ==============================================================================
-- 3. 检查是否需要罗马化 (need_romanization)
-- 如果 romanization 表非空，说明当前语言需要罗马化支持
-- ==============================================================================

function need_romanization()
    return next(romanization) ~= nil
end

-- ==============================================================================
-- 4. 核心转换函数 (char_conv)
-- 将输入字符串中的字符转换为对应的拉丁字母表示
-- ==============================================================================

---@param chars string 要转换的字符串
---@param use_ligature boolean true=连字模式（完整词转换），false=首字母模式
---@param has_separator? string 分隔符（默认空格）
---@return string, table 转换后的字符串，以及对应的罗马化列表（用于高亮定位）
function char_conv(chars, use_ligature, has_separator)
    local separator = has_separator or ' '
    local length = 0
    local char_conv, sp, cache = {}, {}, {}
    local roman_list = {}
    local chars_length = utf8_length(chars)
    local concat = table.concat

    -- 遍历输入字符串的每个 Unicode 字符
    for _, char in utf8_iter(chars) do
        -- 查找映射表中的对应项，如果不存在则保留原字符
        local match = romanization[char] or char
        roman_list[#roman_list + 1] = match

        if use_ligature then
            -- ============================================================
            -- 连字模式：直接将每个字符转换为对应的拉丁字母
            -- 用于完整词匹配（如 "た" → "ta"）
            -- ============================================================
            char_conv[#char_conv + 1] = match
        else
            -- ============================================================
            -- 首字母模式：将连续的非空格字符组合成一个词，取每个词的首字母
            -- 用于首字母匹配（如 "たまこ" → "tmk"）
            -- ============================================================
            length = length + 1

            if #char <= 2 then
                -- 普通字符（1~2 字节，如英文字母、拉丁扩展字符）
                if (char ~= ' ' and length ~= chars_length) then
                    -- 非空格且非最后一个字符：缓存到当前词中
                    cache[#cache + 1] = match
                elseif (char == ' ' or length == chars_length) then
                    -- 遇到空格或到达末尾：完成当前词
                    if length == chars_length then
                        -- 最后一个字符也加入缓存
                        cache[#cache + 1] = match
                    end
                    -- 将当前词的所有字符连接，存入 sp 列表
                    sp[#sp + 1] = concat(cache)
                    itable_clear(cache)  -- 清空缓存，开始下一个词
                end
            else
                -- 宽字符（3~4 字节，如中文、日文、韩文等）
                -- 每个宽字符单独作为一个词
                if next(cache) ~= nil then
                    -- 如果缓存中有之前的字符，先完成这个词
                    sp[#sp + 1] = concat(cache)
                    itable_clear(cache)
                end
                -- 将当前宽字符加入 sp 列表（作为单独的词）
                sp[#sp + 1] = match
            end
        end
    end

    if use_ligature then
        -- 连字模式：直接返回所有转换后的字符连接
        return concat(char_conv), roman_list
    else
        -- 首字母模式：用分隔符连接所有词（每个词只取首字母）
        -- 注意：这里返回的是每个词的所有字符，实际使用时会取首字母
        return concat(sp, separator), roman_list
    end
end

return char_conv