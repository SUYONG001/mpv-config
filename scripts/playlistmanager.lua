-- ==============================================================================
-- playlistmanager.lua — 播放列表管理器
-- ==============================================================================
-- 功能概述：
--   1. 显示、导航、编辑当前播放列表
--   2. 支持按名称、日期、大小排序，支持随机播放和反转
--   3. 支持从目录加载文件到播放列表
--   4. 支持保存/加载 m3u 播放列表
--   5. 支持 URL 标题解析（使用 yt-dlp）和本地文件标题解析（使用 ffprobe）
--   6. 提供可自定义的快捷键绑定和界面样式
-- ==============================================================================
-- 完成全量中文注释解析
-- ==============================================================================

local settings = {
  -- 动态按键绑定：仅在播放列表可见时强制覆盖导航键
  -- 若为 "no"，则可以通过任意导航键显示播放列表
  dynamic_binds = true,

  -- 多个按键用空格分隔

  -- 显示播放列表和命令菜单的主按键
  key_showplaylist = "SHIFT+ENTER",
  key_openmenu = "",

  -- 按住时临时显示播放列表（松开后隐藏）
  key_peek_at_playlist = "",

  -- 动态导航按键
  key_moveup = "UP",
  key_movedown = "DOWN",
  key_movepageup = "PGUP",
  key_movepagedown = "PGDWN",
  key_movebegin = "HOME",
  key_moveend = "END",
  key_selectfile = "RIGHT LEFT",
  key_unselectfile = "",
  key_playfile = "ENTER",
  key_removefile = "BS",
  key_closeplaylist = "ESC SHIFT+ENTER",

  -- 额外功能按键
  key_sortplaylist = "",
  key_shuffleplaylist = "",
  key_reverseplaylist = "",
  key_loadfiles = "",
  key_saveplaylist = "",
  key_selectplaylist = "",

  -- 根据扩展名替换文件名中的匹配内容，空字符串表示不替换
  -- 替换规则按提供的顺序执行
  -- 键为模式，值为替换值
  -- 使用 :gsub('pattern', 'replace')，参考 http://lua-users.org/wiki/StringLibraryTutorial
  -- 'all' 会匹配任何扩展名或协议（如果存在）
  -- 使用 JSON 格式并解析为 Lua 表，以支持 .conf 文件

  filename_replace = [[
    [
      {
        "protocol": { "all": true },
        "rules": [
          { "%%(%x%x)": "hex_to_char" }
        ]
      }
    ]
  ]],

--[=====[ 示例替换规则 - 删除此行以启用
  -- 示例替换：将所有文件的下划线替换为空格
  -- 对于 mp4 和 webm：移除扩展名、移除括号及周围空白、将字母数字之间的点改为空格
  filename_replace = [[
    [
      {
        "ext": { "all": true},
        "rules": [
          { "_" : " " }
        ]
      },{
        "ext": { "mp4": true, "mkv": true },
        "rules": [
          { "^(.+)%..+$": "%1" },
          { "%s*[%[%(].-[%]%)]%s*": "" },
          { "(%w)%.(%w)": "%1 %2" }
        ]
      },{
        "protocol": { "http": true, "https": true },
        "rules": [
          { "^%a+://w*%.?": "" }
        ]
      }
    ]
  ]],
-- 示例替换结束 ]=====]

  -- 从目录搜索文件时使用的文件类型（JSON 数组）
  loadfiles_filetypes = [[
    [
      "jpg", "jpeg", "png", "tif", "tiff", "gif", "webp", "svg", "bmp",
      "mp3", "wav", "ogm", "flac", "m4a", "wma", "ogg", "opus",
      "mkv", "avi", "mp4", "ogv", "webm", "rmvb", "flv", "wmv", "mpeg", "mpg", "m4v", "3gp"
    ]
  ]],

  -- 启动时如果播放列表中有 1 个或更多条目，则加载文件
  loadfiles_on_start = false,
  -- 空闲启动时从工作目录加载文件
  loadfiles_on_idle_start = false,
  -- 始终将加载的文件放在当前播放文件之后
  loadfiles_always_append = false,

  -- 向播放列表添加文件时自动排序
  sortplaylist_on_file_add = false,

  -- 启动时反转播放列表
  reverseplaylist_on_startup = false,

  -- 默认排序方式，必须是 "name-asc", "name-desc", "date-asc", "date-desc", "size-asc", "size-desc" 之一
  default_sort = "name-asc",

  -- 系统类型："linux | windows | auto"
  system = "auto",

  -- 保存路径，使用 ~ 表示主目录。留空则使用 mpv/playlists
  playlist_savepath = "",

  -- 保存时提示输入播放列表文件名
  playlist_save_interactive = true,

  -- 固定保存的文件名。注意会覆盖已有播放列表。留空则生成名称。
  playlist_save_filename = "",

  -- 当前文件卸载后自动保存播放列表
  save_playlist_on_file_end = false,

  -- 每次加载新文件时显示文件标题
  show_title_on_file_load = false,
  -- 每次加载新文件时显示播放列表
  show_playlist_on_file_load = false,
  -- 选择文件播放时关闭播放列表
  close_playlist_on_playfile = false,

  -- 当文件从外部原因加载时同步光标（如文件结束、播放列表下一首快捷键等）
  -- 副作用：如果文件在导航时改变，光标会移动
  -- 好处：使用播放列表下一首/上一首来回切换时，光标始终跟随当前文件
  sync_cursor_on_load = true,

  -- 允许播放列表光标从末尾循环到开头，反之亦然
  loop_cursor = true,

  -- 允许播放列表管理器在文件间导航时写入 watch later 配置
  allow_write_watch_later_config = true,

  -- 关闭或打开播放列表时重置光标导航
  reset_cursor_on_close = true,
  reset_cursor_on_open = true,

  -- 优先显示以下文件的标题："all", "url", "none"。排序仍使用文件名。
  prefer_titles = "url",

  -- 如果启用，用于解析标题的 youtube-dl 可执行文件，可能是 "youtube-dl" 或 "yt-dlp"，也可以是绝对路径
  youtube_dl_executable = "yt-dlp",

  -- 调用 youtube-dl 解析播放列表中 URL 的标题
  resolve_url_titles = false,

  -- 调用 ffprobe 解析播放列表中本地文件的标题（如果元数据中存在）
  resolve_local_titles = false,

  -- URL 标题解析超时时间（秒）
  resolve_title_timeout = 15,

  -- 同时解析的 URL 标题数量。数值越高可能导致卡顿。
  concurrent_title_resolve_limit = 10,

  -- 不活动时 OSD 超时时间（秒），0 表示无超时
  playlist_display_timeout = 0,

  -- 当查看播放列表时，至少显示 display timeout 时间
  peek_respect_display_timeout = false,

  -- 播放列表渲染的最大行数。-1 表示自动计算。
  showamount = -1,

  -- 播放列表 ASS 样式覆盖，放在花括号内，\keyvalue 是一个字段，Lua 中需要额外 \ 转义
  -- 示例 {\\q2\\an7\\fnUbuntu\\fs10\\b0\\bord1} 等于：不换行、左上对齐、字体 Ubuntu、大小 10、不加粗、边框 1
  -- 参考 http://docs.aegisub.org/3.2/ASS_Tags/
  -- 未声明的标签将使用默认 OSD 设置
  -- 这些样式将应用于整个播放列表
  -- 推荐 \\q2 样式，因为文件名换行可能导致意外渲染
  -- 推荐 \\an7 样式以左上对齐，否则会遵循 osd-align-x/y
  style_ass_tags = "{\\q2\\an7}",
  -- 左右和上下的内边距
  text_padding_x = 30,
  text_padding_y = 60,
  
  -- 菜单打开时的屏幕变暗程度 0.0 - 1.0（0 为不变暗，1 为全黑）
  curtain_opacity=0.0,

  -- 使用去除后的名称设置窗口标题
  set_title_stripped = false,
  title_prefix = "",
  title_suffix = " - mpv",

  -- 截断长文件名，以及显示多少字符
  slice_longfilenames = false,
  slice_longfilenames_amount = 70,

  -- 播放列表标题模板
  -- %mediatitle 或 %filename = 正在播放文件的标题或名称
  -- %pos = 正在播放文件的位置
  -- %cursor = 导航光标位置
  -- %plen = 播放列表长度
  -- %N = 换行
  playlist_header = "[%cursor/%plen]",

  -- 播放列表文件模板
  -- %pos = 文件位置（带前导零）
  -- %name = 文件标题或名称
  -- %N = 换行
  -- 也可以使用上面提到的 ass 标签。例如：
  --   selected_file="{\\c&HFF00FF&}➔ %name"   | 为选中文件添加颜色。但是，如果
  --   使用 ass 标签，需要为每一行重置它们（参见 https://github.com/jonniek/mpv-playlistmanager/issues/20）
  normal_file = "○ %name",
  hovered_file = "● %name",
  selected_file = "➔ %name",
  playing_file = "▷ %name",
  playing_hovered_file = "▶ %name",
  playing_selected_file = "➤ %name",

  -- 播放列表被截断时显示的内容
  playlist_sliced_prefix = "...",
  playlist_sliced_suffix = "...",

  -- 向 OSD 输出任务的可视反馈
  display_osd_feedback = true,
}
local opts = require("mp.options")
opts.read_options(settings, "playlistmanager", function(list) update_opts(list) end)

local utils = require("mp.utils")
local msg = require("mp.msg")
local assdraw = require("mp.assdraw")
local input = require("mp.input")

-- 对齐方式映射表（对应 ASS 的 \an 标签）
local alignment_table = {
    [1] = { ["x"] = "left",   ["y"] = "bottom" },
    [2] = { ["x"] = "center", ["y"] = "bottom" },
    [3] = { ["x"] = "right",  ["y"] = "bottom" },
    [4] = { ["x"] = "left",   ["y"] = "center" },
    [5] = { ["x"] = "center", ["y"] = "center" },
    [6] = { ["x"] = "right",  ["y"] = "center" },
    [7] = { ["x"] = "left",   ["y"] = "top" },
    [8] = { ["x"] = "center", ["y"] = "top" },
    [9] = { ["x"] = "right",  ["y"] = "top" },
}

-- 检测操作系统
if settings.system=="auto" then
  local o = {}
  if mp.get_property_native('options/vo-mmcss-profile', o) ~= o then
    settings.system = "windows"
  else
    settings.system = "linux"
  end
end

-- 自动计算 showamount（显示行数）
if settings.showamount == -1 then
  -- 与 draw_playlist() 的高度相同
  local h = 720
  
  local playlist_h = h
  -- 上下使用相同的内边距
  playlist_h = playlist_h - settings.text_padding_y * 2
  
  -- osd-font-size 基于 720p 高度
  -- 参见 https://mpv.io/manual/stable/#options-osd-font-size 
  -- 详情见 https://mpv.io/manual/stable/#options-sub-font-size
  -- draw_playlist() 基于 720p，需要一些转换
  local fs = mp.get_property_native('osd-font-size') * h / 720
  -- 获取 ass 字体大小
  if settings.style_ass_tags ~= nil then
    local ass_fs_tag = settings.style_ass_tags:match('\\fs%d+')
    if ass_fs_tag ~= nil then
      fs = tonumber(ass_fs_tag:match('%d+'))
    end
  end
 
  settings.showamount = math.floor(playlist_h / fs)
  
  -- 排除标题行
  if settings.playlist_header ~= "" then
    settings.showamount = settings.showamount - 1
    -- 标题中可能包含换行符（%N 或 \N）
    for _ in settings.playlist_header:gmatch('%%N') do
      settings.showamount = settings.showamount - 1
    end
    for _ in settings.playlist_header:gmatch('\\N') do
      settings.showamount = settings.showamount - 1
    end
  end
  
  msg.info('自动计算 showamount: ' .. settings.showamount)
end

-- 全局变量
local playlist_overlay = mp.create_osd_overlay("ass-events")  -- 用于绘制播放列表的 OSD 覆盖层
local playlist_visible = false        -- 播放列表当前是否可见
local strippedname = nil              -- 处理后的文件名
local path = nil                      -- 当前文件路径
local directory = nil                 -- 当前文件所在目录
local filename = nil                  -- 当前文件名
local pos = 0                         -- 当前播放位置
local plen = 0                        -- 播放列表长度
local cursor = 0                      -- 当前光标位置
local reversed_playlist_on_startup = false  -- 启动时是否已反转播放列表
-- 保存媒体标题的表，以备后续优先使用
local title_table = {}
-- 已请求解析标题的 URL 和本地文件路径表
local requested_titles = {}

local filetype_lookup = {}            -- 文件类型查找表（用于 loadfiles）

-- 刷新 UI（如果播放列表可见）
function refresh_UI()
  if not playlist_visible then return end
  refresh_globals()
  if plen == 0 then return end
  draw_playlist()
end

-- 更新选项（当配置文件改变时调用）
function update_opts(changelog)
  msg.verbose('更新选项')

  -- 解析 filename_replace JSON
  if changelog.filename_replace then
    if(settings.filename_replace~="") then
      settings.filename_replace = utils.parse_json(settings.filename_replace)
    else
      settings.filename_replace = false
    end
  end

  -- 解析 loadfiles_filetypes JSON
  if changelog.loadfiles_filetypes then
    settings.loadfiles_filetypes = utils.parse_json(settings.loadfiles_filetypes)

    filetype_lookup = {}
    -- 创建 loadfiles 集合
    for _, ext in ipairs(settings.loadfiles_filetypes) do
      filetype_lookup[ext] = true
    end
  end

  if changelog.resolve_url_titles then
    resolve_titles()
  end

  if changelog.resolve_local_titles then
    resolve_titles()
  end

  if changelog.playlist_display_timeout then
    keybindstimer = mp.add_periodic_timer(settings.playlist_display_timeout, remove_keybinds)
    keybindstimer:kill()
  end

  refresh_UI()
end

update_opts({filename_replace = true, loadfiles_filetypes = true})

----- winapi 开始 -----
-- 在 Windows 系统下，可以使用 Win32 API 提供的排序函数
-- 参见 https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-strcmplogicalw
local winapisort = nil
if settings.system == "windows" then
  -- ffiok 为 false 通常意味着 mpv 构建时没有包含 luajit
  local ffiok, ffi = pcall(require, "ffi")
  if ffiok then
    ffi.cdef[[
      int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
      int StrCmpLogicalW(const wchar_t * psz1, const wchar_t * psz2);        
    ]]
   
    local shlwapi = ffi.load("shlwapi.dll")
    
    function MultiByteToWideChar(MultiByteStr)
      local UTF8_CODEPAGE = 65001
      if MultiByteStr then
        local utf16_len = ffi.C.MultiByteToWideChar(UTF8_CODEPAGE, 0, MultiByteStr, -1, nil, 0)
        if utf16_len > 0 then
          local utf16_str = ffi.new("wchar_t[?]", utf16_len)
          if ffi.C.MultiByteToWideChar(UTF8_CODEPAGE, 0, MultiByteStr, -1, utf16_str, utf16_len) > 0 then
            return utf16_str
          end
        end
      end
      return ""
    end
    
    winapisort = function (a, b)
      return shlwapi.StrCmpLogicalW(MultiByteToWideChar(a), MultiByteToWideChar(b)) < 0
    end
    
  end
end
----- winapi 结束 -----

-- 排序模式定义
local sort_modes = {
  {
    id="name-asc",
    title="名称升序",
    sort_fn=function (a, b, playlist)
      if winapisort ~= nil then 
        return winapisort(playlist[a].string, playlist[b].string)
      end
      return alphanumsort(playlist[a].string, playlist[b].string)
    end,
  },
  {
    id="name-desc",
    title="名称降序",
    sort_fn=function (a, b, playlist)
      if winapisort ~= nil then 
        return winapisort(playlist[b].string, playlist[a].string)
      end
      return alphanumsort(playlist[b].string, playlist[a].string)
    end,
  },
  {
    id="date-asc",
    title="日期升序",
    sort_fn=function (a, b)
      return (get_file_info(a).mtime or 0) < (get_file_info(b).mtime or 0)
    end,
  },
  {
    id="date-desc",
    title="日期降序",
    sort_fn=function (a, b)
      return (get_file_info(a).mtime or 0) > (get_file_info(b).mtime or 0)
    end,
  },
  {
    id="size-asc",
    title="大小升序",
    sort_fn=function (a, b)
      return (get_file_info(a).size or 0) < (get_file_info(b).size or 0)
    end,
  },
  {
    id="size-desc",
    title="大小降序",
    sort_fn=function (a, b)
      return (get_file_info(a).size or 0) > (get_file_info(b).size or 0)
    end,
  },
}

local sort_mode = 1
for mode, sort_data in pairs(sort_modes) do
  if sort_data.id == settings.default_sort then
    sort_mode = mode
  end
end

-- 判断路径是否为协议（URL）
function is_protocol(path)
  return type(path) == 'string' and path:match('^%a[%a%d-_]+://') ~= nil
end

-- 预加载钩子：启动时若需要反转播放列表则执行
function on_preloaded_hook()
  if settings.reverseplaylist_on_startup and not reversed_playlist_on_startup then
    reverseplaylist()
    mp.set_property("playlist-pos", 0)
    cursor = 0
    reversed_playlist_on_startup = true
  end
end

-- 文件加载完成时调用
function on_file_loaded()
  refresh_globals()
  if settings.sync_cursor_on_load then cursor=pos end
  refresh_UI() -- 仅在移动光标后刷新

  filename = mp.get_property("filename")
  path = mp.get_property('path')
  local media_title = mp.get_property("media-title")
  if is_protocol(path) and not title_table[path] and path ~= media_title then
    title_table[path] = media_title
  end

  strippedname = stripfilename(mp.get_property('media-title'))
  if settings.show_title_on_file_load then
    mp.commandv('show-text', strippedname)
  end
  if settings.show_playlist_on_file_load then
    showplaylist()
  end
  if settings.set_title_stripped then
    mp.set_property("title", settings.title_prefix..strippedname..settings.title_suffix)
  end
end

-- 开始播放文件时调用
function on_start_file()
  refresh_globals()
  filename = mp.get_property("filename")
  path = mp.get_property('path')
  -- 如果不是 URL，则将路径与工作目录拼接
  if not is_protocol(path) then
    path = utils.join_path(mp.get_property('working-directory'), path)
    directory = utils.split_path(path)
  else
    directory = nil
  end

  if settings.loadfiles_on_start and plen == 1 then
    local ext = filename:match("%.([^%.]+)$")
    -- 加载的是目录或播放列表，不做任何操作，mpv 会将其展开为文件
    if ext and filetype_lookup[ext:lower()] then
      msg.info("从播放文件所在目录加载文件")
      playlist()
    end
  end
end

-- 文件播放结束时调用
function on_end_file()
  if settings.save_playlist_on_file_end then save_playlist() end
  strippedname = nil
  path = nil
  directory = nil
  filename = nil
end

-- 刷新全局变量（当前位置和播放列表长度）
function refresh_globals()
  pos = mp.get_property_number('playlist-pos', 0)
  plen = mp.get_property_number('playlist-count', 0)
end

-- 转义路径中的特殊字符
function escapepath(dir, escapechar)
  return string.gsub(dir, escapechar, '\\'..escapechar)
end

-- 检查替换表中是否包含指定值
function replace_table_has_value(value, valid_values)
  if value == nil or valid_values == nil then
    return false
  end
  return valid_values['all'] or valid_values[value]
end

-- 文件名替换函数表
local filename_replace_functions = {
  -- 解码 URL 中的特殊字符
  hex_to_char = function(x) return string.char(tonumber(x, 16)) end
}

-- 来自 http://lua-users.org/wiki/LuaUnicode
local UTF8_PATTERN = '[%z\1-\127\194-\244][\128-\191]*'

-- 基于 UTF-8 字符返回子串
-- 类似于 string.sub，但不支持负索引
local function utf8_sub(s, i, j)
  if i > j then
    return s
  end

  local t = {}
  local idx = 1
  for char in s:gmatch(UTF8_PATTERN) do
    if i <= idx and idx <= j then
      local width = #char > 2 and 2 or 1
      idx = idx + width
      t[#t + 1] = char
    end
  end
  return table.concat(t)
end

-- 根据设置中的规则，基于扩展名或协议去除文件名
function stripfilename(pathfile, media_title)
  if pathfile == nil then return '' end
  local ext = pathfile:match("%.([^%.]+)$")
  local protocol = pathfile:match("^(%a%a+)://")
  if not ext then ext = "" end
  local tmp = pathfile
  if settings.filename_replace and not media_title then
    for k,v in ipairs(settings.filename_replace) do
      if replace_table_has_value(ext, v['ext']) or replace_table_has_value(protocol, v['protocol']) then
        for ruleindex, indexrules in ipairs(v['rules']) do
          for rule, override in pairs(indexrules) do
            override = filename_replace_functions[override] or override
            tmp = tmp:gsub(rule, override)
          end
        end
      end
    end
  end
  local tmp_clip = utf8_sub(tmp, 1, settings.slice_longfilenames_amount)
  if settings.slice_longfilenames and tmp ~= tmp_clip then
    tmp = tmp_clip .. "..."
  end
  return tmp
end

-- 获取项目文件信息
function get_file_info(item)
  local path = mp.get_property('playlist/' .. item - 1 .. '/filename')
  if is_protocol(path) then return {} end
  local file_info = utils.file_info(path)
  if not file_info then
    msg.warn('读取文件信息失败', path)
    return {}
  end

  return file_info
end

-- 获取播放列表中 0 基位置 i 的友好名称
function get_name_from_index(i, notitle)
  refresh_globals()
  if plen <= i then msg.error("播放列表中没有索引", i, "长度", plen); return nil end
  local _, name = nil
  local title = mp.get_property('playlist/'..i..'/title')
  local name = mp.get_property('playlist/'..i..'/filename')

  local should_use_title = settings.prefer_titles == 'all' or is_protocol(name) and settings.prefer_titles == 'url'
  
  -- 检查文件是否已存储媒体标题
  if not title and should_use_title and title_table[name] then
    title = title_table[name]
  end

  -- 如果有媒体标题，使用更保守的剥离方式
  if title and not notitle and should_use_title then
    -- 转义字符串以便在 OSD 上逐字显示
    -- 参考：https://github.com/mpv-player/mpv/blob/94677723624fb84756e65c8f1377956667244bc9/player/lua/stats.lua#L145
    return stripfilename(title, true):gsub("\\", '\\\239\187\191'):gsub("{", "\\{"):gsub("^ ", "\\h")
  end

  -- 如果存在路径则移除，保留协议用于剥离
  if string.sub(name, 1, 1) == '/' or name:match("^%a:[/\\]") then
    _, name = utils.split_path(name)
  end
  return stripfilename(name):gsub("\\", '\\\239\187\191'):gsub("{", "\\{"):gsub("^ ", "\\h")
end

-- 解析播放列表标题
function parse_header(string)
  local esc_title = stripfilename(mp.get_property("media-title"), true):gsub("%%", "%%%%")
  local esc_file = stripfilename(mp.get_property("filename")):gsub("%%", "%%%%")
  return string:gsub("%%N", "\\N")
               -- 在每个 '\N' 末尾添加一个空白字符，确保空行高度与非空行相同
               :gsub("\\N", "\\N ")
               :gsub("%%pos", mp.get_property_number("playlist-pos",0)+1)
               :gsub("%%plen", mp.get_property("playlist-count"))
               :gsub("%%cursor", cursor+1)
               :gsub("%%mediatitle", esc_title)
               :gsub("%%filename", esc_file)
               -- 撤销名称转义
               :gsub("%%%%", "%%")
end

-- 解析文件名模板
function parse_filename(string, name, index)
  local base = tostring(plen):len()
  local esc_name = stripfilename(name):gsub("%%", "%%%%")
  return string:gsub("%%N", "\\N")
               :gsub("%%pos", string.format("%0"..base.."d", index+1))
               :gsub("%%name", esc_name)
               -- 撤销名称转义
               :gsub("%%%%", "%%")
end

-- 根据索引解析文件名（使用对应的模板）
function parse_filename_by_index(index)
  local template = settings.normal_file

  local is_idle = mp.get_property_native('idle-active')
  local position = is_idle and -1 or pos

  if index == position then
    if index == cursor then
      if selection then
        template = settings.playing_selected_file
      else
        template = settings.playing_hovered_file
      end
    else
      template = settings.playing_file
    end
  elseif index == cursor then
    if selection then
      template = settings.selected_file
    else
      template = settings.hovered_file
    end
  end

  return parse_filename(template, get_name_from_index(index), index)
end

-- 判断是否为终端模式
function is_terminal_mode()
  local width, height, aspect_ratio = mp.get_osd_size()
  return width == 0 and height == 0 and aspect_ratio == 0
end

-- 绘制播放列表
function draw_playlist()
  refresh_globals()

  -- 如果没有正在播放的文件，cursor 可能为 -1，这会导致渲染问题
  if cursor == -1 then
    cursor = 0
  end

  local ass = assdraw.ass_new()
  local terminaloutput = ""
	
  local _, _, a = mp.get_osd_size()
  local h = 720
  local w = math.ceil(h * a)

  if settings.curtain_opacity ~= nil and settings.curtain_opacity ~= 0 and settings.curtain_opacity <= 1.0 then
  -- 幕布变暗，来自 https://github.com/christoph-heinrich/mpv-quality-menu/blob/501794bfbef468ee6a61e54fc8821fe5cd72c4ed/quality-menu.lua#L699-L707
    local alpha = 255 - math.ceil(255 * settings.curtain_opacity)
    ass.text = string.format('{\\pos(0,0)\\rDefault\\an7\\1c&H000000&\\alpha&H%X&}', alpha)
    ass:draw_start()
    ass:rect_cw(0, 0, w, h)
    ass:draw_stop()
    ass:new_event()
  end
	
  ass:append(settings.style_ass_tags)

  -- 添加 \clip 样式
  -- 左右遵循 text_padding_x
  -- 上下遵循 text_padding_y
  local border_size = mp.get_property_number('osd-border-size')
  if settings.style_ass_tags ~= nil then
    local bord = tonumber(settings.style_ass_tags:match('\\bord(%d+%.?%d*)'))
    if bord ~= nil then border_size = bord end
  end
  ass:append(string.format('{\\clip(%f,%f,%f,%f)}',
    settings.text_padding_x - border_size,         settings.text_padding_y - border_size,
    w - 1 - settings.text_padding_x + border_size, h - 1 - settings.text_padding_y + border_size))

  -- 从 mpv.conf 获取对齐方式
  local align_x = mp.get_property("osd-align-x")
  local align_y = mp.get_property("osd-align-y")
  -- 从 style_ass_tags 获取对齐方式
  if settings.style_ass_tags ~= nil then
    local an = tonumber(settings.style_ass_tags:match('\\an(%d)'))
    if an ~= nil and alignment_table[an] ~= nil then
      align_x = alignment_table[an]["x"]
      align_y = alignment_table[an]["y"]
    end
  end
  -- x 范围 [0, w-1]
  local pos_x
  if align_x == 'left' then
    pos_x = settings.text_padding_x
  elseif align_x == 'right' then
    pos_x = w - 1 - settings.text_padding_x
  else
    pos_x = math.floor((w - 1) / 2)
  end
  -- y 范围 [0, h-1]
  local pos_y
  if align_y == 'top' then
    pos_y = settings.text_padding_y
  elseif align_y == 'bottom' then
    pos_y = h - 1 - settings.text_padding_y
  else
    pos_y = math.floor((h - 1) / 2)
  end
  ass:pos(pos_x, pos_y)

  if settings.playlist_header ~= "" then
    local header = parse_header(settings.playlist_header)
    ass:append(header.."\\N")
    terminaloutput = terminaloutput..header.."\n"
  end

  -- (可见索引, 播放列表索引) 对，用于渲染的播放列表条目
  local visible_indices = {}

  local one_based_cursor = cursor + 1
  table.insert(visible_indices, one_based_cursor)

  local offset = 1;
  local visible_indices_length = 1;
  while visible_indices_length < settings.showamount and visible_indices_length < plen do
    -- 添加光标下方偏移步数的条目
    local below = one_based_cursor + offset
    if below <= plen then
      table.insert(visible_indices, below)
      visible_indices_length = visible_indices_length + 1;
    end

    -- 添加光标上方偏移步数的条目
    -- 同时需要再次检查是否还有空间，当限制为偶数时会发生这种情况
    local above = one_based_cursor - offset
    if above >= 1 and visible_indices_length < settings.showamount and visible_indices_length < plen then
      table.insert(visible_indices, 1, above)
      visible_indices_length = visible_indices_length + 1;
    end

    offset = offset + 1
  end

  -- 两个索引都是 1 基的
  for display_index, playlist_index in pairs(visible_indices) do
    if display_index == 1 and playlist_index ~= 1 then
      ass:append(settings.playlist_sliced_prefix.."\\N")
      terminaloutput = terminaloutput..settings.playlist_sliced_prefix.."\n"
    elseif display_index == settings.showamount and playlist_index ~= plen then
      ass:append(settings.playlist_sliced_suffix)
      terminaloutput = terminaloutput..settings.playlist_sliced_suffix.."\n"
    else
      -- parse_filename_by_index 期望 0 基索引
      local fname = parse_filename_by_index(playlist_index - 1)
      ass:append(fname.."\\N")
      terminaloutput = terminaloutput..fname.."\n"
    end
  end

  if is_terminal_mode() then
    local timeout_setting = settings.playlist_display_timeout
    local timeout = timeout_setting == 0 and 2147483 or timeout_setting
    -- TODO: 可能需要从终端输出中去除 ass 标签
    -- 也许可以使用终端颜色输出代替
    mp.osd_message(terminaloutput, timeout)
  else
    playlist_overlay.data = ass.text
    playlist_overlay:update()
  end
end

local peek_display_timer = nil
local peek_button_pressed = false

-- 查看超时处理
function peek_timeout()
  peek_display_timer:kill()
  if not peek_button_pressed and not playlist_visible then
    remove_keybinds()
  end
end

-- 处理复杂的播放列表切换（按下/松开）
function handle_complex_playlist_toggle(table)
  local event = table["event"]
  if event == "press" then
    msg.error("不支持复杂按键事件。回退到普通播放列表显示。")
    showplaylist()
  elseif event == "down" then
    showplaylist(1000000)
    if settings.peek_respect_display_timeout then
      peek_button_pressed = true
      peek_display_timer = mp.add_periodic_timer(settings.playlist_display_timeout, peek_timeout)
    end
  elseif event == "up" then
    -- 将播放列表状态设置为不可见，实际尚未隐藏
    -- 这允许我们检查其他功能是否在移除绑定前渲染了播放列表
    playlist_visible = false

    function remove_keybinds_after_timeout()
      -- 如果播放列表仍不可见，则实际隐藏它
      -- 这允许其他打断查看的按键渲染播放列表而不被查看松开事件关闭
      if not playlist_visible then
        remove_keybinds()
      end
    end

    if settings.peek_respect_display_timeout then
      peek_button_pressed = false
      if not peek_display_timer:is_enabled() then
        mp.add_timeout(0.01, remove_keybinds_after_timeout)
      end
    else
      -- 使用小延迟让动态绑定在按键可能解绑之前运行
      mp.add_timeout(0.01, remove_keybinds_after_timeout)
    end
  end
end

-- 切换播放列表显示
function toggle_playlist(show_function)
  local show = show_function or showplaylist
  if playlist_visible then
    remove_keybinds()
  else
    -- 切换总是无超时显示
    show(0)
  end
end

-- 显示播放列表（可交互）
function showplaylist(duration)
  refresh_globals()
  if plen == 0 then return end
  if not playlist_visible and settings.reset_cursor_on_open then
    resetcursor()
  end

  playlist_visible = true
  add_keybinds()

  draw_playlist()
  keybindstimer:kill()

  local dur = tonumber(duration) or settings.playlist_display_timeout
  if dur > 0 then
    keybindstimer = mp.add_periodic_timer(dur, remove_keybinds)
  end
end

-- 显示播放列表（不可交互）
function showplaylist_non_interactive(duration)
  refresh_globals()
  if plen == 0 then return end
  if not playlist_visible and settings.reset_cursor_on_open then
    resetcursor()
  end
  playlist_visible = true
  draw_playlist()
  keybindstimer:kill()

  local dur = tonumber(duration) or settings.playlist_display_timeout
  if dur > 0 then
    keybindstimer = mp.add_periodic_timer(dur, remove_keybinds)
  end
end

selection=nil
-- 选择文件（标记/取消标记）
function selectfile()
  refresh_globals()
  if plen == 0 then return end
  if not selection then
    selection=cursor
  else
    selection=nil
  end
  showplaylist()
end

-- 取消选择文件
function unselectfile()
  selection=nil
  showplaylist()
end

-- 重置光标
function resetcursor()
  selection = nil
  cursor = mp.get_property_number('playlist-pos', 1)
end

-- 移除文件
function removefile()
  refresh_globals()
  if plen == 0 then return end
  selection = nil
  if cursor==pos then mp.command("script-message unseenplaylist mark true \"playlistmanager avoid conflict when removing file\"") end
  mp.commandv("playlist-remove", cursor)
  if cursor==plen-1 then cursor = cursor - 1 end
  if plen == 1 then
    remove_keybinds()
  else
    showplaylist()
  end
end

-- 光标上移
function moveup()
  refresh_globals()
  if plen == 0 then return end
  if cursor~=0 then
    if selection then mp.commandv("playlist-move", cursor,cursor-1) end
    cursor = cursor-1
  elseif settings.loop_cursor then
    if selection then mp.commandv("playlist-move", cursor,plen) end
    cursor = plen-1
  end
  showplaylist()
end

-- 光标下移
function movedown()
  refresh_globals()
  if plen == 0 then return end
  if cursor ~= plen-1 then
    if selection then mp.commandv("playlist-move", cursor,cursor+2) end
    cursor = cursor + 1
  elseif settings.loop_cursor then
    if selection then mp.commandv("playlist-move", cursor,0) end
    cursor = 0
  end
  showplaylist()
end

-- 光标上翻页
function movepageup()
  refresh_globals()
  if plen == 0 or cursor == 0 then return end
  local offset = settings.showamount % 2 == 0 and 1 or 0
  local last_file_that_doesnt_scroll = math.ceil(settings.showamount / 2)
  local reverse_cursor = plen - cursor
  local files_to_jump = math.max(last_file_that_doesnt_scroll + offset - reverse_cursor, 0) + settings.showamount - 2
  local prev_cursor = cursor
  cursor = cursor - files_to_jump
  if cursor < last_file_that_doesnt_scroll then
    cursor = 0
  end
  if selection then
    mp.commandv("playlist-move", prev_cursor, cursor)
  end
  showplaylist()
end

-- 光标下翻页
function movepagedown()
  refresh_globals()
  if plen == 0 or cursor == plen - 1 then return end
  local last_file_that_doesnt_scroll = math.ceil(settings.showamount / 2) - 1
  local files_to_jump = math.max(last_file_that_doesnt_scroll - cursor, 0) + settings.showamount - 2
  local prev_cursor = cursor
  cursor = cursor + files_to_jump

  local cursor_on_last_page = plen - (settings.showamount - 3)
  if cursor > cursor_on_last_page then
    cursor = plen - 1
  end
  if selection then
    mp.commandv("playlist-move", prev_cursor, cursor + 1)
  end
  showplaylist()
end

-- 光标移到开头
function movebegin()
  refresh_globals()
  if plen == 0 or cursor == 0 then return end
  local prev_cursor = cursor
  cursor = 0
  if selection then mp.commandv("playlist-move", prev_cursor, cursor) end
  showplaylist()
end

-- 光标移到末尾
function moveend()
  refresh_globals()
  if plen == 0 or cursor == plen-1 then return end
  local prev_cursor = cursor
  cursor = plen-1
  if selection then mp.commandv("playlist-move", prev_cursor, cursor+1) end
  showplaylist()
end

-- 写入 watch later 配置
function write_watch_later(force_write)
  if settings.allow_write_watch_later_config then
    if mp.get_property_bool("save-position-on-quit") or force_write then
      mp.command("write-watch-later-config")
    end
  end
end

-- 播放下一首
function playlist_next()
  write_watch_later(true)
  mp.commandv("playlist-next", "weak")
  if settings.close_playlist_on_playfile then
    remove_keybinds()
  end
  refresh_UI()
end

-- 播放上一首
function playlist_prev()
  write_watch_later(true)
  mp.commandv("playlist-prev", "weak")
  if settings.close_playlist_on_playfile then
    remove_keybinds()
  end
  refresh_UI()
end

-- 随机播放
function playlist_random()
  write_watch_later()
  refresh_globals()
  if plen < 2 then return end
  math.randomseed(os.time())
  local random = pos
  while random == pos do
    random = math.random(0, plen-1)
  end
  mp.set_property("playlist-pos", random)
  if settings.close_playlist_on_playfile then
    remove_keybinds()
  end
end

-- 播放选中的文件
function playfile()
  refresh_globals()
  if plen == 0 then return end
  selection = nil
  local is_idle = mp.get_property_native('idle-active')
  if cursor ~= pos or is_idle then
    write_watch_later()
    mp.set_property("playlist-pos", cursor)
    if (mp.get_property_native('pause')) then     -- TK 在选择播放列表文件时恢复播放
      mp.set_property_native("pause",false)
      msg.info("暂停已循环")
    end
  else
    if cursor~=plen-1 then
      cursor = cursor + 1
    end
    write_watch_later()
    mp.commandv("playlist-next", "weak")
  end
  if settings.close_playlist_on_playfile then
    remove_keybinds()
  elseif playlist_visible then
    showplaylist()
  end
end

-- 文件过滤器（根据文件类型查找表筛选）
function file_filter(filenames)
    local files = {}
    for i = 1, #filenames do
        local file = filenames[i]
        local ext = file:match('%.([^%.]+)$')
        if ext and filetype_lookup[ext:lower()] then
            table.insert(files, file)
        end
    end
    return files
end

-- 获取播放列表文件名集合
function get_playlist_filenames_set()
  local filenames = {}
  for n=0,plen-1,1 do
    local filename = mp.get_property('playlist/'..n..'/filename')
    local _, file = utils.split_path(filename)
    filenames[file] = true
  end
  return filenames
end

-- 创建目录中所有文件的播放列表，保持顺序和位置
-- 例如，文件夹中有 12 个文件，你打开第 5 个文件并运行此函数，
-- 剩余的 7 个文件会添加到第 5 个文件之后，前 4 个文件之前
function playlist(force_dir)
  refresh_globals()
  if not directory and plen > 0 then return end
  local hasfile = true
  if plen == 0 then
    hasfile = false
    dir = mp.get_property('working-directory')
  else
    dir = directory
  end

  if dir == "." then dir = "" end
  if force_dir then dir = force_dir end

  local files = file_filter(utils.readdir(dir, "files"))
  if winapisort ~= nil then
    table.sort(files, winapisort)
  else
    table.sort(files, alphanumsort)
  end
  
  
  if files == nil then
    msg.verbose("目录中没有文件")
    return
  end

  local filenames = get_playlist_filenames_set()
  local c, c2 = 0,0
  if files then
    local cur = false
    local filename = mp.get_property("filename")
    for _, file in ipairs(files) do
      if file == nil or file[1] == "." then
          break
      end
      local appendstr = "append"
      if not hasfile then
        cur = true
        appendstr = "append-play"
        hasfile = true
      end
      if filename == file then
        cur = true
      elseif filenames[file] then
        -- 跳过已在播放列表中的文件
      elseif cur == true or settings.loadfiles_always_append then
        mp.commandv("loadfile", utils.join_path(dir, file), appendstr)
        msg.info("追加到播放列表: " .. file)
        c2 = c2 + 1
      else
        mp.commandv("loadfile", utils.join_path(dir, file), appendstr)
        msg.info("前插到播放列表: " .. file)
        mp.commandv("playlist-move", mp.get_property_number("playlist-count", 1)-1,  c)
        c = c + 1
      end
    end
    if c2 > 0 or c>0 then
      msg.info("添加了 "..c + c2.." 个文件到播放列表")
    else
      msg.info("没有找到额外文件")
    end
    cursor = mp.get_property_number('playlist-pos', 1)
  else
    msg.error("无法扫描文件: "..(error or ""))
  end
  refresh_globals()
  if playlist_visible then
    showplaylist()
  end
  if settings.display_osd_feedback then
    if c2 > 0 or c>0 then
      mp.osd_message("添加了 "..c + c2.." 个文件到播放列表")
    else
      mp.osd_message("没有找到额外文件")
    end
  end
  return c + c2
end

-- 菜单项定义
local menu_items = {
  {
    label = "显示播放列表",
    action = function()
      showplaylist()
    end,
  },
  {
    label = "保存播放列表",
    action = function()
      mp.add_timeout(0.1, activate_playlist_save)
    end,
  },
  {
    label = "选择播放列表",
    action = function()
      mp.add_timeout(0.1, select_playlist)
    end,
  },
  {
    label = "加载文件到播放列表",
    action = function()
      playlist()
    end,
  },
  {
    label = "排序播放列表",
    action = function()
      sortplaylist_by_next_mode()
    end,
  },
  {
    label = "反转播放列表",
    action = function()
      reverseplaylist()
    end,
  },
  {
    label = "随机播放列表",
    action = function()
      shuffleplaylist()
    end,
  },
  {
    label = "随机播放文件",
    action = function()
      playlist_random()
    end,
  },
}

local menu_labels = {}
for _, item in pairs(menu_items) do
  table.insert(menu_labels, item.label)
end

-- 打开菜单
function open_menu()
  remove_keybinds()
  input.select({
    prompt = "搜索菜单: ",
    items = menu_labels,
    submit = function (index)
      menu_items[index].action()
    end,
  })
end

-- 解析主目录路径
function parse_home(path)
  if not path:find("^~") then
    return path
  end
  local home_dir = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not home_dir then
    local drive = os.getenv("HOMEDRIVE")
    local path = os.getenv("HOMEPATH")
    if drive and path then
      home_dir = utils.join_path(drive, path)
    else
      msg.error("找不到主目录。")
      return nil
    end
  end
  local result = path:gsub("^~", home_dir)
  return result
end

-- 激活播放列表名称输入提示
function activate_playlist_name_prompt()
  input.get({
    cursor_position = 1,
    prompt = "输入播放列表名称: ",
    submit = function (text)
      input.terminate()
      save_playlist(text)
    end,
    default_text = ".m3u"
  })
end

-- 激活播放列表保存
function activate_playlist_save()
  if settings.playlist_save_interactive then
    remove_keybinds()
    activate_playlist_name_prompt()
  else
    save_playlist()
  end
end

-- 选择播放列表
function select_playlist()
  remove_keybinds()
  local save_path = get_playlist_save_path()
  local files, err = utils.readdir(save_path, "files")
  if err ~= nil then
    mp.error("读取播放列表文件时出错", err)
    return
  end

  local playlists = {}
  for index, file in pairs(files) do
    table.insert(playlists, file)
  end

  input.select({
    prompt = "搜索播放列表: ",
    items = playlists,
    submit = function (index)
      mp.commandv("loadfile", utils.join_path(save_path, playlists[index]))
    end,
  })
end

-- 获取播放列表保存路径
function get_playlist_save_path()
  if settings.playlist_savepath == nil or settings.playlist_savepath == "" then
    return mp.command_native({"expand-path", "~~home/"}).."/playlists"
  else
    local p = parse_home(settings.playlist_savepath)
    if p == nil then
      msg.error("无法解析播放列表保存路径")
    end
    return p or ""
  end
end

-- 将当前播放列表保存为 m3u 文件
function save_playlist(filename)
  local length = mp.get_property_number('playlist-count', 0)
  if length == 0 then return end

  -- 获取播放列表保存路径
  local savepath = get_playlist_save_path()

  -- 如果保存路径不存在则创建
  if utils.readdir(savepath) == nil then
    local windows_args = {'powershell', '-NoProfile', '-Command', 'mkdir', savepath}
    local unix_args = { 'mkdir', savepath }
    local args = settings.system == 'windows' and windows_args or unix_args
    local res = utils.subprocess({ args = args, cancellable = false })
    if res.status ~= 0 then
      msg.error("创建播放列表保存目录失败 "..savepath.."。错误: "..(res.error or "未知"))
      return
    end
  end

  local name = filename
  if name == nil then
    if settings.playlist_save_filename == nil or settings.playlist_save_filename == "" then
      local date = os.date("*t")
      local datestring = ("%02d-%02d-%02d_%02d-%02d-%02d"):format(date.year, date.month, date.day, date.hour, date.min, date.sec)

      name = datestring.."_playlist-size_"..length..".m3u"
    else
      name = settings.playlist_save_filename
    end
  end

  local savepath = utils.join_path(savepath, name)
  local file, err = io.open(savepath, "w")
  if not file then
    msg.error("创建播放列表文件时出错，请检查权限。错误: "..(err or "未知"))
  else
    file:write("#EXTM3U\n")
    local i=0
    while i < length do
      local pwd = mp.get_property("working-directory")
      local filename = mp.get_property('playlist/'..i..'/filename')
      local fullpath = filename
      if not is_protocol(filename) then
        fullpath = utils.join_path(pwd, filename)
      end
      local title = mp.get_property('playlist/'..i..'/title') or title_table[filename]
      if title then
        file:write("#EXTINF:,"..title.."\n")
      end
      file:write(fullpath, "\n")
      i=i+1
    end
    local saved_msg = "播放列表已写入: "..savepath
    if settings.display_osd_feedback then mp.osd_message(saved_msg) end
    msg.info(saved_msg)
    file:close()
  end
end

-- 字母数字混合排序
function alphanumsort(a, b)
  local function padnum(d)
    local dec, n = string.match(d, "(%.?)0*(.+)")
    return #dec > 0 and ("%.12f"):format(d) or ("%s%03d%s"):format(dec, #n, n)
  end
  return tostring(a):lower():gsub("%.?%d+",padnum)..("%3d"):format(#b)
       < tostring(b):lower():gsub("%.?%d+",padnum)..("%3d"):format(#a)
end

-- 快速排序算法，来自 https://github.com/zsugabubus/dotfiles/blob/master/.config/mpv/scripts/playlist-filtersort.lua
function sortplaylist(startover)
  local playlist = mp.get_property_native('playlist')
  if #playlist < 2 then return end

  local order = {}
  for i=1, #playlist do
		order[i] = i
    playlist[i].string = get_name_from_index(i - 1)
	end

  table.sort(order, function(a, b)
    return sort_modes[sort_mode].sort_fn(a, b, playlist)
  end)

  for i=1, #playlist do
    playlist[order[i]].new_pos = i
  end

  for i=1, #playlist do
    while true do
      local j = playlist[i].new_pos
      if i == j then
        break
      end
      mp.commandv('playlist-move', (i)     - 1, (j + 1) - 1)
      mp.commandv('playlist-move', (j - 1) - 1, (i)     - 1)
      playlist[j], playlist[i] = playlist[i], playlist[j]
    end
  end

  for i = 1, #playlist do
    local filename = mp.get_property('playlist/' .. i - 1 .. '/filename')
    local ext = filename:match("%.([^%.]+)$")
    if not ext or not filetype_lookup[ext:lower()] then
      -- 将目录移到播放列表末尾
      mp.commandv('playlist-move', i - 1, #playlist)
    end
  end

  cursor = mp.get_property_number('playlist-pos', 0)
  if startover then
    mp.set_property('playlist-pos', 0)
  end
  if playlist_visible then
    showplaylist()
  end
  if settings.display_osd_feedback then
    mp.osd_message("播放列表已按 "..sort_modes[sort_mode].title.." 排序")
  end
end

-- 按下一个排序模式排序
function sortplaylist_by_next_mode()
  sortplaylist()
  sort_mode = sort_mode + 1
  if sort_mode > #sort_modes then sort_mode = 1 end
end

-- 反转播放列表
function reverseplaylist()
  local length = mp.get_property_number('playlist-count', 0)
  if length < 2 then return end
  for outer=1, length-1, 1 do
    mp.commandv('playlist-move', outer, 0)
  end
  if playlist_visible then
    showplaylist()
  end
  if settings.display_osd_feedback then
    mp.osd_message("播放列表已反转")
  end
end

-- 随机打乱播放列表
function shuffleplaylist()
  refresh_globals()
  if plen < 2 then return end
  mp.command("playlist-shuffle")
  math.randomseed(os.time())
  mp.commandv("playlist-move", pos, math.random(0, plen-1))

  local playlist = mp.get_property_native('playlist')
  for i = 1, #playlist do
    local filename = mp.get_property('playlist/' .. i - 1 .. '/filename')
    local ext = filename:match("%.([^%.]+)$")
    if not ext or not filetype_lookup[ext:lower()] then
      -- 将目录移到播放列表末尾
      mp.commandv('playlist-move', i - 1, #playlist)
    end
  end

  mp.set_property('playlist-pos', 0)
  refresh_globals()
  if playlist_visible then
    showplaylist()
  end
  if settings.display_osd_feedback then
    mp.osd_message("播放列表已随机打乱")
  end
end

-- 绑定按键（普通）
function bind_keys(keys, name, func, opts)
  if keys == nil or keys == "" then
    mp.add_key_binding(keys, name, func, opts)
    return
  end
  local i = 1
  for key in keys:gmatch("[^%s]+") do
    local prefix = i == 1 and '' or i
    mp.add_key_binding(key, name..prefix, func, opts)
    i = i + 1
  end
end

-- 绑定按键（强制覆盖）
function bind_keys_forced(keys, name, func, opts)
  if keys == nil or keys == "" then
    mp.add_forced_key_binding(keys, name, func, opts)
    return
  end
  local i = 1
  for key in keys:gmatch("[^%s]+") do
    local prefix = i == 1 and '' or i
    mp.add_forced_key_binding(key, name..prefix, func, opts)
    i = i + 1
  end
end

-- 解绑按键
function unbind_keys(keys, name)
  if keys == nil or keys == "" then
    mp.remove_key_binding(name)
    return
  end
  local i = 1
  for key in keys:gmatch("[^%s]+") do
    local prefix = i == 1 and '' or i
    mp.remove_key_binding(name..prefix)
    i = i + 1
  end
end

-- 添加播放列表交互按键绑定
function add_keybinds()
  bind_keys_forced(settings.key_moveup, 'moveup', moveup, "repeatable")
  bind_keys_forced(settings.key_movedown, 'movedown', movedown, "repeatable")
  bind_keys_forced(settings.key_movepageup, 'movepageup', movepageup, "repeatable")
  bind_keys_forced(settings.key_movepagedown, 'movepagedown', movepagedown, "repeatable")
  bind_keys_forced(settings.key_movebegin, 'movebegin', movebegin, "repeatable")
  bind_keys_forced(settings.key_moveend, 'moveend', moveend, "repeatable")
  bind_keys_forced(settings.key_selectfile, 'selectfile', selectfile)
  bind_keys_forced(settings.key_unselectfile, 'unselectfile', unselectfile)
  bind_keys_forced(settings.key_playfile, 'playfile', playfile)
  bind_keys_forced(settings.key_removefile, 'removefile', removefile, "repeatable")
  bind_keys_forced(settings.key_closeplaylist, 'closeplaylist', remove_keybinds)
end

-- 移除按键绑定并隐藏播放列表
function remove_keybinds()
  keybindstimer:kill()
  keybindstimer = mp.add_periodic_timer(settings.playlist_display_timeout, remove_keybinds)
  keybindstimer:kill()
  playlist_overlay.data = ""
  playlist_overlay:remove()
  if is_terminal_mode() then
    mp.osd_message("")
  end
  playlist_visible = false
  if settings.reset_cursor_on_close then
    resetcursor()
  end
  if settings.dynamic_binds then
    unbind_keys(settings.key_moveup, 'moveup')
    unbind_keys(settings.key_movedown, 'movedown')
    unbind_keys(settings.key_movepageup, 'movepageup')
    unbind_keys(settings.key_movepagedown, 'movepagedown')
    unbind_keys(settings.key_movebegin, 'movebegin')
    unbind_keys(settings.key_moveend, 'moveend')
    unbind_keys(settings.key_selectfile, 'selectfile')
    unbind_keys(settings.key_unselectfile, 'unselectfile')
    unbind_keys(settings.key_playfile, 'playfile')
    unbind_keys(settings.key_removefile, 'removefile')
    unbind_keys(settings.key_closeplaylist, 'closeplaylist')
  end
end

keybindstimer = mp.add_periodic_timer(settings.playlist_display_timeout, remove_keybinds)
keybindstimer:kill()

if not settings.dynamic_binds then
  add_keybinds()
end

if settings.loadfiles_on_idle_start and mp.get_property_number('playlist-count', 0) == 0 then
  playlist()
end

mp.observe_property('playlist-count', "number", function(_, plcount)
  -- 如果承诺在播放列表大小增加时排序，则执行
  if settings.sortplaylist_on_file_add and (plcount > plen) then
    msg.info("添加的文件将自动排序")
    refresh_globals()
    sortplaylist()
  end
  refresh_UI()
  resolve_titles()
end)
mp.observe_property('osd-dimensions', 'native', refresh_UI)

-- URL 标题请求队列
url_request_queue = {}
function url_request_queue.push(item) table.insert(url_request_queue, item) end
function url_request_queue.pop() return table.remove(url_request_queue, 1) end
local url_titles_to_fetch = url_request_queue
local ongoing_url_requests = {}

-- URL 标题获取节流器
function url_fetching_throttler()
  if #url_titles_to_fetch == 0 then
    url_title_fetch_timer:kill()
  end

  local ongoing_url_requests_count = 0
  for _, ongoing in pairs(ongoing_url_requests) do
    if ongoing then
      ongoing_url_requests_count = ongoing_url_requests_count + 1
    end
  end

  -- 如果有可用槽位，开始解析一些 URL 标题
  local amount_to_fetch = math.max(0, settings.concurrent_title_resolve_limit - ongoing_url_requests_count)
  for index=1,amount_to_fetch,1 do
    local file = url_titles_to_fetch.pop()
    if file then
      ongoing_url_requests[file] = true
      resolve_ytdl_title(file)
    end
  end
end

url_title_fetch_timer = mp.add_periodic_timer(0.1, url_fetching_throttler)
url_title_fetch_timer:kill()

-- 本地标题请求队列
local_request_queue = {}
function local_request_queue.push(item) table.insert(local_request_queue, item) end
function local_request_queue.pop() return table.remove(local_request_queue, 1) end
local local_titles_to_fetch = local_request_queue
local ongoing_local_request = false

-- 仅允许 1 个并发的本地标题解析进程
function local_fetching_throttler()
  if not ongoing_local_request then
    local file = local_titles_to_fetch.pop()
    if file then
      ongoing_local_request = true
      resolve_ffprobe_title(file)
    end
  end
end

-- 解析标题（URL 和本地）
function resolve_titles()
  if settings.prefer_titles == 'none' then return end
  if not settings.resolve_url_titles and not settings.resolve_local_titles then return end

  local length = mp.get_property_number('playlist-count', 0)
  if length < 2 then return end
  -- 遍历所有条目，因为我们无法预测它如何变化
  local added_urls = false
  local added_local = false
  for i=0,length - 1,1 do
    local filename = mp.get_property('playlist/'..i..'/filename')
    local title = mp.get_property('playlist/'..i..'/title')
    if i ~= pos
      and filename
      and not title
      and not title_table[filename]
      and not requested_titles[filename]
    then
      requested_titles[filename] = true
      if filename:match('^https?://') and settings.resolve_url_titles then
        url_titles_to_fetch.push(filename)
        added_urls = true
      elseif settings.prefer_titles == "all" and settings.resolve_local_titles then
        local_titles_to_fetch.push(filename)
        added_local = true
      end
    end
  end
  if added_urls then
    url_title_fetch_timer:resume()
  end
  if added_local then
    local_fetching_throttler()
  end
end

-- 使用 yt-dlp 解析 URL 标题
function resolve_ytdl_title(filename)
  local args = {
    settings.youtube_dl_executable,
    '--no-playlist',
    '--flat-playlist',
    '-sJ',
    '--no-config',
    filename,
  }
  local req = mp.command_native_async(
    {
      name = "subprocess",
      args = args,
      playback_only = false,
      capture_stdout = true
    },
    function (success, res)
      ongoing_url_requests[filename] = false
      if res.killed_by_us then
        msg.verbose('解析 URL 标题请求超时 ' .. filename)
        return
      end
      if res.status == 0 then
        local json, err = utils.parse_json(res.stdout)
        if not err then
          local is_playlist = json['_type'] and json['_type'] == 'playlist'
          local title = (is_playlist and '[playlist]: ' or '') .. json['title']
          msg.verbose(filename .. " 解析为 '" .. title .. "'")
          title_table[filename] = title
          mp.set_property_native('user-data/playlistmanager/titles', title_table)
          refresh_UI()
        else
          msg.error("解析 json 失败，原因: "..(err or "未知"))
        end
      else
        msg.error("解析 URL 标题失败 "..filename.." 错误: "..(res.error or "未知"))
      end
    end
  )

  mp.add_timeout(
    settings.resolve_title_timeout,
    function()
      mp.abort_async_command(req)
      ongoing_url_requests[filename] = false
    end
  )
end

-- 使用 ffprobe 解析本地文件标题
function resolve_ffprobe_title(filename)
  local args = { "ffprobe", "-show_format", "-show_entries", "format=tags", "-loglevel", "quiet", filename }
  local req = mp.command_native_async(
    {
      name = "subprocess",
      args = args,
      playback_only = false,
      capture_stdout = true
    },
    function (success, res)
      ongoing_local_request = false
      local_fetching_throttler()
      if res.killed_by_us then
        msg.verbose('解析本地标题请求超时 ' .. filename)
        return
      end
      if res.status == 0 then
        local title = string.match(res.stdout, "title=([^\n\r]+)")
        if title then
          msg.verbose(filename .. " 解析为 '" .. title .. "'")
          title_table[filename] = title
          mp.set_property_native('user-data/playlistmanager/titles', title_table)
          refresh_UI()
        end
      else
        msg.error("解析本地标题失败 "..filename.." 错误: "..(res.error or "未知"))
      end
    end
  )
end

-- 脚本消息处理器
function handlemessage(msg, value, value2)
  if msg == "show" and value == "playlist" then
    if value2 ~= "toggle" then
      showplaylist(value2)
      return
    else
      toggle_playlist(showplaylist)
      return
    end
  end
  if msg == "show" and value == "playlist-nokeys" then
    if value2 ~= "toggle" then
      showplaylist_non_interactive(value2)
      return
    else
      toggle_playlist(showplaylist_non_interactive)
      return
    end
  end
  if msg == "show" and value == "filename" and strippedname and value2 then
    mp.commandv('show-text', strippedname, tonumber(value2)*1000 ) ; return
  end
  if msg == "show" and value == "filename" and strippedname then
    mp.commandv('show-text', strippedname ) ; return
  end
  if msg == "sort" then sortplaylist(value) ; return end
  if msg == "shuffle" then shuffleplaylist() ; return end
  if msg == "reverse" then reverseplaylist() ; return end
  if msg == "loadfiles" then playlist(value) ; return end
  if msg == "save" then save_playlist(value) ; return end
  if msg == "save-interactive" then activate_playlist_name_prompt() ; return end
  if msg == "open-menu" then open_menu() ; return end
  if msg == "select-playlist" then select_playlist() ; return end
  if msg == "playlist-next" then playlist_next() ; return end
  if msg == "playlist-prev" then playlist_prev() ; return end
  if msg == "playlist-next-random" then playlist_random() ; return end
  if msg == "close" then remove_keybinds() end
end

mp.register_script_message("playlistmanager", handlemessage)

-- 绑定额外功能按键
bind_keys(settings.key_sortplaylist, "sortplaylist", sortplaylist_by_next_mode)
bind_keys(settings.key_shuffleplaylist, "shuffleplaylist", shuffleplaylist)
bind_keys(settings.key_reverseplaylist, "reverseplaylist", reverseplaylist)
bind_keys(settings.key_loadfiles, "loadfiles", playlist)
bind_keys(settings.key_saveplaylist, "saveplaylist", activate_playlist_save)
bind_keys(settings.key_selectplaylist, "selectplaylist", select_playlist)
bind_keys(settings.key_openmenu, "openmenu", open_menu)
bind_keys(settings.key_showplaylist, "showplaylist", showplaylist)
bind_keys(
  settings.key_peek_at_playlist,
  "peek_at_playlist",
  handle_complex_playlist_toggle,
  { complex=true }
)

-- 注册事件
mp.register_event("start-file", on_start_file)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_end_file)
mp.add_hook("on_preloaded", 50, on_preloaded_hook)