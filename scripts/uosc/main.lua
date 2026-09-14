-- ==============================================================================
-- main.lua — uosc UI 框架主入口
-- ==============================================================================
-- 功能概述：
--   1. 这是 uosc 的启动入口，负责加载所有模块、初始化配置、状态和 UI 元素
--   2. 注册 mpv 属性观察者（observers）和事件监听器（event handlers）
--   3. 处理来自 input.conf 的快捷键绑定和脚本消息
--   4. 管理所有 UI 元素的创建、销毁和生命周期
-- ==============================================================================
-- 原作者：tomasklaen (https://github.com/tomasklaen/uosc)
-- 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 版本声明与基础配置
-- ==============================================================================

--[[ uosc | https://github.com/tomasklaen/uosc ]]
-- 定义 uosc 版本号
local uosc_version = '5.12.0'

-- 向其他脚本（如 console.lua）广播 uosc 版本信息
mp.commandv('script-message', 'uosc-version', uosc_version)

-- 强制关闭 mpv 自带的 OSC（屏显控制栏），由 uosc 全权接管
mp.set_property('osc', 'no')

-- ==============================================================================
-- 2. 模块加载
-- ==============================================================================

assdraw = require('mp.assdraw')  -- ASS 绘图模块（用于 OSD 渲染）
opt = require('mp.options')      -- 配置读取模块
utils = require('mp.utils')      -- 工具函数模块
msg = require('mp.msg')          -- 日志输出模块
osd = mp.create_osd_overlay('ass-events')  -- 创建 OSD 图层（用于所有 UI 渲染）
QUARTER_PI_SIN = math.sin(math.pi / 4)     -- 预计算 45° 正弦值（用于圆角计算）

-- 加载标准库（提供各种工具函数）
require('lib/std')

-- ==============================================================================
-- 3. 默认配置 (Defaults)
-- 这些值会被 uosc.conf 中的用户配置覆盖
-- ==============================================================================

defaults = {
    -- 时间轴（进度条）配置
    timeline_style = 'line',          -- 进度条样式：'line'（细线）或 'bar'（粗条）
    timeline_line_width = 2,          -- 细线样式下的线宽（像素）
    timeline_size = 40,               -- 进度条展开时的高度（像素）
    progress = 'windowed',            -- 精简进度条显示模式：'windowed'（窗口模式）/ 'fullscreen' / 'always' / 'never'
    progress_size = 2,                -- 精简进度条的高度（像素）
    progress_line_width = 20,         -- 精简进度条的宽度（像素）
    timeline_persistency = '',        -- 进度条常驻显示的条件（如 paused / audio / video 等）
    timeline_border = 1,              -- 进度条顶部边框高度（像素）
    timeline_step = '5',              -- 滚轮在进度条上滚动时的跳转秒数（加 ! 后缀表示精确跳转）
    timeline_cache = true,            -- 是否显示缓存进度指示
    timeline_heatmap = 'overlay',     -- YouTube 热力图显示模式：'overlay' / 'above' / 'no'

    -- 控制栏按钮配置（语法复杂，支持条件显示、徽章等）
    controls =
    'menu,gap,<video,audio>subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,gap,space,<video,audio>speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen',
    controls_size = 32,               -- 控制栏按钮大小（像素）
    controls_margin = 8,              -- 控制栏距屏幕边缘的距离（像素）
    controls_spacing = 2,             -- 按钮之间的间距（像素）
    controls_persistency = '',        -- 控制栏常驻显示的条件

    -- 音量控件配置
    volume = 'right',                 -- 音量控件位置：'none' / 'left' / 'right'
    volume_size = 0,                 -- 音量控件宽度（像素）
    volume_persistency = '',          -- 音量控件常驻显示的条件
    volume_border = 1,                -- 音量控件边框厚度（像素）
    volume_step = 1,                  -- 每次调整音量的步进值（百分比）

    -- 播放速度控件配置
    speed_persistency = '',           -- 速度控件常驻显示的条件
    speed_step = 0.1,                 -- 速度调整步进值
    speed_step_is_factor = false,     -- 是否以倍率方式调整（true = 乘除，false = 加减）

    -- 菜单配置
    menu_item_height = 36,            -- 菜单项高度（像素）
    menu_min_width = 260,             -- 菜单最小宽度（像素）
    menu_padding = 4,                 -- 菜单内边距（像素）
    menu_type_to_search = true,       -- 是否在菜单中输入字符即触发搜索

    -- 顶栏配置
    top_bar = 'no-border',            -- 顶栏显示模式：'never' / 'no-border' / 'always'
    top_bar_size = 40,                -- 顶栏高度（像素）
    top_bar_persistency = '',         -- 顶栏常驻显示的条件
    top_bar_controls = 'right',       -- 顶栏窗口控制按钮位置：'no' / 'left' / 'right'
    top_bar_title = 'yes',            -- 顶栏标题：'no' / 'yes' / 自定义模板字符串
    top_bar_alt_title = '',           -- 备选标题模板
    top_bar_alt_title_place = 'below',-- 备选标题显示方式：'below'（下方） / 'toggle'（点击切换）
    top_bar_flash_on = 'video,audio', -- 加载哪些类型文件时顶栏闪动提示

    -- 窗口边框配置（无边框模式下）
    window_border_size = 1,

    -- 自动连播与随机播放
    autoload = false,                 -- 播放结束后是否自动加载同目录下一文件
    shuffle = false,                  -- 是否启用随机播放模式

    -- 界面缩放与外观
    scale = 1,                        -- 界面整体缩放系数
    scale_fullscreen = 1.3,           -- 全屏模式下的额外缩放系数
    font_scale = 1,                   -- 字体缩放系数
    text_border = 1.2,                -- 文字边框厚度
    border_radius = 4,                -- 按钮/菜单圆角半径（像素）
    color = '',                       -- 颜色覆写（RGB HEX，逗号分隔）
    opacity = '',                     -- 透明度覆写（值范围 0~1，逗号分隔）
    animation_duration = 100,         -- 动画持续时间（毫秒）
    refine = '',                      -- 性能增强功能（text_width / sorting）
    flash_duration = 1000,            -- 闪动持续时间（毫秒）
    proximity_in = 40,                -- 鼠标进入元素的触发距离（像素）
    proximity_out = 120,              -- 鼠标离开元素的触发距离（像素）

    -- 时间显示
    total_time = false,               -- 已废弃，由 destination_time 替代
    destination_time = 'playtime-remaining', -- 目标时间显示模式：'total' / 'playtime-remaining' / 'time-remaining'
    time_precision = 0,               -- 时间显示精度（小数位数）

    font_bold = false,                -- 是否全局使用粗体
    autohide = false,                 -- 是否自动隐藏光标
    buffered_time_threshold = 60,     -- 缓冲时间显示阈值（秒）

    pause_indicator = 'flash',        -- 暂停指示器模式：'flash' / 'static' / 'manual'

    -- 流媒体画质选项
    stream_quality_options = '4320,2160,1440,1080,720,480,360,240,144',

    -- 文件类型定义（扩展名列表）
    video_types =
    '3g2,3gp,asf,avi,f4v,flv,h264,h265,m2ts,m4v,mkv,mov,mp4,mp4v,mpeg,mpg,ogm,ogv,rm,rmvb,ts,vob,webm,wmv,y4m',
    audio_types =
    'aac,ac3,aiff,ape,au,cue,dsf,dts,flac,m4a,mid,midi,mka,mp3,mp4a,oga,ogg,opus,spx,tak,tta,wav,weba,wma,wv',
    image_types = 'apng,avif,bmp,gif,j2k,jp2,jfif,jpeg,jpg,jxl,mj2,png,svg,tga,tif,tiff,webp',
    subtitle_types = 'aqt,ass,gsub,idx,jss,lrc,mks,pgs,pjs,psb,rt,sbv,slt,smi,sub,sup,srt,ssa,ssf,ttxt,txt,usf,vt,vtt',
    playlist_types = 'm3u,m3u8,pls,url,cue',

    -- autoload 加载的文件类型
    load_types = 'video,audio,image',

    -- 文件浏览
    default_directory = '~/',         -- 打开文件菜单的默认目录
    show_hidden_files = false,        -- 是否显示隐藏文件
    use_trash = false,                -- 删除文件时是否移入回收站

    -- OSD 边距与章节标记
    adjust_osd_margins = true,        -- 是否根据 UI 显隐自动调整 OSD 边距
    chapter_ranges = 'openings:30abf964,endings:30abf964,ads:c54e4e80',  -- 章节范围颜色标记
    chapter_range_patterns = 'openings:オープニング;endings:エンディング', -- 章节标题匹配模式

-- 多语言与字幕下载
    languages = 'slang,en',           -- 界面语言优先级
    subtitles_directory = '~~/subtitles', -- 字幕下载保存目录

    disable_elements = '',            -- 禁用的 UI 元素 ID 列表
    
    -- 👇 [新增] 将硬编码的底层变量暴露为配置项
    open_subtitles_api_key = 'b0rd16N0bp7DETMpO4pYZwIqmQkZbYQr',  -- OpenSubtitles API 密钥
    render_delay = 1 / 60,            -- 渲染帧率上限（秒/帧）
}

-- 复制默认配置，作为运行时 options 表
options = table_copy(defaults)

-- ==============================================================================
-- 4. 配置更新函数 (handle_options)
-- 当 uosc.conf 中的配置发生变化时，此函数被调用
-- ==============================================================================
function handle_options(changed_options)
    -- 如果时间精度变化，清空时间戳缓存（因为显示格式变了）
    if changed_options.time_precision then
        timestamp_zero_rep_clear_cache()
    end
    -- 更新配置派生值（如颜色、透明度、文件类型等）
    update_config()
    -- 更新人类可读的时间显示（如 "01:23:45"）
    update_human_times()
    -- 应用用户禁用的 UI 元素
    Manager:disable('user', options.disable_elements)
    -- 通知所有 UI 元素配置已变化
    Elements:trigger('options')
    -- 更新鼠标与 UI 元素的接近度
    Elements:update_proximities()
    -- 请求重新渲染
    request_render()
end

-- 读取用户配置（从 uosc.conf）
opt.read_options(options, 'uosc', handle_options)

-- ==============================================================================
-- 5. 配置值规范化 (Normalize values)
-- 确保配置值在有效范围内
-- ==============================================================================

-- 确保 proximity_out > proximity_in（否则鼠标永远无法触发元素显示）
options.proximity_out = math.max(options.proximity_out, options.proximity_in + 1)

-- 如果 chapter_ranges 以 '^op|' 开头，重置为默认值（兼容旧版配置）
if options.chapter_ranges:sub(1, 4) == '^op|' then options.chapter_ranges = defaults.chapter_ranges end

-- 处理废弃的 total_time 配置
if options.total_time and options.destination_time == 'playtime-remaining' then
    msg.warn('`total_time` is deprecated. Use `destination_time` instead.')
    options.destination_time = 'total'
elseif not itable_index_of({'total', 'playtime-remaining', 'time-remaining'}, options.destination_time) then
    -- 如果 destination_time 无效，回退到默认值
    options.destination_time = 'playtime-remaining'
end

-- 规范化 top_bar_controls（只接受 'left' 或 'right'）
if not itable_index_of({'left', 'right'}, options.top_bar_controls) then
    options.top_bar_controls = options.top_bar_controls == 'yes' and 'right' or nil
end

-- ==============================================================================
-- 6. 国际化 (Internationalization)
-- ==============================================================================

local intl = require('lib/intl')  -- 加载国际化模块
t = intl.t                        -- 翻译函数（用于多语言支持）
require('lib/char_conv')          -- 字符转换（用于搜索时的模糊匹配）
fzy = require('lib/fzy')          -- fzy 模糊搜索算法

-- ==============================================================================
-- 7. 配置构建 (Config)
-- 将用户配置转换为内部使用的 config 表
-- ==============================================================================

-- 默认颜色配置（RGB HEX 格式，不带 #）
local config_defaults = {
    color = {
        foreground = serialize_rgba('ffffff').color,
        foreground_text = serialize_rgba('000000').color,
        background = serialize_rgba('000000').color,
        background_text = serialize_rgba('ffffff').color,
        curtain = serialize_rgba('111111').color,
        success = serialize_rgba('a5e075').color,
        error = serialize_rgba('ff616e').color,
        match = serialize_rgba('69c5ff').color,
        heatmap = serialize_rgba('00adee').color,
    },
    opacity = {
        timeline = 0.9,
        position = 1,
        chapters = 0.8,
        slider = 0.9,
        slider_gauge = 1,
        controls = 0,
        speed = 0.6,
        menu = 1,
        submenu = 0.4,
        border = 1,
        title = 1,
        tooltip = 1,
        thumbnail = 1,
        curtain = 0.8,
        idle_indicator = 0.8,
        audio_indicator = 0.5,
        buffering_indicator = 0.3,
        playlist_position = 0.8,
        heatmap = 0.4,
    },
}

-- 构建最终 config 表
config = {
    version = uosc_version,                           -- 版本号
    
    -- 👇 [修改] 原本写死的字符串，现在改为读取 options 选项
    open_subtitles_api_key = options.open_subtitles_api_key,  -- OpenSubtitles API 密钥
    open_subtitles_agent = 'uosc v' .. uosc_version,          -- User-Agent (跟随版本号，无需配置)

    -- 👇 [修改] 原本写死的 1 / 60，现在改为读取 options 选项
    render_delay = options.render_delay,              -- 渲染频率上限

    -- 从 mpv 配置中读取的 OSD 相关设置
    font = mp.get_property('options/osd-font'),
    osd_margin_x = mp.get_property('osd-margin-x'),
    osd_margin_y = mp.get_property('osd-margin-y'),
    osd_alignment_x = mp.get_property('osd-align-x'),
    osd_alignment_y = mp.get_property('osd-align-y'),

    -- 性能增强功能集（从 options.refine 解析）
    refine = create_set(comma_split(options.refine)),

    -- 文件类型扩展名表
    types = {
        video = comma_split(options.video_types),
        audio = comma_split(options.audio_types),
        image = comma_split(options.image_types),
        subtitle = comma_split(options.subtitle_types),
        playlist = comma_split(options.playlist_types),
        media = comma_split(options.video_types
            .. ',' .. options.audio_types
            .. ',' .. options.image_types
            .. ',' .. options.playlist_types),
        load = {}, -- 由 update_load_types() 填充
    },

    stream_quality_options = comma_split(options.stream_quality_options),
    top_bar_flash_on = comma_split(options.top_bar_flash_on),

    -- 章节范围配置（用于在进度条上标记 OP/ED/广告 等）
    chapter_ranges = (function()
        ---@type table<string, string[]> 备用匹配模式
        local alt_patterns = {}
        if options.chapter_range_patterns and options.chapter_range_patterns ~= '' then
            for _, definition in ipairs(split(options.chapter_range_patterns, ';+ *')) do
                local name_patterns = split(definition, ' *:')
                local name, patterns = name_patterns[1], name_patterns[2]
                if name and patterns then alt_patterns[name] = split(patterns, ',') end
            end
        end

        ---@type table<string, {color: string; opacity: number; patterns?: string[]}>
        local ranges = {}
        if options.chapter_ranges and options.chapter_ranges ~= '' then
            for _, definition in ipairs(split(options.chapter_ranges, ' *,+ *')) do
                local name_color = split(definition, ' *:+ *')
                local name, color = name_color[1], name_color[2]
                if name and color
                    and name:match('^[a-zA-Z0-9_]+$') and color:match('^[a-fA-F0-9]+$')
                    and (#color == 6 or #color == 8) then
                    local range = serialize_rgba(name_color[2])  -- 解析颜色（支持 RRGGBB 或 RRGGBBAA）
                    range.patterns = alt_patterns[name]
                    ranges[name_color[1]] = range
                end
            end
        end
        return ranges
    end)(),

    -- 颜色与透明度
    color = table_copy(config_defaults.color),
    opacity = table_copy(config_defaults.opacity),

    -- 鼠标离开后，哪些元素应该淡出
    cursor_leave_fadeout_elements = {'timeline', 'volume', 'top_bar', 'controls'},

    -- 进度条滚轮步进值（解析 options.timeline_step）
    timeline_step = 5,
    timeline_step_flag = '',
}

-- ==============================================================================
-- 8. 文件类型加载函数 (update_load_types)
-- 根据 options.load_types 决定 autoload 加载哪些类型的文件
-- ==============================================================================
function update_load_types()
    local extensions = {}
    local types = create_set(comma_split(options.load_types:lower()))

    -- 如果包含 'same'，则与当前文件类型保持一致
    if types.same then
        types.same = nil
        if state and state.type then types[state.type] = true end
    end

    -- 遍历所有类型，收集对应的扩展名
    for _, name in ipairs(table_keys(types)) do
        local type_extensions = config.types[name]
        if type(type_extensions) == 'table' then
            itable_append(extensions, type_extensions)
        else
            msg.warn('Unknown load type: ' .. name)
        end
    end

    config.types.load = extensions
end

-- ==============================================================================
-- 9. 配置更新函数 (update_config)
-- 将 options 中的值处理并存入 config 表
-- ==============================================================================
function update_config()
    -- 如果启用 autoload，设置 mpv 的 keep-open 和 keep-open-pause
    if options.autoload then
        mp.commandv('set', 'keep-open', 'yes')
        mp.commandv('set', 'keep-open-pause', 'no')
    end

    -- 为各个 UI 元素添加 `{element}_persistency` 配置属性
    -- 例如 timeline_persistency = "paused,video" 表示在暂停或有视频时保持显示
    for _, name in ipairs({'timeline', 'controls', 'volume', 'top_bar', 'speed'}) do
        local option_name = name .. '_persistency'
        local value, flags = options[option_name], {}
        if type(value) == 'string' then
            for _, state in ipairs(comma_split(value)) do flags[state] = true end
        end
        config[option_name] = flags
    end

    -- 解析透明度配置
    config.opacity = table_assign({}, config_defaults.opacity, serialize_key_value_list(options.opacity,
        function(value, key)
            return clamp(0, tonumber(value) or config.opacity[key], 1)
        end
    ))

    -- 解析颜色配置
    config.color = table_assign({}, config_defaults.color, serialize_key_value_list(options.color, function(value)
        return serialize_rgba(value).color
    end))

    -- 全局颜色简写（方便其他模块使用）
    fg, bg = config.color.foreground, config.color.background
    fgt, bgt = config.color.foreground_text, config.color.background_text

    -- 解析进度条滚轮步进值
    do
        local is_exact = options.timeline_step:sub(-1) == '!'
        config.timeline_step = tonumber(is_exact and options.timeline_step:sub(1, -2) or options.timeline_step)
        config.timeline_step_flag = is_exact and 'exact' or ''
    end

    -- 更新 load_types
    update_load_types()
end
update_config()

-- ==============================================================================
-- 10. 默认菜单项 (create_default_menu_items)
-- 当 input.conf 中没有定义菜单项时，使用这些默认项
-- ==============================================================================
function create_default_menu_items()
    return {
        {title = t('Subtitles'), value = 'script-binding uosc/subtitles'},
        {title = t('Audio tracks'), value = 'script-binding uosc/audio'},
        {title = t('Stream quality'), value = 'script-binding uosc/stream-quality'},
        {title = t('Playlist'), value = 'script-binding uosc/items'},
        {title = t('Chapters'), value = 'script-binding uosc/chapters'},
        {
            title = t('Navigation'),
            items = {
                {title = t('Next'), hint = t('playlist or file'), value = 'script-binding uosc/next'},
                {title = t('Prev'), hint = t('playlist or file'), value = 'script-binding uosc/prev'},
                {title = t('Delete file & Next'), value = 'script-binding uosc/delete-file-next'},
                {title = t('Delete file & Prev'), value = 'script-binding uosc/delete-file-prev'},
                {title = t('Delete file & Quit'), value = 'script-binding uosc/delete-file-quit'},
                {title = t('Open file'), value = 'script-binding uosc/open-file'},
            },
        },
        {
            title = t('Utils'),
            items = {
                {
                    title = t('Aspect ratio'),
                    items = {
                        {title = t('Default'), value = 'set video-aspect-override "-1"'},
                        {title = '16:9', value = 'set video-aspect-override "16:9"'},
                        {title = '4:3', value = 'set video-aspect-override "4:3"'},
                        {title = '2.35:1', value = 'set video-aspect-override "2.35:1"'},
                    },
                },
                {title = t('Audio devices'), value = 'script-binding uosc/audio-device'},
                {title = t('Editions'), value = 'script-binding uosc/editions'},
                {title = t('Screenshot'), value = 'async screenshot'},
                {title = t('Key bindings'), value = 'script-binding uosc/keybinds'},
                {title = t('Show in directory'), value = 'script-binding uosc/show-in-directory'},
                {title = t('Open config folder'), value = 'script-binding uosc/open-config-directory'},
                {title = t('Update uosc'), value = 'script-binding uosc/update'},
            },
        },
        {title = t('Quit'), value = 'quit'},
    }
end

-- ==============================================================================
-- 11. 状态表 (State)
-- 存储播放器当前状态的所有变量
-- ==============================================================================

display = {ax = 0, ay = 0, bx = 1280, by = 720, width = 1280, height = 720, initialized = false}
cursor = require('lib/cursor')  -- 鼠标光标管理模块

state = {
    -- 操作系统平台检测
    platform = (function()
        local platform = mp.get_property_native('platform')
        if platform then
            if itable_index_of({'windows', 'darwin'}, platform) then return platform end
        else
            if os.getenv('windir') ~= nil then return 'windows' end
            local homedir = os.getenv('HOME')
            if homedir ~= nil and string.sub(homedir, 1, 6) == '/Users' then return 'darwin' end
        end
        return 'linux'
    end)(),

    cwd = mp.get_property('working-directory'),  -- 当前工作目录
    path = nil,                   -- 当前文件路径或 URL
    history = {},                 -- 播放历史（存储完整路径）
    time = nil,                   -- 当前播放时间（秒）
    speed = 1,                    -- 播放速度
    ---@type number|nil
    duration = nil,               -- 当前媒体总时长（秒）
    max_seconds = nil,            -- 时间轴预期达到的最大秒数（考虑速度）
    time_human = nil,             -- 当前播放时间（人类可读格式）
    destination_time_human = nil, -- 目标时间（取决于 destination_time 配置）
    pause = mp.get_property_native('pause'),
    ime_active = mp.get_property_native('input-ime'),  -- 输入法是否激活
    chapters = {},
    chapter_ranges = {},
    border = mp.get_property_native('border'),
    title_bar = mp.get_property_native('title-bar'),
    fullscreen = mp.get_property_native('fullscreen'),
    maximized = mp.get_property_native('window-maximized'),
    fullormaxed = mp.get_property_native('fullscreen') or mp.get_property_native('window-maximized'),
    render_timer = nil,
    render_last_time = 0,
    volume = mp.get_property_native('volume'),
    volume_max = mp.get_property_native('volume-max'),
    mute = nil,
    type = nil,                   -- 文件类型：'video' / 'image' / 'audio'
    is_idle = false,
    is_video = false,
    is_audio = false,             -- 是否纯音频文件（mp3 等）
    is_image = false,
    is_stream = false,            -- 是否网络流媒体
    has_image = false,
    has_audio = false,
    has_sub = false,
    has_chapter = false,
    has_playlist = false,
    shuffle = options.shuffle,    -- 是否随机播放
    ---@type nil|{pos: number; paths: string[]}
    shuffle_history = nil,        -- 随机播放历史
    on_shuffle = function() state.shuffle_history = nil end,
    mouse_bindings_enabled = false,
    uncached_ranges = nil,        -- 未缓存的时间段（流媒体缓冲指示）
    cache = nil,
    cache_buffering = 100,        -- 缓冲进度（0~100）
    cache_underrun = false,       -- 是否发生缓存欠载
    cache_duration = nil,         -- 缓存时长（秒）
    core_idle = false,            -- 播放器核心是否空闲
    eof_reached = false,          -- 是否到达文件末尾
    render_delay = config.render_delay,
    playlist_count = 0,
    playlist_pos = 0,
    margin_top = 0,
    margin_bottom = 0,
    margin_left = 0,
    margin_right = 0,
    hidpi_scale = 1,
    scale = 1,
    radius = 0,
}

buttons = require('lib/buttons')           -- 按钮管理模块
thumbnail = {width = 0, height = 0, disabled = false}  -- 缩略图状态
external = {}                              -- 外部脚本设置的属性
key_binding_overwrites = {}                -- 快捷键覆盖表
Elements = require('elements/Elements')    -- UI 元素管理器
Menu = require('elements/Menu')            -- 菜单系统

-- 加载状态相关的工具模块
require('lib/utils')
require('lib/text')
require('lib/ass')
require('lib/menus')

-- ==============================================================================
-- 12. ziggy 可执行文件路径检测
-- ziggy 是一个辅助工具，用于剪贴板操作等
-- ==============================================================================
do
    local bin = 'ziggy-' .. (state.platform == 'windows' and 'windows.exe' or state.platform)
    config.ziggy_path = os.getenv('MPV_UOSC_ZIGGY') or join_path(mp.get_script_directory(), join_path('bin', bin))
end

-- ==============================================================================
-- 13. 状态更新函数 (State Updaters)
-- ==============================================================================

-- 更新显示尺寸
function update_display_dimensions()
    state.scale = (state.hidpi_scale or 1) * (state.fullormaxed and options.scale_fullscreen or options.scale)
    state.radius = round(options.border_radius * state.scale)
    local real_width, real_height = mp.get_osd_size()
    if real_width <= 0 then return end
    display.bx, display.width, display.by, display.height = real_width, real_width, real_height, real_height
    display.initialized = true

    -- 通知所有 UI 元素显示尺寸已变化
    Elements:trigger('display')

    -- 更新鼠标与元素的接近度
    Elements:update_proximities()
    request_render()
end

-- 更新全屏/最大化状态
function update_fullormaxed()
    state.fullormaxed = state.fullscreen or state.maximized
    update_display_dimensions()
    Elements:trigger('prop_fullormaxed', state.fullormaxed)
    cursor:leave()  -- 光标离开，避免残留状态
end

-- 更新时长
function update_duration()
    local duration = state._duration and ((state.rebase_start_time == false and state.start_time)
        and (state._duration + state.start_time) or state._duration)
    set_state('duration', duration)
    update_human_times()
end

-- 更新人类可读的时间显示
function update_human_times()
    state.speed = state.speed or 1
    if state.time then
        if state.duration then
            if options.destination_time == 'playtime-remaining' then
                state.destination_time_human = format_time((state.time - state.duration) / state.speed, state.duration)
            elseif options.destination_time == 'total' then
                state.destination_time_human = format_time(state.duration, state.duration)
            else
                state.destination_time_human = format_time(state.time - state.duration, state.duration)
            end
        else
            state.destination_time_human = nil
        end
        state.time_human = format_time(state.time, state.duration or state.time)
    else
        state.time_human, state.destination_time_human = nil, nil
    end
end

-- ==============================================================================
-- 14. OSD 边距更新 (update_margins)
-- 通知 mpv 和其他脚本（如 console.lua）屏幕未被 UI 遮挡的区域
-- 用于字幕等 OSD 元素自动避开 UI 控件
-- ==============================================================================
function update_margins()
    if display.height == 0 then return end

    local function causes_margin(element)
        return element and element.enabled and (element:is_persistent() or element.min_visibility > 0.5)
    end
    local timeline, top_bar, controls, volume = Elements.timeline, Elements.top_bar, Elements.controls, Elements.volume
    local left, right, top, bottom = 0, 0, 0, 0

    if causes_margin(controls) then
        bottom = (display.height - controls.ay) / display.height
    elseif causes_margin(timeline) then
        bottom = (display.height - timeline.ay) / display.height
    end

    if causes_margin(top_bar) then top = top_bar.title_by / display.height end

    if causes_margin(volume) then
        if options.volume == 'left' then
            left = volume.bx / display.width
        elseif options.volume == 'right' then
            right = volume.ax / display.width
        end
    end

    if top == state.margin_top and bottom == state.margin_bottom and
        left == state.margin_left and right == state.margin_right then
        return
    end

    state.margin_top = top
    state.margin_bottom = bottom
    state.margin_left = left
    state.margin_right = right

    -- 向其他脚本广播 OSD 边距信息
    if utils.shared_script_property_set then
        utils.shared_script_property_set('osc-margins', string.format('%f,%f,%f,%f', 0, 0, top, bottom))
    end
    mp.set_property_native('user-data/osc/margins', {l = left, r = right, t = top, b = bottom})

    if not options.adjust_osd_margins then return end
    local osd_margin_y, osd_margin_x, osd_factor_x = 0, 0, display.width / display.height * 720
    if config.osd_alignment_y == 'bottom' then
        osd_margin_y = round(bottom * 720)
    elseif config.osd_alignment_y == 'top' then
        osd_margin_y = round(top * 720)
    end
    if config.osd_alignment_x == 'left' then
        osd_margin_x = round(left * osd_factor_x)
    elseif config.osd_alignment_x == 'right' then
        osd_margin_x = round(right * osd_factor_x)
    end
    mp.set_property_native('osd-margin-y', osd_margin_y + config.osd_margin_y)
    mp.set_property_native('osd-margin-x', osd_margin_x + config.osd_margin_x)
end

-- ==============================================================================
-- 15. 状态设置辅助函数
-- ==============================================================================

-- 创建一个状态设置函数（用于属性观察者）
function create_state_setter(name, callback)
    return function(_, value)
        set_state(name, value)
        if callback then callback() end
        request_render()
    end
end

-- 设置状态值并触发相关事件
function set_state(name, value)
    state[name] = value
    local state_event = state['on_' .. name]
    if state_event then state_event(value) end
    Elements:trigger('prop_' .. name, value)
end

-- ==============================================================================
-- 16. 文件结束处理 (handle_file_end)
-- 视频播放完毕时，自动加载下一集（如果启用 autoload 或 shuffle）
-- ==============================================================================
function handle_file_end()
    local resume = false
    if not state.loop_file then
        if state.has_playlist then
            resume = state.shuffle and navigate_playlist(1)
        else
            resume = options.autoload and navigate_directory(1)
        end
    end
    if resume then mp.command('set pause no') end
end

-- 文件结束计时器（在文件即将结束时触发）
local file_end_timer = mp.add_timeout(1, handle_file_end)
file_end_timer:kill()

-- 加载当前目录中指定索引的文件
function load_file_index_in_current_directory(index)
    if not state.path or is_protocol(state.path) then return end

    local serialized = serialize_path(state.path)
    if serialized and serialized.dirname then
        local files, _dirs, error = read_directory(serialized.dirname, {
            types = config.types.load,
            hidden = options.show_hidden_files,
        })

        if error then
            msg.error(error)
            return
        end

        sort_strings(files)
        if index < 0 then index = #files + index + 1 end

        if files[index] then
            mp.commandv('loadfile', join_path(serialized.dirname, files[index]))
        end
    end
end

-- 更新渲染频率
function update_render_delay(name, fps)
    if fps then state.render_delay = 1 / fps end
end

-- 观察显示器刷新率
function observe_display_fps(name, fps)
    if fps then
        mp.unobserve_property(update_render_delay)
        mp.unobserve_property(observe_display_fps)
        mp.observe_property('display-fps', 'native', update_render_delay)
    end
end

-- ==============================================================================
-- 17. 状态钩子 (State Hooks)
-- 注册 mpv 事件监听器，响应文件加载、结束等事件
-- ==============================================================================

-- 文件加载事件
mp.register_event('file-loaded', function()
    local path = normalize_path(mp.get_property_native('path'))
    itable_delete_value(state.history, path)
    state.history[#state.history + 1] = path
    set_state('path', path)

    -- 根据文件类型闪动顶栏
    for _, type in ipairs(config.top_bar_flash_on) do
        if state['is_' .. type] then
            Elements:flash({'top_bar'})
            break
        end
    end
end)

-- 文件结束事件
mp.register_event('end-file', function(event)
    set_state('path', nil)
    if event.reason == 'eof' then
        file_end_timer:kill()
        handle_file_end()
    end
end)

-- 观察播放时间
mp.observe_property('playback-time', 'number', create_state_setter('time', function()
    -- 在文件即将结束时触发 handle_file_end
    file_end_timer:kill()
    if state.duration and state.time and not state.pause then
        local remaining = (state.duration - state.time) / state.speed
        if remaining < 5 then
            local timeout = remaining - 0.02
            if timeout > 0 then
                file_end_timer.timeout = timeout
                file_end_timer:resume()
            else
                handle_file_end()
            end
        end
    end

    update_human_times()
end))

-- 观察其他 mpv 属性
mp.observe_property('rebase-start-time', 'bool', create_state_setter('rebase_start_time', update_duration))
mp.observe_property('demuxer-start-time', 'number', create_state_setter('start_time', update_duration))
mp.observe_property('duration', 'number', create_state_setter('_duration', update_duration))
mp.observe_property('speed', 'number', create_state_setter('speed', update_human_times))

-- 观察轨道列表（用于检测文件类型）
mp.observe_property('track-list', 'native', function(name, value)
    local types = {sub = 0, image = 0, audio = 0, video = 0}
    for _, track in ipairs(value) do
        if track.type == 'video' then
            if track.image or track.albumart then
                types.image = types.image + 1
            else
                types.video = types.video + 1
            end
        elseif types[track.type] then
            types[track.type] = types[track.type] + 1
        end
    end
    set_state('is_audio', types.video == 0 and types.audio > 0)
    set_state('is_image', types.image > 0 and types.video == 0 and types.audio == 0)
    set_state('has_image', types.image > 0)
    set_state('has_audio', types.audio > 0)
    set_state('has_many_audio', types.audio > 1)
    set_state('has_sub', types.sub > 0)
    set_state('has_many_sub', types.sub > 1)
    set_state('is_video', types.video > 0)
    set_state('has_many_video', types.video > 1)
    set_state('type', state.is_video and 'video' or state.is_audio and 'audio' or state.is_image and 'image' or nil)
    update_load_types()
    Elements:trigger('dispositions')
end)

-- 观察版本数
mp.observe_property('editions', 'number', function(_, editions)
    if editions then set_state('has_many_edition', editions > 1) end
    Elements:trigger('dispositions')
end)

-- 观察章节列表
mp.observe_property('chapter-list', 'native', function(_, chapters)
    local chapters, chapter_ranges = serialize_chapters(chapters), {}
    if chapters then chapters, chapter_ranges = serialize_chapter_ranges(chapters) end
    set_state('chapters', chapters)
    set_state('chapter_ranges', chapter_ranges)
    set_state('has_chapter', #chapters > 0)
    Elements:trigger('dispositions')
end)

-- 观察窗口状态
mp.observe_property('border', 'bool', create_state_setter('border'))
mp.observe_property('title-bar', 'bool', create_state_setter('title_bar'))
mp.observe_property('loop-file', 'native', create_state_setter('loop_file'))
mp.observe_property('ab-loop-a', 'number', create_state_setter('ab_loop_a'))
mp.observe_property('ab-loop-b', 'number', create_state_setter('ab_loop_b'))
mp.observe_property('playlist-pos-1', 'number', create_state_setter('playlist_pos'))
mp.observe_property('playlist-count', 'number', function(_, value)
    set_state('playlist_count', value)
    set_state('has_playlist', value > 1)
    Elements:trigger('dispositions')
end)
mp.observe_property('fullscreen', 'bool', create_state_setter('fullscreen', update_fullormaxed))
mp.observe_property('window-maximized', 'bool', create_state_setter('maximized', update_fullormaxed))

-- 观察空闲状态
mp.observe_property('idle-active', 'bool', function(_, idle)
    set_state('is_idle', idle)
    Elements:trigger('dispositions')
    mp.commandv('script-message-to', 'thumbfast', 'clear')
end)

-- 观察暂停状态
mp.observe_property('pause', 'bool', create_state_setter('pause', function() file_end_timer:kill() end))

-- 观察音量相关
mp.observe_property('volume', 'number', create_state_setter('volume'))
mp.observe_property('volume-max', 'number', create_state_setter('volume_max'))
mp.observe_property('mute', 'bool', create_state_setter('mute'))

-- 观察 OSD 尺寸
mp.observe_property('osd-dimensions', 'native', function(name, val)
    update_display_dimensions()
    request_render()
end)

-- 观察 HiDPI 缩放
mp.observe_property('display-hidpi-scale', 'native', create_state_setter('hidpi_scale', update_display_dimensions))

-- 观察缓存状态
mp.observe_property('cache', 'string', create_state_setter('cache'))
mp.observe_property('cache-buffering-state', 'number', create_state_setter('cache_buffering'))
mp.observe_property('demuxer-via-network', 'native', create_state_setter('is_stream', function()
    Elements:trigger('dispositions')
end))

-- 观察缓存状态（用于绘制未缓存范围）
mp.observe_property('demuxer-cache-state', 'native', function(prop, cache_state)
    local cached_ranges, bof, eof, uncached_ranges = nil, nil, nil, nil
    if cache_state then
        cached_ranges, bof, eof = cache_state['seekable-ranges'], cache_state['bof-cached'], cache_state['eof-cached']
        set_state('cache_underrun', cache_state['underrun'])
        set_state('cache_duration', not cache_state.eof and cache_state['cache-duration'] or nil)
    else
        cached_ranges = {}
    end

    if not (state.duration and (#cached_ranges > 0 or state.cache == 'yes' or
            (state.cache == 'auto' and state.is_stream))) then
        if state.uncached_ranges then set_state('uncached_ranges', nil) end
        set_state('cache_duration', nil)
        return
    end

    -- 规范化缓存范围
    local ranges = {}
    for _, range in ipairs(cached_ranges) do
        ranges[#ranges + 1] = {
            math.max(range['start'] or 0, 0),
            math.min(range['end'] or state.duration --[[@as number]], state.duration),
        }
    end
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    if bof then ranges[1][1] = 0 end
    if eof then ranges[#ranges][2] = state.duration end

    -- 将缓存范围反转，得到未缓存范围
    local inverted_ranges = {{0, state.duration}}
    for _, cached in pairs(ranges) do
        inverted_ranges[#inverted_ranges][2] = cached[1]
        inverted_ranges[#inverted_ranges + 1] = {cached[2], state.duration}
    end
    uncached_ranges = {}
    local last_range = nil
    for _, range in ipairs(inverted_ranges) do
        if last_range and last_range[2] + 0.5 > range[1] then
            last_range[2] = range[2]
        else
            if range[2] - range[1] > 0.5 then
                uncached_ranges[#uncached_ranges + 1] = range
                last_range = range
            end
        end
    end

    set_state('uncached_ranges', uncached_ranges)
end)

-- 观察显示刷新率
mp.observe_property('display-fps', 'native', observe_display_fps)
mp.observe_property('estimated-display-fps', 'native', update_render_delay)

-- 观察文件结束和核心空闲状态
mp.observe_property('eof-reached', 'native', create_state_setter('eof_reached'))
mp.observe_property('core-idle', 'native', create_state_setter('core_idle'))

-- ==============================================================================
-- 18. 快捷键绑定 (Key Binds)
-- 注册 uosc 的所有快捷键命令
-- ==============================================================================

-- 添加一个支持快捷键覆盖的绑定
---@param name string
---@param callback fun(event: table)
---@param flags nil|string
function bind_command(name, callback, flags)
    mp.add_key_binding(nil, name, function(...)
        if key_binding_overwrites[name] then
            mp.command(key_binding_overwrites[name])
        else
            callback(...)
        end
    end, flags)
end

-- UI 切换与闪动
bind_command('toggle-ui', function() Elements:toggle({'timeline', 'controls', 'volume', 'top_bar'}) end)
bind_command('flash-ui', function() Elements:flash({'timeline', 'controls', 'volume', 'top_bar'}) end)
bind_command('flash-timeline', function() Elements:flash({'timeline'}) end)
bind_command('flash-top-bar', function() Elements:flash({'top_bar'}) end)
bind_command('flash-volume', function() Elements:flash({'volume'}) end)
bind_command('flash-speed', function() Elements:flash({'speed'}) end)
bind_command('flash-pause-indicator', function() Elements:flash({'pause_indicator'}) end)
bind_command('flash-progress', function() Elements:flash({'progress'}) end)
bind_command('toggle-progress', function() Elements:maybe('timeline', 'toggle_progress') end)
bind_command('toggle-title', function() Elements:maybe('top_bar', 'toggle_title') end)
bind_command('decide-pause-indicator', function() Elements:maybe('pause_indicator', 'decide') end)

-- 菜单相关
bind_command('menu', function() toggle_menu_with_items() end)
bind_command('menu-blurred', function() toggle_menu_with_items({mouse_nav = true}) end)
bind_command('keybinds', function()
    if Menu:is_open('keybinds') then
        Menu:close()
    else
        open_command_menu({type = 'keybinds', items = get_keybinds_items(), search_style = 'palette'})
    end
end)

-- 字幕下载与加载
bind_command('download-subtitles', open_subtitle_downloader)
bind_command('load-subtitles', create_track_loader_menu_opener({
    prop = 'sub',
    title = t('Load subtitles'),
    loaded_message = t('Loaded subtitles'),
    allowed_types = itable_join(config.types.video, config.types.subtitle),
}))
bind_command('load-audio', create_track_loader_menu_opener({
    prop = 'audio',
    title = t('Load audio'),
    loaded_message = t('Loaded audio'),
    allowed_types = itable_join(config.types.video, config.types.audio),
}))
bind_command('load-video', create_track_loader_menu_opener({
    prop = 'video',
    title = t('Load video'),
    loaded_message = t('Loaded video'),
    allowed_types = config.types.video,
}))

-- 轨道选择菜单
bind_command('subtitles', create_select_tracklist_type_menu_opener({
    title = t('Subtitles'),
    type = 'sub',
    prop = 'sid',
    enable_prop = 'sub-visibility',
    secondary = {prop = 'secondary-sid', icon = 'vertical_align_top', enable_prop = 'secondary-sub-visibility'},
    load_command = 'script-binding uosc/load-subtitles',
    download_command = 'script-binding uosc/download-subtitles',
}))
bind_command('audio', create_select_tracklist_type_menu_opener({
    title = t('Audio'), type = 'audio', prop = 'aid', load_command = 'script-binding uosc/load-audio',
}))
bind_command('video', create_select_tracklist_type_menu_opener({
    title = t('Video'), type = 'video', prop = 'vid', load_command = 'script-binding uosc/load-video',
}))

-- 播放列表菜单
bind_command('playlist', create_self_updating_menu_opener({
    title = t('Playlist'),
    type = 'playlist',
    list_prop = 'playlist',
    footnote = t('Paste path or url to add.') .. ' ' .. t('%s to reorder.', 'ctrl+up/down/pgup/pgdn/home/end'),
    serializer = function(playlist)
        local items = {}
        local force_filename = mp.get_property_native('osd-playlist-entry') == 'filename'
        for index, item in ipairs(playlist) do
            local title = type(item.title) == 'string' and #item.title > 0 and item.title or false
            items[index] = {
                title = (not force_filename and title) and title
                    or (is_protocol(item.filename) and item.filename or serialize_path(item.filename).basename),
                hint = tostring(index),
                active = item.current,
                value = index,
            }
        end
        return items
    end,
    on_activate = function(event) mp.commandv('set', 'playlist-pos-1', tostring(event.value)) end,
    on_paste = function(event) mp.commandv('loadfile', tostring(event.value), 'append') end,
    on_key = function(event)
        if event.id == 'ctrl+c' and event.selected_item then
            local payload = mp.get_property_native('playlist/' .. (event.selected_item.value - 1) .. '/filename')
            set_clipboard(payload)
        end
    end,
    on_move = function(event)
        local from, to = event.from_index, event.to_index
        mp.commandv('playlist-move', tostring(from - 1), tostring(to - (to > from and 0 or 1)))
    end,
    on_remove = function(event) mp.commandv('playlist-remove', tostring(event.value - 1)) end,
}))

-- 章节菜单
bind_command('chapters', create_self_updating_menu_opener({
    title = t('Chapters'),
    type = 'chapters',
    list_prop = 'chapter-list',
    active_prop = 'chapter',
    serializer = function(chapters, current_chapter)
        local items = {}
        chapters = normalize_chapters(chapters)
        for index, chapter in ipairs(chapters) do
            items[index] = {
                title = chapter.title or '',
                hint = format_time(chapter.time, state.duration),
                value = index,
                active = index - 1 == current_chapter,
            }
        end
        return items
    end,
    on_activate = function(event) mp.commandv('set', 'chapter', tostring(event.value - 1)) end,
}))

-- 版本菜单
bind_command('editions', create_self_updating_menu_opener({
    title = t('Editions'),
    type = 'editions',
    list_prop = 'edition-list',
    active_prop = 'current-edition',
    serializer = function(editions, current_id)
        local items = {}
        for _, edition in ipairs(editions or {}) do
            local edition_id_1 = tostring(edition.id + 1)
            items[#items + 1] = {
                title = edition.title or t('Edition %s', edition_id_1),
                hint = edition_id_1,
                value = edition.id,
                active = edition.id == current_id,
            }
        end
        return items
    end,
    on_activate = function(event) mp.commandv('set', 'edition', event.value) end,
}))

-- 在文件管理器中显示当前文件
bind_command('show-in-directory', function()
    if not state.path or is_protocol(state.path) then return end

    if state.platform == 'windows' then
        utils.subprocess_detached({args = {'explorer', '/select,', state.path .. ' '}, cancellable = false})
    elseif state.platform == 'darwin' then
        utils.subprocess_detached({args = {'open', '-R', state.path}, cancellable = false})
    elseif state.platform == 'linux' then
        local result = utils.subprocess({args = {'nautilus', state.path}, cancellable = false})
        if result.status ~= 0 then
            utils.subprocess({args = {'xdg-open', serialize_path(state.path).dirname}, cancellable = false})
        end
    end
end)

-- 流媒体画质菜单
bind_command('stream-quality', open_stream_quality_menu)

-- 打开文件菜单
bind_command('open-file', open_open_file_menu)

-- 随机播放切换
bind_command('shuffle', function() set_state('shuffle', not state.shuffle) end)

-- 导航命令
bind_command('items', function()
    if state.has_playlist then
        mp.command('script-binding uosc/playlist')
    else
        mp.command('script-binding uosc/open-file')
    end
end)
bind_command('next', function() navigate_item(1) end)
bind_command('prev', function() navigate_item(-1) end)
bind_command('next-file', function() navigate_directory(1) end)
bind_command('prev-file', function() navigate_directory(-1) end)
bind_command('first', function()
    if state.has_playlist then
        mp.commandv('set', 'playlist-pos-1', '1')
    else
        load_file_index_in_current_directory(1)
    end
end)
bind_command('last', function()
    if state.has_playlist then
        mp.commandv('set', 'playlist-pos-1', tostring(state.playlist_count))
    else
        load_file_index_in_current_directory(-1)
    end
end)
bind_command('first-file', function() load_file_index_in_current_directory(1) end)
bind_command('last-file', function() load_file_index_in_current_directory(-1) end)

-- 删除文件并导航
bind_command('delete-file-prev', function() delete_file_navigate(-1) end)
bind_command('delete-file-next', function() delete_file_navigate(1) end)
bind_command('delete-file-quit', function()
    mp.command('stop')
    if state.path and not is_protocol(state.path) then delete_file(state.path) end
    mp.command('quit')
end)

-- 菜单导航命令
bind_command('menu-prev', function() Elements:maybe('menu', 'navigate_by_items', -1) end)
bind_command('menu-next', function() Elements:maybe('menu', 'navigate_by_items', 1) end)
bind_command('menu-prev-page', function() Elements:maybe('menu', 'navigate_by_page', -1) end)
bind_command('menu-next-page', function() Elements:maybe('menu', 'navigate_by_page', 1) end)
bind_command('menu-start', function() Elements:maybe('menu', 'navigate_by_items', -math.huge) end)
bind_command('menu-end', function() Elements:maybe('menu', 'navigate_by_items', math.huge) end)
bind_command('menu-activate', function() Elements:maybe('menu', 'activate_selected_item') end)
bind_command('menu-back', function() Elements:maybe('menu', 'back') end)

-- 音频设备菜单
bind_command('audio-device', create_self_updating_menu_opener({
    title = t('Audio devices'),
    type = 'audio-device-list',
    list_prop = 'audio-device-list',
    active_prop = 'audio-device',
    serializer = function(audio_device_list, current_device)
        current_device = current_device or 'auto'
        local ao = mp.get_property('current-ao') or ''
        local items = {}
        for _, device in ipairs(audio_device_list) do
            if device.name == 'auto' or string.match(device.name, '^' .. ao) then
                local hint = string.match(device.name, ao .. '/(.+)')
                if not hint then hint = device.name end
                items[#items + 1] = {
                    title = device.description:sub(1, 7) == 'Default'
                        and t('Default %s', device.description:sub(9))
                        or device.description,
                    hint = hint,
                    active = device.name == current_device,
                    value = device.name,
                }
            end
        end
        return items
    end,
    on_activate = function(event) mp.commandv('set', 'audio-device', event.value) end,
}))

-- 剪贴板相关
bind_command('paste', function()
    local has_playlist = mp.get_property_native('playlist-count') > 1
    mp.commandv('script-binding', 'uosc/paste-to-' .. (has_playlist and 'playlist' or 'open'))
end)
bind_command('paste-to-open', function()
    local payload = get_clipboard()
    if payload then mp.commandv('loadfile', payload) end
end)
bind_command('paste-to-playlist', function()
    if state.is_idle then
        mp.commandv('script-binding', 'uosc/paste-to-open')
    else
        local payload = get_clipboard()
        if payload then
            mp.commandv('loadfile', payload, 'append')
            mp.commandv('show-text', t('Added to playlist') .. ': ' .. payload, 3000)
        end
    end
end)
bind_command('copy-to-clipboard', function()
    if state.path then
        set_clipboard(state.path)
    else
        mp.commandv('show-text', t('Nothing to copy'), 3000)
    end
end)

-- 打开配置文件夹
bind_command('open-config-directory', function()
    local config_path = mp.command_native({'expand-path', '~~/mpv.conf'})
    local config = serialize_path(normalize_path(config_path))

    if config then
        local args
        if state.platform == 'windows' then
            args = {'explorer', '/select,', config.path}
        elseif state.platform == 'darwin' then
            args = {'open', '-R', config.path}
        elseif state.platform == 'linux' then
            args = {'xdg-open', config.dirname}
        end
        utils.subprocess_detached({args = args, cancellable = false})
    else
        msg.error('Couldn\'t serialize config path "' .. config_path .. '".')
    end
end)

-- 更新 uosc
bind_command('update', function()
    if not Elements:has('updater') then require('elements/Updater'):new() end
end)

-- ==============================================================================
-- 19. 脚本消息处理器 (Message Handlers)
-- 接收来自其他脚本或 mpv 命令的消息
-- ==============================================================================

mp.register_script_message('show-submenu', function(id) toggle_menu_with_items({submenu = id}) end)
mp.register_script_message('show-submenu-blurred', function(id)
    toggle_menu_with_items({submenu = id, mouse_nav = true})
end)

-- 打开菜单（接收 JSON 格式的菜单数据）
mp.register_script_message('open-menu', function(json, submenu_id)
    local data = utils.parse_json(json)
    if type(data) ~= 'table' or type(data.items) ~= 'table' then
        msg.error('open-menu: received json didn\'t produce a table with menu configuration')
    else
        open_command_menu(data, {submenu = submenu_id, on_close = data.on_close})
    end
end)

-- 更新菜单
mp.register_script_message('update-menu', function(json)
    local data = utils.parse_json(json)
    if type(data) ~= 'table' or type(data.items) ~= 'table' then
        msg.error('update-menu: received json didn\'t produce a table with menu configuration')
    else
        local menu = data.type and Menu:is_open(data.type)
        if menu then menu:update(data) end
    end
end)

-- 选择菜单项
mp.register_script_message('select-menu-item', function(type, item_index, menu_id)
    local menu = Menu:is_open(type)
    local index = tonumber(item_index)
    if menu and index and not menu.mouse_nav then
        index = round(index)
        if index > 0 and index <= #menu.current.items then
            menu:select_index(index, menu_id)
            menu:scroll_to_index(index, menu_id, true)
        end
    end
end)

-- 关闭菜单
mp.register_script_message('close-menu', function(type)
    if Menu:is_open(type) then Menu:close() end
end)

-- 菜单动作（如搜索取消、搜索更新）
mp.register_script_message('menu-action', function(name, ...)
    local menu = Menu:is_open()
    if menu then
        local method = ({
            ['search-cancel'] = 'search_cancel',
            ['search-query-update'] = 'search_query_update',
        })[name]
        if method then menu[method](menu, ...) end
    end
end)

-- thumbfast 缩略图信息
mp.register_script_message('thumbfast-info', function(json)
    local data = utils.parse_json(json)
    if type(data) ~= 'table' or not data.width or not data.height then
        thumbnail.disabled = true
        msg.error('thumbfast-info: received json didn\'t produce a table with thumbnail information')
    else
        thumbnail = data
        request_render()
    end
end)

-- 外部脚本设置属性
mp.register_script_message('set', function(name, value)
    external[name] = value
    Elements:trigger('external_prop_' .. name, value)
end)

-- 切换 UI 元素显隐
mp.register_script_message('toggle-elements', function(elements) Elements:toggle(comma_split(elements)) end)

-- 设置 UI 元素最小可见度
mp.register_script_message('set-min-visibility', function(visibility, elements)
    local fraction = tonumber(visibility)
    local ids = comma_split(elements and elements ~= '' and elements or 'timeline,controls,volume,top_bar')
    if fraction then Elements:set_min_visibility(clamp(0, fraction, 1), ids) end
end)

-- 闪动 UI 元素
mp.register_script_message('flash-elements', function(elements) Elements:flash(comma_split(elements)) end)

-- 覆盖快捷键绑定
mp.register_script_message('overwrite-binding', function(name, command) key_binding_overwrites[name] = command end)

-- 禁用 UI 元素
mp.register_script_message('disable-elements', function(id, elements) Manager:disable(id, elements) end)

-- ==============================================================================
-- 20. UI 元素管理器 (Elements & Manager)
-- 负责创建、销毁和管理所有 UI 元素
-- ==============================================================================

-- 动态 UI 元素构造器
local constructors = {
    window_border = require('elements/WindowBorder'),
    buffering_indicator = require('elements/BufferingIndicator'),
    pause_indicator = require('elements/PauseIndicator'),
    top_bar = require('elements/TopBar'),
    timeline = require('elements/Timeline'),
    controls = options.controls and options.controls ~= 'never' and require('elements/Controls'),
    volume = itable_index_of({'left', 'right'}, options.volume) and require('elements/Volume'),
}

-- 必需元素（始终创建）
require('elements/Curtain'):new()

-- Element Manager：根据配置管理 UI 元素的创建和销毁
Manager = {
    -- 可管理的元素 ID 列表
    _ids = itable_join(table_keys(constructors), {'idle_indicator', 'audio_indicator'}),
    ---@type table<string, string[]> 客户端与禁用元素列表的映射
    _disabled_by = {},
    ---@type table<string, boolean> 当前禁用的元素 ID 集合
    disabled = {},
}

-- 设置客户端要禁用的元素
---@param client string
---@param element_ids string|string[]|nil `foo,bar` 或 `{'foo', 'bar'}`
function Manager:disable(client, element_ids)
    self._disabled_by[client] = comma_split(element_ids)
    ---@diagnostic disable-next-line: deprecated
    self.disabled = create_set(itable_join(unpack(table_values(self._disabled_by))))
    self:_commit()
end

-- 提交更改：创建或销毁元素
function Manager:_commit()
    for _, id in ipairs(self._ids) do
        local constructor = constructors[id]
        if not self.disabled[id] then
            if not Elements:has(id) and constructor then constructor:new() end
        else
            Elements:maybe(id, 'destroy')
        end
    end

    -- 通知所有元素更新尺寸
    Elements:trigger('display')
end

-- 初始提交：应用用户禁用的元素
Manager:disable('user', options.disable_elements)