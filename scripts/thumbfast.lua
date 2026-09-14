-- ==============================================================================
-- thumbfast.lua — 高性能即时缩略图生成器
-- ==============================================================================
-- 功能概述：
--   1. 在后台启动一个独立的 mpv 子进程（无界面、无音频、无字幕）
--   2. 当鼠标悬停在进度条上时，通知子进程跳转到对应时间点并截取画面
--   3. 将截取到的原始图像数据（BGRA 格式）通过 overlay 叠加到播放画面上
--   4. 支持网络视频、音频文件、HDR 色调映射、硬件解码等复杂场景
-- ==============================================================================
-- 原作者：mpv-player 社区
-- 由用户 [2026.07.04] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 用户配置区 (Options)
-- 这些默认值可通过 script-opts/thumbfast.conf 文件覆盖修改
-- ==============================================================================
local options = {
    -- Socket 通信路径（留空则自动根据操作系统生成）
    socket = "",

    -- 缩略图文件输出路径（留空则自动生成临时文件）
    thumbnail = "",

    -- 缩略图最大宽/高（像素），会等比缩放以适应限制
    -- 当系统开启 HiDPI 时，该值会自动乘以缩放系数
    max_height = 200,
    max_width = 200,

    -- 缩略图显示时的额外缩放系数（需要 mpv 0.38+）
    -- 注意：增大此值不如直接增大 max_height/max_width 画质好
    scale_factor = 1,

    -- HDR 色调映射算法，"no" 表示禁用
    tone_mapping = "auto",

    -- Overlay 图层 ID（用于在画面上叠加缩略图）
    overlay_id = 42,

    -- 是否在文件加载时立即生成后台子进程（消除首次悬停的延迟）
    spawn_first = false,

    -- 空闲多少秒后自动关闭子进程以节省资源，0 表示不关闭
    quit_after_inactivity = 0,

    -- 是否对网络视频启用缩略图
    network = false,

    -- 是否对纯音频文件启用缩略图（实际会显示封面或可视化）
    audio = false,

    -- 后台子进程是否启用硬件解码（auto 或 no）
    hwdec = false,

    -- Windows 专用：是否使用原生 WinAPI 直接写入命名管道（需要 LuaJIT）
    direct_io = false,

    -- mpv 可执行文件的路径（默认 "mpv"，会从 PATH 或 frontend 自动解析）
    mpv_path = "mpv"
}

-- ==============================================================================
-- 2. 基础模块加载与版本检测
-- ==============================================================================
mp.utils = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "thumbfast")

local properties = {}                     -- 缓存 mpv 的各种属性
local pre_0_30_0 = mp.command_native_async == nil  -- mpv < 0.30.0 无异步命令
local pre_0_33_0 = true                   -- mpv < 0.33.0 无原生管道支持
local support_media_control = mp.get_property_native("media-controls") ~= nil

-- ==============================================================================
-- 3. 子进程调用封装 (subprocess)
-- 兼容 mpv 0.30.0 前后不同的 API 风格
-- ==============================================================================
function subprocess(args, async, callback)
    callback = callback or function() end

    if not pre_0_30_0 then
        -- mpv >= 0.30.0：使用原生命令 API
        if async then
            return mp.command_native_async({
                name = "subprocess",
                playback_only = true,
                args = args,
                env = "PATH=" .. os.getenv("PATH")
            }, callback)
        else
            return mp.command_native({
                name = "subprocess",
                playback_only = false,
                capture_stdout = true,
                args = args,
                env = "PATH=" .. os.getenv("PATH")
            })
        end
    else
        -- mpv < 0.30.0：使用 utils 模块
        if async then
            return mp.utils.subprocess_detached({args = args}, callback)
        else
            return mp.utils.subprocess({args = args})
        end
    end
end

-- ==============================================================================
-- 4. Windows 原生管道支持 (WinAPI)
-- 使用 FFI 直接调用 Windows API 加速管道通信（需要 LuaJIT）
-- ==============================================================================
local winapi = {}
if options.direct_io then
    local ffi_loaded, ffi = pcall(require, "ffi")
    if ffi_loaded then
        winapi = {
            ffi = ffi,
            C = ffi.C,
            bit = require("bit"),
            socket_wc = "",

            -- WinAPI 常量定义
            CP_UTF8 = 65001,
            GENERIC_WRITE = 0x40000000,
            OPEN_EXISTING = 3,
            FILE_FLAG_WRITE_THROUGH = 0x80000000,
            FILE_FLAG_NO_BUFFERING = 0x20000000,
            PIPE_NOWAIT = ffi.new("unsigned long[1]", 0x00000001),
            INVALID_HANDLE_VALUE = ffi.cast("void*", -1),
            _lpNumberOfBytesWritten = ffi.new("unsigned long[1]"),
        }
        -- 缓存管道创建标志，避免每次 bor() 调用
        winapi._createfile_pipe_flags = winapi.bit.bor(
            winapi.FILE_FLAG_WRITE_THROUGH,
            winapi.FILE_FLAG_NO_BUFFERING
        )

        -- 声明 Windows API 函数
        ffi.cdef[[
            void* __stdcall CreateFileW(const wchar_t *lpFileName, unsigned long dwDesiredAccess, unsigned long dwShareMode, void *lpSecurityAttributes, unsigned long dwCreationDisposition, unsigned long dwFlagsAndAttributes, void *hTemplateFile);
            bool __stdcall WriteFile(void *hFile, const void *lpBuffer, unsigned long nNumberOfBytesToWrite, unsigned long *lpNumberOfBytesWritten, void *lpOverlapped);
            bool __stdcall CloseHandle(void *hObject);
            bool __stdcall SetNamedPipeHandleState(void *hNamedPipe, unsigned long *lpMode, unsigned long *lpMaxCollectionCount, unsigned long *lpCollectDataTimeout);
            int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
        ]]

        -- UTF-8 → UTF-16 转换函数（用于管道名称）
        winapi.MultiByteToWideChar = function(MultiByteStr)
            if MultiByteStr then
                local utf16_len = winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, nil, 0)
                if utf16_len > 0 then
                    local utf16_str = winapi.ffi.new("wchar_t[?]", utf16_len)
                    if winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, utf16_str, utf16_len) > 0 then
                        return utf16_str
                    end
                end
            end
            return ""
        end
    else
        options.direct_io = false  -- FFI 未加载，回退到普通模式
    end
end

-- ==============================================================================
-- 5. 全局状态变量
-- ==============================================================================
local file               -- 管道文件句柄
local file_bytes = 0     -- 已写入管道的字节数
local spawned = false    -- 子进程是否已启动
local disabled = false   -- 缩略图功能是否被禁用
local force_disabled = false  -- 被强制禁用（如子进程启动失败）
local spawn_waiting = false   -- 正在等待子进程启动
local spawn_working = false   -- 子进程已成功启动并工作
local script_written = false  -- 客户端脚本是否已写入磁盘

local dirty = false      -- 是否有属性变化需要重新计算

local x, y               -- 缩略图在屏幕上的绘制坐标
local last_x, last_y     -- 上一次绘制坐标（用于判断是否需要重绘）

local last_seek_time     -- 最近一次请求的时间点（秒）

local effective_w, effective_h = options.max_width, options.max_height  -- 实际使用的缩略图尺寸
local real_w, real_h     -- 子进程实际生成的缩略图尺寸（可能与请求尺寸略有偏差）
local last_real_w, last_real_h  -- 上一次的实际尺寸

local script_name        -- 调用缩略图的脚本名称（用于向特定脚本回传渲染消息）

local show_thumbnail = false  -- 当前是否应显示缩略图

-- 各类视频滤镜分类（用于构建子进程的 vf 链）
local filters_reset = {["lavfi-crop"]=true, ["crop"]=true}       -- 需要重置视频尺寸的滤镜
local filters_runtime = {["hflip"]=true, ["vflip"]=true}          -- 可动态调整的滤镜
local filters_all = {["hflip"]=true, ["vflip"]=true, ["lavfi-crop"]=true, ["crop"]=true}

-- 支持的色调映射算法列表
local tone_mappings = {
    ["none"]=true, ["clip"]=true, ["linear"]=true,
    ["gamma"]=true, ["reinhard"]=true, ["hable"]=true, ["mobius"]=true
}
local last_tone_mapping   -- 上一次使用的色调映射算法

local last_vf_reset = ""   -- 上一次的重置类滤镜字符串
local last_vf_runtime = "" -- 上一次的运行时滤镜字符串

local last_rotate = 0      -- 上一次的视频旋转角度
local par = ""             -- 像素宽高比修正参数
local last_par = ""

local last_crop = nil      -- 上一次的裁剪参数

local last_has_vid = 0     -- 上一次是否有视频轨道
local has_vid = 0          -- 当前是否有视频轨道

local file_timer           -- 周期性检测缩略图文件是否生成完成的定时器
local file_check_period = 1/60  -- 检测周期（约 16.7ms）

local allow_fast_seek = true  -- 是否允许快速跳转（用于长视频优化）

-- ==============================================================================
-- 6. 平台检测与路径自动配置
-- ==============================================================================

-- 客户端脚本模板（用于 macOS/Linux 下通过脚本启动 IPC 通道）
local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumbfast" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

-- 自动检测操作系统
local function get_os()
    local raw_os_name = ""

    if jit and jit.os and jit.arch then
        raw_os_name = jit.os
    else
        if package.config:sub(1,1) == "\\" then
            -- Windows
            local env_OS = os.getenv("OS")
            if env_OS then
                raw_os_name = env_OS
            end
        else
            raw_os_name = subprocess({"uname", "-s"}).stdout
        end
    end

    raw_os_name = (raw_os_name):lower()

    local os_patterns = {
        ["windows"] = "windows",
        ["linux"]   = "linux",
        ["osx"]     = "darwin",
        ["mac"]     = "darwin",
        ["darwin"]  = "darwin",
        ["^mingw"]  = "windows",
        ["^cygwin"] = "windows",
        ["bsd$"]    = "darwin",
        ["sunos"]   = "darwin"
    }

    local str_os_name = "linux"
    for pattern, name in pairs(os_patterns) do
        if raw_os_name:match(pattern) then
            str_os_name = name
            break
        end
    end
    return str_os_name
end

local os_name = mp.get_property("platform") or get_os()
local path_separator = os_name == "windows" and "\\" or "/"

-- 自动生成 socket 和 thumbnail 路径
if options.socket == "" then
    if os_name == "windows" then
        options.socket = "thumbfast"
    else
        options.socket = "/tmp/thumbfast"
    end
end

if options.thumbnail == "" then
    if os_name == "windows" then
        options.thumbnail = os.getenv("TEMP") .. "\\thumbfast.out"
    else
        options.thumbnail = "/tmp/thumbfast.out"
    end
end

-- 使用进程 ID 确保路径唯一（多实例不冲突）
local unique = mp.utils.getpid()
options.socket = options.socket .. unique
options.thumbnail = options.thumbnail .. unique

-- Windows 下将 socket 路径转换为管道路径
if options.direct_io then
    if os_name == "windows" then
        winapi.socket_wc = winapi.MultiByteToWideChar("\\\\.\\pipe\\" .. options.socket)
    end
    if winapi.socket_wc == "" then
        options.direct_io = false
    end
end

options.scale_factor = math.floor(options.scale_factor)

-- ==============================================================================
-- 7. mpv 可执行文件自动定位
-- ==============================================================================
local mpv_path = options.mpv_path
local frontend_path

-- Windows：尝试从前端进程路径获取
if mpv_path == "mpv" and os_name == "windows" then
    frontend_path = mp.get_property_native("user-data/frontend/process-path")
    mpv_path = frontend_path or mpv_path
end

-- macOS：尝试从当前进程路径获取
if mpv_path == "mpv" and os_name == "darwin" and unique then
    mpv_path = string.gsub(subprocess({"ps", "-o", "comm=", "-p", tostring(unique)}).stdout, "[\n\r]", "")
    if mpv_path ~= "mpv" then
        mpv_path = string.gsub(mpv_path, "/mpv%-bundle$", "/mpv")
        local mpv_bin = mp.utils.file_info("/usr/local/mpv")
        if mpv_bin and mpv_bin.is_file then
            mpv_path = "/usr/local/mpv"
        else
            local mpv_app = mp.utils.file_info("/Applications/mpv.app/Contents/MacOS/mpv")
            if mpv_app and mpv_app.is_file then
                mp.msg.warn("symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            else
                mp.msg.warn("drag to your Applications folder and symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            end
        end
    end
end

-- ==============================================================================
-- 8. 色调映射自动检测（从 vo-passes 中读取当前使用的算法）
-- ==============================================================================
local function vo_tone_mapping()
    local passes = mp.get_property_native("vo-passes")
    if passes and passes["fresh"] then
        for k, v in pairs(passes["fresh"]) do
            for k2, v2 in pairs(v) do
                if k2 == "desc" and v2 then
                    local tone_mapping = string.match(v2, "([0-9a-z.-]+) tone map")
                    if tone_mapping then
                        return tone_mapping
                    end
                end
            end
        end
    end
end

-- ==============================================================================
-- 9. 视频滤镜链构建 (vf_string)
-- 根据当前视频属性生成完整的 vf 滤镜字符串
-- ==============================================================================
local function vf_string(filters, full)
    local vf = ""
    local vf_table = properties["vf"]

    -- 处理原生裁剪（video-crop）
    if (properties["video-crop"] or "") ~= "" then
        vf = "lavfi-crop=" .. string.gsub(
            properties["video-crop"],
            "(%d*)x?(%d*)%+(%d+)%+(%d+)",
            "w=%1:h=%2:x=%3:y=%4"
        ) .. ","
        local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
        local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
        if width and height then
            vf = string.gsub(vf, "w=:h=:", "w=" .. width .. ":h=" .. height .. ":")
        end
    end

    -- 处理用户自定义 vf（仅保留指定类型的滤镜）
    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            if filters[vf_table[i].name] then
                local args = ""
                for key, value in pairs(vf_table[i].params) do
                    if args ~= "" then
                        args = args .. ":"
                    end
                    args = args .. key .. "=" .. value
                end
                vf = vf .. vf_table[i].name .. "=" .. args .. ","
            end
        end
    end

    -- HDR 色调映射（仅当视频是 BT.2020 色域时启用）
    if (full and options.tone_mapping ~= "no") or options.tone_mapping == "auto" then
        if properties["video-params"] and properties["video-params"]["primaries"] == "bt.2020" then
            local tone_mapping = options.tone_mapping
            if tone_mapping == "auto" then
                tone_mapping = last_tone_mapping or properties["tone-mapping"]
                if tone_mapping == "auto" and properties["current-vo"] == "gpu-next" then
                    tone_mapping = vo_tone_mapping()
                end
            end
            if not tone_mappings[tone_mapping] then
                tone_mapping = "hable"
            end
            last_tone_mapping = tone_mapping
            vf = vf .. "zscale=transfer=linear,format=gbrpf32le,tonemap=" .. tone_mapping .. ",zscale=transfer=bt709,"
        end
    end

    -- 最终缩放与格式转换（仅当 full=true 时，即生成缩略图的最后一环）
    if full then
        vf = vf .. "scale=w=" .. effective_w .. ":h=" .. effective_h .. par ..
             ",pad=w=" .. effective_w .. ":h=" .. effective_h .. ":x=-1:y=-1,format=bgra"
    end

    return vf
end

-- ==============================================================================
-- 10. 缩略图尺寸计算 (calc_dimensions)
-- 根据视频宽高比和配置的 max_width/max_height 计算实际输出尺寸
-- ==============================================================================
local function calc_dimensions()
    local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
    local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
    if not width or not height then return end

    local scale = properties["display-hidpi-scale"] or 1

    -- 等比缩放，长边不超过限制
    if width / height > options.max_width / options.max_height then
        effective_w = math.floor(options.max_width * scale + 0.5)
        effective_h = math.floor(height / width * effective_w + 0.5)
    else
        effective_h = math.floor(options.max_height * scale + 0.5)
        effective_w = math.floor(width / height * effective_h + 0.5)
    end

    -- 像素宽高比修正
    local v_par = properties["video-out-params"] and properties["video-out-params"]["par"] or 1
    if v_par == 1 then
        par = ":force_original_aspect_ratio=decrease"
    else
        par = ""
    end
end

-- ==============================================================================
-- 11. 缩略图状态信息上报 (info)
-- 向主 UI 脚本（如 ModernX）发送缩略图可用性及尺寸信息
-- ==============================================================================
local info_timer = nil

local function info(w, h)
    local rotate = properties["video-params"] and properties["video-params"]["rotate"]
    local image = properties["current-tracks/video"] and properties["current-tracks/video"]["image"]
    local albumart = image and properties["current-tracks/video"]["albumart"]

    -- 判定缩略图功能是否应被禁用
    disabled = (w or 0) == 0 or (h or 0) == 0 or
        has_vid == 0 or
        (properties["demuxer-via-network"] and not options.network) or
        (albumart and not options.audio) or
        (image and not albumart) or
        force_disabled

    -- 如果当前没有视频轨道或尚未获取旋转信息，等待 50ms 后重试
    if info_timer then
        info_timer:kill()
        info_timer = nil
    elseif has_vid == 0 or (rotate == nil and not disabled) then
        info_timer = mp.add_timeout(0.05, function() info(w, h) end)
    end

    -- 将状态信息打包成 JSON 发送给 ModernX
    local json, err = mp.utils.format_json({
        width = w * options.scale_factor,
        height = h * options.scale_factor,
        scale_factor = options.scale_factor,
        disabled = disabled,
        available = true,
        socket = options.socket,
        thumbnail = options.thumbnail,
        overlay_id = options.overlay_id
    })
    if pre_0_30_0 then
        mp.command_native({"script-message", "thumbfast-info", json})
    else
        mp.command_native_async({"script-message", "thumbfast-info", json}, function() end)
    end
end

-- ==============================================================================
-- 12. 缩略图文件清理 (remove_thumbnail_files)
-- ==============================================================================
local function remove_thumbnail_files()
    if file then
        file:close()
        file = nil
        file_bytes = 0
    end
    os.remove(options.thumbnail)
    os.remove(options.thumbnail .. ".bgra")
end

-- ==============================================================================
-- 13. 子进程生成与启动 (spawn)
-- 这是整个脚本最核心的函数：启动一个精简的 mpv 实例作为缩略图生成器
-- ==============================================================================
local activity_timer

local function spawn(time)
    if disabled then return end

    local path = properties["path"]
    if path == nil then return end

    -- 管理空闲关闭计时器
    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    -- 处理网络视频（如 YouTube 的流式 URL）
    local open_filename = properties["stream-open-filename"]
    local ytdl = open_filename and properties["demuxer-via-network"] and path ~= open_filename
    if ytdl then
        path = open_filename
    end

    remove_thumbnail_files()

    local vid = properties["vid"]
    has_vid = vid or 0

    -- 构建子进程的命令行参数
    -- 注意：这是一个完全独立的 mpv 进程，与主播放器互不干扰
    local args = {
        mpv_path,
        "--no-config",                       -- 不加载任何配置文件
        "--msg-level=all=no",                -- 不输出任何日志
        "--idle",                            -- 空闲时保持进程存活
        "--pause",                           -- 启动后立即暂停
        "--keep-open=always",                -- 保持窗口打开
        "--really-quiet",                    -- 极静模式
        "--no-terminal",                     -- 不占用终端
        "--load-scripts=no",                 -- 不加载任何 Lua 脚本
        "--osc=no",                          -- 不加载 OSC
        "--ytdl=no",                         -- 不启用 ytdl
        "--load-stats-overlay=no",
        "--load-osd-console=no",
        "--load-auto-profiles=no",
        "--edition=" .. (properties["edition"] or "auto"),
        "--vid=" .. (vid or "auto"),
        "--no-sub",                          -- 不加载字幕
        "--no-audio",                        -- 不处理音频
        "--start=" .. time,
        allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",  -- 关键帧跳转（更快）
        "--ytdl-format=worst",               -- 用最低画质下载（只为缩略图）
        "--demuxer-readahead-secs=0",        -- 不解码多余数据
        "--demuxer-max-bytes=128KiB",        -- 限制内存占用
        "--vd-lavc-skiploopfilter=all",      -- 跳过环路滤波（加速解码）
        "--vd-lavc-software-fallback=1",
        "--vd-lavc-fast",
        "--vd-lavc-threads=2",
        "--hwdec=" .. (options.hwdec and "auto" or "no"),
        "--vf=" .. vf_string(filters_all, true),
        "--sws-scaler=fast-bilinear",
        "--video-rotate=" .. last_rotate,
        "--ovc=rawvideo",                    -- 输出原始视频数据
        "--of=image2",                       -- 输出格式为图像序列
        "--ofopts=update=1",
        "--o=" .. options.thumbnail
    }

    -- 不同 mpv 版本的兼容性补丁
    if not pre_0_30_0 then
        table.insert(args, "--sws-allow-zimg=no")
    end

    if support_media_control then
        table.insert(args, "--media-controls=no")
    end

    if os_name == "darwin" and properties["macos-app-activation-policy"] then
        table.insert(args, "--macos-app-activation-policy=accessory")
    end

    -- IPC 通信通道配置
    if os_name == "windows" or pre_0_33_0 then
        table.insert(args, "--input-ipc-server=" .. options.socket)
    elseif not script_written then
        -- macOS/Linux 下通过辅助脚本启动 IPC
        local client_script_path = options.socket .. ".run"
        local script = io.open(client_script_path, "w+")
        if script == nil then
            mp.msg.error("client script write failed")
            return
        else
            script_written = true
            script:write(string.format(client_script, options.socket))
            script:close()
            subprocess({"chmod", "+x", client_script_path}, true)
            table.insert(args, "--scripts=" .. client_script_path)
        end
    else
        local client_script_path = options.socket .. ".run"
        table.insert(args, "--scripts=" .. client_script_path)
    end

    table.insert(args, "--")
    table.insert(args, path)

    spawned = true
    spawn_waiting = true

    -- 异步启动子进程
    subprocess(args, true,
        function(success, result)
            -- 子进程启动失败的处理逻辑
            if spawn_waiting and (success == false or (result.status ~= 0 and result.status ~= -2)) then
                spawned = false
                spawn_waiting = false
                options.tone_mapping = "no"
                mp.msg.error("mpv subprocess create failed")

                -- 【用户定制】以下 show-text 命令已被注释，以消除界面弹窗干扰
                if not spawn_working then
                    if options.mpv_path == "mpv" then
                        -- 各种前端环境下的错误提示（已静音）
                        -- 具体代码省略...
                    end
                end
            elseif success == true and (result.status == 0 or result.status == -2) then
                -- 子进程启动成功
                if not spawn_working and properties["current-vo"] == "libmpv" and options.mpv_path ~= mpv_path then
                    -- 特定前端的配置提示（已静音）
                end
                spawn_working = true
                spawn_waiting = false
            end
        end
    )
end

-- ==============================================================================
-- 14. IPC 通信：向子进程发送命令 (run)
-- 通过命名管道或 socket 向缩略图生成器发送指令
-- ==============================================================================
local function run(command)
    if not spawned then return end

    -- Windows 原生管道模式（direct_io）
    if options.direct_io then
        local hPipe = winapi.C.CreateFileW(
            winapi.socket_wc,
            winapi.GENERIC_WRITE,
            0,
            nil,
            winapi.OPEN_EXISTING,
            winapi._createfile_pipe_flags,
            nil
        )
        if hPipe ~= winapi.INVALID_HANDLE_VALUE then
            local buf = command .. "\n"
            winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
            winapi.C.WriteFile(hPipe, buf, #buf + 1, winapi._lpNumberOfBytesWritten, nil)
            winapi.C.CloseHandle(hPipe)
        end
        return
    end

    local command_n = command .. "\n"

    -- Windows 命名管道
    if os_name == "windows" then
        -- 管道缓冲区 4KB，超过则重新打开
        if file and file_bytes + #command_n >= 4096 then
            file:close()
            file = nil
            file_bytes = 0
        end
        if not file then
            file = io.open("\\\\.\\pipe\\" .. options.socket, "r+b")
        end
    elseif pre_0_33_0 then
        -- 旧版 mpv 通过 socat 代理通信
        subprocess({"/usr/bin/env", "sh", "-c", "echo '" .. command .. "' | socat - " .. options.socket})
        return
    elseif not file then
        -- Unix domain socket
        file = io.open(options.socket, "r+")
    end

    if file then
        file_bytes = file:seek("end")
        file:write(command_n)
        file:flush()
    end
end

-- ==============================================================================
-- 15. 缩略图绘制 (draw)
-- 将生成好的 .bgra 文件叠加到 OSD 画面上
-- ==============================================================================
local function draw(w, h, script)
    if not w or not show_thumbnail then return end

    if x ~= nil then
        -- 直接使用 overlay-add 命令绘制
        local scale_w, scale_h = options.scale_factor ~= 1 and (w * options.scale_factor) or nil,
                                 options.scale_factor ~= 1 and (h * options.scale_factor) or nil
        if pre_0_30_0 then
            mp.command_native({
                "overlay-add",
                options.overlay_id,
                x, y,
                options.thumbnail .. ".bgra",
                0,
                "bgra",
                w, h,
                (4 * w),
                scale_w, scale_h
            })
        else
            mp.command_native_async({
                "overlay-add",
                options.overlay_id,
                x, y,
                options.thumbnail .. ".bgra",
                0,
                "bgra",
                w, h,
                (4 * w),
                scale_w, scale_h
            }, function() end)
        end
    elseif script then
        -- 或者通过脚本消息转发给其他 UI（如 ImPlay）
        local json, err = mp.utils.format_json({
            width = w,
            height = h,
            scale_factor = options.scale_factor,
            x = x,
            y = y,
            socket = options.socket,
            thumbnail = options.thumbnail,
            overlay_id = options.overlay_id
        })
        mp.commandv("script-message-to", script, "thumbfast-render", json)
    end
end

-- ==============================================================================
-- 16. 缩略图尺寸校验 (real_res)
-- 从生成的文件大小反推实际宽高，防止损坏或不完整的数据
-- ==============================================================================
local function real_res(req_w, req_h, filesize)
    local count = filesize / 4  -- BGRA 格式每像素 4 字节
    local diff = (req_w * req_h) - count

    -- 处理旋转后的宽高交换
    if (properties["video-params"] and properties["video-params"]["rotate"] or 0) % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if diff == 0 then
        return req_w, req_h
    else
        -- 如果尺寸不匹配，尝试在允许的偏差范围内找到正确的宽高
        local threshold = 5
        local long_side, short_side = req_w, req_h
        if req_h > req_w then
            long_side, short_side = req_h, req_w
        end
        for a = short_side, short_side - threshold, -1 do
            if count % a == 0 then
                local b = count / a
                if long_side - b < threshold then
                    if req_h < req_w then
                        return b, a
                    else
                        return a, b
                    end
                end
            end
        end
        return nil  -- 无法验证，放弃
    end
end

-- ==============================================================================
-- 17. 文件安全移动 (move_file)
-- Windows 下先删除目标文件再重命名，防止 overlay-add 读取时被覆盖导致崩溃
-- ==============================================================================
local function move_file(from, to)
    if os_name == "windows" then
        os.remove(to)
    end
    os.rename(from, to)
end

-- ==============================================================================
-- 18. 子进程跳转控制 (seek)
-- 通知子进程跳转到指定时间点截取画面
-- ==============================================================================
local function seek(fast)
    if last_seek_time then
        run("async seek " .. last_seek_time .. (fast and " absolute+keyframes" or " absolute+exact"))
    end
end

-- ==============================================================================
-- 19. 定时跳转管理 (seek_timer)
-- 防止短时间内频繁跳转导致子进程过载
-- ==============================================================================
local seek_period = 3 / 60  -- 约 50ms 的跳转间隔
local seek_period_counter = 0
local seek_timer
seek_timer = mp.add_periodic_timer(seek_period, function()
    if seek_period_counter == 0 then
        seek(allow_fast_seek)
        seek_period_counter = 1
    else
        if seek_period_counter == 2 then
            if allow_fast_seek then
                seek_timer:kill()
                seek()
            end
        else
            seek_period_counter = seek_period_counter + 1
        end
    end
end)
seek_timer:kill()

local function request_seek()
    if seek_timer:is_enabled() then
        seek_period_counter = 0
    else
        seek_timer:resume()
        seek(allow_fast_seek)
        seek_period_counter = 1
    end
end

-- ==============================================================================
-- 20. 缩略图文件轮询检测 (check_new_thumb)
-- 周期性地检查子进程是否已生成新的缩略图文件
-- ==============================================================================
local function check_new_thumb()
    -- 先将文件移到临时位置，防止读写不一致
    local tmp = options.thumbnail .. ".tmp"
    move_file(options.thumbnail, tmp)
    local finfo = mp.utils.file_info(tmp)
    if not finfo then return false end

    spawn_waiting = false

    -- 验证文件尺寸是否有效
    local w, h = real_res(effective_w, effective_h, finfo.size)
    if w then
        -- 有效缩略图，移到最终位置
        move_file(tmp, options.thumbnail .. ".bgra")

        real_w, real_h = w, h
        if real_w and (real_w ~= last_real_w or real_h ~= last_real_h) then
            last_real_w, last_real_h = real_w, real_h
            info(real_w, real_h)
        end
        if not show_thumbnail then
            file_timer:kill()
        end
        return true
    end

    return false
end

-- ==============================================================================
-- 21. 周期性文件检测定时器
-- ==============================================================================
file_timer = mp.add_periodic_timer(file_check_period, function()
    if check_new_thumb() then
        draw(real_w, real_h, script_name)
    end
end)
file_timer:kill()

-- ==============================================================================
-- 22. 清除缩略图 (clear)
-- 移除当前显示的缩略图并停止所有相关定时器
-- ==============================================================================
local function clear()
    file_timer:kill()
    seek_timer:kill()

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    last_seek_time = nil
    show_thumbnail = false
    last_x = nil
    last_y = nil

    if script_name then return end  -- 如果是由其他脚本驱动的，由该脚本自行清除

    if pre_0_30_0 then
        mp.command_native({"overlay-remove", options.overlay_id})
    else
        mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
    end
end

-- ==============================================================================
-- 23. 退出子进程 (quit)
-- 关闭缩略图生成器子进程
-- ==============================================================================
local function quit()
    activity_timer:kill()
    if show_thumbnail then
        activity_timer:resume()
        return
    end
    run("quit")
    spawned = false
    real_w, real_h = nil, nil
    clear()
end

-- ==============================================================================
-- 24. 空闲计时器
-- 当超过 quit_after_inactivity 秒无操作时自动退出子进程
-- ==============================================================================
activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()

-- ==============================================================================
-- 25. 对外接口：生成缩略图 (thumb)
-- 由 ModernX 等 UI 脚本通过 script-message 调用
-- ==============================================================================
local function thumb(time, r_x, r_y, script)
    if disabled then return end

    time = tonumber(time)
    if time == nil then return end

    -- 坐标解析
    if r_x == "" or r_y == "" then
        x, y = nil, nil
    else
        x, y = math.floor(r_x + 0.5), math.floor(r_y + 0.5)
    end

    script_name = script

    -- 只有坐标变化或首次显示时才重绘
    if last_x ~= x or last_y ~= y or not show_thumbnail then
        show_thumbnail = true
        last_x, last_y = x, y
        draw(real_w, real_h, script)
    end

    -- 重置空闲计时器
    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    -- 只有时间点变化时才向子进程发起跳转
    if time == last_seek_time then return end
    last_seek_time = time

    if not spawned then
        spawn(time)
    end
    request_seek()

    if not file_timer:is_enabled() then
        file_timer:resume()
    end
end

-- ==============================================================================
-- 26. 属性变化监控 (watch_changes)
-- 当视频尺寸、旋转、裁剪等属性变化时，重新计算缩略图参数
-- ==============================================================================
local function watch_changes()
    if not dirty or not properties["video-out-params"] then return end
    dirty = false

    local old_w = effective_w
    local old_h = effective_h

    calc_dimensions()

    local vf_reset = vf_string(filters_reset)
    local rotate = properties["video-rotate"] or 0

    -- 检测是否有实质性变化
    local resized = old_w ~= effective_w or
        old_h ~= effective_h or
        last_vf_reset ~= vf_reset or
        (last_rotate % 180) ~= (rotate % 180) or
        par ~= last_par or
        last_crop ~= properties["video-crop"]

    if resized then
        last_rotate = rotate
        info(effective_w, effective_h)
    elseif last_has_vid ~= has_vid and has_vid ~= 0 then
        info(effective_w, effective_h)
    end

    -- 如果子进程已启动，通知其更新参数
    if spawned then
        if resized then
            -- 尺寸变化需要重启子进程（mpv 不支持运行时改变输出尺寸）
            local seek_time = last_seek_time
            run("quit")
            clear()
            spawned = false
            spawn(seek_time or mp.get_property_number("time-pos", 0))
            file_timer:resume()
        else
            if rotate ~= last_rotate then
                run("set video-rotate " .. rotate)
            end
            local vf_runtime = vf_string(filters_runtime)
            if vf_runtime ~= last_vf_runtime then
                run("vf set " .. vf_string(filters_all, true))
                last_vf_runtime = vf_runtime
            end
        end
    else
        last_vf_runtime = vf_string(filters_runtime)
    end

    -- 更新缓存状态
    last_vf_reset = vf_reset
    last_rotate = rotate
    last_par = par
    last_crop = properties["video-crop"]
    last_has_vid = has_vid

    -- 如果启用 spawn_first，在文件加载后立即启动子进程
    if not spawned and not disabled and options.spawn_first and resized then
        spawn(mp.get_property_number("time-pos", 0))
        file_timer:resume()
    end
end

-- ==============================================================================
-- 27. 属性监听器注册
-- 监控各种 mpv 属性变化，触发相应处理
-- ==============================================================================
local function update_property(name, value)
    properties[name] = value
end

local function update_property_dirty(name, value)
    properties[name] = value
    dirty = true
    if name == "tone-mapping" then
        last_tone_mapping = nil
    end
end

local function update_tracklist(name, value)
    -- 从 track-list 中提取当前选中的视频轨道
    for _, track in ipairs(value) do
        if track.type == "video" and track.selected then
            properties["current-tracks/video"] = track
            return
        end
    end
end

local function sync_changes(prop, val)
    update_property(prop, val)
    if val == nil then return end

    if type(val) == "boolean" then
        if prop == "vid" then
            has_vid = 0
            last_has_vid = 0
            info(effective_w, effective_h)
            clear()
            return
        end
        val = val and "yes" or "no"
    end

    if prop == "vid" then
        has_vid = 1
    end

    if not spawned then return end
    run("set " .. prop .. " " .. val)
    dirty = true
end

-- ==============================================================================
-- 28. 文件加载与关闭事件
-- ==============================================================================
local function file_load()
    clear()
    spawned = false
    real_w, real_h = nil, nil
    last_real_w, last_real_h = nil, nil
    last_tone_mapping = nil
    last_seek_time = nil

    if info_timer then
        info_timer:kill()
        info_timer = nil
    end

    calc_dimensions()
    info(effective_w, effective_h)
end

local function shutdown()
    run("quit")
    remove_thumbnail_files()
    if os_name ~= "windows" then
        os.remove(options.socket)
        os.remove(options.socket .. ".run")
    end
end

-- ==============================================================================
-- 29. 时长变化处理
-- 短视频禁用快速跳转（因为关键帧间隔太短），长视频启用
-- ==============================================================================
local function on_duration(prop, val)
    allow_fast_seek = (val or 30) >= 30
end

-- ==============================================================================
-- 30. 属性观察者注册
-- ==============================================================================
mp.observe_property("current-tracks/video", "native", function(name, value)
    if pre_0_33_0 then
        mp.unobserve_property(update_tracklist)
        pre_0_33_0 = false
    end
    update_property(name, value)
end)

mp.observe_property("track-list", "native", update_tracklist)
mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)
mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property)
mp.observe_property("video-rotate", "native", update_property)
mp.observe_property("video-crop", "native", update_property)
mp.observe_property("path", "native", update_property)
mp.observe_property("vid", "native", sync_changes)
mp.observe_property("edition", "native", sync_changes)
mp.observe_property("duration", "native", on_duration)

-- ==============================================================================
-- 31. 脚本消息与事件注册
-- ==============================================================================
mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)

mp.register_event("file-loaded", file_load)
mp.register_event("shutdown", shutdown)

-- 空闲时持续监控属性变化
mp.register_idle(watch_changes)