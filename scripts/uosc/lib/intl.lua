-- ==============================================================================
-- intl.lua — 国际化/多语言支持模块
-- ==============================================================================
-- 功能概述：
--   1. 加载多语言翻译文件（JSON 格式），为 uosc 提供多语言支持
--   2. 根据 uosc.conf 中的 languages 配置决定语言优先级
--   3. 支持从 intl/ 目录加载内置语言包，也支持加载自定义 JSON 文件
--   4. 提供 t() 翻译函数，支持带参数的格式化翻译
--   5. 翻译结果带缓存，避免重复查找
-- ==============================================================================
-- 语言加载顺序：
--   1. 从 languages 配置中解析语言列表（如 "slang,en,zh-hans"）
--   2. 如果包含 "slang"，则替换为 mpv 的 slang 属性值（如 "chi"）
--   3. 按优先级从高到低加载：后加载的覆盖先加载的
--   4. 语言名称可以是 .json 文件路径、'en'（重置为空，用于降级）或语言代码
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 初始化变量
-- ==============================================================================

-- 语言文件所在的目录（uosc/intl/）
local intl_dir = mp.get_script_directory() .. '/intl/'

-- 存储当前加载的所有翻译数据（键值对：原始文本 → 翻译文本）
local locale = {}

-- 翻译缓存：已翻译的文本缓存，避免重复格式化
-- 缓存键格式：text|arg（如 "Play/Pause|" 或 "Chapter %s|5"）
local cache = {}

-- ==============================================================================
-- 2. 获取语言列表 (get_languages)
-- 解析 uosc.conf 中的 languages 配置
-- ==============================================================================

-- 参考：Windows 支持的语言列表
-- https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/supported-languages?pivots=store-installer-msix#list-of-supported-languages
function get_languages()
    local languages = {}

    -- 遍历 languages 配置（逗号分隔的语言代码或路径）
    for _, lang in ipairs(comma_split(options.languages)) do
        if (lang == 'slang') then
            -- 'slang' 是特殊关键词：替换为 mpv 的 slang 属性值（字幕语言偏好）
            -- 例如 mpv.conf 中设置了 slang=chi,eng，则 slang 会被替换为 "chi,eng"
            local slang = mp.get_property_native('slang')
            if slang then
                -- 将 slang 中的每个语言代码追加到列表
                itable_append(languages, slang)
            end
        else
            -- 普通语言代码或 .json 文件路径
            languages[#languages + 1] = lang
        end
    end

    return languages
end

-- ==============================================================================
-- 3. 从 JSON 文件加载翻译数据 (get_locale_from_json)
-- ==============================================================================

---@param path string 文件路径（支持 mpv 路径扩展，如 ~~/my-lang.json）
---@return table|nil 解析后的 JSON 表，如果文件不存在或无效则返回 nil
function get_locale_from_json(path)
    -- 展开路径（如 ~~/ → 配置目录）
    local expand_path = mp.command_native({'expand-path', path})

    -- 检查文件是否存在
    local meta, meta_error = utils.file_info(expand_path)
    if not meta or not meta.is_file then
        return nil
    end

    -- 打开文件
    local json_file = io.open(expand_path, 'r')
    if not json_file then
        return nil
    end

    -- 读取全部内容
    local json = json_file:read('*all')
    json_file:close()

    -- 解析 JSON
    local json_table = utils.parse_json(json)
    return json_table
end

-- ==============================================================================
-- 4. 翻译函数 (t)
-- 根据当前语言环境翻译文本
-- ==============================================================================

---@param text string 要翻译的原始文本（英语）
---@param a string|nil 格式化参数（用于 {占位符}）
---@return string 翻译后的文本
function t(text, a)
    if not text then
        return ''
    end

    -- 构建缓存键
    local key = text
    if a then
        key = key .. '|' .. a
    end

    -- 如果缓存中有，直接返回
    if cache[key] then
        return cache[key]
    end

    -- 查找翻译：如果在 locale 中有对应的翻译则使用，否则使用原始文本
    -- string.format 用于替换参数（如 "Chapter %s" → "Chapter 5"）
    cache[key] = string.format(locale[text] or text, a or '')

    return cache[key]
end

-- ==============================================================================
-- 5. 加载语言数据
-- ==============================================================================

-- 获取语言列表（按优先级从高到低）
local languages = get_languages()

-- 从高优先级到低优先级加载（后加载的覆盖先加载的）
for i = #languages, 1, -1 do
    lang = languages[i]

    if (lang:match('.json$')) then
        -- 如果语言名称以 .json 结尾，直接作为文件路径加载
        -- 支持加载自定义 JSON 文件，如 ~~/my-lang.json
        table_assign(locale, get_locale_from_json(lang))
    elseif (lang == 'en') then
        -- 'en' 是特殊关键词：重置 locale 为空
        -- 当用户想完全使用英语时，清除之前加载的所有翻译
        locale = {}
    else
        -- 普通语言代码：从 intl/ 目录加载对应的 JSON 文件
        -- 如 'zh-hans' → intl/zh-hans.json
        table_assign(locale, get_locale_from_json(intl_dir .. lang:lower() .. '.json'))
    end
end

-- ==============================================================================
-- 6. 导出 t 函数
-- ==============================================================================

return {t = t}