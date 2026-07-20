-- Agent detection module for WezTerm Agent Deck
-- Detects AI coding agents running in terminal panes via process information
local wezterm = require('wezterm')

local M = {}

-- Cache for agent detection results
-- Structure: { pane_id -> { agent_type, timestamp } }
local detection_cache = {}
local CACHE_TTL_MS = 5000  -- Cache results for 5 seconds

--- Check if a string matches any pattern in a list
---@param str string String to check
---@param patterns table List of patterns (Lua patterns)
---@return boolean True if any pattern matches
local function matches_any_pattern(str, patterns)
    if not str or not patterns then
        return false
    end
    
    local str_lower = str:lower()
    
    for _, pattern in ipairs(patterns) do
        -- Try Lua pattern match first, fall back to plain text if pattern is invalid
        local success, result = pcall(function()
            return str_lower:find(pattern:lower())
        end)
        if success and result then
            return true
        end
        -- Fallback to plain text search if pattern match failed
        if not success and str_lower:find(pattern:lower(), 1, true) then
            return true
        end
    end
    
    return false
end

--- Extract executable name from full path
---@param path string Full executable path
---@return string Executable name
local function get_executable_name(path)
    if not path then
        return ''
    end
    
    -- Handle both Unix and Windows paths
    local name = path:match('[/\\]([^/\\]+)$') or path
    
    -- Remove common extensions
    name = name:gsub('%.exe$', '')
    
    return name
end

--- Check if cache entry is still valid
---@param entry table Cache entry with timestamp
---@return boolean True if still valid
local function is_cache_valid(entry)
    if not entry then
        return false
    end
    
    local now = os.time() * 1000
    return (now - entry.timestamp) < CACHE_TTL_MS
end

--- Check if an agent is enabled in the configuration
---@param agent_name string Agent name to check
---@param config table Plugin configuration
---@return boolean True if agent should be checked
local function is_agent_enabled(agent_name, config)
    -- If enabled_agents is not set, all agents are enabled
    if not config.enabled_agents then
        return true
    end
    
    for _, enabled in ipairs(config.enabled_agents) do
        if enabled == agent_name then
            return true
        end
    end
    
    return false
end

--- Get patterns for a specific detection phase
--- Uses specific patterns if available, falls back to generic patterns
---@param agent_config table Agent configuration
---@param pattern_type string Type of patterns: 'executable', 'argv', 'title'
---@param agent_name string Agent name (used as ultimate fallback)
---@return table List of patterns to match
local function get_patterns_for_phase(agent_config, pattern_type, agent_name)
    local specific_key = pattern_type .. '_patterns'
    
    -- Priority 1: Specific patterns for this phase
    if agent_config[specific_key] and #agent_config[specific_key] > 0 then
        return agent_config[specific_key]
    end
    
    -- Priority 2: Generic patterns field
    if agent_config.patterns and #agent_config.patterns > 0 then
        return agent_config.patterns
    end
    
    -- Priority 3: Agent name as fallback
    return { agent_name }
end

--- Try to detect agent from executable path and argv
---@param executable string Full executable path
---@param argv_str string Joined argv string
---@param config table Plugin configuration
---@return string|nil Agent type name or nil
local function detect_from_process_info(executable, argv_str, config)
    local exe_name = get_executable_name(executable)
    
    for agent_name, agent_config in pairs(config.agents) do
        if is_agent_enabled(agent_name, config) then
            -- Check full executable path first (most specific)
            local exe_patterns = get_patterns_for_phase(agent_config, 'executable', agent_name)
            if matches_any_pattern(executable, exe_patterns) then
                return agent_name
            end
            
            -- Check executable name against specific patterns
            if matches_any_pattern(exe_name, exe_patterns) then
                return agent_name
            end
            
            -- Fallback: check against generic patterns (catches bare process names like 'opencode')
            local generic_patterns = agent_config.patterns
            if generic_patterns and #generic_patterns > 0 then
                if matches_any_pattern(executable, generic_patterns) or matches_any_pattern(exe_name, generic_patterns) then
                    return agent_name
                end
            end
            
            -- Check argv string
            local argv_patterns = get_patterns_for_phase(agent_config, 'argv', agent_name)
            if matches_any_pattern(argv_str, argv_patterns) then
                return agent_name
            end
        end
    end
    
    return nil
end

--- Try to detect agent from pane title
---@param pane_title string Pane title
---@param config table Plugin configuration
---@return string|nil Agent type name or nil
local function detect_from_title(pane_title, config)
    if not pane_title or pane_title == '' then
        return nil
    end
    
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

--- Detect agent type from process information
---@param pane userdata WezTerm pane object
---@param config table Plugin configuration
---@return string|nil Agent type name or nil if no agent detected

--- Recursively detect agent in a process subtree (post-order DFS)
--- Prefers deeper/nested matches (e.g. pi running inside herdr multiplexer)
---@param node table Process info node (executable/name/argv/children)
---@param config table Plugin configuration
---@param depth number Recursion depth guard (cycle/depth protection)
---@return string|nil Agent type name or nil
local function detect_in_subtree(node, config, depth)
    if not node or depth > 8 then
        return nil
    end
    if node.children then
        for _, child in pairs(node.children) do
            local found = detect_in_subtree(child, config, depth + 1)
            if found then
                return found
            end
        end
    end
    local executable = node.executable or ''
    local name = node.name or ''
    local argv = node.argv or {}
    local argv_str = table.concat(argv, ' ')
    local t = detect_from_process_info(executable, argv_str, config)
    if not t and name ~= '' then
        t = detect_from_process_info(name, argv_str, config)
    end
    return t
end

---
--- Bridge to Herdr's own agent detection.
--- WezTerm exposes only a single-level process tree, so an agent nested
--- inside Herdr (pi is a grandchild: herdr -> pwsh -> node/pi) is invisible
--- to the plugin. Herdr already detects the inner agent, so we query it via
--- wezterm.run_child_process (the sandbox-safe native API, NOT Lua io.popen
--- which WezTerm blocks). Result is cached globally so all panes share one
--- `herdr agent list` call per TTL instead of one per pane.
---@param config table Plugin configuration
---@return string|nil Agent type name or nil
local herdr_bridge_cache = { value = nil, ts = 0 }
local HERDR_BRIDGE_TTL_MS = 2000
local function detect_via_herdr(config)
    local now = os.time() * 1000
    if (now - herdr_bridge_cache.ts) < HERDR_BRIDGE_TTL_MS then
        return herdr_bridge_cache.value
    end

    local HERDR = 'C:\\Users\\mohit\\AppData\\Local\\Programs\\Herdr\\bin\\herdr.exe'
    local found = nil
    -- Use pwsh (herdr only resolves under pwsh, not cmd)
    local pcall_ok, success, stdout = pcall(wezterm.run_child_process,
        { 'pwsh', '-NoLogo', '-c', HERDR .. ' agent list' })

    if pcall_ok and success and stdout and stdout ~= '' then
        if stdout:find('"agent"%s*:%s*"pi"') then
            found = 'pi'
        end
    end

    wezterm.log_info('[agent-deck] herdr-bridge pcall_ok=' .. tostring(pcall_ok)
        .. ' success=' .. tostring(success) .. ' outlen=' .. tostring(stdout and #stdout or 0)
        .. ' found=' .. tostring(found))

    pcall(function()
        wezterm.run_child_process({ 'pwsh', '-NoLogo', '-c',
            'echo ' .. os.time() .. ' bridge pcall_ok=' .. tostring(pcall_ok) .. ' success=' .. tostring(success)
            .. ' outlen=' .. tostring(stdout and #stdout or 0) .. ' found=' .. tostring(found)
            .. ' >> C:/Users/mohit/agent-deck-bridge.log' })
    end)

    herdr_bridge_cache.value = found
    herdr_bridge_cache.ts = now
    return found
end

function M.detect_agent(pane, config)
    local pane_id = pane:pane_id()

    pcall(function()
        wezterm.run_child_process({ 'pwsh', '-NoLogo', '-c',
            'echo ' .. os.time() .. ' CALLED pane=' .. tostring(pane_id) .. ' >> C:/Users/mohit/agent-deck-bridge.log' })
    end)

    -- Check cache first
    local cached = detection_cache[pane_id]
    if is_cache_valid(cached) then
        return cached.agent_type
    end
    
    local agent_type = nil
    
    -- Phase 1: Try to get detailed process info (most reliable)
    local success, process_info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    
    if success and process_info then
        wezterm.log_info('[agent-deck] foreground=' .. tostring(process_info.executable or 'nil'))
        agent_type = detect_in_subtree(process_info, config, 0)
    end

    -- Phase 2: Fallback to simpler process name
    if not agent_type then
        local name_success, process_name = pcall(function()
            return pane:get_foreground_process_name()
        end)
        
        if name_success and process_name then
            agent_type = detect_from_process_info(process_name, '', config)
        end
    end
    
    -- Phase 3: Fallback to pane title (for agents that set terminal title)
    if not agent_type then
        local title_success, pane_title = pcall(function()
            return pane:get_title()
        end)
        
        if title_success then
            agent_type = detect_from_title(pane_title, config)
        end
        
        -- Also try pane.title property as secondary source
        if not agent_type then
            local prop_success, prop_title = pcall(function()
                return pane.title
            end)
            
            if prop_success and prop_title ~= pane_title then
                agent_type = detect_from_title(prop_title, config)
            end
        end
    end
    
    -- Phase 4: bridge to Herdr's own agent detection.
    -- Herdr hosts agents (e.g. pi) as grandchildren, invisible to the
    -- single-level process tree. When Phases 1-3 found nothing, ask
    -- Herdr directly (cached, sandbox-safe via run_child_process).
    if not agent_type then
        agent_type = detect_via_herdr(config)
    end

    -- Update cache
    detection_cache[pane_id] = {
        agent_type = agent_type,
        timestamp = os.time() * 1000,
    }

    pcall(function()
        wezterm.run_child_process({ 'pwsh', '-NoLogo', '-c',
            'echo ' .. os.time() .. ' pane=' .. tostring(pane_id) .. ' agent=' .. tostring(agent_type)
            .. ' >> C:/Users/mohit/agent-deck-bridge.log' })
    end)

    return agent_type
end

--- Clear detection cache for a pane
---@param pane_id number Pane ID
function M.clear_cache(pane_id)
    if pane_id then
        detection_cache[pane_id] = nil
    else
        detection_cache = {}
    end
end

--- Get all detected agents (from cache)
---@return table<number, string> Map of pane_id -> agent_type
function M.get_cached_agents()
    local result = {}
    local now = os.time() * 1000
    
    for pane_id, entry in pairs(detection_cache) do
        if (now - entry.timestamp) < CACHE_TTL_MS and entry.agent_type then
            result[pane_id] = entry.agent_type
        end
    end
    
    return result
end

return M
