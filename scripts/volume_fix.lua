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
    --  音频文件扩展名定义（完整版）
    -- ============================================================
    local audio_exts = {
        -- 无损压缩格式
        flac = true, ape = true, wav = true,
        -- 无损压缩（少见格式）
        alac = true, tta = true, tak = true, wv = true,
        -- 有损压缩格式
        mp3 = true, aac = true, ogg = true, opus = true,
        -- 有损压缩（少见格式）
        wma = true, mp2 = true, mp1 = true, ac3 = true,
        -- Apple 格式
        m4a = true, caf = true,
        -- 游戏/光盘音频格式
        cue = true, dsf = true, dff = true, iso = true,
        -- 未压缩格式
        aiff = true, aifc = true, au = true, snd = true, pcm = true,
        -- 容器格式（可包含音频）
        mka = true, weba = true,
        -- 模块格式（少见）
        mod = true, s3m = true, xm = true, it = true, mid = true, midi = true,
    }

    if audio_exts[ext] then
        -- ============================================================
        --  音频文件专属设置
        --  以下所有设置仅通过 file-local-options 作用于当前音频文件
        --  不会对任何视频文件产生污染
        -- ============================================================

        -- 独立音量
        mp.set_property("file-local-options/volume", opts.audio_vol)

        -- 强制显示窗口（频谱 / 封面需要渲染目标）
        mp.set_property("file-local-options/force-window", "yes")

        -- 显示内嵌专辑封面
        mp.set_property("file-local-options/audio-display", "yes")
        -- 无内嵌封面时自动搜索同目录封面图
        mp.set_property("file-local-options/audio-display-cover", "yes")

        -- 降低渲染分辨率，节省 GPU 资源
        -- 高度由 volume_fix.conf 中的 audio_scale_height 指定
        -- force_original_aspect_ratio=decrease：保持比例，仅在超出时缩小
        local scale_h = opts.audio_scale_height
        mp.set_property("file-local-options/vf",
            "scale=" .. scale_h .. ":" .. scale_h .. ":force_original_aspect_ratio=decrease")

        -- 关闭视频插值（音频文件没有帧率概念）
        mp.set_property("file-local-options/interpolation", "no")
        -- 以音频时钟同步
        mp.set_property("file-local-options/video-sync", "audio")

        -- 关闭视频后处理（对音频无意义，减少 GPU 占用）
        mp.set_property("file-local-options/deband", "no")
        mp.set_property("file-local-options/scale", "bilinear")
        mp.set_property("file-local-options/cscale", "bilinear")
        mp.set_property("file-local-options/dscale", "bilinear")

    else
        -- ============================================================
        --  视频文件专属设置
        -- ============================================================

        -- 独立音量
        mp.set_property("file-local-options/volume", opts.video_vol)
    end
end

mp.register_event("start-file", set_volume)