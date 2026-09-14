-- ==============================================================================
-- TopBar.lua — 顶部标题栏组件
-- ==============================================================================
-- 功能概述：
--   1. 在窗口顶部显示一个标题栏，包含窗口控制按钮（最小化/最大化/关闭）
--   2. 显示当前播放文件的媒体标题（支持属性扩展模板）
--   3. 支持备选标题（alt title），可显示在下方或通过点击切换
--   4. 显示当前章节信息（章节序号 + 标题 + 剩余时间）
--   5. 显示播放列表位置（当前索引/总数）
--   6. 支持多种显示模式：仅在无边框模式显示、始终显示、从不显示
-- ==============================================================================
-- 交互方式：
--   - 点击标题区域：切换主/备选标题（如果启用 toggle 模式）
--   - 点击播放列表位置区域：打开播放列表菜单
--   - 点击章节区域：打开章节菜单
--   - 窗口控制按钮：最小化、最大化/还原、关闭
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- ==============================================================================
-- 1. 类型定义 (Type Alias)
-- ==============================================================================

---@alias TopBarButtonProps {icon: string; hover_fg?: string; hover_bg?: string; command: (fun():string)}
-- 顶栏按钮属性：
--   icon      : 按钮图标（Material Icons）
--   hover_fg  : 悬停时的前景色（覆盖默认）
--   hover_bg  : 悬停时的背景色（覆盖默认）
--   command   : 点击时执行的命令函数

-- ==============================================================================
-- 2. TopBar 类定义
-- 继承自 Element，实现顶部标题栏
-- ==============================================================================

---@class TopBar : Element
local TopBar = class(Element)

-- ==============================================================================
-- 3. 构造函数与初始化 (new / init)
-- ==============================================================================

function TopBar:new() return Class.new(self) --[[@as TopBar]] end

function TopBar:init()
    -- 调用父类 Element 的初始化
    -- render_order = 4 表示渲染在进度条上方
    Element.init(self, 'top_bar', {render_order = 4})

    -- 尺寸相关变量
    self.size = 0               -- 顶栏总高度
    self.alt_title_size = 0     -- 备选标题字号
    self.chapter_size = 0       -- 章节字号
    self.titles_spacing = 1     -- 标题间距
    self.icon_size = 1          -- 图标大小
    self.font_size = 1          -- 主标题字号
    self.title_by = 1           -- 标题底部 Y 坐标（用于 OSD 边距计算）

    -- 标题切换状态
    self.show_alt_as_main = false   -- 是否将备选标题显示为主标题
    self.main_title = nil           -- 主标题（展开后的文本）
    self.alt_title = nil            -- 备选标题（展开后的文本）
    ---@type table<string, string|nil>
    self.render_titles = {}         -- 最终渲染的标题 {main, alt}
    ---@type {index: number; title: string}|nil
    self.current_chapter = nil      -- 当前章节信息

    -- ============================================================
    -- 窗口控制按钮定义
    -- ============================================================
    local function maximized_command()
        if state.platform == 'windows' then
            -- Windows 平台：根据边框和全屏状态决定命令
            mp.command(state.border
                and (state.fullscreen and 'set fullscreen no;cycle window-maximized' or 'cycle window-maximized')
                or 'set window-maximized no;cycle fullscreen')
        else
            -- 非 Windows 平台
            mp.command(state.fullormaxed and 'set fullscreen no;set window-maximized no' or 'set window-maximized yes')
        end
    end

    local close = {
        icon = 'close',
        hover_bg = '2311e8',   -- 悬停红色背景（Windows 风格）
        hover_fg = 'ffffff',   -- 悬停白色文字
        command = function() mp.command('quit') end
    }
    local max = {
        icon = 'crop_square',
        command = maximized_command
    }
    local min = {
        icon = 'minimize',
        command = function() mp.command('cycle window-minimized') end
    }

    -- 按钮顺序根据 top_bar_controls 配置决定（左对齐或右对齐）
    self.buttons = options.top_bar_controls == 'left' and {close, max, min} or {min, max, close}

    -- 注册属性观察者
    self:register_observers()

    -- 决定启用状态
    self:decide_enabled()

    -- 更新尺寸
    self:update_dimensions()
end

-- ==============================================================================
-- 4. 模板展开函数 (expand_template)
-- 将 mpv 属性模板（如 ${media-title}）展开为实际文本
-- ==============================================================================

---@return string|nil
local function expand_template(template)
    -- 展开模板，移除换行符、尾部斜杠和空格，并进行 ASS 转义
    local tmp = mp.command_native({'expand-text', template})
        :gsub('\\n', ' ')           -- 换行转空格
        :gsub('[\\%s]+$', '')       -- 移除尾部斜杠和空白
        :gsub('^%s+', '')           -- 移除头部空白
    return tmp and tmp ~= '' and ass_escape(tmp) or nil
end

-- ==============================================================================
-- 5. 模板监听器 (add_template_listener)
-- 监听模板中所有属性，任意属性变化时触发回调
-- ==============================================================================

---@param template string
---@param callback fun()
function TopBar:add_template_listener(template, callback)
    -- 提取模板中所有的属性名
    local props = get_expansion_props(template)

    -- 为每个属性注册观察者
    for prop, _ in pairs(props) do
        self:observe_mp_property(prop, 'native', callback)
    end

    -- 如果没有属性，立即执行回调（静态模板）
    if not next(props) then
        callback()
    end
end

-- ==============================================================================
-- 6. 注册属性观察者 (register_observers)
-- 监听主标题和备选标题相关的属性变化
-- ==============================================================================

function TopBar:register_observers()
    -- ============================================================
    -- 主标题 (Main title)
    -- ============================================================
    if #options.top_bar_title > 0 and options.top_bar_title ~= 'no' then
        if options.top_bar_title == 'yes' then
            -- 'yes' 模式：从 mpv 的 'title' 属性读取模板
            local template = nil
            local function update_main_title()
                self.main_title = expand_template(template)
                self:update_render_titles()
            end
            local function remove_template_listener(callback)
                mp.unobserve_property(callback)
            end

            self:observe_mp_property('title', 'string', function(_, title)
                -- 移除旧的监听器
                remove_template_listener(update_main_title)
                template = title

                if template then
                    -- 移除 mpv 自动添加的 ' - mpv' 后缀
                    if template:sub(-6) == ' - mpv' then
                        template = template:sub(1, -7)
                    end
                    self:add_template_listener(template, update_main_title)
                end
            end)
        elseif type(options.top_bar_title) == 'string' then
            -- 自定义模板字符串
            self:add_template_listener(options.top_bar_title, function()
                self.main_title = expand_template(options.top_bar_title)
                self:update_render_titles()
            end)
        end
    end

    -- ============================================================
    -- 备选标题 (Alt title)
    -- ============================================================
    if #options.top_bar_alt_title > 0 and options.top_bar_alt_title ~= 'no' then
        self:add_template_listener(options.top_bar_alt_title, function()
            self.alt_title = expand_template(options.top_bar_alt_title)
            self:update_render_titles()
        end)
    end
end

-- ==============================================================================
-- 7. 启用状态判断 (decide_enabled)
-- ==============================================================================

function TopBar:decide_enabled()
    -- 根据 top_bar 配置决定是否启用
    if options.top_bar == 'no-border' then
        -- 无边框模式：只有在无边框、无标题栏或全屏时显示
        self.enabled = not state.border or state.title_bar == false or state.fullscreen
    else
        -- 始终显示模式
        self.enabled = options.top_bar == 'always'
    end

    -- 必须有至少一个可见元素（控制按钮、标题或播放列表）
    self.enabled = self.enabled and (
        options.top_bar_controls
        or options.top_bar_title ~= 'no'
        or state.has_playlist
    )
end

-- ==============================================================================
-- 8. 更新渲染标题 (update_render_titles)
-- 处理主标题和备选标题的去重和切换逻辑
-- ==============================================================================

function TopBar:update_render_titles()
    local main, alt = self.main_title, self.alt_title

    -- 将 'No file' 替换为本地化文本
    if main == 'No file' then
        main = t('No file')
    end

    -- 如果主标题为空，回退到备选标题
    if not main or main == '' then
        main, alt = alt, nil
    end

    -- 去重：如果主标题完全包含备选标题，只保留较长的那个
    if main and alt and not self.show_alt_as_main then
        local longer_title, shorter_title
        if #main < #alt then
            longer_title, shorter_title = alt, main
        else
            longer_title, shorter_title = main, alt
        end

        local escaped_shorter_title = regexp_escape(shorter_title --[[@as string]])
        if string.match(longer_title --[[@as string]], escaped_shorter_title) then
            main, alt = longer_title, nil
        end
    end

    -- 如果启用了"备选作为主标题"模式，交换主备
    if self.show_alt_as_main and alt and alt ~= '' then
        main, alt = alt, nil
    end

    self.render_titles.main, self.render_titles.alt = main, alt
    self:update_dimensions()
    request_render()
end

-- ==============================================================================
-- 9. 选择当前章节 (select_current_chapter)
-- 根据当前播放时间更新当前章节信息
-- ==============================================================================

function TopBar:select_current_chapter()
    local current_chapter_index = self.current_chapter and self.current_chapter.index
    local current_chapter

    -- 查找当前时间所在的章节
    if state.time and state.chapters then
        _, current_chapter = itable_find(
            state.chapters,
            function(c) return state.time >= c.time end,
            #state.chapters,
            1
        )
    end

    local new_chapter_index = current_chapter and current_chapter.index

    -- 章节变化时更新
    if current_chapter_index ~= new_chapter_index then
        self.current_chapter = current_chapter

        -- 如果配置了章节闪动，触发闪动效果
        if itable_has(config.top_bar_flash_on, 'chapter') then
            self:flash()
        end

        self:update_dimensions()
    end
end

-- ==============================================================================
-- 10. 尺寸更新 (update_dimensions)
-- ==============================================================================

function TopBar:update_dimensions()
    self.size = round(options.top_bar_size * state.scale)
    self.title_spacing = round(1 * state.scale)
    self.icon_size = round(self.size * 0.5)

    -- 字号 = (高度 - 顶部内边距 × 2) × 字体缩放
    self.font_size = math.floor((self.size - (math.ceil(self.size * 0.25) * 2)) * options.font_scale)

    self.alt_title_size = round(self.font_size * 1.2)
    self.chapter_size = round(self.font_size * 1.1)

    local window_border_size = Elements:v('window_border', 'size', 0)

    -- 计算最小点击区域高度（保证低 proximity 设置下也能点击到章节按钮）
    local min_hitbox_height = self.size
    if self.render_titles.alt and options.top_bar_alt_title_place == 'below' then
        min_hitbox_height = min_hitbox_height + self.title_spacing + self.alt_title_size
    end
    if self.current_chapter then
        min_hitbox_height = min_hitbox_height + self.title_spacing + self.chapter_size
    end

    self.ax = window_border_size
    self.ay = window_border_size
    self.bx = display.width - window_border_size

    -- 扩展 hitbox 以便低 proximity 设置下仍能点击章节按钮
    self.by = math.max(self.size + window_border_size, min_hitbox_height - options.proximity_in)
end

-- ==============================================================================
-- 11. 切换主/备标题 (toggle_title)
-- ==============================================================================

function TopBar:toggle_title()
    if options.top_bar_alt_title_place ~= 'toggle' then
        return
    end
    self.show_alt_as_main = not self.show_alt_as_main
    self:update_render_titles()
end

-- ==============================================================================
-- 12. 属性观察者
-- ==============================================================================

function TopBar:on_prop_time()
    self:select_current_chapter()
end

function TopBar:on_prop_chapters()
    self:select_current_chapter()
end

function TopBar:on_prop_border()
    self:decide_enabled()
    self:update_dimensions()
end

function TopBar:on_prop_title_bar()
    self:decide_enabled()
    self:update_dimensions()
end

function TopBar:on_prop_fullscreen()
    self:decide_enabled()
    self:update_dimensions()
end

function TopBar:on_prop_maximized()
    self:decide_enabled()
    self:update_dimensions()
end

function TopBar:on_prop_has_playlist()
    self:decide_enabled()
    self:update_dimensions()
end

function TopBar:on_display()
    self:update_dimensions()
end

function TopBar:on_options()
    self:decide_enabled()
    self:update_dimensions()
end

-- ==============================================================================
-- 13. 渲染函数 (render)
-- 绘制顶栏的所有元素：窗口控制按钮、标题、播放列表位置、章节信息
-- ==============================================================================

function TopBar:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then
        return
    end

    local ass = assdraw.ass_new()

    -- 注意：by 可能被人为扩展，不能用于渲染
    local ax, ay, bx, by = self.ax, self.ay, self.bx, self.ay + self.size
    local margin = math.floor((self.size - self.font_size) / 4)

    -- ============================================================
    -- 窗口控制按钮 (Window controls)
    -- ============================================================
    if options.top_bar_controls then
        local is_left = options.top_bar_controls == 'left'
        local button_ax = 0

        if is_left then
            button_ax = ax
            ax = self.size * #self.buttons  -- 为按钮预留空间
        else
            button_ax = bx - self.size * #self.buttons
            bx = button_ax                -- 为按钮预留空间
        end

        for _, button in ipairs(self.buttons) do
            local rect = {
                ax = button_ax,
                ay = ay,
                bx = button_ax + self.size,
                by = by
            }

            local is_hover = get_point_to_rectangle_proximity(cursor, rect) <= 0
            local opacity = is_hover and 1 or config.opacity.controls
            local button_fg = is_hover and (button.hover_fg or bg) or fg
            local button_bg = is_hover and (button.hover_bg or fg) or bg

            -- 注册点击事件
            cursor:zone('primary_down', rect, button.command)

            -- 按钮背景（圆形/圆角矩形）
            local bg_size = self.size - margin
            local bg_ax, bg_ay = rect.ax + (is_left and margin or 0), rect.ay + margin
            local bg_bx, bg_by = bg_ax + bg_size, bg_ay + bg_size

            ass:rect(bg_ax, bg_ay, bg_bx, bg_by, {
                color = button_bg,
                opacity = visibility * opacity,
                radius = state.radius,
            })

            -- 按钮图标
            ass:icon(bg_ax + bg_size / 2, bg_ay + bg_size / 2, bg_size * 0.5, button.icon, {
                color = button_fg,
                border_color = button_bg,
                opacity = visibility,
                border = options.text_border * state.scale,
            })

            button_ax = button_ax + self.size
        end
    end

    -- ============================================================
    -- 窗口标题 (Window title)
    -- ============================================================
    local main_title, alt_title = self.render_titles.main, self.render_titles.alt

    if main_title or state.has_playlist then
        local padding = round(self.font_size / 2)
        local left_aligned = options.top_bar_controls == 'left'
        local title_ax, title_bx, title_ay = ax + margin, bx - margin, self.ay + margin

        -- ============================================================
        -- 播放列表位置 (Playlist position)
        -- ============================================================
        if state.has_playlist then
            local text = state.playlist_pos .. '' .. state.playlist_count
            local formatted_text = '{\\b1}' .. state.playlist_pos .. '{\\b0\\fs' .. self.font_size * 0.9 .. '}/'
                .. state.playlist_count

            local opts = {size = self.font_size, wrap = 2, color = fgt, opacity = visibility}
            local rect_width = round(text_width(text, opts) + padding * 2)

            local ax = left_aligned and title_bx - rect_width or title_ax
            local rect = {
                ax = ax,
                ay = title_ay,
                bx = ax + rect_width,
                by = by - margin,
            }

            local opacity = get_point_to_rectangle_proximity(cursor, rect) <= 0
                and 1 or config.opacity.playlist_position

            if opacity > 0 then
                ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
                    color = fg,
                    opacity = visibility * opacity,
                    radius = state.radius,
                })
            end

            ass:txt(rect.ax + (rect.bx - rect.ax) / 2, rect.ay + (rect.by - rect.ay) / 2, 5, formatted_text, opts)

            -- 更新标题边界
            if left_aligned then
                title_bx = rect.ax - margin
            else
                title_ax = rect.bx + margin
            end

            -- 点击打开播放列表
            cursor:zone('primary_down', rect, function()
                mp.command('script-binding uosc/playlist')
            end)
        end

        -- ============================================================
        -- 标题文字（主标题 + 备选标题 + 章节信息）
        -- 水平空间不足时跳过渲染
        -- ============================================================
        if title_bx - title_ax > self.font_size * 3 and options.top_bar_title ~= 'no' then
            -- 主标题
            if main_title then
                local opts = {
                    size = self.font_size,
                    wrap = 2,
                    color = bgt,
                    opacity = visibility,
                    border = options.text_border * state.scale,
                    border_color = bg,
                    clip = string.format('\\clip(%d, %d, %d, %d)', self.ax, ay, title_bx, by),
                }

                local rect_ideal_width = round(text_width(main_title, opts) + padding * 2)
                local rect_width = math.min(rect_ideal_width, title_bx - title_ax)
                local ax = left_aligned and title_bx - rect_width or title_ax
                local by = by - margin
                local title_rect = {ax = ax, ay = title_ay, bx = ax + rect_width, by = by}

                -- 如果启用 toggle 模式，点击标题切换主/备
                if options.top_bar_alt_title_place == 'toggle' then
                    cursor:zone('primary_down', title_rect, function()
                        self:toggle_title()
                    end)
                end

                -- 标题背景
                ass:rect(title_rect.ax, title_rect.ay, title_rect.bx, title_rect.by, {
                    color = bg,
                    opacity = visibility * config.opacity.title,
                    radius = state.radius,
                })

                -- 标题文字
                local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
                local x = align == 6 and title_rect.bx - padding or ax + padding
                ass:txt(x, ay + (self.size / 2), align, main_title, opts)

                title_ay = by + self.title_spacing
            end

            -- 备选标题（显示在主标题下方）
            if alt_title and options.top_bar_alt_title_place == 'below' then
                local by = title_ay + self.alt_title_size
                local opts = {
                    size = round(self.alt_title_size * 0.77),
                    wrap = 2,
                    color = bgt,
                    border = options.text_border * state.scale,
                    border_color = bg,
                    opacity = visibility,
                }

                local rect_ideal_width = round(text_width(alt_title, opts) + padding * 2)
                local rect_width = math.min(rect_ideal_width, title_bx - title_ax)
                local ax = left_aligned and title_bx - rect_width or title_ax
                local bx = ax + rect_width

                opts.clip = string.format('\\clip(%d, %d, %d, %d)', title_ax, title_ay, bx, by)

                ass:rect(ax, title_ay, bx, by, {
                    color = bg,
                    opacity = visibility * config.opacity.title,
                    radius = state.radius,
                })

                local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
                local x = align == 6 and bx - padding or ax + padding
                ass:txt(x, title_ay + self.alt_title_size / 2, align, alt_title, opts)

                title_ay = by + self.title_spacing
            end

            -- ============================================================
            -- 当前章节信息
            -- ============================================================
            if self.current_chapter then
                local padding_half = round(padding / 2)

                -- 构建章节文本（带装饰符号）
                local prefix, postfix = left_aligned and '' or '└ ', left_aligned and ' ┘' or ''
                local text = prefix .. self.current_chapter.index .. ': ' .. self.current_chapter.title .. postfix

                -- 计算章节剩余时间
                local next_chapter = state.chapters[self.current_chapter.index + 1]
                local chapter_end = next_chapter and next_chapter.time or state.duration or 0
                local remaining_time = ((state.time or 0) - chapter_end) /
                    (options.destination_time == 'time-remaining' and 1 or state.speed)
                local remaining_human = format_time(remaining_time, math.abs(remaining_time))

                local opts = {
                    size = round(self.chapter_size * 0.77),
                    italic = true,
                    wrap = 2,
                    color = bgt,
                    border = options.text_border * state.scale,
                    border_color = bg,
                    opacity = visibility * 0.8,
                }

                local remaining_width = timestamp_width(remaining_human, opts)
                local remaining_box_width = remaining_width + padding_half * 2

                -- 章节标题
                local max_bx = title_bx - remaining_box_width - self.title_spacing
                local rect_ideal_width = round(text_width(text, opts) + padding * 2)
                local rect_width = math.min(rect_ideal_width, max_bx - title_ax)
                local ax = left_aligned and title_bx - rect_width or title_ax
                local rect = {
                    ax = ax,
                    ay = title_ay,
                    bx = ax + rect_width,
                    by = title_ay + self.chapter_size,
                }

                opts.clip = string.format('\\clip(%d, %d, %d, %d)', title_ax, title_ay, rect.bx, rect.by)

                ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
                    color = bg,
                    opacity = visibility * config.opacity.title,
                    radius = state.radius,
                })

                local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
                local x = align == 6 and rect.bx - padding or rect.ax + padding
                ass:txt(x, rect.ay + self.chapter_size / 2, align, text, opts)

                -- 剩余时间
                local time_ax = left_aligned
                    and rect.ax - self.title_spacing - remaining_box_width
                    or rect.bx + self.title_spacing
                local time_bx = time_ax + remaining_box_width

                opts.clip = nil
                ass:rect(time_ax, rect.ay, time_bx, rect.by, {
                    color = bg,
                    opacity = visibility * config.opacity.title,
                    radius = state.radius,
                })
                ass:txt(time_ax + padding_half, rect.ay + self.chapter_size / 2, 4, remaining_human, opts)

                -- 点击打开章节菜单
                rect.bx = time_bx
                cursor:zone('primary_down', rect, function()
                    mp.command('script-binding uosc/chapters')
                end)

                title_ay = rect.by + self.title_spacing
            end
        end

        self.title_by = title_ay - 1
    else
        self.title_by = ay
    end

    return ass
end

return TopBar