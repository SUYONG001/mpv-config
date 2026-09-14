-- ==============================================================================
-- menus.lua — uosc 菜单构建辅助函数
-- ==============================================================================
-- 功能概述：
--   1. 提供构建各类菜单的辅助函数，供 uosc 内部和外部脚本调用
--   2. 包含：命令菜单、文件导航菜单、轨道选择菜单、自更新菜单等
--   3. 从 input.conf 解析用户自定义菜单项
--   4. 提供字幕下载、流媒体画质切换等高级菜单功能
-- ==============================================================================
-- 这是 uosc 菜单系统的“指挥部”，所有具体菜单的构建逻辑都在这里。
-- 与 Menu.lua（渲染引擎）配合工作：Menu.lua 负责绘制，menus.lua 负责构建数据。
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- ==============================================================================
-- 1. 类型定义 (Type Aliases)
-- ==============================================================================

---@alias OpenCommandMenuOptions {submenu?: string; mouse_nav?: boolean; on_close?: string | string[]}
-- 打开命令菜单的选项：
--   submenu   : 初始激活的子菜单 ID
--   mouse_nav : 是否使用鼠标导航模式
--   on_close  : 关闭时执行的命令

-- ==============================================================================
-- 2. 打开命令菜单 (open_command_menu)
-- 最基础的菜单打开函数，所有其他菜单构建函数都基于此
-- ==============================================================================

---@param data MenuData
---@param opts? OpenCommandMenuOptions
function open_command_menu(data, opts)
    opts = opts or {}
    local menu

    -- 执行 mpv 命令
    local function run_command(command)
        if type(command) == 'table' then
            ---@diagnostic disable-next-line: deprecated
            mp.commandv(unpack(command))
        else
            mp.command(tostring(command))
        end
    end

    -- 菜单事件回调
    local function callback(event)
        -- 如果菜单配置了 callback（通过 script-message 转发）
        if type(menu.root.callback) == 'table' then
            ---@diagnostic disable-next-line: deprecated
            mp.commandv(unpack(itable_join({'script-message-to'}, menu.root.callback, {utils.format_json(event)})))
        elseif event.type == 'activate' then
            -- 基本模式（无 callback）：直接执行命令
            -- 注意：修饰键和动作在基本模式下不可用
            -- `alt` 修饰键激活但不关闭菜单
            if (event.modifiers == 'alt' or not event.modifiers) and not event.action then
                run_command(event.value)
            end
            -- 约定：只有纯菜单项激活才关闭菜单
            -- 使用修饰键或触发动作不关闭菜单
            if not event.keep_open and not event.modifiers and not event.action then
                menu:close()
            end
        end
    end

    ---@type MenuOptions
    local menu_opts = table_assign_props({}, opts, {'mouse_nav'})
    menu = Menu:open(data, callback, menu_opts)

    -- 如果有 submenu 参数，激活对应的子菜单
    if opts.submenu then
        menu:activate_menu(opts.submenu)
    end

    return menu
end

-- ==============================================================================
-- 3. 切换菜单 (toggle_menu_with_items)
-- 如果菜单已打开则关闭，否则打开主菜单
-- ==============================================================================

---@param opts? OpenCommandMenuOptions
function toggle_menu_with_items(opts)
    if Menu:is_open('menu') then
        Menu:close()
    else
        open_command_menu({
            type = 'menu',
            items = get_menu_items(),
            search_submenus = true,   -- 搜索时包含子菜单内容
        }, opts)
    end
end

-- ==============================================================================
-- 4. 创建自更新菜单 (create_self_updating_menu_opener)
-- 用于播放列表、章节、版本等需要随属性变化自动刷新的菜单
-- ==============================================================================

---@alias TrackEventRemove {type: 'remove' | 'delete', index: number; value: any;}
---@alias TrackEventReload {type: 'reload', index: number; value: any;}
---@param opts {type: string; title: string; list_prop: string; active_prop?: string; footnote?: string; serializer: fun(list: any, active: any): MenuDataItem[]; actions?: MenuAction[]; actions_place?: 'inside'|'outside'; on_paste: fun(event: MenuEventPaste); on_move?: fun(event: MenuEventMove); on_activate?: fun(event: MenuEventActivate); on_remove?: fun(event: TrackEventRemove); on_delete?: fun(event: TrackEventRemove); on_reload?: fun(event: TrackEventReload); on_key?: fun(event: MenuEventKey, close: fun())}
function create_self_updating_menu_opener(opts)
    return function()
        -- 如果菜单已打开，关闭它（切换效果）
        if Menu:is_open(opts.type) then
            Menu:close()
            return
        end

        -- 获取列表数据和当前选中项
        local list = mp.get_property_native(opts.list_prop)
        local active = opts.active_prop and mp.get_property_native(opts.active_prop) or nil
        local menu

        -- 更新菜单项
        local function update()
            menu:update_items(opts.serializer(list, active))
        end

        -- ============================================================
        -- 监听列表属性变化
        -- ============================================================
        local ignore_initial_list = true
        local function handle_list_prop_change(name, value)
            if ignore_initial_list then
                ignore_initial_list = false
            else
                list = value
                update()
            end
        end

        -- ============================================================
        -- 监听选中项属性变化
        -- ============================================================
        local ignore_initial_active = true
        local function handle_active_prop_change(name, value)
            if ignore_initial_active then
                ignore_initial_active = false
            else
                active = value
                update()
            end
        end

        -- 清理并关闭菜单
        local function cleanup_and_close()
            mp.unobserve_property(handle_list_prop_change)
            mp.unobserve_property(handle_active_prop_change)
            menu:close()
        end

        -- ============================================================
        -- 构建初始菜单数据
        -- ============================================================
        local initial_items, selected_index = opts.serializer(list, active)

        ---@type MenuAction[]
        local actions = opts.actions or {}

        -- 移动操作（上/下）
        if opts.on_move then
            actions[#actions + 1] = {
                name = 'move_up',
                icon = 'arrow_upward',
                label = t('Move up') .. ' (ctrl+up/pgup/home)',
                filter_hidden = true,
            }
            actions[#actions + 1] = {
                name = 'move_down',
                icon = 'arrow_downward',
                label = t('Move down') .. ' (ctrl+down/pgdwn/end)',
                filter_hidden = true,
            }
        end

        -- 刷新操作
        if opts.on_reload then
            actions[#actions + 1] = {
                name = 'reload',
                icon = 'refresh',
                label = t('Reload') .. ' (f5)'
            }
        end

        -- 删除/移除操作
        if opts.on_remove or opts.on_delete then
            local label = (opts.on_remove and t('Remove') or t('Delete')) .. ' (del)'
            if opts.on_remove and opts.on_delete then
                label = t('Remove') .. ' (' .. t('%s to delete', 'del, ctrl+del') .. ')'
            end
            actions[#actions + 1] = {
                name = 'remove',
                icon = 'delete',
                label = label
            }
        end

        -- 删除或移除（根据 modifiers 决定）
        function remove_or_delete(index, value, menu_id, modifiers)
            if opts.on_remove and opts.on_delete then
                local method = modifiers == 'ctrl' and 'delete' or 'remove'
                local handler = method == 'delete' and opts.on_delete or opts.on_remove
                if handler then
                    handler({type = method, value = value, index = index})
                end
            elseif opts.on_remove or opts.on_delete then
                local method = opts.on_delete and 'delete' or 'remove'
                local handler = opts.on_delete or opts.on_remove
                if handler then
                    handler({type = method, value = value, index = index})
                end
            end
        end

        -- 打开菜单
        menu = Menu:open({
            type = opts.type,
            title = opts.title,
            footnote = opts.footnote,
            items = initial_items,
            item_actions = actions,
            item_actions_place = opts.actions_place,
            selected_index = selected_index,
            on_move = opts.on_move and 'callback' or nil,
            on_paste = opts.on_paste and 'callback' or nil,
        }, function(event)
            if event.type == 'activate' then
                -- 处理移动操作
                if (event.action == 'move_up' or event.action == 'move_down') and opts.on_move then
                    local to_index = event.index + (event.action == 'move_up' and -1 or 1)
                    if to_index >= 1 and to_index <= #menu.current.items then
                        opts.on_move({
                            type = 'move',
                            from_index = event.index,
                            to_index = to_index,
                            menu_id = menu.current.id,
                        })
                        menu:select_index(to_index)
                        if not event.is_pointer then
                            menu:scroll_to_index(to_index, nil, true)
                        end
                    end
                -- 处理刷新操作
                elseif event.action == 'reload' and opts.on_reload then
                    opts.on_reload({type = 'reload', index = event.index, value = event.value})
                -- 处理删除/移除操作
                elseif event.action == 'remove' and (opts.on_remove or opts.on_delete) then
                    remove_or_delete(event.index, event.value, event.menu_id, event.modifiers)
                -- 普通激活
                else
                    opts.on_activate(event --[[@as MenuEventActivate]])
                    -- 没有修饰键且没有动作时关闭菜单
                    if not event.modifiers and not event.action then
                        cleanup_and_close()
                    end
                end
            elseif event.type == 'key' then
                local item = event.selected_item

                if event.id == 'enter' then
                    -- 用户按 Enter 但菜单中没有可选项，关闭菜单
                    cleanup_and_close()
                elseif event.key == 'f5' and opts.on_reload and item then
                    opts.on_reload({type = 'reload', index = item.index, value = item.value})
                elseif event.key == 'del' and (opts.on_remove or opts.on_delete) and item then
                    if itable_has({nil, 'ctrl'}, event.modifiers) then
                        remove_or_delete(item.index, item.value, event.menu_id, event.modifiers)
                    end
                elseif opts.on_key then
                    opts.on_key(event --[[@as MenuEventKey]], cleanup_and_close)
                end
            elseif event.type == 'paste' and opts.on_paste then
                opts.on_paste(event --[[@as MenuEventPaste]])
            elseif event.type == 'close' then
                cleanup_and_close()
            elseif event.type == 'move' and opts.on_move then
                opts.on_move(event --[[@as MenuEventMove]])
            elseif event.type == 'remove' and opts.on_move then
                -- 忽略 remove 事件（由 on_move 处理）
            end
        end)

        -- 监听列表属性变化
        mp.observe_property(opts.list_prop, 'native', handle_list_prop_change)
        if opts.active_prop then
            mp.observe_property(opts.active_prop, 'native', handle_active_prop_change)
        end
    end
end

-- ==============================================================================
-- 5. 创建轨道选择菜单 (create_select_tracklist_type_menu_opener)
-- 用于音轨、字幕轨、视频轨的选择菜单
-- ==============================================================================

---@param opts {title: string; type: string; prop: string; enable_prop?: string; secondary?: {prop: string; icon: string; enable_prop?: string}; load_command: string; download_command?: string}
function create_select_tracklist_type_menu_opener(opts)
    local snd = opts.secondary

    -- 获取当前主轨道和次轨道索引
    local function get_props()
        return tonumber(mp.get_property(opts.prop)),
               snd and tonumber(mp.get_property(snd.prop)) or nil
    end

    -- 序列化轨道列表为菜单项
    local function serialize_tracklist(tracklist)
        local items = {}

        -- 加载按钮
        if opts.load_command then
            items[#items + 1] = {
                title = t('Load'),
                bold = true,
                italic = true,
                hint = t('open file'),
                value = '{load}',
                actions = opts.download_command
                    and {{name = 'download', icon = 'language', label = t('Search online')}}
                    or nil,
            }
        end
        if #items > 0 then
            items[#items].separator = true
        end

        local track_prop_index, snd_prop_index = get_props()
        local filename = mp.get_property_native('filename/no-ext')
        local escaped_filename = filename and regexp_escape(filename)
        local first_item_index = #items + 1
        local active_index = nil
        local disabled_item = nil
        local track_actions = nil
        local track_external_actions = {}

        -- 次轨道动作
        if snd then
            local action = {
                name = 'as_secondary',
                icon = snd.icon,
                label = t('Use as secondary') .. ' (shift+enter/click)',
            }
            track_actions = {action}
            table.insert(track_external_actions, action)
        end

        -- 外部轨道的额外动作（刷新、删除）
        table.insert(track_external_actions, {
            name = 'reload',
            icon = 'refresh',
            label = t('Reload') .. ' (f5)'
        })
        table.insert(track_external_actions, {
            name = 'remove',
            icon = 'delete',
            label = t('Remove') .. ' (del)'
        })

        -- 遍历轨道列表
        for _, track in ipairs(tracklist) do
            if track.type == opts.type then
                local hint_values = {}
                local track_selected = track.selected and track.id == track_prop_index
                local snd_selected = snd and track.id == snd_prop_index

                local function h(value)
                    value = trim(value)
                    if #value > 0 then
                        hint_values[#hint_values + 1] = value
                    end
                end

                -- 收集轨道信息作为提示文字
                if track.lang then h(track.lang) end
                if track['demux-h'] then
                    h(track['demux-w'] and (track['demux-w'] .. 'x' .. track['demux-h'])
                       or (track['demux-h'] .. 'p'))
                end
                if track['demux-fps'] then
                    h(string.format('%.5gfps', track['demux-fps']))
                end
                h(track.codec)
                if track['audio-channels'] then
                    h(track['audio-channels'] == 1
                        and t('%s channel', track['audio-channels'])
                        or t('%s channels', track['audio-channels']))
                end
                if track['demux-samplerate'] then
                    h(string.format('%.3gkHz', track['demux-samplerate'] / 1000))
                end
                if track.forced then h(t('forced')) end
                if track.default then h(t('default')) end

                -- 处理外部轨道（去掉文件名前缀）
                if track.external then
                    local extension = track.title:match('%.([^%.]+)$')
                    if track.title and escaped_filename and extension then
                        track.title = trim(track.title:gsub(escaped_filename .. '%.?', ''):gsub('%.?([^%.]+)$', ''))
                        if track.title == '' or (track.lang and track.title:lower() == track.lang:lower()) then
                            track.title = nil
                        end
                    end
                    h(t('external'))
                end

                items[#items + 1] = {
                    title = (track.title and track.title or t('Track %s', track.id)),
                    hint = table.concat(hint_values, ', '),
                    value = track.id,
                    active = track_selected or snd_selected,
                    italic = snd_selected,
                    icon = snd and snd_selected and snd.icon or nil,
                    actions = track.external and track_external_actions or track_actions,
                }

                if track_selected then
                    if disabled_item then
                        disabled_item.active = false
                    end
                    active_index = #items
                end
            end
        end

        return items, active_index or first_item_index
    end

    -- 刷新轨道
    local function reload(id)
        if id then
            mp.commandv(opts.type .. '-reload', id)
        end
    end

    -- 移除轨道
    local function remove(id)
        if id then
            mp.commandv(opts.type .. '-remove', id)
        end
    end

    ---@param event MenuEventActivate
    local function handle_activate(event)
        if event.value == '{load}' then
            -- 加载按钮
            mp.command(event.action == 'download' and opts.download_command or opts.load_command)
        else
            if snd and (event.action == 'as_secondary' or event.modifiers == 'shift') then
                -- 设为次轨道
                local _, snd_track_index = get_props()
                mp.commandv('set', snd.prop, event.value == snd_track_index and 'no' or event.value)
                if snd.enable_prop then
                    mp.commandv('set', snd.enable_prop, 'yes')
                end
            elseif event.action == 'reload' then
                reload(event.value)
            elseif event.action == 'remove' then
                remove(event.value)
            elseif not event.modifiers or event.modifiers == 'alt' then
                -- 切换主轨道
                mp.commandv('set', opts.prop, event.value == get_props() and 'no' or event.value)
                if opts.enable_prop then
                    mp.commandv('set', opts.enable_prop, 'yes')
                end
            end
        end
    end

    ---@param event MenuEventKey
    local function handle_key(event)
        if event.selected_item then
            if event.id == 'f5' then
                reload(event.selected_item.value)
            elseif event.id == 'del' then
                remove(event.selected_item.value)
            end
        end
    end

    return create_self_updating_menu_opener({
        title = opts.title,
        footnote = t('Toggle to disable.') .. ' ' .. t('Paste path or url to add.'),
        type = opts.type,
        list_prop = 'track-list',
        serializer = serialize_tracklist,
        on_activate = handle_activate,
        on_key = handle_key,
        actions_place = 'outside',
        on_paste = function(event) load_track(opts.type, event.value) end,
    })
end

-- ==============================================================================
-- 6. 打开文件导航菜单 (open_file_navigation_menu)
-- 用于浏览文件系统并选择文件/目录
-- ==============================================================================

---@alias NavigationMenuOptions {type: string, title?: string, allowed_types?: string[], file_actions?: MenuAction[], directory_actions?: MenuAction[], active_path?: string, selected_path?: string; on_close?: fun()}

-- Opens a file navigation menu with items inside `directory_path`.
---@param directory_path string
---@param handle_activate fun(event: MenuEventActivate)
---@param opts NavigationMenuOptions
function open_file_navigation_menu(directory_path, handle_activate, opts)
    -- 处理特殊路径 '{drives}'（Windows 驱动器列表）
    if directory_path == '{drives}' then
        if state.platform ~= 'windows' then
            directory_path = '/'  -- 非 Windows 平台回退到根目录
        end
    else
        directory_path = normalize_path(mp.command_native({'expand-path', directory_path}))
    end

    opts = opts or {}
    ---@type string|nil
    local current_directory = nil
    ---@type Menu
    local menu
    ---@type string | nil
    local back_path
    local separator = path_separator(directory_path)

    -- ============================================================
    -- 序列化目录内容为菜单项 (serialize_items)
    -- ============================================================
    ---@param path string 目录路径或 '{drives}'
    ---@param selected_path? string 选中的路径
    ---@return MenuStackChild[] menu_items
    ---@return number selected_index
    ---@return string|nil error
    local function serialize_items(path, selected_path)
        -- 处理 Windows 驱动器列表
        if path == '{drives}' then
            local process = mp.command_native({
                name = 'subprocess',
                capture_stdout = true,
                playback_only = false,
                args = {'fsutil', 'fsinfo', 'drives'},
            })
            local items, selected_index = {}, 1

            if process.status == 0 then
                for drive in process.stdout:gmatch('(%a:)\\') do
                    if drive then
                        local drive_path = normalize_path(drive)
                        items[#items + 1] = {
                            title = drive,
                            hint = t('drive'),
                            value = drive_path,
                            active = opts.active_path == drive_path,
                        }
                        if selected_path == drive_path then
                            selected_index = #items
                        end
                    end
                end
            else
                return {}, 1, 'Couldn\'t open drives. Error: ' .. utils.to_string(process.stderr)
            end
            return items, selected_index
        end

        -- 普通路径
        local serialized = serialize_path(path)
        if not serialized then
            return {}, 0, 'Couldn\'t serialize path "' .. path .. '.'
        end

        local files, directories, error = read_directory(serialized.path, {
            types = opts.allowed_types,
            hidden = options.show_hidden_files,
        })

        if error then
            return {}, 1, error
        end

        local is_root = not serialized.dirname

        if not files or not directories then
            return {}, 0
        end

        sort_strings(directories)
        sort_strings(files)

        -- ============================================================
        -- 构建菜单项：先显示父目录（..），然后是目录，最后是文件
        -- ============================================================
        local items = {}

        -- 父目录
        if is_root then
            if state.platform == 'windows' then
                items[#items + 1] = {
                    title = '..',
                    hint = t('Drives'),
                    value = '{drives}',
                    separator = true,
                    is_to_parent = true,
                }
            end
        else
            items[#items + 1] = {
                title = '..',
                hint = t('parent dir'),
                value = serialized.dirname,
                separator = true,
                is_to_parent = true,
            }
        end

        back_path = items[#items] and items[#items].value
        local selected_index = #items + 1

        -- 目录
        for _, dir in ipairs(directories) do
            items[#items + 1] = {
                title = dir .. ' ' .. separator,
                value = join_path(path, dir),
                bold = true,
                actions = opts.directory_actions,
            }
        end

        -- 文件
        for _, file in ipairs(files) do
            items[#items + 1] = {
                title = file,
                value = join_path(path, file),
                actions = opts.file_actions,
            }
        end

        -- 标记激活项
        for index, item in ipairs(items) do
            if not item.is_to_parent then
                if opts.active_path == item.value then
                    item.active = true
                    if not selected_path then
                        selected_index = index
                    end
                end

                if selected_path == item.value then
                    selected_index = index
                end
            end
        end

        return items, selected_index
    end

    -- ============================================================
    -- 菜单数据
    -- ============================================================
    local menu_data = {
        type = opts.type,
        title = opts.title or '',
        footnote = t('%s to go up in tree.', 'alt+up') .. ' ' .. t('Paste path or url to open.'),
        items = {},
        on_paste = 'callback',
    }

    -- ============================================================
    -- 打开目录 (open_directory)
    -- ============================================================
    ---@param path string
    local function open_directory(path)
        local items, selected_index, error = serialize_items(path, current_directory)
        if error then
            msg.error(error)
            items = {
                {title = 'Something went wrong. See console for errors.', selectable = false, muted = true}
            }
        end

        local title = opts.title
        if not title then
            if path == '{drives}' then
                title = 'Drives'
            else
                local serialized = serialize_path(path)
                title = serialized and serialized.basename .. separator or '??'
            end
        end

        current_directory = path
        menu_data.title = title
        menu_data.items = items
        menu:search_cancel()
        menu:update(menu_data)
        menu:select_index(selected_index)
        menu:scroll_to_index(selected_index, nil, true)
    end

    -- ============================================================
    -- 关闭菜单 (close)
    -- ============================================================
    local function close()
        menu:close()
        if opts.on_close then
            opts.on_close()
        end
    end

    -- ============================================================
    -- 激活菜单项 (activate)
    -- ============================================================
    ---@param event MenuEventActivate
    ---@param only_if_dir? boolean 是否仅当是目录时才激活
    local function activate(event, only_if_dir)
        local path = event.value
        local is_drives = path == '{drives}'

        if is_drives then
            open_directory(path)
            return
        end

        local info, error = utils.file_info(path)

        if not info then
            msg.error('Can\'t retrieve path info for "' .. path .. '". Error: ' .. (error or ''))
            return
        end

        -- 如果是目录且没有修饰键/动作，进入该目录
        if info.is_dir and not event.modifiers and not event.action then
            open_directory(path)
        elseif not only_if_dir then
            handle_activate(event)
        end
    end

    -- ============================================================
    -- 打开菜单并设置事件回调
    -- ============================================================
    menu = Menu:open(menu_data, function(event)
        if event.type == 'activate' then
            activate(event --[[@as MenuEventActivate]])
        elseif event.type == 'back' or (event.type == 'key' and itable_has({'alt+up', 'left'}, event.id)) then
            if back_path then
                open_directory(back_path)
            end
        elseif event.type == 'paste' then
            handle_activate({type = 'activate', value = event.value})
        elseif event.type == 'key' then
            if event.id == 'right' then
                -- 右方向键：激活选中项（仅当是目录时进入）
                local selected_item = event.selected_item
                if selected_item then
                    activate(table_assign({}, selected_item, {type = 'activate'}), true)
                end
            elseif event.id == 'ctrl+c' and event.selected_item then
                -- 复制路径到剪贴板
                set_clipboard(event.selected_item.value)
            end
        elseif event.type == 'close' then
            close()
        end
    end)

    -- 打开初始目录
    open_directory(directory_path)

    return menu
end

-- ==============================================================================
-- 7. 从 input.conf 解析菜单项 (On demand menu items loading)
-- 解析用户自定义的右键菜单（通过 input.conf 中的注释标记）
-- ==============================================================================

do
    ---@type {key: string; cmd: string; comment: string; is_menu_item: boolean}[]|nil
    local all_user_bindings = nil
    ---@type MenuStackItem[]|nil
    local menu_items = nil

    -- 判断是否为 uosc 菜单项注释
    local function is_uosc_menu_comment(v)
        return v:match('^!') or v:match('^menu:')
    end

    -- 获取 input.conf 中所有相关的绑定（即使被覆盖）
    function get_all_user_bindings()
        if all_user_bindings then
            return all_user_bindings
        end
        all_user_bindings = {}

        local input_conf_property = mp.get_property_native('input-conf')
        local input_conf_iterator

        -- mpv.net v7 使用 memory:// 协议
        if input_conf_property:sub(1, 9) == 'memory://' then
            local input_conf_lines = split(input_conf_property:sub(10), '\n')
            local i = 0
            input_conf_iterator = function()
                i = i + 1
                return input_conf_lines[i]
            end
        else
            local input_conf = input_conf_property == '' and '~~/input.conf' or input_conf_property
            local input_conf_path = mp.command_native({'expand-path', input_conf})
            local input_conf_meta, meta_error = utils.file_info(input_conf_path)

            -- 文件不存在：使用默认菜单
            if not input_conf_meta or not input_conf_meta.is_file then
                menu_items = create_default_menu_items()
                return menu_items, all_user_bindings
            end

            input_conf_iterator = io.lines(input_conf_path)
        end

        -- 逐行解析 input.conf
        for line in input_conf_iterator do
            local key, command, comment = string.match(line, '%s*([%S]+)%s+([^#]*)%s*(.-)%s*$')
            local is_commented_out = key and key:sub(1, 1) == '#'

            if comment and #comment > 0 then
                comment = comment:sub(2)
            end
            if command then
                command = trim(command)
            end

            local is_menu_item = comment and is_uosc_menu_comment(comment)

            if key
                -- 过滤掉 `#F2` 这类明显被注释掉的绑定
                and not (is_commented_out and #key > 1)
                -- 过滤掉不是 uosc 菜单项的注释
                and (not is_commented_out or is_menu_item) then
                all_user_bindings[#all_user_bindings + 1] = {
                    key = key,
                    cmd = command,
                    comment = comment or '',
                    is_menu_item = is_menu_item,
                }
            end
        end

        return all_user_bindings
    end

    -- 获取菜单项列表
    function get_menu_items()
        if menu_items then
            return menu_items
        end

        local all_user_bindings = get_all_user_bindings()
        local main_menu = {items = {}, items_by_command = {}}
        local by_id = {}  -- 子菜单 ID 缓存

        -- 遍历所有绑定，构建菜单树
        for _, bind in ipairs(all_user_bindings) do
            local key, command, comment = bind.key, bind.cmd, bind.comment
            local title = ''

            -- 从注释中提取菜单标题
            if comment then
                local comments = split(comment, '#')
                local titles = itable_filter(comments, is_uosc_menu_comment)
                if titles and #titles > 0 then
                    title = titles[1]:match('^!%s*(.*)%s*') or titles[1]:match('^menu:%s*(.*)%s*')
                end
            end

            if title ~= '' then
                local is_dummy = key:sub(1, 1) == '#'  -- 虚拟键（无实际按键）
                local submenu_id = ''
                local target_menu = main_menu
                local title_parts = split(title or '', ' *> *')

                -- 逐级构建子菜单
                for index, title_part in ipairs(#title_parts > 0 and title_parts or {''}) do
                    if index < #title_parts then
                        -- 子菜单
                        submenu_id = submenu_id .. title_part

                        if not by_id[submenu_id] then
                            local items = {}
                            by_id[submenu_id] = {items = items, items_by_command = {}}
                            target_menu.items[#target_menu.items + 1] = {
                                title = title_part,
                                items = items,
                            }
                        end

                        target_menu = by_id[submenu_id]
                    else
                        -- 菜单项（叶子节点）
                        -- 如果命令已存在，只追加快捷键提示
                        if key ~= '#' and command ~= '' and target_menu.items_by_command[command] then
                            local hint = target_menu.items_by_command[command].hint
                            local key_human = keybind_to_human(key)
                            target_menu.items_by_command[command].hint =
                                hint and hint .. ', ' .. key_human or key_human
                        else
                            -- 分隔符
                            if title_part:sub(1, 3) == '---' then
                                local last_item = target_menu.items[#target_menu.items]
                                if last_item then
                                    last_item.separator = true
                                end
                            elseif command ~= 'ignore' then
                                local item = {
                                    title = title_part,
                                    hint = not is_dummy and keybind_to_human(key) or nil,
                                    value = command,
                                }
                                if command == '' then
                                    item.selectable = false
                                    item.muted = true
                                    item.italic = true
                                else
                                    target_menu.items_by_command[command] = item
                                end
                                target_menu.items[#target_menu.items + 1] = item
                            end
                        end
                    end
                end
            end
        end

        menu_items = #main_menu.items > 0 and main_menu.items or create_default_menu_items()
        return menu_items
    end
end

-- ==============================================================================
-- 8. 快捷键列表菜单项 (get_keybinds_items)
-- 用于显示所有可用的快捷键绑定
-- ==============================================================================

-- Adapted from `stats.lua`
function get_keybinds_items()
    local items = {}

    -- uosc 和 mpv-menu-plugin 中无按键的菜单项
    local no_key_menu_binds = itable_filter(
        get_all_user_bindings(),
        function(b)
            return b.is_menu_item and b.cmd and b.cmd ~= '' and (b.key == '#' or b.key == '_')
        end
    )

    local binds_dump = itable_join(find_active_keybindings(), no_key_menu_binds)
    local ids = {}

    -- 转换为菜单项
    for _, bind in pairs(binds_dump) do
        local id = bind.key .. '<>' .. bind.cmd
        if not ids[id] then
            ids[id] = true
            items[#items + 1] = {
                title = bind.cmd,
                hint = keybind_to_human(bind.key) or bind.key,
                value = bind.cmd,
            }
        end
    end

    -- 排序
    table.sort(items, function(a, b)
        return a.title < b.title
    end)

    -- 如果有结果则返回，否则返回空状态提示
    return #items > 0 and items or {
        {
            title = t('%s are empty', '`input-bindings`'),
            selectable = false,
            align = 'center',
            italic = true,
            muted = true,
        },
    }
end

-- ==============================================================================
-- 9. 流媒体画质菜单 (open_stream_quality_menu)
-- 用于 YouTube 等流媒体的分辨率切换
-- ==============================================================================

function open_stream_quality_menu()
    if Menu:is_open('stream-quality') then
        Menu:close()
        return
    end

    local ytdl_format = mp.get_property_native('ytdl-format')
    local items = {}
    ---@type Menu
    local menu

    -- 生成画质选项列表
    for _, height in ipairs(config.stream_quality_options) do
        local format = 'bestvideo[height<=?' .. height .. ']+bestaudio/best[height<=?' .. height .. ']'
        items[#items + 1] = {
            title = height .. 'p',
            value = format,
            active = format == ytdl_format,
        }
    end

    menu = Menu:open({
        type = 'stream-quality',
        title = t('Stream quality'),
        items = items,
    }, function(event)
        if event.type == 'activate' then
            mp.set_property('ytdl-format', event.value)

            -- 重新加载视频以应用新画质
            -- 代码参考：https://github.com/jgreco/mpv-youtube-quality
            -- 来源：https://github.com/4e6/mpv-reload/
            local duration = mp.get_property_native('duration')
            local time_pos = mp.get_property('time-pos')

            mp.command('playlist-play-index current')

            -- VOD（非直播）保持播放位置，直播则从头开始
            if duration and duration > 0 then
                local function seeker()
                    mp.commandv('seek', time_pos, 'absolute')
                    mp.unregister_event(seeker)
                end
                mp.register_event('file-loaded', seeker)
            end

            -- 如果按了 alt，不关闭菜单（可多次切换）
            if not event.alt then
                menu:close()
            end
        end
    end)
end

-- ==============================================================================
-- 10. 打开文件菜单 (open_open_file_menu)
-- 浏览并打开文件
-- ==============================================================================

function open_open_file_menu()
    if Menu:is_open('open-file') then
        Menu:close()
        return
    end

    ---@type Menu | nil
    local menu
    local directory
    local active_file

    -- 确定起始目录
    if state.path == nil or is_protocol(state.path) then
        directory = options.default_directory
        active_file = nil
    else
        local serialized = serialize_path(state.path)
        if serialized then
            directory = serialized.dirname
            active_file = serialized.path
        end
    end

    if not directory then
        msg.error('Couldn\'t serialize path "' .. state.path .. '".')
        return
    end

    -- 文件加载后更新菜单中的激活状态
    local function handle_file_loaded()
        if menu and menu:is_alive() then
            menu:activate_one_value(normalize_path(mp.get_property_native('path')))
        end
    end

    menu = open_file_navigation_menu(
        directory,
        function(event)
            if not menu then
                return
            end

            local command = has_any_extension(event.value, config.types.playlist) and 'loadlist' or 'loadfile'

            -- Shift 或 add_to_playlist 动作：追加到播放列表
            if event.modifiers == 'shift' or event.action == 'add_to_playlist' then
                mp.commandv(command, event.value, 'append')
                local serialized = serialize_path(event.value)
                local filename = serialized and serialized.basename or event.value
                mp.commandv('show-text', t('Added to playlist') .. ': ' .. filename, 3000)

            -- 直接打开（无修饰键或 ctrl/alt 修饰键）
            elseif itable_has({nil, 'ctrl', 'alt', 'alt+ctrl'}, event.modifiers)
                and itable_has({nil, 'force_open'}, event.action) then
                mp.commandv(command, event.value)
                if not event.alt then
                    menu:close()
                end
            end
        end,
        {
            type = 'open-file',
            allowed_types = config.types.media,
            active_path = active_file,
            directory_actions = {
                {
                    name = 'add_to_playlist',
                    icon = 'playlist_add',
                    label = t('Add to playlist') .. ' (shift+enter/click)',
                },
                {
                    name = 'force_open',
                    icon = 'play_circle_outline',
                    label = t('Open in mpv') .. ' (ctrl+enter/click)',
                },
            },
            file_actions = {
                {
                    name = 'add_to_playlist',
                    icon = 'playlist_add',
                    label = t('Add to playlist') .. ' (shift+enter/click)',
                },
            },
            keep_open = true,
            on_close = function()
                mp.unregister_event(handle_file_loaded)
            end,
        }
    )

    if menu then
        mp.register_event('file-loaded', handle_file_loaded)
    end
end

-- ==============================================================================
-- 11. 创建轨道加载菜单 (create_track_loader_menu_opener)
-- 用于加载外部音轨、字幕轨、视频轨
-- ==============================================================================

---@param opts {prop: 'sub'|'audio'|'video'; title: string; loaded_message: string; allowed_types: string[]}
function create_track_loader_menu_opener(opts)
    local menu_type = 'load-' .. opts.prop

    return function()
        if Menu:is_open(menu_type) then
            Menu:close()
            return
        end

        ---@type Menu
        local menu
        local path = state.path

        -- 确定起始目录
        if path then
            if is_protocol(path) then
                path = false
            else
                local serialized_path = serialize_path(path)
                path = serialized_path ~= nil and serialized_path.dirname or false
            end
        end
        if not path then
            path = options.default_directory
        end

        -- 激活菜单项：加载轨道文件
        local function handle_activate(event)
            load_track(opts.prop, event.value)
            local serialized = serialize_path(event.value)
            local filename = serialized and serialized.basename or event.value
            mp.commandv('show-text', opts.loaded_message .. ': ' .. filename, 3000)
            if not event.alt then
                menu:close()
            end
        end

        menu = open_file_navigation_menu(path, handle_activate, {
            type = menu_type,
            title = opts.title,
            allowed_types = opts.allowed_types,
        })
    end
end

-- ==============================================================================
-- 12. 字幕下载菜单 (open_subtitle_downloader)
-- 从 OpenSubtitles 下载字幕
-- ==============================================================================

function open_subtitle_downloader()
    local menu_type = 'download-subtitles'
    ---@type Menu
    local menu

    if Menu:is_open(menu_type) then
        Menu:close()
        return
    end

    local search_suggestion, file_path, destination_directory = '', nil, nil
    local credentials = {
        '--api-key', config.open_subtitles_api_key,
        '--agent', config.open_subtitles_agent
    }

    -- 确定搜索建议、文件路径和保存目录
    if state.path then
        if is_protocol(state.path) then
            local title = mp.get_property_native('title')
            if title and not is_protocol(title) then
                search_suggestion = title
            end
        else
            local serialized_path = serialize_path(state.path)
            if serialized_path then
                search_suggestion = serialized_path.filename
                file_path = state.path
                destination_directory = serialized_path.dirname
            end
        end
    end

    -- 确定字幕保存目录
    local force_destination = options.subtitles_directory:sub(1, 1) == '!'
    if force_destination or not destination_directory then
        local subtitles_directory = options.subtitles_directory:sub(force_destination and 2 or 1)
        destination_directory = mp.command_native({'expand-path', subtitles_directory})
    end

    local handle_download, handle_search

    -- ============================================================
    -- 错误检查辅助函数 (should_abort)
    -- ============================================================
    ---@param error string|nil
    ---@param data any
    ---@param check_is_valid? fun(data: any):boolean
    ---@return boolean abort
    local function should_abort(error, data, check_is_valid)
        if error or not data or (not check_is_valid or not check_is_valid(data)) then
            menu:update_items({
                {
                    title = t('Something went wrong.'),
                    align = 'center',
                    muted = true,
                    italic = true,
                    selectable = false,
                },
                {
                    title = t('See console for details.'),
                    align = 'center',
                    muted = true,
                    italic = true,
                    selectable = false,
                },
            })
            msg.error(error or ('Invalid response: ' .. (utils.format_json(data) or tostring(data))))
            return true
        end
        return false
    end

    -- ============================================================
    -- 处理下载 (handle_download)
    -- ============================================================
    ---@param data {kind: 'file', id: number}|{kind: 'page', query: string, page: number}
    handle_download = function(data)
        if data.kind == 'page' then
            handle_search(data.query, data.page)
            return
        end

        -- 显示加载状态
        menu = Menu:open({
            type = menu_type .. '-result',
            search_style = 'disabled',
            items = {{icon = 'spinner', align = 'center', selectable = false, muted = true}},
        }, function(event)
            if event.type == 'key' and event.key == 'enter' then
                menu:close()
            end
        end)

        -- 调用 ziggy 下载字幕
        local args = itable_join({'download-subtitles'}, credentials, {
            '--file-id', tostring(data.id),
            '--destination', destination_directory,
        })

        call_ziggy_async(args, function(error, data)
            if not menu:is_alive() then
                return
            end

            if should_abort(error, data, function(data) return type(data.file) == 'string' end) then
                return
            end

            -- 加载下载的字幕
            load_track('sub', data.file)

            -- 显示下载结果
            menu:update_items({
                {
                    title = t('Subtitles loaded & enabled'),
                    bold = true,
                    icon = 'check',
                    selectable = false,
                },
                {
                    title = t('Remaining downloads today: %s', data.remaining .. '/' .. data.total),
                    italic = true,
                    muted = true,
                    icon = 'file_download',
                    selectable = false,
                },
                {
                    title = t('Resets in: %s', data.reset_time),
                    italic = true,
                    muted = true,
                    icon = 'schedule',
                    selectable = false,
                },
            })
        end)
    end

    -- ============================================================
    -- 处理搜索 (handle_search)
    -- ============================================================
    ---@param query string
    ---@param page number|nil
    handle_search = function(query, page)
        if not menu:is_alive() then
            return
        end

        page = math.max(1, type(page) == 'number' and round(page) or 1)

        -- 显示加载状态
        menu:update_items({{icon = 'spinner', align = 'center', selectable = false, muted = true}})

        -- 调用 ziggy 搜索字幕
        local args = itable_join({'search-subtitles'}, credentials)

        -- 语言过滤
        local languages = itable_filter(get_languages(), function(lang)
            return lang:match('.json$') == nil
        end)
        args[#args + 1] = '--languages'
        args[#args + 1] = table.concat(table_keys(create_set(languages)), ',')  -- 去重

        args[#args + 1] = '--page'
        args[#args + 1] = tostring(page)

        if file_path then
            args[#args + 1] = '--hash'
            args[#args + 1] = file_path
        end

        if query and #query > 0 then
            args[#args + 1] = '--query'
            args[#args + 1] = query
        end

        call_ziggy_async(args, function(error, data)
            if not menu:is_alive() then
                return
            end

            local function check_is_valid(data)
                return type(data.data) == 'table' and data.page and data.total_pages
            end

            if should_abort(error, data, check_is_valid) then
                return
            end

            -- 过滤有效字幕条目
            local subs = itable_filter(data.data, function(sub)
                return sub and sub.attributes and sub.attributes.release
                    and type(sub.attributes.files) == 'table' and #sub.attributes.files > 0
            end)

            -- 转换为菜单项
            local items = itable_map(subs, function(sub)
                local hints = {sub.attributes.language}
                if sub.attributes.foreign_parts_only then
                    hints[#hints + 1] = t('foreign parts only')
                end
                if sub.attributes.hearing_impaired then
                    hints[#hints + 1] = t('hearing impaired')
                end
                local url = sub.attributes.url
                return {
                    title = sub.attributes.release,
                    hint = table.concat(hints, ', '),
                    value = {kind = 'file', id = sub.attributes.files[1].file_id, url = url},
                    keep_open = true,
                    actions = url and {{
                        name = 'open_in_browser',
                        icon = 'open_in_new',
                        label = t('Open in browser') .. ' (shift)',
                    }} or nil,
                }
            end)

            if #items == 0 then
                items = {
                    {title = t('no results'), align = 'center', muted = true, italic = true, selectable = false},
                }
            end

            -- 分页导航
            if data.page > 1 then
                items[#items + 1] = {
                    title = t('Previous page'),
                    align = 'center',
                    bold = true,
                    italic = true,
                    icon = 'navigate_before',
                    keep_open = true,
                    value = {kind = 'page', query = query, page = data.page - 1},
                }
            end

            if data.page < data.total_pages then
                items[#items + 1] = {
                    title = t('Next page'),
                    align = 'center',
                    bold = true,
                    italic = true,
                    icon = 'navigate_next',
                    keep_open = true,
                    value = {kind = 'page', query = query, page = data.page + 1},
                }
            end

            menu:update_items(items)
        end)
    end

    -- ============================================================
    -- 初始菜单
    -- ============================================================
    local initial_items = {
        {
            title = t('%s to search', 'enter'),
            align = 'center',
            muted = true,
            italic = true,
            selectable = false,
        },
    }

    menu = Menu:open(
        {
            type = menu_type,
            title = t('enter query'),
            items = initial_items,
            search_style = 'palette',      -- 常驻搜索框
            on_search = 'callback',
            search_debounce = 'submit',    -- Enter 提交搜索
            search_suggestion = search_suggestion,
            search_submit = search_suggestion and #search_suggestion > 0,
        },
        function(event)
            if event.type == 'activate' then
                -- 在浏览器中打开字幕页面
                if event.action == 'open_in_browser' or event.modifiers == 'shift' then
                    local command = ({
                        windows = 'explorer',
                        linux = 'xdg-open',
                        darwin = 'open',
                    })[state.platform]
                    local url = event.value.url
                    mp.command_native_async({
                        name = 'subprocess',
                        capture_stderr = true,
                        capture_stdout = true,
                        playback_only = false,
                        args = {command, url},
                    }, function(success, result, error)
                        if not success then
                            local err_str = utils.to_string(error or result.stderr)
                            msg.error('Error trying to open url "' .. url .. '" in browser: ' .. err_str)
                        end
                    end)
                elseif not event.action then
                    -- 下载字幕
                    handle_download(event.value)
                end
            elseif event.type == 'search' then
                -- 执行搜索
                handle_search(event.query)
            end
        end
    )
end