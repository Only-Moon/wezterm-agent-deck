-- WezTerm Agent Deck Plugin
-- Monitor and display AI coding agent status in terminal panes
local wezterm = require('wezterm')

local M = {}

-- Determine platform-specific separator
local is_windows = string.match(wezterm.target_triple or '', 'windows') ~= nil
local separator = is_windows and '\\' or '/'

-- Set up package.path for sub-modules
local function setup_package_path()
    local plugin_list = wezterm.plugin.list()
    if not plugin_list or #plugin_list == 0 then
        return nil
    end
    
    -- Find our plugin directory by looking for agent-deck in the path
    local plugin_dir = nil
    for _, plugin in ipairs(plugin_list) do
        if plugin.plugin_dir and plugin.plugin_dir:find('agent%-deck') then
            plugin_dir = plugin.plugin_dir
            break
        end
    end
    
    if not plugin_dir then
        -- Fallback: use the first plugin's directory (useful during local dev)
        plugin_dir = plugin_list[1].plugin_dir
    end
    
    if plugin_dir then
        -- Add plugin directory to package.path for requiring sub-modules
        local plugin_path = plugin_dir .. separator .. '?.lua'
        local components_path = plugin_dir .. separator .. 'components' .. separator .. '?.lua'
        
        if not package.path:find(plugin_path, 1, true) then
            package.path = package.path .. ';' .. plugin_path .. ';' .. components_path
        end
    end
    
    return plugin_dir
end

-- Initialize package path
local plugin_dir = setup_package_path()

-- Lazy-loaded modules (loaded on first use)
local modules = {}

local function get_module(name)
    if not modules[name] then
        local success, mod = pcall(require, name)
        if success then
            modules[name] = mod
        else
            wezterm.log_error('[agent-deck] Failed to load module ' .. name .. ': ' .. tostring(mod))
            return nil
        end
    end
    return modules[name]
end

-- Internal state
local state = {
    initialized = false,
    agent_states = {},  -- pane_id -> { agent_type, status, last_update, cooldown_start }
    last_notification = {},  -- pane_id -> timestamp
    -- Tracks whether we've already notified for the current waiting state.
    -- Stored outside agent_states so it survives agent detection flickers/state resets.
    -- Cleared only when the agent has been confirmed working (sustained, not a flicker).
    waiting_notified = {},  -- pane_id -> true
    last_cleanup = 0,  -- timestamp of last cache cleanup
}

-- Cache cleanup interval (30 seconds)
local CLEANUP_INTERVAL_MS = 30000
-- Max age for cache entries before cleanup (60 seconds)
local MAX_CACHE_AGE_MS = 60000

--[[ ============================================
     Cache Cleanup (memory leak prevention)
     ============================================ ]]

local function get_all_pane_ids(window)
    local pane_ids = {}
    local success, _ = pcall(function()
        for _, mux_tab in ipairs(window:mux_window():tabs()) do
            for _, p in ipairs(mux_tab:panes()) do
                pane_ids[p:pane_id()] = true
            end
        end
    end)
    return pane_ids
end

local function cleanup_stale_entries(window)
    local now = os.time() * 1000
    
    if (now - state.last_cleanup) < CLEANUP_INTERVAL_MS then
        return
    end
    
    state.last_cleanup = now
    local active_panes = get_all_pane_ids(window)
    
    for pane_id, _ in pairs(state.agent_states) do
        if not active_panes[pane_id] then
            state.agent_states[pane_id] = nil
        end
    end
    
    for pane_id, _ in pairs(state.last_notification) do
        if not active_panes[pane_id] then
            state.last_notification[pane_id] = nil
        end
    end

    for pane_id, _ in pairs(state.waiting_notified) do
        if not active_panes[pane_id] then
            state.waiting_notified[pane_id] = nil
        end
    end
    
    if detection_cache then
        for pane_id, entry in pairs(detection_cache) do
            if not active_panes[pane_id] or (now - entry.timestamp) > MAX_CACHE_AGE_MS then
                detection_cache[pane_id] = nil
            end
        end
    end
end

--[[ ============================================
     Configuration Management (inline)
     ============================================ ]]

local default_config = {
    update_interval = 5000,
    cooldown_ms = 2000,
    max_lines = 100,
    enabled_agents = nil,
    
    agents = {
        opencode = {
            patterns = { 'opencode' },
            executable_patterns = {
                'opencode%-darwin',
                'opencode%-linux',
                'opencode%-win',
                '%.opencode/bin/opencode',
                '/opencode%-ai/',
                '/opencode$',
            },
            argv_patterns = {
                'bunx%s+opencode',
                'npx%s+opencode',
                '/opencode$',
            },
            title_patterns = { 'opencode' },
        },
        claude = {
            patterns = { 'claude', 'claude%-code' },
            executable_patterns = {
                '@anthropic%-ai/claude%-code',
                '/claude%-code/',
                '/claude$',
                '^claude%s*$',
            },
            argv_patterns = {
                '@anthropic%-ai/claude%-code',
                'claude%-code',
                '^claude%s*$',
            },
            title_patterns = {
                'claude code',
                'claude',
            },
        },
        gemini = { patterns = { 'gemini' } },
        codex = { patterns = { 'codex' } },
        aider = { patterns = { 'aider' } },
    },
    
    tab_title = {
        enabled = true,
        position = 'left',
        components = {
            { type = 'icon' },
            { type = 'separator', text = ' ' },
        },
    },
    
    right_status = {
        enabled = true,
        components = {
            { type = 'badge', filter = 'waiting', label = 'waiting' },
            { type = 'separator', text = ' | ' },
            { type = 'badge', filter = 'working', label = 'working' },
        },
    },
    
    colors = {
        working = 'green',
        waiting = 'yellow',
        idle = 'blue',
        inactive = 'gray',
    },
    
    icons = {
        style = 'unicode',
        unicode = {
            working = '●',
            waiting = '◔',
            idle = '○',
            inactive = '◌',
        },
        nerd = {
            working = '',  -- nf-fa-circle
            waiting = '',  -- nf-fa-adjust
            idle = '',  -- nf-fa-circle_o
            inactive = '',  -- nf-cod-circle_outline
        },
        emoji = {
            working = '🟢',
            waiting = '🟡',
            idle = '🔵',
            inactive = '⚪',
        },
    },
    
    notifications = {
        enabled = true,
        on_waiting = true,
        timeout_ms = 4000,
        -- Notification backend: 'native' (wezterm toast) or 'terminal-notifier' (macOS only, supports sound)
        backend = 'native',
        -- terminal-notifier specific options (only used when backend = 'terminal-notifier')
        terminal_notifier = {
            path = nil,
            sound = 'default',
            group = 'wezterm-agent-deck',
            title = 'WezTerm Agent Deck',
            activate = true,
        },
    },
}

local current_config = nil

local function deep_merge(t1, t2)
    local result = {}
    for k, v in pairs(t1) do
        if type(v) == 'table' and type(t2[k]) == 'table' then
            result[k] = deep_merge(v, t2[k])
        elseif t2[k] ~= nil then
            result[k] = t2[k]
        else
            result[k] = v
        end
    end
    for k, v in pairs(t2) do
        if result[k] == nil then
            result[k] = v
        end
    end
    return result
end

local function deep_copy(t)
    if type(t) ~= 'table' then return t end
    local result = {}
    for k, v in pairs(t) do
        result[k] = deep_copy(v)
    end
    return result
end

local function set_config(opts)
    if not opts then
        current_config = deep_copy(default_config)
    else
        current_config = deep_merge(default_config, opts)
    end
end

local function get_config()
    if not current_config then
        current_config = deep_copy(default_config)
    end
    return current_config
end

local function get_status_color(status_name)
    local cfg = get_config()
    return cfg.colors[status_name] or cfg.colors.inactive
end

local function get_status_icon(status_name)
    local cfg = get_config()
    local style = cfg.icons.style or 'unicode'
    local icons = cfg.icons[style] or cfg.icons.unicode
    return icons[status_name] or icons.inactive
end

--[[ ============================================
     Agent Detection (inline)
     ============================================ ]]

local detection_cache = {}
local CACHE_TTL_MS = 1500

local function get_executable_name(path)
    if not path then return '' end
    local name = path:match('[/\\]([^/\\]+)$') or path
    return name:gsub('%.exe$', '')
end

local function matches_any_pattern(str, patterns)
    if not str or not patterns then return false end
    local str_lower = str:lower()
    for _, pattern in ipairs(patterns) do
        local success, result = pcall(function()
            return str_lower:find(pattern:lower())
        end)
        if success and result then return true end
        if not success and str_lower:find(pattern:lower(), 1, true) then return true end
    end
    return false
end

local function is_agent_enabled(agent_name, config)
    if not config.enabled_agents then return true end
    for _, enabled in ipairs(config.enabled_agents) do
        if enabled == agent_name then return true end
    end
    return false
end

local function get_patterns_for_phase(agent_config, pattern_type, agent_name)
    local specific_key = pattern_type .. '_patterns'
    if agent_config[specific_key] and #agent_config[specific_key] > 0 then
        return agent_config[specific_key]
    end
    if agent_config.patterns and #agent_config.patterns > 0 then
        return agent_config.patterns
    end
    return { agent_name }
end

local function detect_from_process_info(executable, argv_str, config)
    local exe_name = get_executable_name(executable)
    for agent_name, agent_config in pairs(config.agents) do
        if is_agent_enabled(agent_name, config) then
            local exe_patterns = get_patterns_for_phase(agent_config, 'executable', agent_name)
            if matches_any_pattern(executable, exe_patterns) or matches_any_pattern(exe_name, exe_patterns) then
                return agent_name
            end
            -- Fallback: check against generic patterns (catches bare process names like 'opencode')
            local generic_patterns = agent_config.patterns
            if generic_patterns and #generic_patterns > 0 then
                if matches_any_pattern(executable, generic_patterns) or matches_any_pattern(exe_name, generic_patterns) then
                    return agent_name
                end
            end
            local argv_patterns = get_patterns_for_phase(agent_config, 'argv', agent_name)
            if matches_any_pattern(argv_str, argv_patterns) then
                return agent_name
            end
        end
    end
    return nil
end

local function detect_from_title(pane_title, config)
    if not pane_title or pane_title == '' then return nil end
    for agent_name, agent_config in pairs(config.agents) do
        if is_agent_enabled(agent_name, config) then
            local title_patterns = get_patterns_for_phase(agent_config, 'title', agent_name)
            if matches_any_pattern(pane_title, title_patterns) then
                return agent_name
            end
        end
    end
    return nil
end

local function detect_agent(pane, config)
    local pane_id = pane:pane_id()
    local now = os.time() * 1000
    
    local cached = detection_cache[pane_id]
    if cached and (now - cached.timestamp) < CACHE_TTL_MS then
        return cached.agent_type
    end
    
    local agent_type = nil
    
    local success, process_info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    
    if success and process_info then
        local executable = process_info.executable or ''
        local name = process_info.name or ''
        local argv_str = table.concat(process_info.argv or {}, ' ')
        agent_type = detect_from_process_info(executable, argv_str, config)
        if not agent_type and name ~= '' then
            agent_type = detect_from_process_info(name, argv_str, config)
        end
        
        if not agent_type and process_info.children then
            for _, child in pairs(process_info.children) do
                local child_exe = child.executable or ''
                local child_name = child.name or ''
                local child_argv = table.concat(child.argv or {}, ' ')
                agent_type = detect_from_process_info(child_exe, child_argv, config)
                if not agent_type and child_name ~= '' then
                    agent_type = detect_from_process_info(child_name, child_argv, config)
                end
                if agent_type then break end
            end
        end
    end
    
    if not agent_type then
        local name_success, process_name = pcall(function()
            return pane:get_foreground_process_name()
        end)
        if name_success and process_name then
            agent_type = detect_from_process_info(process_name, '', config)
        end
    end
    
    if not agent_type then
        local title_success, pane_title = pcall(function()
            return pane:get_title()
        end)
        if title_success then
            agent_type = detect_from_title(pane_title, config)
        end
        if not agent_type then
            local prop_success, prop_title = pcall(function()
                return pane.title
            end)
            if prop_success and prop_title then
                agent_type = detect_from_title(prop_title, config)
            end
        end
    end
    
    detection_cache[pane_id] = { agent_type = agent_type, timestamp = now }
    return agent_type
end

--[[ ============================================
     Status Detection (inline)
     ============================================ ]]

local default_patterns = {
    working = {
        'esc to interrupt',
        'esc interrupt',
        'ctrl%+c to interrupt',
        'thinking', 'pondering', 'processing', 'analyzing',
        'generating', 'writing', 'reading', 'searching',
        'delegating work', 'planning next steps', 'gathering context',
        'searching the codebase', 'searching the web', 'making edits',
        'running commands', 'gathering thoughts', 'considering next steps',
    },
    waiting = {
        'esc to cancel', 'yes, allow once', 'yes, allow always',
        'allow once', 'allow always', 'deny',
        'no, and tell', 'do you trust', 'run this command',
        'execute this', 'continue%?', 'proceed%?',
        '%(y/n%)', '%(Y/n%)', '%[y/n%]', '%[Y/n%]',
        '%(y/N%)', '%(Y/N%)', '%[y/N%]', '%[Y/N%]',
        'approve this plan', 'do you want to proceed',
        'press enter to continue',
        -- Plan mode ask tool patterns (OpenCode v1.1.18+)
        'enter confirm',           -- Confirmation hint in ask dialog footer
        'esc dismiss',             -- Dismiss hint in ask dialog footer
        'type your own answer',    -- Custom input option in ask dialogs
    },
    idle = { '^>%s*$', '^> $', '^>$' },
}

local function strip_ansi(text)
    if not text then return '' end
    local result = text
    result = result:gsub('\27%[%d*;?%d*;?%d*[A-Za-z]', '')
    result = result:gsub('\27%].-\007', '')
    result = result:gsub('\27%].-\27\\', '')
    result = result:gsub('\27%[%?%d+[hl]', '')
    result = result:gsub('\27%[%d*[ABCDEFGJKST]', '')
    result = result:gsub('\27%[%d*;%d*[Hf]', '')
    result = result:gsub('\27%[%d*m', '')
    result = result:gsub('\27%[[0-9;]*m', '')
    result = result:gsub('\r', '')
    return result
end

local function matches_any_status(text, patterns)
    if not text or not patterns then return false end
    local text_lower = text:lower()
    for _, pattern in ipairs(patterns) do
        local success, result = pcall(function()
            return text_lower:find(pattern:lower())
        end)
        if success and result then return true end
        if not success and text_lower:find(pattern:lower(), 1, true) then return true end
    end
    return false
end

--- Split text into lines once, return reusable table
local function split_lines(text)
    if not text then return {} end
    local lines = {}
    for line in text:gmatch('[^\n]+') do
        lines[#lines + 1] = line
    end
    return lines
end

--- Get last N entries from a pre-split lines table
local function last_n_lines(lines, n)
    local count = #lines
    if count == 0 then return '' end
    local start = math.max(1, count - n + 1)
    local result = {}
    for i = start, count do
        result[#result + 1] = lines[i]
    end
    return table.concat(result, '\n')
end

local function detect_status(pane, agent_type, config)
    if not agent_type then return 'inactive' end

    local success, text = pcall(function()
        return pane:get_lines_as_text(config.max_lines or 100)
    end)

    if not success or not text or text == '' then
        return 'inactive'
    end

    local clean_text = strip_ansi(text)

    local agent_config = config.agents[agent_type]
    local patterns = default_patterns
    if agent_config and agent_config.status_patterns then
        patterns = {
            working = agent_config.status_patterns.working or default_patterns.working,
            waiting = agent_config.status_patterns.waiting or default_patterns.waiting,
            idle = agent_config.status_patterns.idle or default_patterns.idle,
        }
    end

    -- Split lines ONCE and reuse
    local lines = split_lines(clean_text)
    if #lines == 0 then return 'inactive' end

    -- Check last 5 lines for idle indicators
    local start_5 = math.max(1, #lines - 4)
    for i = start_5, #lines do
        local trimmed = lines[i]:match('^%s*(.-)%s*$') or ''

        -- Check for ">" prompt (Claude/OpenCode prompt starts with >)
        if trimmed == '>' or trimmed:match('^>%s') then
            return 'idle'
        end

        -- Check custom idle patterns
        if matches_any_status(trimmed, patterns.idle) then
            return 'idle'
        end
    end

    -- Check if last line is empty/whitespace (OpenCode idle state)
    local last_trimmed = lines[#lines]:match('^%s*(.-)%s*$') or ''
    local last_line_empty = (last_trimmed == '')

    -- Check last 10 lines for working/waiting (reuse the single split)
    local recent_text = last_n_lines(lines, 10)

    if matches_any_status(recent_text, patterns.working) then
        return 'working'
    end

    -- If last line is empty and no working indicators, likely idle
    if last_line_empty then
        return 'idle'
    end

    -- Check waiting only in recent lines (reduce false positives from scrollback)
    if matches_any_status(recent_text, patterns.waiting) then
        return 'waiting'
    end

    -- Default to idle
    return 'idle'
end

--[[ ============================================
     Rendering (inline)
     ============================================ ]]

local function get_default_title(tab)
    local pane = tab.active_pane
    local title = pane.title or ''
    if title == '' then
        local process_name = pane.foreground_process_name or ''
        if process_name ~= '' then
            title = process_name:match('[/\\]([^/\\]+)$') or process_name
        end
    end
    if title == '' then title = 'Terminal' end
    return title
end

local function render_icon(status_name)
    local icon = get_status_icon(status_name)
    local color = get_status_color(status_name)
    return {
        { Foreground = { Color = color } },
        { Text = icon },
        { Attribute = { Intensity = 'Normal' } },
    }
end

local function render_badge(counts, filter, label)
    local count = 0
    if filter == 'all' then
        for _, c in pairs(counts) do count = count + c end
    else
        count = counts[filter] or 0
    end
    
    if count == 0 then return {} end
    
    local color = get_status_color(filter ~= 'all' and filter or 'working')
    local text = tostring(count)
    if label then text = text .. ' ' .. label end
    
    return {
        { Foreground = { Color = color } },
        { Text = text },
        { Attribute = { Intensity = 'Normal' } },
    }
end

local function render_separator(text)
    return { { Text = text or ' ' } }
end

local function render_component(comp, context)
    local comp_type = comp.type
    
    if comp_type == 'icon' then
        return render_icon(context.status or 'inactive')
    elseif comp_type == 'separator' then
        return render_separator(comp.text)
    elseif comp_type == 'badge' then
        return render_badge(context.counts or {}, comp.filter or 'all', comp.label)
    elseif comp_type == 'label' then
        local format = comp.format or '{status}'
        local text = format:gsub('{status}', context.status or 'inactive')
        text = text:gsub('{agent_type}', context.agent_type or 'unknown')
        text = text:gsub('{agent_name}', context.agent_type or 'unknown')
        local color = get_status_color(context.status or 'inactive')
        return {
            { Foreground = { Color = color } },
            { Text = text },
            { Attribute = { Intensity = 'Normal' } },
        }
    elseif comp_type == 'agent_name' then
        local agent_type = context.agent_type or 'unknown'
        local text = comp.short and agent_type:sub(1, 1):upper() or agent_type
        local color = get_status_color(context.status or 'inactive')
        return {
            { Foreground = { Color = color } },
            { Text = text },
            { Attribute = { Intensity = 'Normal' } },
        }
    end
    
    return {}
end

local function render_components(component_list, context)
    local result = {}
    for _, comp in ipairs(component_list) do
        local items = render_component(comp, context)
        for _, item in ipairs(items) do
            table.insert(result, item)
        end
    end
    return result
end

local function render_tab_title(agent_state, tab, tab_config)
    local default_title = get_default_title(tab)
    
    if not agent_state then
        return { { Text = ' ' .. default_title .. ' ' } }
    end
    
    local context = {
        status = agent_state.status or 'inactive',
        agent_type = agent_state.agent_type,
    }
    
    local component_items = render_components(tab_config.components or {}, context)
    local result = { { Text = ' ' } }
    
    if tab_config.position == 'left' then
        for _, item in ipairs(component_items) do
            table.insert(result, item)
        end
        table.insert(result, { Text = default_title })
    else
        table.insert(result, { Text = default_title })
        for _, item in ipairs(component_items) do
            table.insert(result, item)
        end
    end
    
    table.insert(result, { Text = ' ' })
    return result
end

local function render_tab_title_multi(all_pane_states, tab, tab_config)
    local default_title = get_default_title(tab)
    local result = { { Text = ' ' } }
    
    if tab_config.position == 'left' then
        for i, pane_data in ipairs(all_pane_states) do
            local status = pane_data.state.status or 'inactive'
            local icon = get_status_icon(status)
            local color = get_status_color(status)
            table.insert(result, { Foreground = { Color = color } })
            table.insert(result, { Text = icon })
            if i < #all_pane_states then
                table.insert(result, { Text = '' })
            end
        end
        table.insert(result, { Attribute = { Intensity = 'Normal' } })
        table.insert(result, { Text = ' ' .. default_title })
    else
        table.insert(result, { Text = default_title .. ' ' })
        for i, pane_data in ipairs(all_pane_states) do
            local status = pane_data.state.status or 'inactive'
            local icon = get_status_icon(status)
            local color = get_status_color(status)
            table.insert(result, { Foreground = { Color = color } })
            table.insert(result, { Text = icon })
            if i < #all_pane_states then
                table.insert(result, { Text = '' })
            end
        end
        table.insert(result, { Attribute = { Intensity = 'Normal' } })
    end
    
    table.insert(result, { Text = ' ' })
    return result
end

local function render_right_status(counts)
    local cfg = get_config()
    local total = 0
    for _, count in pairs(counts) do total = total + count end
    if total == 0 then return {} end
    
    local context = { counts = counts }
    local result = render_components(cfg.right_status.components or {}, context)
    
    -- Filter empty items and trailing separators
    local filtered = {}
    local last_was_text = false
    for _, item in ipairs(result) do
        local is_separator = item.Text and item.Text:match('^[%s|%-]+$')
        local is_empty = item.Text and item.Text == ''
        if not is_empty then
            if is_separator and not last_was_text then
                -- skip
            else
                table.insert(filtered, item)
                last_was_text = item.Text and not item.Text:match('^[%s|%-]+$')
            end
        end
    end
    
    while #filtered > 0 do
        local last = filtered[#filtered]
        if last.Text and last.Text:match('^[%s|%-]+$') then
            table.remove(filtered)
        else
            break
        end
    end
    
    if #filtered > 0 then
        table.insert(filtered, 1, { Text = ' ' })
        table.insert(filtered, { Text = ' ' })
    end
    
    return filtered
end

--[[ ============================================
     Notifications (inline)
     ============================================ ]]

local MIN_NOTIFICATION_GAP_MS = 10000
local AGENT_GONE_GRACE_MS = 5000  -- Wait 5s before treating agent as truly gone

local function shell_escape(str)
    if not str then return '' end
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

--- Build a per-pane notification group ID
local function pane_group(config, pane_id)
    local tn_config = config.notifications.terminal_notifier or {}
    return (tn_config.group or 'wezterm-agent-deck') .. '-' .. tostring(pane_id)
end

local function send_terminal_notifier(subtitle, message, config, opts)
    opts = opts or {}
    local tn_config = config.notifications.terminal_notifier or {}
    local binary = tn_config.path or 'terminal-notifier'
    local title = tn_config.title or 'WezTerm Agent Deck'

    local args = { binary, '-title', title, '-subtitle', subtitle, '-message', message }

    -- Use per-call sound override, fall back to default
    local sound = opts.sound
    if sound == nil then
        sound = tn_config.sound
    end
    if sound then
        table.insert(args, '-sound')
        table.insert(args, sound)
    end

    if opts.group then
        table.insert(args, '-group')
        table.insert(args, opts.group)
    end

    if tn_config.activate then
        table.insert(args, '-activate')
        table.insert(args, 'com.github.wez.wezterm')
    end

    local success, err = pcall(function()
        wezterm.background_child_process(args)
    end)
    if not success then
        wezterm.log_warn('[agent-deck] terminal-notifier spawn failed: ' .. tostring(err))
        return false
    end
    return true
end

--- Remove a terminal-notifier notification by group
local function remove_terminal_notification(config, group)
    local tn_config = config.notifications.terminal_notifier or {}
    local binary = tn_config.path or 'terminal-notifier'
    pcall(function()
        wezterm.background_child_process({ binary, '-remove', group })
    end)
end

local function get_agent_display_name(agent_type)
    local agent_names = {
        opencode = 'OpenCode',
        claude = 'Claude',
        gemini = 'Gemini',
        codex = 'Codex',
        aider = 'Aider',
    }
    return agent_names[agent_type] or agent_type
end

local function notify_waiting(pane, agent_type, config)
    if not config.notifications.enabled or not config.notifications.on_waiting then
        return
    end

    local agent_name = get_agent_display_name(agent_type)
    local subtitle = agent_name .. ' - Attention Needed'
    local message = 'Needs your input'
    local timeout_ms = config.notifications.timeout_ms or 4000
    local backend = config.notifications.backend or 'native'

    if backend == 'terminal-notifier' then
        if send_terminal_notifier(subtitle, message, config, {
            group = pane_group(config, pane:pane_id()),
        }) then
            wezterm.log_info('[agent-deck] terminal-notifier sent: ' .. subtitle)
        end
        return
    end

    local tab = pane:tab()
    if not tab then return end
    local mux_window = tab:window()
    if not mux_window then return end
    local gui_window = mux_window:gui_window()
    if not gui_window then return end

    gui_window:toast_notification(subtitle, message, nil, timeout_ms)
    wezterm.log_info('[agent-deck] notification sent: ' .. subtitle)
end

local function notify_finished(pane_id, config)
    -- Clear any lingering waiting notification for this pane
    if (config.notifications.backend or 'native') == 'terminal-notifier' then
        remove_terminal_notification(config, pane_group(config, pane_id))
    end
end

--- Remove the notification for a pane when it's no longer waiting
local function clear_pane_notification(pane_id, config)
    if (config.notifications.backend or 'native') == 'terminal-notifier' then
        remove_terminal_notification(config, pane_group(config, pane_id))
    end
end

--[[ ============================================
     Core Plugin Logic
     ============================================ ]]

local function get_agent_state(pane_id)
    return state.agent_states[pane_id]
end

local function should_notify_waiting(pane_id)
    return not state.waiting_notified[pane_id]
end

local function mark_waiting_notified(pane_id)
    state.waiting_notified[pane_id] = true
end

local function clear_waiting_notified(pane_id)
    state.waiting_notified[pane_id] = nil
end

local function update_agent_state(pane, config)
    local pane_id = pane:pane_id()
    local current_state = state.agent_states[pane_id]
    local now = os.time() * 1000

    local agent_type = detect_agent(pane, config)

    if not agent_type then
        if current_state then
            -- Grace period: don't clear state immediately when detection flickers.
            if not current_state.undetected_since then
                current_state.undetected_since = now
                current_state.last_update = now
                return current_state
            elseif (now - current_state.undetected_since) < AGENT_GONE_GRACE_MS then
                current_state.last_update = now
                return current_state
            end

            local old_status = current_state.status
            state.agent_states[pane_id] = nil
            detection_cache[pane_id] = nil
            clear_waiting_notified(pane_id)
            notify_finished(pane_id, config)
            wezterm.emit('agent_deck.agent_finished', nil, pane, current_state.agent_type)
            if old_status ~= 'inactive' then
                wezterm.emit('agent_deck.status_changed', nil, pane, old_status, 'inactive', nil)
            end
        end
        return nil
    end

    -- Agent re-detected, clear any grace period timer
    if current_state then
        current_state.undetected_since = nil
    end

    local new_status = detect_status(pane, agent_type, config)

    if not current_state then
        current_state = {
            agent_type = agent_type,
            status = new_status,
            last_update = now,
            cooldown_start = nil,
        }
        state.agent_states[pane_id] = current_state
        wezterm.emit('agent_deck.agent_detected', nil, pane, agent_type)
        wezterm.emit('agent_deck.status_changed', nil, pane, 'inactive', new_status, agent_type)

        if new_status == 'waiting' and should_notify_waiting(pane_id) then
            wezterm.log_warn('[agent-deck] NOTIFY new-agent pane=' .. pane_id)
            notify_waiting(pane, agent_type, config)
            mark_waiting_notified(pane_id)
        end

        return current_state
    end

    local old_status = current_state.status

    -- Cooldown logic: working -> idle needs sustained idle before transitioning
    if old_status == 'working' and new_status == 'idle' then
        if not current_state.cooldown_start then
            current_state.cooldown_start = now
            current_state.last_update = now
            return current_state
        elseif (now - current_state.cooldown_start) < config.cooldown_ms then
            current_state.last_update = now
            return current_state
        end
        current_state.cooldown_start = nil
    elseif new_status == 'working' then
        current_state.cooldown_start = nil
        -- Agent confirmed working — next waiting state is a genuinely new question.
        if state.waiting_notified[pane_id] then
            wezterm.log_warn('[agent-deck] CLEAR waiting_notified pane=' .. pane_id .. ' (confirmed working)')
            clear_pane_notification(pane_id, config)
            clear_waiting_notified(pane_id)
        end
    end

    if old_status ~= new_status then
        current_state.status = new_status
        current_state.last_update = now
        wezterm.emit('agent_deck.status_changed', nil, pane, old_status, new_status, agent_type)

        if new_status == 'waiting' and should_notify_waiting(pane_id) then
            wezterm.log_warn('[agent-deck] NOTIFY pane=' .. pane_id .. ' ' .. old_status .. ' -> waiting')
            notify_waiting(pane, agent_type, config)
            mark_waiting_notified(pane_id)
            wezterm.emit('agent_deck.attention_needed', nil, pane, agent_type, 'waiting_for_input')
        end
    else
        current_state.last_update = now
    end

    current_state.agent_type = agent_type
    return current_state
end

local function get_all_agent_states()
    return state.agent_states
end

local function count_agents_by_status()
    local counts = { working = 0, waiting = 0, idle = 0, inactive = 0 }
    for _, agent_state in pairs(state.agent_states) do
        local s = agent_state.status or 'inactive'
        counts[s] = (counts[s] or 0) + 1
    end
    return counts
end

--[[ ============================================
     Public API
     ============================================ ]]

function M.setup(opts)
    set_config(opts)
    state.initialized = true
    wezterm.log_info('[agent-deck] Plugin initialized')
end

function M.apply_to_config(config, opts)
    if opts then set_config(opts) end

    local plugin_config = get_config()
    config.status_update_interval = plugin_config.update_interval

    -- Suppress WezTerm's built-in OSC notifications to prevent duplicate/persistent
    -- notifications from agents like Claude Code that send their own escape sequences
    if plugin_config.notifications.suppress_osc_notifications then
        config.notification_handling = 'NeverShow'
    end
    
    if plugin_config.tab_title.enabled then
        wezterm.on('format-tab-title', function(tab, tabs, panes, wezterm_config, hover, max_width)
            local active_pane_id = tab.active_pane.pane_id
            local all_pane_states = {}
            
            for _, pane_info in ipairs(tab.panes or {}) do
                local p_state = get_agent_state(pane_info.pane_id)
                if p_state then
                    table.insert(all_pane_states, {
                        state = p_state,
                        is_active = (pane_info.pane_id == active_pane_id)
                    })
                end
            end
            
            if #all_pane_states == 0 then
                return nil
            end
            
            return render_tab_title_multi(all_pane_states, tab, plugin_config.tab_title)
        end)
    end
    
    -- Status bar (right status)
    if plugin_config.right_status.enabled then
        wezterm.on('update-status', function(window, pane)
            cleanup_stale_entries(window)
            
            for _, mux_tab in ipairs(window:mux_window():tabs()) do
                for _, p in ipairs(mux_tab:panes()) do
                    update_agent_state(p, plugin_config)
                end
            end
            
            local counts = count_agents_by_status()
            local right_status = render_right_status(counts)
            
            if right_status and #right_status > 0 then
                window:set_right_status(wezterm.format(right_status))
            end
        end)
    else
        wezterm.on('update-status', function(window, pane)
            cleanup_stale_entries(window)
            
            for _, mux_tab in ipairs(window:mux_window():tabs()) do
                for _, p in ipairs(mux_tab:panes()) do
                    update_agent_state(p, plugin_config)
                end
            end
        end)
    end
    
    state.initialized = true
    wezterm.log_info('[agent-deck] Plugin applied to config')
end

-- Export for advanced users
M.get_agent_state = get_agent_state
M.get_all_agent_states = get_all_agent_states
M.count_agents_by_status = count_agents_by_status
M.get_config = get_config
M.set_config = set_config
M.get_status_color = get_status_color
M.get_status_icon = get_status_icon
M.update_pane = function(pane)
    return update_agent_state(pane, get_config())
end

return M
