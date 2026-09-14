-- ==============================================================================
-- Updater.lua — uosc 更新器组件
-- ==============================================================================
-- 功能概述：
--   1. 检查 uosc 是否有新版本可用（通过 GitHub API）
--   2. 显示当前版本和最新版本信息
--   3. 提供一键更新功能（下载并安装最新版 uosc）
--   4. 显示更新日志链接
--   5. 支持 Windows、macOS、Linux 三大平台
--   6. 提供友好的 UI 反馈（加载动画、状态图标、输出日志）
-- ==============================================================================
-- 使用方式：
--   通过快捷键或命令调用：script-binding uosc/update
--   或在菜单中点击 "Update uosc"
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入父类 Element
local Element = require('elements/Element')

-- 加载动画的点阵（用于显示 "正在检查..." 的动画效果）
local dots = {'.', '..', '...'}

-- ==============================================================================
-- 1. 辅助函数：清理输出文本 (cleanup_output)
-- 移除多余的空白字符和换行
-- ==============================================================================

local function cleanup_output(output)
    return tostring(output)
        :gsub('%c*\n%c*', '\n')  -- 规范化换行符
        :match('^[%s%c]*(.-)[%s%c]*$')  -- 去除首尾空白
end

-- ==============================================================================
-- 2. Updater 类定义
-- 继承自 Element，实现更新器的完整 UI 和逻辑
-- ==============================================================================

---@class Updater : Element
local Updater = class(Element)

-- ==============================================================================
-- 3. 构造函数与初始化 (new / init)
-- ==============================================================================

function Updater:new() return Class.new(self) --[[@as Updater]] end

function Updater:init()
    -- 调用父类 Element 的初始化
    -- render_order = 1000 表示渲染在所有元素之上（仅次于菜单）
    Element.init(self, 'updater', {render_order = 1000})

    -- 状态变量
    self.output = nil          -- 输出日志文本
    self.title = ''            -- 标题文本
    self.state = 'circle'      -- 状态图标名称（'circle' 为初始，'pending' 映射为 'spinner'）
    self.update_available = false  -- 是否有可用更新

    -- ============================================================
    -- 按钮定义
    -- ============================================================
    self.check_button = {
        method = 'check',
        title = t('Check for updates')
    }
    self.update_button = {
        method = 'update',
        title = t('Update uosc'),
        color = config.color.success   -- 绿色（成功色）
    }
    self.changelog_button = {
        method = 'open_changelog',
        title = t('Open changelog')
    }
    self.close_button = {
        method = 'destroy',
        title = t('Close') .. ' (Esc)',
        color = config.color.error     -- 红色（错误色）
    }
    self.quit_button = {
        method = 'quit',
        title = t('Quit')
    }

    -- 初始按钮列表（检查 + 关闭）
    self.buttons = {self.check_button, self.close_button}
    self.selected_button_index = 1   -- 默认选中第一个按钮

    -- ============================================================
    -- 快捷键绑定
    -- ============================================================
    self:add_key_binding('right', 'select_next_button')
    self:add_key_binding('tab', 'select_next_button')
    self:add_key_binding('left', 'select_prev_button')
    self:add_key_binding('shift+tab', 'select_prev_button')
    self:add_key_binding('enter', 'activate_selected_button')
    self:add_key_binding('kp_enter', 'activate_selected_button')
    self:add_key_binding('esc', 'destroy')

    -- 注册幕布（背景遮罩）
    Elements:maybe('curtain', 'register', self.id)

    -- 立即开始检查更新
    self:check()
end

-- ==============================================================================
-- 4. 销毁 (destroy)
-- ==============================================================================

function Updater:destroy()
    -- 取消幕布注册
    Elements:maybe('curtain', 'unregister', self.id)
    Element.destroy(self)
end

-- ==============================================================================
-- 5. 退出 mpv (quit)
-- ==============================================================================

function Updater:quit()
    mp.command('quit')
end

-- ==============================================================================
-- 6. 按钮导航 (select_prev_button / select_next_button)
-- ==============================================================================

function Updater:select_prev_button()
    self.selected_button_index = self.selected_button_index - 1
    if self.selected_button_index < 1 then
        self.selected_button_index = #self.buttons
    end
    request_render()
end

function Updater:select_next_button()
    self.selected_button_index = self.selected_button_index + 1
    if self.selected_button_index > #self.buttons then
        self.selected_button_index = 1
    end
    request_render()
end

-- ==============================================================================
-- 7. 激活选中按钮 (activate_selected_button)
-- ==============================================================================

function Updater:activate_selected_button()
    local button = self.buttons[self.selected_button_index]
    if button then
        self[button.method](self)
    end
end

-- ==============================================================================
-- 8. 输出日志 (append_output)
-- ==============================================================================

---@param msg string
function Updater:append_output(msg)
    -- 追加日志文本（ASS 转义防止注入）
    self.output = (self.output or '') .. ass_escape('\n' .. cleanup_output(msg))
    request_render()
end

-- ==============================================================================
-- 9. 显示错误 (display_error)
-- ==============================================================================

---@param msg string
function Updater:display_error(msg)
    self.state = 'error'   -- 切换为错误图标
    self.title = t('An error has occurred.') .. ' ' .. t('See console for details.')
    self:append_output(msg)
    print(msg)  -- 同时输出到控制台
end

-- ==============================================================================
-- 10. 打开更新日志 (open_changelog)
-- ==============================================================================

function Updater:open_changelog()
    if self.state == 'pending' then return end

    local url = 'https://github.com/tomasklaen/uosc/releases'
    self:append_output('Opening URL: ' .. url)

    -- 异步打开 URL
    call_ziggy_async({'open', url}, function(error)
        if error then
            self:display_error(error)
            return
        end
    end)
end

-- ==============================================================================
-- 11. 检查更新 (check)
-- 调用 GitHub API 获取最新版本信息
-- ==============================================================================

function Updater:check()
    if self.state == 'pending' then return end

    self.state = 'pending'
    self.title = t('Checking for updates') .. '...'

    -- GitHub API URL（获取最新 release）
    local url = 'https://api.github.com/repos/tomasklaen/uosc/releases/latest'
    local headers = utils.format_json({
        Accept = 'application/vnd.github+json',
    })
    local args = {'http-get', '--headers', headers, url}

    self:append_output('Fetching: ' .. url)

    -- 异步 HTTP 请求
    call_ziggy_async(args, function(error, response)
        if error then
            self:display_error(error)
            return
        end

        -- 解析 JSON 响应
        local release = utils.parse_json(type(response.body) == 'string' and response.body or '')

        if response.status == 200 and type(release) == 'table' and type(release.tag_name) == 'string' then
            -- 比较版本号（tag_name 如 "v5.12.0"）
            self.update_available = config.version ~= release.tag_name

            self:append_output('Response: 200 OK')
            self:append_output('Current version: ' .. config.version)
            self:append_output('Latest version: ' .. release.tag_name)

            if self.update_available then
                -- 有新版本
                self.state = 'upgrade'
                self.title = t('Update available')
                self.buttons = {self.update_button, self.changelog_button, self.close_button}
                self.selected_button_index = 1
            else
                -- 已是最新
                self.state = 'done'
                self.title = t('Up to date')
            end
        else
            -- 请求失败
            self:display_error('Response couldn\'t be parsed, is invalid, or not-OK status code.\nStatus: ' ..
                response.status .. '\nBody: ' .. response.body)
        end

        request_render()
    end)
end

-- ==============================================================================
-- 12. 执行更新 (update)
-- 下载并安装最新版 uosc
-- ==============================================================================

function Updater:update()
    if self.state == 'pending' then return end

    self.state = 'pending'
    self.title = t('Updating uosc')
    self.output = nil
    request_render()

    -- 获取 mpv 配置目录
    local config_dir = mp.command_native({'expand-path', '~~/'})

    -- ============================================================
    -- 处理更新结果 (handle_result)
    -- ============================================================
    local function handle_result(success, result, error)
        if success and result and result.status == 0 then
            -- 更新成功
            self.state = 'done'
            self.title = t('uosc has been installed. Restart mpv for it to take effect.')
            self.buttons = {self.quit_button, self.close_button}
            self.selected_button_index = 1
        else
            -- 更新失败
            self.state = 'error'
            self.title = t('An error has occurred.') .. ' ' .. t('See above for clues.')
        end

        -- 收集输出信息
        local output = (result.stdout or '') .. '\n' .. (error or result.stderr or '')

        -- macOS 已知问题提示
        if state.platform == 'darwin' then
            output = 'Self-updater is known not to work on MacOS.\n' ..
                'If you know about a solution, please make an issue and share it with us!.\n' ..
                output
        end

        self:append_output(output)
    end

    -- ============================================================
    -- 执行更新命令 (update)
    -- ============================================================
    local function update(args)
        -- 设置环境变量（传递 mpv 配置目录）
        local env = utils.get_env_list()
        env[#env + 1] = 'MPV_CONFIG_DIR=' .. config_dir

        mp.command_native_async({
            name = 'subprocess',
            capture_stderr = true,
            capture_stdout = true,
            playback_only = false,
            args = args,
            env = env,
        }, handle_result)
    end

    -- ============================================================
    -- 平台特定更新逻辑
    -- ============================================================

    if state.platform == 'windows' then
        -- Windows：使用 PowerShell 脚本
        local url = 'https://raw.githubusercontent.com/tomasklaen/uosc/HEAD/installers/windows.ps1'
        update({'powershell', '-NoProfile', '-Command', 'irm ' .. url .. ' | iex'})

    else
        -- Linux / macOS：检测依赖（curl 和 unzip）
        local missing = {}

        for _, name in ipairs({'curl', 'unzip'}) do
            local result = mp.command_native({
                name = 'subprocess',
                capture_stdout = true,
                playback_only = false,
                args = {'which', name},
            })
            local path = cleanup_output(result and result.stdout or '')
            if path == '' then
                missing[#missing + 1] = name
            end
        end

        if #missing > 0 then
            -- 缺少依赖
            local stderr = 'Missing dependencies: ' .. table.concat(missing, ', ')

            -- snap 包的特殊提示
            if config_dir:match('/snap/') then
                stderr = stderr ..
                    '\nThis is a known error for mpv snap packages.\n' ..
                    'You can still update uosc by entering the Linux install command from uosc\'s readme into your terminal, ' ..
                    'it just can\'t be done this way.\n' ..
                    'If you know about a solution, please make an issue and share it with us!'
            end

            handle_result(false, {stderr = stderr})
        else
            -- 使用 Unix 安装脚本
            local url = 'https://raw.githubusercontent.com/tomasklaen/uosc/HEAD/installers/unix.sh'
            update({'/bin/bash', '-c', 'source <(curl -fsSL ' .. url .. ')'})
        end
    end
end

-- ==============================================================================
-- 13. 渲染函数 (render)
-- 绘制更新器的完整 UI
-- ==============================================================================

function Updater:render()
    local ass = assdraw.ass_new()

    -- ============================================================
    -- 尺寸计算
    -- ============================================================
    local text_size = math.min(20 * state.scale, display.height / 20)
    local icon_size = text_size * 2
    local center_x = round(display.width / 2)

    -- 颜色：根据状态变化
    local color = fg
    if self.state == 'done' or self.update_available then
        color = config.color.success   -- 绿色（成功/有更新）
    elseif self.state == 'error' then
        color = config.color.error     -- 红色（错误）
    end

    -- ============================================================
    -- 分割线（装饰性横线）
    -- ============================================================
    local divider_width = round(math.min(500 * state.scale, display.width * 0.8))
    local divider_half = divider_width / 2
    local divider_border_half = round(1 * state.scale)
    local divider_y = display.height * 0.65

    local divider_ay = round(divider_y - divider_border_half)
    local divider_by = round(divider_y + divider_border_half)

    -- 左半部分
    ass:rect(center_x - divider_half, divider_ay, center_x - icon_size, divider_by, {
        color = color,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = 0.5,
    })

    -- 右半部分
    ass:rect(center_x + icon_size, divider_ay, center_x + divider_half, divider_by, {
        color = color,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = 0.5,
    })

    -- ============================================================
    -- 中央图标 / 加载动画
    -- ============================================================
    if self.state == 'pending' then
        -- 加载中：旋转的 spinner
        ass:spinner(center_x, divider_y, icon_size, {
            color = fg,
            border = options.text_border * state.scale,
            border_color = bg,
        })
    else
        -- 状态图标（circle / upgrade / done / error）
        ass:icon(center_x, divider_y, icon_size * 0.8, self.state, {
            color = color,
            border = options.text_border * state.scale,
            border_color = bg,
        })
    end

    -- ============================================================
    -- 输出日志（显示在图标上方）
    -- ============================================================
    local output = self.output or dots[math.ceil((mp.get_time() % 1) * #dots)]
    ass:txt(center_x, divider_y - icon_size, 2, output, {
        size = text_size,
        color = fg,
        border = options.text_border * state.scale,
        border_color = bg,
    })

    -- ============================================================
    -- 标题（显示在图标下方）
    -- ============================================================
    ass:txt(center_x, divider_y + icon_size, 5, self.title, {
        size = text_size,
        bold = true,
        color = color,
        border = options.text_border * state.scale,
        border_color = bg,
    })

    -- ============================================================
    -- 底部按钮组
    -- ============================================================
    local outline = round(1 * state.scale)
    local spacing = outline * 9
    local padding = round(text_size * 0.5)

    local text_opts = {size = text_size, bold = true}

    -- 计算所有按钮的总宽度
    local total_width = (#self.buttons - 1) * spacing
    for _, button in ipairs(self.buttons) do
        button.width = text_width(button.title, text_opts) + padding * 2
        total_width = total_width + button.width
    end

    -- 按钮行坐标
    local ay = round(divider_y + icon_size * 1.8)
    local ax = round(display.width / 2 - total_width / 2)
    local height = text_size + padding * 2

    -- 逐个绘制按钮
    for index, button in ipairs(self.buttons) do
        local rect = {
            ax = ax,
            ay = ay,
            bx = ax + button.width,
            by = ay + height,
        }
        ax = rect.bx + spacing

        local is_hovered = get_point_to_rectangle_proximity(cursor, rect) <= 0

        -- 按钮背景
        ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
            color = button.color or fg,
            radius = state.radius,
            opacity = is_hovered and 1 or 0.8,
        })

        -- 选中按钮的外发光边框
        if index == self.selected_button_index then
            ass:rect(rect.ax - outline * 4, rect.ay - outline * 4, rect.bx + outline * 4, rect.by + outline * 4, {
                border = outline,
                border_color = button.color or fg,
                radius = state.radius + outline * 4,
                opacity = {primary = 0, border = 0.5},
            })
        end

        -- 按钮文字
        local x = rect.ax + (rect.bx - rect.ax) / 2
        local y = rect.ay + (rect.by - rect.ay) / 2
        ass:txt(x, y, 5, button.title, {
            size = text_size,
            bold = true,
            color = fgt,   -- 文字使用前景文字色（与背景形成对比）
        })

        -- 注册点击事件
        cursor:zone('primary_down', rect, self:create_action(button.method))

        -- 鼠标悬停时自动选中
        if is_hovered then
            self.selected_button_index = index
        end
    end

    return ass
end

return Updater