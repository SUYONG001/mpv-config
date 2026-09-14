-- ==============================================================================
-- autoload.lua — 自动加载同目录文件到播放列表
-- ==============================================================================
-- 功能概述：
--   1. 当 mpv 开始播放一个文件时，自动扫描该文件所在目录
--   2. 按文件名自然排序（人类直觉顺序：1,2,3,...10,11 而非 1,10,11,2,3）
--   3. 将当前文件前后的媒体文件自动添加到播放列表中
--   4. 支持递归扫描子目录、过滤隐藏文件、限定同类型文件等
-- ==============================================================================
-- 原作者：mpv-player 社区
-- 由用户 [2026.07.04] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 常量定义
-- ==============================================================================
local MAX_ENTRIES = 5000       -- 最大加载文件数（前后各最多 5000 个）
local MAX_DIR_STACK = 20       -- 递归扫描的最大目录深度（防止无限递归）

-- ==============================================================================
-- 2. 模块加载
-- ==============================================================================
local msg = require 'mp.msg'        -- 日志输出模块
local options = require 'mp.options' -- 配置读取模块
local utils = require 'mp.utils'    -- 工具函数模块

-- ==============================================================================
-- 3. 用户配置区 (Options)
-- 这些默认值可通过 script-opts/autoload.conf 文件覆盖修改
-- ==============================================================================
local o = {
    disabled = false,           -- 是否完全禁用自动加载
    images = true,              -- 是否加载图片文件
    videos = true,              -- 是否加载视频文件
    audio = true,               -- 是否加载音频文件
    additional_image_exts = "", -- 额外图片扩展名（逗号分隔）
    additional_video_exts = "", -- 额外视频扩展名（逗号分隔）
    additional_audio_exts = "", -- 额外音频扩展名（逗号分隔）
    ignore_hidden = true,       -- 是否忽略以 . 开头的隐藏文件
    same_type = false,          -- 是否只加载与当前文件同类型的文件
    directory_mode = "auto",    -- 目录扫描模式：auto/recursive/lazy/ignore
    ignore_patterns = ""        -- 忽略的文件名模式（Lua 正则）
}

-- ==============================================================================
-- 4. 默认扩展名定义
-- ==============================================================================

-- 将数组转换为哈希表（用于快速查找）
local function Set(t)
    local set = {}
    for _, v in pairs(t) do set[v] = true end
    return set
end

-- 默认视频扩展名
local EXTENSIONS_VIDEO_DEFAULT = Set {
    '3g2', '3gp', 'avi', 'flv', 'm2ts', 'm4v', 'mj2', 'mkv', 'mov',
    'mp4', 'mpeg', 'mpg', 'ogv', 'rmvb', 'webm', 'wmv', 'y4m'
}

-- 默认音频扩展名
local EXTENSIONS_AUDIO_DEFAULT = Set {
    'aiff', 'ape', 'au', 'flac', 'm4a', 'mka', 'mp3', 'oga', 'ogg',
    'ogm', 'opus', 'wav', 'wma'
}

-- 默认图片扩展名
local EXTENSIONS_IMAGES_DEFAULT = Set {
    'avif', 'bmp', 'gif', 'j2k', 'jp2', 'jpeg', 'jpg', 'jxl', 'png',
    'svg', 'tga', 'tif', 'tiff', 'webp'
}

-- 最终使用的扩展名集合（在 create_extensions() 中构建）
local EXTENSIONS, EXTENSIONS_VIDEO, EXTENSIONS_AUDIO, EXTENSIONS_IMAGES

-- ==============================================================================
-- 5. 集合工具函数
-- ==============================================================================

-- 集合并集：将 b 中的所有键加入 a
local function SetUnion(a, b)
    for k in pairs(b) do a[k] = true end
    return a
end

-- ==============================================================================
-- 6. 配置解析函数（支持转义逗号）
-- 将 "bak%,x%,,another" 解析为 {"bak,x,", "another"}
-- ==============================================================================

-- 查找字符串中 pattern 的位置，若未找到则返回字符串末尾+1
local function FindOrPastTheEnd(string, pattern, start_at)
    local pos1, pos2 = string:find(pattern, start_at)
    return pos1 or #string + 1,
           pos2 or #string + 1
end

-- 解析逗号分隔的列表，支持用 %% 转义逗号
local function Split(list)
    local set = {}
    local item_pos = 1
    local item = ""

    while item_pos <= #list do
        -- 查找 %%*, 模式（转义逗号）
        local pos1, pos2 = FindOrPastTheEnd(list, "%%*,", item_pos)

        local pattern_length = pos2 - pos1
        local is_comma_escaped = pattern_length % 2  -- 奇数表示找到了转义逗号

        local pos_before_escape = pos1 - 1
        local item_escape_count = pattern_length - is_comma_escaped

        -- 拼接已处理的部分
        item = item .. string.sub(list, item_pos, pos_before_escape + item_escape_count)

        if is_comma_escaped == 1 then
            -- 这是一个转义逗号，保留它作为普通字符
            item = item .. ","
        else
            -- 这是一个真正的分隔逗号，完成当前项
            set[item] = true
            item = ""
        end

        item_pos = pos2 + 1
    end

    -- 处理最后一项
    set[item] = true
    set[""] = nil  -- 排除空项

    return set
end

-- ==============================================================================
-- 7. 配置初始化函数
-- ==============================================================================

-- 解析用户自定义的额外扩展名
local function split_option_exts(video, audio, image)
    if video then o.additional_video_exts = Split(o.additional_video_exts) end
    if audio then o.additional_audio_exts = Split(o.additional_audio_exts) end
    if image then o.additional_image_exts = Split(o.additional_image_exts) end
end

-- 解析忽略模式列表
local function split_patterns()
    o.ignore_patterns = Split(o.ignore_patterns)
end

-- 构建最终的扩展名集合（默认 + 用户自定义）
local function create_extensions()
    EXTENSIONS = {}
    EXTENSIONS_VIDEO = {}
    EXTENSIONS_AUDIO = {}
    EXTENSIONS_IMAGES = {}

    if o.videos then
        SetUnion(SetUnion(EXTENSIONS_VIDEO, EXTENSIONS_VIDEO_DEFAULT), o.additional_video_exts)
        SetUnion(EXTENSIONS, EXTENSIONS_VIDEO)
    end
    if o.audio then
        SetUnion(SetUnion(EXTENSIONS_AUDIO, EXTENSIONS_AUDIO_DEFAULT), o.additional_audio_exts)
        SetUnion(EXTENSIONS, EXTENSIONS_AUDIO)
    end
    if o.images then
        SetUnion(SetUnion(EXTENSIONS_IMAGES, EXTENSIONS_IMAGES_DEFAULT), o.additional_image_exts)
        SetUnion(EXTENSIONS, EXTENSIONS_IMAGES)
    end
end

-- 验证 directory_mode 的有效值
local function validate_directory_mode()
    if o.directory_mode ~= "recursive" and o.directory_mode ~= "lazy"
       and o.directory_mode ~= "ignore" then
        o.directory_mode = nil  -- 无效值，回退到 mpv 全局设置
    end
end

-- ==============================================================================
-- 8. 读取配置文件
-- ==============================================================================
options.read_options(o, nil, function(list)
    split_option_exts(list.additional_video_exts, list.additional_audio_exts,
                      list.additional_image_exts)
    if list.videos or list.additional_video_exts or
        list.audio or list.additional_audio_exts or
        list.images or list.additional_image_exts then
        create_extensions()
    end
    if list.directory_mode then
        validate_directory_mode()
    end
    if list.ignore_patterns then
        split_patterns()
    end
end)

-- 执行初始配置
split_option_exts(true, true, true)
split_patterns()
create_extensions()
validate_directory_mode()

-- ==============================================================================
-- 9. 辅助函数
-- ==============================================================================

-- 批量添加文件到播放列表（支持在指定位置插入）
-- files 格式：{{filename, position}, ...}
local function add_files(files)
    local oldcount = mp.get_property_number("playlist-count", 1)
    for i = 1, #files do
        mp.commandv("loadfile", files[i][1], "append")           -- 先追加到末尾
        mp.commandv("playlist-move", oldcount + i - 1, files[i][2]) -- 再移动到目标位置
    end
end

-- 提取文件扩展名（若没有则返回 "nomatch"）
local function get_extension(path)
    return path:match("%.([^%.]+)$") or "nomatch"
end

-- 检查文件是否匹配忽略模式
local function is_ignored(file)
    for pattern in pairs(o.ignore_patterns) do
        if file:match(pattern) then
            return true
        end
    end
    return false
end

-- ==============================================================================
-- 10. 自然排序算法 (alphanumsort)
-- 实现人类直觉的排序：1,2,3,...10,11,12 而非 1,10,11,12,2,3
-- 算法来源：http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua
-- ==============================================================================
local function alphanumsort(filenames)
    -- 将数字部分补零并对齐，使排序符合自然顺序
    local function padnum(n, d)
        return #d > 0 and ("%03d%s%.12f"):format(#n, n, tonumber(d) / (10 ^ #d))
            or ("%03d%s"):format(#n, n)
    end

    -- 构建排序元组：{排序键, 原始文件名}
    local tuples = {}
    for i, f in ipairs(filenames) do
        tuples[i] = {f:lower():gsub("0*(%d+)%.?(%d*)", padnum), f}
    end

    -- 按排序键排序，长度相同时按原始文件名长度排序
    table.sort(tuples, function(a, b)
        return a[1] == b[1] and #b[2] < #a[2] or a[1] < b[1]
    end)

    -- 提取排序后的原始文件名
    for i, tuple in ipairs(tuples) do filenames[i] = tuple[2] end
    return filenames
end

-- ==============================================================================
-- 11. 状态变量
-- ==============================================================================
local autoloaded        -- 是否已执行过自动加载（用于区分手动播放列表）
local added_entries = {} -- 已添加的文件名缓存（防止重复添加）
local autoloaded_dir    -- 当前自动加载的目录路径

-- ==============================================================================
-- 12. 目录扫描函数 (scan_dir)
-- 递归扫描指定目录，收集所有匹配扩展名的文件
-- ==============================================================================
local function scan_dir(path, current_file, dir_mode, separator, dir_depth, total_files, extensions)
    -- 防止递归过深
    if dir_depth == MAX_DIR_STACK then
        return
    end

    msg.trace("scanning: " .. path)

    -- 读取当前目录的文件和子目录
    local files = utils.readdir(path, "files") or {}
    local dirs = dir_mode ~= "ignore" and utils.readdir(path, "dirs") or {}
    local prefix = path == "." and "" or path

    -- 过滤函数：从数组中移除不满足条件的元素
    local function filter(t, iter)
        for i = #t, 1, -1 do
            if not iter(t[i]) then
                table.remove(t, i)
            end
        end
    end

    -- 过滤文件列表
    filter(files, function(v)
        -- 当前播放的文件始终保留
        local current = prefix .. v == current_file
        if current then
            return true
        end
        -- 忽略隐藏文件
        if o.ignore_hidden and v:match("^%.") then
            return false
        end
        -- 忽略匹配 ignore_patterns 的文件
        if is_ignored(v) then
            return false
        end
        -- 检查扩展名是否匹配
        local ext = get_extension(v)
        return ext and extensions[ext:lower()]
    end)

    -- 过滤目录列表（只过滤隐藏目录）
    filter(dirs, function(d)
        return not (o.ignore_hidden and d:match("^%."))
    end)

    -- 对文件和目录进行自然排序
    alphanumsort(files)
    alphanumsort(dirs)

    -- 添加路径前缀
    for i, file in ipairs(files) do
        files[i] = prefix .. file
    end

    -- 追加数组
    local function append(t1, t2)
        local t1_size = #t1
        for i = 1, #t2 do
            t1[t1_size + i] = t2[i]
        end
    end

    append(total_files, files)

    -- 处理子目录
    if dir_mode == "recursive" then
        -- 递归模式：进入每个子目录继续扫描
        for _, dir in ipairs(dirs) do
            scan_dir(prefix .. dir .. separator, current_file, dir_mode,
                     separator, dir_depth + 1, total_files, extensions)
        end
    else
        -- 非递归模式：将子目录本身当作"虚拟文件"加入列表（允许用户播放目录）
        for i, dir in ipairs(dirs) do
            dirs[i] = prefix .. dir
        end
        append(total_files, dirs)
    end
end

-- ==============================================================================
-- 13. 核心函数：查找并添加播放列表条目 (find_and_add_entries)
-- 在 start-file 事件触发时执行
-- ==============================================================================
local function find_and_add_entries()
    -- 检查播放是否已被中止
    local aborted = mp.get_property_native("playback-abort")
    if aborted then
        msg.debug("stopping: playback aborted")
        return
    end

    -- 获取当前文件路径
    local path = mp.get_property("path", "")
    local dir, filename = utils.split_path(path)
    msg.trace(("dir: %s, filename: %s"):format(dir, filename))

    -- 检查是否禁用自动加载
    if o.disabled then
        msg.debug("stopping: autoload disabled")
        return
    -- 不是本地文件（如网络流）则跳过
    elseif #dir == 0 then
        msg.debug("stopping: not a local path")
        return
    end

    -- 获取当前播放列表状态
    local pl_count = mp.get_property_number("playlist-count", 1)
    local this_ext = get_extension(filename)

    -- 如果播放列表已有多个条目且 autoload 未标记，说明是手动播放列表，跳过自动加载
    if pl_count > 1 and autoloaded == nil then
        msg.debug("stopping: manually made playlist")
        return
    -- 如果是单文件播放，初始化自动加载状态
    elseif pl_count == 1 then
        autoloaded = true
        autoloaded_dir = dir
        added_entries = {}
    end

    -- ================================================================
    -- 确定要加载的文件类型（same_type 模式下只加载同类型）
    -- ================================================================
    local extensions
    if o.same_type then
        if EXTENSIONS_VIDEO[this_ext:lower()] then
            extensions = EXTENSIONS_VIDEO
        elseif EXTENSIONS_AUDIO[this_ext:lower()] then
            extensions = EXTENSIONS_AUDIO
        elseif EXTENSIONS_IMAGES[this_ext:lower()] then
            extensions = EXTENSIONS_IMAGES
        end
    else
        extensions = EXTENSIONS
    end
    if not extensions then
        msg.debug("stopping: no matched extensions list")
        return
    end

    -- ================================================================
    -- 扫描目录，收集所有符合条件的文件
    -- ================================================================
    local pl = mp.get_property_native("playlist", {})
    local pl_current = mp.get_property_number("playlist-pos-1", 1)
    msg.trace(("playlist-pos-1: %s, playlist: %s"):format(pl_current,
        utils.to_string(pl)))

    local files = {}
    scan_dir(autoloaded_dir, path,
             o.directory_mode or mp.get_property("directory-mode", "lazy"),
             mp.get_property_native("platform") == "windows" and "\\" or "/",
             0, files, extensions)

    if next(files) == nil then
        msg.debug("no other files or directories in directory")
        return
    end

    -- ================================================================
    -- 找到当前文件在排序列表中的位置
    -- ================================================================
    local current
    for i = 1, #files do
        if files[i] == path then
            current = i
            break
        end
    end
    if not current then
        msg.debug("current file not found in directory")
        return
    end
    msg.trace("current file position in files: " .. current)

    -- 将已存在的播放列表条目标记为"已添加"，防止重复
    for _, entry in ipairs(pl) do
        added_entries[entry.filename] = true
    end
    added_entries[path] = true  -- 当前文件也不重复添加

    -- ================================================================
    -- 构建待添加列表：分别扫描当前位置之前和之后的文件
    -- ================================================================
    local append = {[-1] = {}, [1] = {}}  -- -1 为之前，1 为之后

    for direction = -1, 1, 2 do  -- 两次迭代：direction = -1 和 +1
        for i = 1, MAX_ENTRIES do
            local pos = current + i * direction
            local file = files[pos]

            if file == nil or file[1] == "." then
                break  -- 到达列表末尾或以 . 开头的目录
            end

            -- 跳过已存在的文件
            if not added_entries[file] then
                if direction == -1 then
                    -- 前置文件：插入到当前文件之前
                    msg.verbose("Prepending " .. file)
                    table.insert(append[-1], 1, {file, pl_current + i * direction + 1})
                else
                    -- 后置文件：追加到当前文件之后
                    msg.verbose("Adding " .. file)
                    if pl_count > 1 then
                        table.insert(append[1], {file, pl_current + i * direction - 1})
                    else
                        -- 单文件播放时直接追加
                        mp.commandv("loadfile", file, "append")
                    end
                end
                added_entries[file] = true
            end
        end

        -- 单文件模式：先处理前置文件，再统一移动
        if pl_count == 1 and direction == -1 and #append[-1] > 0 then
            local load = append[-1]
            for i = 1, #load do
                mp.commandv("loadfile", load[i][1], "append")
            end
            mp.commandv("playlist-move", 0, current)
        end
    end

    -- ================================================================
    -- 多文件模式：批量插入前置和后置文件
    -- ================================================================
    if pl_count > 1 then
        add_files(append[1])   -- 插入后置文件
        add_files(append[-1])  -- 插入前置文件
    end
end

-- ==============================================================================
-- 14. 注册事件
-- 在每次启动新文件时触发自动加载
-- ==============================================================================
mp.register_event("start-file", find_and_add_entries)