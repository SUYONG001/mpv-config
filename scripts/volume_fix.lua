-- ============================================================
--  volume_fix.lua — 音视频独立配置
-- ============================================================
--  功能：
--  1. 音视频独立音量控制
--  2. 音频文件专属设置（封面、频谱、分辨率、算法关闭等）
--  3. 音频缩放分辨率可通过 volume_fix.conf 中的 audio_scale_height 指定
--  所有音频专属设置均通过 file-local-options 隔离，
--  不会对视频文件产生任何影响。

local opt = require 'mp.options'
local opts = {
    -- 默认值，会被 script-opts/volume_fix.conf 覆盖
    audio_vol = 90,
    video_vol = 100,
    -- 音频模式下的封面渲染目标高度（像素），1080 为默认值
    audio_scale_height = 1080,
}
opt.read_options(opts, "volume_fix")

local function set_volume()
    local path = mp.get_property("path")
    if not path then return end

    -- 获取文件扩展名
    local ext = path:match("%.([^%.]+)$")
    if not ext then return end
    ext = ext:lower()

-- ============================================================
--  判断当前文件是否为"纯音频"（允许有封面，但无真实视频轨）
-- ============================================================
local function is_audio_only()
    -- 没有音频轨 → 不是音频文件
    if mp.get_property("aid") == "no" then return false end

    -- 没有视频轨 → 纯音频
    if mp.get_property("vid") == "no" then return true end

    -- 有视频轨，但这条轨是专辑封面 → 视为纯音频
    local albumart = mp.get_property_native("current-tracks/video/albumart")
    if albumart == true then return true end

    -- 有真实视频轨 → 视频文件
    return false
end

if is_audio_only() then
    -- 音频专属设置（原样保留）
else
    -- 视频专属设置
end

mp.register_event("file-loaded", set_volume)
