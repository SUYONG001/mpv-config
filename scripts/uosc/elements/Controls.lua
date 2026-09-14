-- ==============================================================================
-- Controls.lua — 控制栏组件
-- ==============================================================================
-- 功能概述：
--   1. 解析 `options.controls` 配置字符串，创建控制栏上的所有按钮和控件
--   2. 支持四种尺寸模式：static（固定）、dynamic（动态）、gap（间距）、space（填充）
--   3. 支持条件显示：根据文件类型、轨道数量等动态显示/隐藏按钮
--   4. 支持按钮徽章（badge）：显示轨道数量等实时信息
--   5. 自适应布局：当空间不足时，自动隐藏中间的元素
-- ==============================================================================
-- 所属：uosc UI 框架（https://github.com/tomasklaen/uosc）
-- 由用户 [2026.07.20] 完成全量中文注释解析
-- ==============================================================================

-- 引入依赖的组件
local Element = require('elements/Element')
local Button = require('elements/Button')
local CycleButton = require('elements/CycleButton')
local ManagedButton = require('elements/ManagedButton')
local Speed = require('elements/Speed')

-- ==============================================================================
-- 尺寸模式说明 (sizing)
-- ==============================================================================
--   static  静态元素：有最高空间占用优先级，空间不足时优先消失
--   dynamic 动态元素：会收缩以腾出空间给静态元素，收缩到 ratio_min 后消失
--   gap     间距元素：空间不足时收缩
--   space   填充元素：扩展填充可用空间，必要时收缩
--
--   scale    ：相对于 `options.controls_size` 的缩放系数
--   ratio    ：静态或动态元素的宽高比（width / height）
--   ratio_min：动态元素的最小宽高比（收缩到此时仍不消失）
-- ==============================================================================

---@alias ControlItem {element?: Element; kind: string; sizing: 'space' | 'static' | 'dynamic' | 'gap'; scale: number; ratio?: number; ratio_min?: number; hide: boolean; dispositions?: {[string]: boolean}[]}
-- ControlItem 字段说明：
--   element     : 对应的 UI 元素实例
--   kind        : 控件类型（command / cycle / button / speed / gap / space）
--   sizing      : 尺寸模式（static / dynamic / gap / space）
--   scale       : 缩放系数
--   ratio       : 宽高比（仅 static/dynamic 有效）
--   ratio_min   : 最小宽高比（仅 dynamic 有效）
--   hide        : 是否隐藏（由布局算法控制）
--   dispositions: 条件显示规则（OR 组，每组内部为 AND 条件）

---@class Controls : Element
local Controls = class(Element)

-- ==============================================================================
-- 构造函数与初始化
-- ==============================================================================

function Controls:new() return Class.new(self) --[[@as Controls]] end

function Controls:init()
    -- 调用父类 Element 的初始化
    -- 参数：'controls' 是元素 ID，render_order = 6（控制栏渲染在中间层）
    Element.init(self, 'controls', {render_order = 6})

    ---@type ControlItem[] 从 `options.controls` 序列化得到的所有控件
    self.controls = {}
    ---@type ControlItem[] 匹配当前条件（dispositions）后实际显示的控件
    self.layout = {}

    -- 初始化控件（解析配置字符串）
    self:init_options()
end

-- 销毁时，同时销毁所有子控件
function Controls:destroy()
    self:destroy_elements()
    Element.destroy(self)
end

-- ==============================================================================
-- 控件初始化 (init_options)
-- 将 `options.controls` 字符串解析为控件列表
-- ==============================================================================

function Controls:init_options()
    -- 预置快捷按钮映射（shorthands）
    -- 格式：名称 = '类型:参数...?工具提示'
    local shorthands = {
        ['play-pause'] = 'cycle:pause:pause:no/yes=play_arrow?' .. t('Play/Pause'),
        menu = 'command:menu:script-binding uosc/menu-blurred?' .. t('Menu'),
        subtitles = 'command:subtitles:script-binding uosc/subtitles#sub>0?' .. t('Subtitles'),
        audio = 'command:graphic_eq:script-binding uosc/audio#audio>1?' .. t('Audio'),
        ['audio-device'] = 'command:speaker:script-binding uosc/audio-device?' .. t('Audio device'),
        video = 'command:theaters:script-binding uosc/video#video>1?' .. t('Video'),
        playlist = 'command:list_alt:script-binding uosc/playlist?' .. t('Playlist'),
        chapters = 'command:bookmark:script-binding uosc/chapters#chapters>0?' .. t('Chapters'),
        ['editions'] = 'command:bookmarks:script-binding uosc/editions#editions>1?' .. t('Editions'),
        ['stream-quality'] = 'command:high_quality:script-binding uosc/stream-quality?' .. t('Stream quality'),
        ['open-file'] = 'command:file_open:script-binding uosc/open-file?' .. t('Open file'),
        ['items'] = 'command:list_alt:script-binding uosc/items?' .. t('Playlist/Files'),
        prev = 'command:arrow_back_ios:script-binding uosc/prev?' .. t('Previous'),
        next = 'command:arrow_forward_ios:script-binding uosc/next?' .. t('Next'),
        first = 'command:first_page:script-binding uosc/first?' .. t('First'),
        last = 'command:last_page:script-binding uosc/last?' .. t('Last'),
        ['loop-playlist'] = 'cycle:repeat:loop-playlist:no/inf!?' .. t('Loop playlist'),
        ['loop-file'] = 'cycle:repeat_one:loop-file:no/inf!?' .. t('Loop file'),
        shuffle = 'toggle:shuffle:shuffle?' .. t('Shuffle'),
        autoload = 'toggle:hdr_auto:autoload@uosc?' .. t('Autoload'),
        fullscreen = 'cycle:crop_free:fullscreen:no/yes=fullscreen_exit!?' .. t('Fullscreen'),
    }

    -- ================================================================
    -- 第一步：解析原始字符串，分离 disposition（条件）和 config（配置）
    -- ================================================================
    -- 例如：'<video,audio>subtitles' → disposition='video,audio', config='subtitles'
    local items = {}
    local in_disposition = false
    local current_item = nil

    -- 逐字符遍历 options.controls 字符串
    for c in options.controls:gmatch('.') do
        if not current_item then
            current_item = {disposition = '', config = ''}
        end

        if c == '<' and #current_item.config == 0 then
            -- 进入条件部分
            in_disposition = true
        elseif c == '>' and #current_item.config == 0 then
            -- 退出条件部分
            in_disposition = false
        elseif c == ',' and not in_disposition then
            -- 逗号分隔：完成当前项
            items[#items + 1] = current_item
            current_item = nil
        else
            -- 普通字符：追加到 disposition 或 config
            local prop = in_disposition and 'disposition' or 'config'
            current_item[prop] = current_item[prop] .. c
        end
    end
    items[#items + 1] = current_item

    -- ================================================================
    -- 第二步：创建控件
    -- ================================================================
    self.controls = {}

    for i, item in ipairs(items) do
        -- 展开 shorthand
        local config = shorthands[item.config] and shorthands[item.config] or item.config

        -- 解析工具提示（? 后面的部分）
        local config_tooltip = split(config, ' *%? *')
        local tooltip = config_tooltip[2]
        config = shorthands[config_tooltip[1]]
            and split(shorthands[config_tooltip[1]], ' *%? *')[1] or config_tooltip[1]

        -- 解析角标（# 后面的部分）
        local config_badge = split(config, ' *# *')
        config = config_badge[1]
        local badge = config_badge[2]

        -- 解析类型和参数（: 分隔）
        local parts = split(config, ' *: *')
        local kind, params = parts[1], itable_slice(parts, 2)

        -- ================================================================
        -- 解析 disposition（条件显示规则）
        -- 格式：OR 组用逗号分隔，AND 条件用 + 连接
        -- 例如：'has_audio+!audio' → 有音轨且不是纯音频文件
        -- ================================================================
        ---@type {[string]: boolean}[]
        local dispositions = {}
        ---@type string[]
        local disposition_props = {}

        for _, or_group in ipairs(comma_split(item.disposition)) do
            local group = {}
            for _, condition in ipairs(split(or_group, ' *+ *')) do
                if #condition > 0 then
                    local value = condition:sub(1, 1) ~= '!'
                    local name = not value and condition:sub(2) or condition

                    -- 处理 has_xxx 和 is_xxx 类型的条件
                    if name:sub(1, 4) == 'has_' or itable_has({'idle', 'image', 'audio', 'video', 'stream'}, name) then
                        local prop = name:sub(1, 4) == 'has_' and name or 'is_' .. name
                        group[prop] = value
                    else
                        -- 其他属性直接作为 mpv 属性名
                        disposition_props[#disposition_props + 1] = name
                        group[name] = value
                    end
                end
            end
            dispositions[#dispositions + 1] = group
        end

        -- 将 toggle 转换为 cycle（no/yes 切换）
        if kind == 'toggle' then
            kind = 'cycle'
            params[#params + 1] = 'no/yes!'
        end

        -- 创建控件对象
        local control = {dispositions = dispositions, kind = kind}

        -- ================================================================
        -- 根据类型创建对应的元素
        -- ================================================================

        if kind == 'space' then
            -- 空白填充元素
            control.sizing = 'space'

        elseif kind == 'gap' then
            -- 间距元素
            table_assign(control, {sizing = 'gap', scale = 1, ratio = params[1] or 0.3, ratio_min = 0})

        elseif kind == 'command' then
            -- 命令按钮：点击执行 mpv 命令
            if #params ~= 2 then
                mp.error(string.format(
                    'command button needs 2 parameters, %d received: %s', #params, table.concat(params, '/')
                ))
            else
                local element = Button:new('control_' .. i, {
                    render_order = self.render_order,
                    icon = params[1],
                    anchor_id = 'controls',
                    on_click = function() mp.command(params[2]) end,
                    tooltip = tooltip,
                    count_prop = 'sub',
                })
                table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
                if badge then self:register_badge_updater(badge, element) end
            end

        elseif kind == 'cycle' then
            -- 循环切换按钮：点击在多个状态间循环
            if #params ~= 3 then
                mp.error(string.format(
                    'cycle button needs 3 parameters, %d received: %s',
                    #params, table.concat(params, '/')
                ))
            else
                local state_configs = split(params[3], ' */ *')
                local states = {}

                for _, state_config in ipairs(state_configs) do
                    local active = false
                    if state_config:sub(-1) == '!' then
                        active = true
                        state_config = state_config:sub(1, -2)
                    end
                    local state_params = split(state_config, ' *= *')
                    local value, icon = state_params[1], state_params[2] or params[1]
                    states[#states + 1] = {value = value, icon = icon, active = active}
                end

                local element = CycleButton:new('control_' .. i, {
                    render_order = self.render_order,
                    prop = params[2],
                    anchor_id = 'controls',
                    states = states,
                    tooltip = tooltip,
                })
                table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
                if badge then self:register_badge_updater(badge, element) end
            end

        elseif kind == 'button' then
            -- 托管按钮：由外部脚本管理状态
            if #params ~= 1 then
                mp.error(string.format(
                    'managed button needs 1 parameter, %d received: %s', #params, table.concat(params, '/')
                ))
            else
                local element = ManagedButton:new('control_' .. i, {
                    name = params[1],
                    render_order = self.render_order,
                    anchor_id = 'controls',
                    on_hide = function() self:reflow() end,
                })
                table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
            end

        elseif kind == 'speed' then
            -- 速度滑块
            if not Elements.speed then
                local element = Speed:new({anchor_id = 'controls', render_order = self.render_order})
                local scale = tonumber(params[1]) or 1.3
                table_assign(control, {
                    element = element, sizing = 'dynamic', scale = scale, ratio = 3.5, ratio_min = 2,
                })
            else
                msg.error('there can only be 1 speed slider')
            end

        else
            msg.error('unknown element kind "' .. kind .. '"')
            break
        end

        -- 如果有 disposition 条件，为元素添加属性观察者
        if control.element then
            for _, prop in ipairs(disposition_props) do
                control.element:observe_mp_property(prop, function() self:reflow() end)
            end
        end

        self.controls[#self.controls + 1] = control
    end

    self:reflow()
end

-- ==============================================================================
-- 重新布局 (reflow)
-- 根据当前状态过滤可见控件，并重新计算布局
-- ==============================================================================

function Controls:reflow()
    -- 只保留匹配当前条件且未隐藏的控件
    self.layout = {}

    for _, control in ipairs(self.controls) do
        local matches = false
        local conditions_num = 0

        -- 检查 OR 组中的 AND 条件
        for _, group in pairs(control.dispositions) do
            local group_matches = true
            for prop, value in pairs(group) do
                conditions_num = conditions_num + 1
                ---@type boolean
                local current_value

                -- 从 state 或 mpv 属性获取当前值
                if prop:sub(1, 4) == 'has_' or prop:sub(1, 3) == 'is_' then
                    current_value = state[prop]
                else
                    current_value = mp.get_property_bool(prop, false)
                end

                if current_value ~= value then
                    group_matches = false
                    break
                end
            end

            if group_matches then
                matches = true
                break
            end
        end

        -- 没有条件时默认匹配
        if conditions_num == 0 then matches = true end

        local show = matches and (not control.element or control.element.hide ~= true)
        if control.element then control.element.enabled = show end

        if show then
            self.layout[#self.layout + 1] = control
        end
    end

    self:update_dimensions()
    Elements:trigger('controls_reflow')
end

-- ==============================================================================
-- 徽章更新器 (register_badge_updater)
-- 为按钮注册角标（badge）自动更新功能
-- ==============================================================================

---@param badge string
---@param element Element 支持 `badge` 属性的元素
function Controls:register_badge_updater(badge, element)
    local prop_and_limit = split(badge, ' *> *')
    local prop, limit = prop_and_limit[1], tonumber(prop_and_limit[2] or -1)
    local observable_name, serializer, is_external_prop = prop, nil, false

    -- 处理内置轨道类型（sub / audio / video）
    if itable_index_of({'sub', 'audio', 'video'}, prop) then
        observable_name = 'track-list'
        serializer = function(value)
            local count = 0
            for _, track in ipairs(value) do
                if track.type == prop then count = count + 1 end
            end
            return count
        end
    else
        -- 处理外部属性（prop@owner 语法）
        local parts = split(prop, '@')
        if #parts > 1 then
            prop, is_external_prop = parts[1] ~= '' and parts[1] or parts[2], true
        end
        serializer = function(value)
            return value and (type(value) == 'table' and #value or tostring(value)) or nil
        end
    end

    -- 处理属性变化，更新徽章
    local function handler(_, value)
        local new_value = serializer(value) --[[@as nil|string|integer]]
        local value_number = tonumber(new_value)
        -- 如果超过限制才显示徽章
        if value_number then
            new_value = value_number > limit and value_number or nil
        end
        element.badge = new_value
        request_render()
    end

    if is_external_prop then
        element['on_external_prop_' .. prop] = function(_, value) handler(prop, value) end
    else
        element:observe_mp_property(observable_name, handler)
    end
end

-- ==============================================================================
-- 可见度计算 (get_visibility)
-- ==============================================================================

function Controls:get_visibility()
    -- 如果速度控件正在被拖拽，强制显示控制栏
    if Elements:v('speed', 'dragging') then return 1 end

    -- 如果时间轴被悬停，强制隐藏控制栏（-1 表示强制隐藏）
    if Elements:maybe('timeline', 'get_is_hovered') then
        return -1
    end

    -- 否则使用父类的可见度计算
    return Element.get_visibility(self)
end

-- ==============================================================================
-- 尺寸更新 (update_dimensions)
-- 核心布局算法：计算所有控件的位置和大小
-- ==============================================================================

function Controls:update_dimensions()
    local window_border = Elements:v('window_border', 'size', 0)
    local size = round(options.controls_size * state.scale)
    local spacing = round(options.controls_spacing * state.scale)
    local margin = round(options.controls_margin * state.scale)

    -- 检查可用空间是否足够
    local available_space = display.height - window_border * 2
        - Elements:v('top_bar', 'size', 0)
        - Elements:v('timeline', 'size', 0)
    self.enabled = available_space > size + 10

    -- 重置隐藏标志
    for c, control in ipairs(self.layout) do
        control.hide = false
        if control.element then control.element.enabled = self.enabled end
    end

    if not self.enabled then return end

    -- 容器尺寸
    self.bx = display.width - window_border - margin
    self.by = Elements:v('timeline', 'ay', display.height - window_border) - margin
    self.ax, self.ay = window_border + margin, self.by - size

    -- ================================================================
    -- 计算布局参数
    -- ================================================================
    local available_width = self.bx - self.ax
    local statics_width = 0
    local min_content_width = statics_width
    local max_dynamics_width = 0
    local dynamic_units = 0
    local spaces = 0
    local gaps = 0

    -- 遍历所有控件，统计尺寸
    for c, control in ipairs(self.layout) do
        if control.sizing == 'space' then
            spaces = spaces + 1
        elseif control.sizing == 'gap' then
            gaps = gaps + control.scale * control.ratio
        elseif control.sizing == 'static' then
            local width = size * control.scale * control.ratio + (c ~= #self.layout and spacing or 0)
            statics_width = statics_width + width
            min_content_width = min_content_width + width
        elseif control.sizing == 'dynamic' then
            local sp = (c ~= #self.layout and spacing or 0)
            statics_width = statics_width + sp
            min_content_width = min_content_width + size * control.scale * control.ratio_min + sp
            max_dynamics_width = max_dynamics_width + size * control.scale * control.ratio
            dynamic_units = dynamic_units + control.scale * control.ratio
        end
    end

    -- ================================================================
    -- 如果空间不足，从中间开始隐藏元素
    -- ================================================================
    if min_content_width > available_width then
        local i = math.ceil(#self.layout / 2 + 0.1)
        for a = 0, #self.layout - 1, 1 do
            i = i + (a * (a % 2 == 0 and 1 or -1))
            local control = self.layout[i]

            if control.sizing ~= 'gap' and control.sizing ~= 'space' then
                control.hide = true
                if control.element then control.element.enabled = false end

                if control.sizing == 'static' then
                    local width = size * control.scale * control.ratio
                    min_content_width = min_content_width - width - spacing
                    statics_width = statics_width - width - spacing
                elseif control.sizing == 'dynamic' then
                    statics_width = statics_width - spacing
                    min_content_width = min_content_width - size * control.scale * control.ratio_min - spacing
                    max_dynamics_width = max_dynamics_width - size * control.scale * control.ratio
                    dynamic_units = dynamic_units - control.scale * control.ratio
                end

                if min_content_width < available_width then break end
            end
        end
    end

    -- ================================================================
    -- 实际布局：分配空间并设置坐标
    -- ================================================================
    local current_x = self.ax
    local width_for_dynamics = available_width - statics_width
    local empty_space_width = width_for_dynamics - max_dynamics_width
    local width_for_gaps = math.min(empty_space_width, size * gaps)
    local individual_space_width = spaces > 0 and ((empty_space_width - width_for_gaps) / spaces) or 0

    for c, control in ipairs(self.layout) do
        if not control.hide then
            local sizing = control.sizing
            local element = control.element
            local scale = control.scale
            local ratio = control.ratio
            local width = 0
            local height = 0

            if sizing == 'space' then
                if individual_space_width > 0 then width = individual_space_width end
            elseif sizing == 'gap' then
                if width_for_gaps > 0 then width = width_for_gaps * (ratio / gaps) end
            elseif sizing == 'static' then
                height = size * scale
                width = height * ratio
            elseif sizing == 'dynamic' then
                height = size * scale
                -- 动态元素宽度：如果有足够空间则使用完整宽度，否则按比例分配
                width = max_dynamics_width < width_for_dynamics
                    and height * ratio
                    or width_for_dynamics * ((scale * ratio) / dynamic_units)
            end

            local bx = current_x + width
            if element then
                element:set_coordinates(round(current_x), round(self.by - height), bx, self.by)
            end
            current_x = element and bx + spacing or bx
        end
    end

    Elements:update_proximities()
    request_render()
end

-- ==============================================================================
-- 事件回调
-- ==============================================================================

function Controls:on_dispositions() self:reflow() end
function Controls:on_display() self:update_dimensions() end
function Controls:on_prop_border() self:update_dimensions() end
function Controls:on_prop_title_bar() self:update_dimensions() end
function Controls:on_prop_fullormaxed() self:update_dimensions() end
function Controls:on_timeline_enabled() self:update_dimensions() end

-- 销毁所有子控件
function Controls:destroy_elements()
    for _, control in ipairs(self.controls) do
        if control.element then control.element:destroy() end
    end
end

-- 配置变化时重新初始化
function Controls:on_options()
    self:destroy_elements()
    self:init_options()
end

return Controls