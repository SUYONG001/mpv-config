-- ==============================================================================
-- fzy.lua — 模糊搜索算法实现 (Lua 版)
-- ==============================================================================
-- 功能概述：
--   1. 实现 fzy 字符串模糊匹配算法（用于菜单搜索）
--   2. 检查搜索词（needle）是否为目标字符串（haystack）的子序列
--   3. 计算匹配质量分数（分数越高匹配越好）
--   4. 返回匹配字符在目标字符串中的位置（用于高亮显示）
--   5. 支持批量过滤和排序
-- ==============================================================================
-- 算法特点：
--   - 基于动态规划（DP）计算最优匹配
--   - 对特殊字符（斜杠、下划线、点、大写字母）给予额外加分
--   - 连续匹配的字符获得更高分数
--   - 支持大小写敏感/不敏感模式
-- ==============================================================================
-- 许可证：MIT License (c) 2020 Seth Warn
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 评分常量定义
-- ==============================================================================

-- 开头匹配的罚分（每个字符 -0.005）
local SCORE_GAP_LEADING = -0.005

-- 尾部匹配的罚分（每个字符 -0.005）
local SCORE_GAP_TRAILING = -0.005

-- 中间不匹配的罚分（每个字符 -0.01）
local SCORE_GAP_INNER = -0.01

-- 连续匹配的奖励（+1.0）
local SCORE_MATCH_CONSECUTIVE = 1.0

-- 斜杠后匹配的奖励（如路径分隔符后，+0.9）
local SCORE_MATCH_SLASH = 0.9

-- 单词边界匹配的奖励（如 - _ 空格后，+0.8）
local SCORE_MATCH_WORD = 0.8

-- 大写字母匹配的奖励（驼峰命名中，+0.7）
local SCORE_MATCH_CAPITAL = 0.7

-- 点后匹配的奖励（如文件扩展名前，+0.6）
local SCORE_MATCH_DOT = 0.6

-- 最高分（完全匹配时返回）
local SCORE_MAX = math.huge

-- 最低分（无效匹配时返回）
local SCORE_MIN = -math.huge

-- 最大匹配长度（超过此长度不计算）
local MATCH_MAX_LENGTH = 1024

-- ==============================================================================
-- 2. fzy 模块定义
-- ==============================================================================

local fzy = {}

-- ==============================================================================
-- 3. 子序列检测 (has_match)
-- 检查 needle 是否是 haystack 的子序列
-- ==============================================================================

-- 检查 needle 是否为 haystack 的子序列
-- 通常在调用 score 或 positions 之前使用
---
-- Args:
--   needle (string)        : 搜索词
--   haystack (string)      : 目标字符串
--   case_sensitive (bool)  : 是否大小写敏感（默认为 false）
--
-- Returns:
--   bool
function fzy.has_match(needle, haystack, case_sensitive)
    -- 如果不区分大小写，全部转为小写
    if not case_sensitive then
        needle = string.lower(needle)
        haystack = string.lower(haystack)
    end

    -- 贪心匹配：遍历 needle 中的每个字符，在 haystack 中顺序查找
    local j = 1
    for i = 1, string.len(needle) do
        -- 从位置 j 开始查找当前字符
        j = string.find(haystack, needle:sub(i, i), j, true)
        if not j then
            return false  -- 找不到则匹配失败
        else
            j = j + 1     -- 找到则移动到下一个位置继续
        end
    end

    return true
end

-- ==============================================================================
-- 4. 辅助函数：字符类型判断
-- ==============================================================================

-- 判断字符是否为小写字母
local function is_lower(c)
    return c:match("%l")
end

-- 判断字符是否为大写字母
local function is_upper(c)
    return c:match("%u")
end

-- ==============================================================================
-- 5. 预计算加分 (precompute_bonus)
-- 为 haystack 的每个位置计算匹配加分
-- 加分规则：
--   - 位于斜杠后  ：+0.9
--   - 位于 - _ 空格后：+0.8（单词边界）
--   - 位于点后  ：+0.6
--   - 大写字母前一个小写字母：+0.7（驼峰命名）
-- ==============================================================================

local function precompute_bonus(haystack)
    local match_bonus = {}

    local last_char = "/"
    for i = 1, string.len(haystack) do
        local this_char = haystack:sub(i, i)

        if last_char == "/" or last_char == "\\" then
            match_bonus[i] = SCORE_MATCH_SLASH
        elseif last_char == "-" or last_char == "_" or last_char == " " then
            match_bonus[i] = SCORE_MATCH_WORD
        elseif last_char == "." then
            match_bonus[i] = SCORE_MATCH_DOT
        elseif is_lower(last_char) and is_upper(this_char) then
            match_bonus[i] = SCORE_MATCH_CAPITAL
        else
            match_bonus[i] = 0
        end

        last_char = this_char
    end

    return match_bonus
end

-- ==============================================================================
-- 6. 核心计算 (compute)
-- 使用动态规划计算匹配分数矩阵
-- ==============================================================================

-- 动态规划矩阵说明：
--   D[i][j] = 匹配到 needle[i] 和 haystack[j] 时的最优分数（必须以 haystack[j] 结尾）
--   M[i][j] = 匹配到 needle[i] 时，haystack[1..j] 范围内的最优分数
--
--   转移方程：
--   当 needle[i] == haystack[j] 时：
--     D[i][j] = max(
--       M[i-1][j-1] + match_bonus[j],  -- 从上一个匹配继续
--       D[i-1][j-1] + SCORE_MATCH_CONSECUTIVE  -- 连续匹配
--     )
--   否则：
--     D[i][j] = SCORE_MIN
--
--   M[i][j] = max(M[i][j-1] + gap_score, D[i][j])
local function compute(needle, haystack, D, M, case_sensitive)
    -- 注意：加分必须在大小写转换之前计算，因为大小写信息用于驼峰命名加分
    local match_bonus = precompute_bonus(haystack)

    local n = string.len(needle)
    local m = string.len(haystack)

    -- 如果不区分大小写，全部转为小写
    if not case_sensitive then
        needle = string.lower(needle)
        haystack = string.lower(haystack)
    end

    -- 预提取 haystack 的所有字符（避免在循环中反复提取）
    local haystack_chars = {}
    for i = 1, m do
        haystack_chars[i] = haystack:sub(i, i)
    end

    -- 逐行计算 DP 矩阵
    for i = 1, n do
        D[i] = {}
        M[i] = {}

        local prev_score = SCORE_MIN
        -- 最后一个字符使用尾部罚分，其他使用中间罚分
        local gap_score = i == n and SCORE_GAP_TRAILING or SCORE_GAP_INNER
        local needle_char = needle:sub(i, i)

        for j = 1, m do
            if needle_char == haystack_chars[j] then
                local score = SCORE_MIN

                if i == 1 then
                    -- 第一个字符：起始位置之前的字符都算作"开头罚分"
                    score = ((j - 1) * SCORE_GAP_LEADING) + match_bonus[j]
                elseif j > 1 then
                    -- 从两个来源取最优：
                    --   a) 从上一个匹配继续（使用 match_bonus）
                    --   b) 连续匹配（使用 SCORE_MATCH_CONSECUTIVE）
                    local a = M[i - 1][j - 1] + match_bonus[j]
                    local b = D[i - 1][j - 1] + SCORE_MATCH_CONSECUTIVE
                    score = math.max(a, b)
                end

                D[i][j] = score
                prev_score = math.max(score, prev_score + gap_score)
                M[i][j] = prev_score
            else
                D[i][j] = SCORE_MIN
                prev_score = prev_score + gap_score
                M[i][j] = prev_score
            end
        end
    end
end

-- ==============================================================================
-- 7. 计算匹配分数 (score)
-- ==============================================================================

-- 计算匹配分数（分数越高表示匹配越好）
--
-- Args:
--   needle (string)        : 搜索词（必须是 haystack 的子序列）
--   haystack (string)      : 目标字符串
--   case_sensitive (bool)  : 是否大小写敏感（默认为 false）
--
-- Returns:
--   number: 匹配分数。使用 get_score_min() 和 get_score_max() 获取边界值
function fzy.score(needle, haystack, case_sensitive)
    local n = string.len(needle)
    local m = string.len(haystack)

    -- 无效匹配情况
    if n == 0 or m == 0 or m > MATCH_MAX_LENGTH or n > m then
        return SCORE_MIN
    elseif n == m then
        -- 完全相同（长度相等），返回最高分
        return SCORE_MAX
    else
        local D = {}
        local M = {}
        compute(needle, haystack, D, M, case_sensitive)
        return M[n][m]
    end
end

-- ==============================================================================
-- 8. 计算匹配位置 (positions)
-- 返回 needle 中的每个字符在 haystack 中的位置索引
-- ==============================================================================

-- 计算 fzy 匹配的位置
--
-- 确定 needle 中每个字符在 haystack 中的最优匹配位置
--
-- Args:
--   needle (string)        : 搜索词（必须是 haystack 的子序列）
--   haystack (string)      : 目标字符串
--   case_sensitive (bool)  : 是否大小写敏感（默认为 false）
--
-- Returns:
--   {int,...}: 位置数组，positions[n] 表示 needle 第 n 个字符在 haystack 中的位置
--   number: 匹配分数（同 score 返回值）
function fzy.positions(needle, haystack, case_sensitive)
    local n = string.len(needle)
    local m = string.len(haystack)

    -- 无效匹配情况
    if n == 0 or m == 0 or m > MATCH_MAX_LENGTH or n > m then
        return {}, SCORE_MIN
    elseif n == m then
        -- 完全相同：返回所有位置
        local consecutive = {}
        for i = 1, n do
            consecutive[i] = i
        end
        return consecutive, SCORE_MAX
    end

    local D = {}
    local M = {}
    compute(needle, haystack, D, M, case_sensitive)

    -- 反向追踪最优路径
    local positions = {}
    local match_required = false
    local j = m

    for i = n, 1, -1 do
        while j >= 1 do
            -- 找到一个有效的匹配点
            if D[i][j] ~= SCORE_MIN and (match_required or D[i][j] == M[i][j]) then
                -- 判断是否需要强制连续匹配
                match_required = (i ~= 1) and (j ~= 1) and (
                    M[i][j] == D[i - 1][j - 1] + SCORE_MATCH_CONSECUTIVE
                )
                positions[i] = j
                j = j - 1
                break
            else
                j = j - 1
            end
        end
    end

    return positions, M[n][m]
end

-- ==============================================================================
-- 9. 批量过滤 (filter)
-- 对一组 haystack 应用 has_match 和 positions
-- ==============================================================================

-- 对 haystacks 数组应用 has_match 和 positions
--
-- Args:
--   needle (string)        : 搜索词
--   haystack ({string, ...}): 目标字符串数组
--   case_sensitive (bool)  : 是否大小写敏感（默认为 false）
--
-- Returns:
--   {{idx, positions, score}, ...}: 每个匹配项返回一个条目，包含：
--     - idx     : 在 haystacks 中的索引
--     - positions : positions 返回值
--     - score   : score 返回值
function fzy.filter(needle, haystacks, case_sensitive)
    local result = {}

    for i, line in ipairs(haystacks) do
        if fzy.has_match(needle, line, case_sensitive) then
            local p, s = fzy.positions(needle, line, case_sensitive)
            table.insert(result, {i, p, s})
        end
    end

    return result
end

-- ==============================================================================
-- 10. 边界值查询函数
-- ==============================================================================

-- 返回 score 函数的最低值
-- 特殊情况：空 needle 或 needle/haystack 超过最大长度时返回此值
function fzy.get_score_min()
    return SCORE_MIN
end

-- 返回 score 函数的最高值（完全匹配时）
function fzy.get_score_max()
    return SCORE_MAX
end

-- 返回最大评估长度
function fzy.get_max_length()
    return MATCH_MAX_LENGTH
end

-- 返回正常匹配的最低分数（高于此分数表示有效的非空匹配）
function fzy.get_score_floor()
    return MATCH_MAX_LENGTH * SCORE_GAP_INNER
end

-- 返回非精确匹配的最高分数
function fzy.get_score_ceiling()
    return MATCH_MAX_LENGTH * SCORE_MATCH_CONSECUTIVE
end

-- 返回当前实现名称
function fzy.get_implementation_name()
    return "lua"
end

-- ==============================================================================
-- 11. 导出 fzy 模块
-- ==============================================================================

return fzy