local NuiLine = require("nui.line")
local NuiTree = require("nui.tree")
local NuiSplit = require("nui.split")
local NuiPopup = require("nui.popup")
local utils = require("neo-tree.utils")
local highlights = require("neo-tree.ui.highlights")
local popups = require("neo-tree.ui.popups")
local events = require("neo-tree.events")
local keymap = require("nui.utils.keymap")
local autocmd = require("nui.utils.autocmd")
local log = require("neo-tree.log")
local windows = require("neo-tree.ui.windows")
local nt = require("neo-tree")

local M = { resize_timer_interval = 50 }
local ESC_KEY = utils.keycode("<ESC>")
local default_popup_size = { width = 60, height = "80%" }
local draw, create_tree, render_tree

local floating_windows = {}
local update_floating_windows = function()
  local valid_windows = {}
  for _, win in ipairs(floating_windows) do
    if M.is_window_valid(win.winid) then
      table.insert(valid_windows, win)
    end
  end
  floating_windows = valid_windows
end

local tabid_to_tabnr = function(tabid)
  return vim.api.nvim_tabpage_is_valid(tabid) and vim.api.nvim_tabpage_get_number(tabid)
end

local buffer_is_usable = function(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

local cleaned_up = false
---Clean up invalid neotree buffers (e.g after a session restore)
---@param force boolean if true, force cleanup. Otherwise only cleanup once
M.clean_invalid_neotree_buffers = function(force)
  if cleaned_up and not force then
    return
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local bufname = vim.fn.bufname(buf)
    local is_neotree_buffer = string.match(bufname, "neo%-tree [^ ]+ %[%d+]")
    local is_valid_neotree, _ = pcall(vim.api.nvim_buf_get_var, buf, "neo_tree_source")
    if is_neotree_buffer and not is_valid_neotree then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  cleaned_up = true
end

local resize_monitor_timer = nil
local start_resize_monitor = function()
  local interval = M.resize_timer_interval or -1
  if interval < 0 then
    return
  end
  if type(interval) ~= "number" then
    log.warn("Invalid resize_timer_interval:", interval)
    return
  end
  if resize_monitor_timer then
    return
  end
  local manager = require("neo-tree.sources.manager")
  local check_window_size
  local speed_up_loops = 0
  check_window_size = function()
    local windows_exist = false
    local success, err = pcall(manager._for_each_state, nil, function(state)
      if state.win_width and M.tree_is_visible(state) then
        windows_exist = true
        local current_size = utils.get_inner_win_width(state.winid)
        if current_size ~= state.win_width then
          log.trace("Window size changed, redrawing tree")
          state.win_width = current_size
          render_tree(state)
          speed_up_loops = 21 -- move to fast timer for the next 1000 ms
        end
      end
    end)

    speed_up_loops = speed_up_loops - 1
    if success then
      if windows_exist then
        local this_interval = interval
        if speed_up_loops > 0 then
          this_interval = 50
        else
          speed_up_loops = 0
        end
        vim.defer_fn(check_window_size, this_interval)
      else
        log.trace("No windows exist, stopping resize monitor")
      end
    else
      log.debug("Error checking window size: ", err)
      vim.defer_fn(check_window_size, math.max(interval * 5, 1000))
    end
  end

  vim.defer_fn(check_window_size, interval)
end

---Safely closes the window and deletes the buffer associated with the state
---@param state neotree.State State of the source to close
---@param focus_prior_window boolean | nil if true or nil, focus the window that was previously focused
M.close = function(state, focus_prior_window)
  log.debug("Closing window, but saving position first.")
  M.position.save(state)

  if focus_prior_window == nil then
    focus_prior_window = true
  end
  local window_existed = false
  if state and state.winid then
    if M.window_exists(state) then
      local bufnr = vim.api.nvim_win_get_buf(state.winid)
      -- if bufnr is different then we expect,  then it was taken over by
      -- another buffer, so we can't delete it now
      if bufnr == state.bufnr then
        window_existed = true
        if state.current_position == "current" then
          -- we are going to hide the buffer instead of closing the window
          M.position.save(state)
          local new_buf = vim.fn.bufnr("#")
          if new_buf < 1 then
            new_buf = vim.api.nvim_create_buf(true, false)
          end
          vim.api.nvim_win_set_buf(state.winid, new_buf)
        else
          local args = {
            position = state.current_position,
            source = state.name,
            winid = state.winid,
            tabnr = tabid_to_tabnr(state.tabid), -- for compatibility
            tabid = state.tabid,
          }
          events.fire_event(events.NEO_TREE_WINDOW_BEFORE_CLOSE, args)
          local win_list = vim.api.nvim_tabpage_list_wins(0)
          if focus_prior_window and #win_list > 1 then
            -- focus the prior used window if we are closing the currently focused window
            local current_winid = vim.api.nvim_get_current_win()
            if current_winid == state.winid then
              local pwin = require("neo-tree").get_prior_window()
              if type(pwin) == "number" and pwin > 0 then
                pcall(vim.api.nvim_set_current_win, pwin)
              end
            end
          end
          -- if the window was a float, changing the current win would have closed it already
          pcall(vim.api.nvim_win_close, state.winid, true)
          events.fire_event(events.NEO_TREE_WINDOW_AFTER_CLOSE, args)
        end
      end
    end
    state.winid = nil
  end
  local bufnr = utils.get_value(state, "bufnr", 0, true)
  if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    state.bufnr = nil
    local success, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    if not success and err and err:match("E523") then
      vim.schedule_wrap(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)()
    end
  end
  return window_existed
end

M.close_floating_window = function(source_name)
  local found_windows = {}
  for _, win in ipairs(floating_windows) do
    if win.source_name == source_name then
      table.insert(found_windows, win)
    end
  end

  local valid_window_was_closed = false
  for _, win in ipairs(found_windows) do
    if not valid_window_was_closed then
      valid_window_was_closed = M.is_window_valid(win.winid)
    end
    -- regardless of whether the window is valid or not, nui will cleanup
    win:unmount()
  end
  return valid_window_was_closed
end

M.close_all_floating_windows = function()
  while #floating_windows > 0 do
    local win = table.remove(floating_windows)
    win:unmount()
  end
end

M.get_nui_popup = function(winid)
  for _, win in ipairs(floating_windows) do
    if win.winid == winid then
      return win
    end
  end
end

---@param source_items neotree.FileItem[]
---@param filtered_items neotree.Config.Filesystem.FilteredItems
local remove_filtered = function(source_items, filtered_items)
  local visible = {}
  local hidden = {}
  for _, item in ipairs(source_items) do
    local fby = item.filtered_by
    if not fby or item.is_reveal_target or item.contains_reveal_target then
      visible[#visible + 1] = item
    else
      while fby do
        if fby.never_show then
          -- pretend it doesn't exist
          break
        elseif filtered_items.visible or item.is_nested or fby.always_show then
          visible[#visible + 1] = item
          break
        elseif fby.name or fby.pattern or fby.dotfiles or fby.hidden then
          hidden[#hidden + 1] = item
          break
        elseif fby.show_gitignored and fby.gitignored then
          visible[#visible + 1] = item
          break
        elseif fby.parent then
          fby = fby.parent
        else
          -- filtered by some other reason
          hidden[#hidden + 1] = item
          break
        end
      end
    end
  end
  return visible, hidden
end

---@class neotree.FileNodeData : neotree.FileItem

---@class neotree.FileNode : neotree.FileNodeData, NuiTree.Node

local create_nodes
---Transforms a list of items into a collection of TreeNodes.
---@param source_items neotree.FileItem[] The list of items to transform. The expected
--interface for these items depends on the component renderers configured for
--the given source, but they must contain at least an id field.
---@param state neotree.State The current state of the plugin.
---@param level integer Optional. The current level of the tree, defaults to 0.
---@return table nodes A collection of TreeNodes.
create_nodes = function(source_items, state, level)
  level = level or 0
  local nodes = {}
  local filtered_items = state.filtered_items or {}
  local visible, hidden = remove_filtered(source_items, filtered_items)

  if #visible == 0 and level <= 1 and filtered_items.force_visible_in_empty_folder then
    source_items = hidden
  else
    source_items = visible
  end

  local show_indent_marker_for_message
  local msg = state.renderers.message or {}
  if msg[1] and msg[1][1] == "indent" then
    local indent = msg[1]
    ---these types might need a slight rework but this cast is correct.
    ---@diagnostic disable-next-line: cast-type-mismatch
    ---@cast indent neotree.Component.Common.Indent
    show_indent_marker_for_message = indent.with_markers
  end

  for i, item in ipairs(source_items) do
    local is_last_child = i == #source_items

    local nodeData = {
      id = item.id,
      name = item.name,
      type = item.type,
      loaded = item.loaded,
      filtered_by = item.filtered_by,
      extra = item.extra,
      is_nested = item.is_nested,
      skip_node = item.skip_node,
      is_empty_with_hidden_root = item.is_empty_with_hidden_root,
      stat = item.stat,
      stat_provider = item.stat_provider,
      -- TODO: The below properties are not universal and should not be here.
      -- Maybe they should be moved to the "extra" field?
      is_link = item.is_link,
      link_to = item.link_to,
      path = item.path,
      ext = item.ext,
      search_pattern = item.search_pattern,
      level = level,
      is_last_child = is_last_child,
    }

    local node_children = nil
    if item.children ~= nil then
      node_children = create_nodes(item.children, state, level + 1)
    end

    local node = NuiTree.Node(nodeData, node_children)
    if item._is_expanded then
      node:expand()
    end
    table.insert(nodes, node)
  end

  if #hidden > 0 then
    if source_items == hidden then
      local nodeData = {
        id = hidden[#hidden].id .. "_hidden_message",
        name = "(forced to show "
          .. #hidden
          .. " hidden "
          .. (#hidden > 1 and "items" or "item")
          .. ")",
        type = "message",
        level = level,
        is_last_child = show_indent_marker_for_message,
      }
      local node = NuiTree.Node(nodeData)
      table.insert(nodes, node)
    elseif filtered_items.show_hidden_count or (#visible == 0 and level <= 1) then
      local nodeData = {
        id = hidden[#hidden].id .. "_hidden_message",
        name = "(" .. #hidden .. " hidden " .. (#hidden > 1 and "items" or "item") .. ")",
        type = "message",
        level = level,
        is_last_child = show_indent_marker_for_message,
      }
      if #nodes > 0 then
        nodes[#nodes].is_last_child = not show_indent_marker_for_message
      end
      local node = NuiTree.Node(nodeData)
      table.insert(nodes, node)
    end
  end
  return nodes
end

local one_line = function(text)
  if type(text) == "string" then
    return text:gsub("\n", " ")
  else
    return text
  end
end

M.render_component = function(component, item, state, remaining_width)
  local component_func = state.components[component[1]]
  if component_func then
    local success, component_data, wanted_width =
      pcall(component_func, component, item, state, remaining_width)
    if success then
      if component_data == nil then
        return { {} }
      end
      if component_data.text then
        -- everything else is easier if we make sure this is always the same shape
        -- which is an array of { text, highlight } tables
        component_data = { component_data }
      end
      for _, data in ipairs(component_data) do
        data.text = one_line(data.text)
      end
      return component_data, wanted_width
    else
      local name = component[1] or "[missing_name]"
      local msg = string.format("Error rendering component %s: %s", name, component_data)
      log.warn(msg)
      return { { text = msg, highlight = highlights.NORMAL } }
    end
  else
    local name = component[1] or "[missing_name]"
    local msg = "Neo-tree: Component " .. name .. " not found."
    log.warn(msg)
    return { { text = msg, highlight = highlights.NORMAL } }
  end
end

local prepare_node = function(item, state)
  if item.skip_node then
    if item.is_empty_with_hidden_root then
      local line = NuiLine()
      line:append("(empty folder)", highlights.MESSAGE)
      return line
    else
      return nil
    end
  end
  -- pre_render is used to calculate the longest node width
  -- without actually rendering the node.
  -- We'll try to reuse that work if possible.
  local pre_render = state._in_pre_render
  if item.line and not pre_render then
    local line = item.line
    -- Only use it once, we don't want to accidentally use stale data
    item.line = nil
    if
      line
      and item.wanted_width
      and state.longest_node
      and item.wanted_width <= state.longest_node
    then
      return line
    end
  end
  ---@class NuiLine
  local line = NuiLine()

  local renderer = state.renderers[item.type]
  if not renderer then
    line:append(item.type .. ": ", "Comment")
    line:append(item.name)
    return line
  end

  local remaining_cols = state.win_width
  if remaining_cols == nil then
    if state.winid then
      remaining_cols = vim.api.nvim_win_get_width(state.winid)
    else
      local default_width = utils.resolve_config_option(state, "window.width", 40)
      remaining_cols = default_width
    end
  end

  local wanted_width = 0
  if state.current_position == "current" then
    local longest = state.longest_node or 0
    remaining_cols = math.min(remaining_cols, longest + 4)
  end

  local should_pad = false

  for _, component in ipairs(renderer) do
    repeat
      if component.enabled == false then
        break
      end
      local component_data, component_wanted_width =
        M.render_component(component, item, state, remaining_cols - (should_pad and 1 or 0))
      local actual_width = 0
      if component_data then
        for _, data in ipairs(component_data) do
          if data.text then
            local padding = ""
            if should_pad and #data.text and data.text:sub(1, 1) ~= " " and not data.no_padding then
              padding = " "
            end
            data.text = padding .. data.text
            should_pad = data.text:sub(#data.text) ~= " " and not data.no_next_padding

            actual_width = actual_width + vim.api.nvim_strwidth(data.text)
            line:append(data.text, data.highlight)
            remaining_cols = remaining_cols - vim.fn.strchars(data.text)
          end
        end
      end
      component_wanted_width = component_wanted_width or actual_width
      wanted_width = wanted_width + component_wanted_width
    until true
  end

  line.wanted_width = wanted_width
  if pre_render then
    item.line = line
    state.longest_node = math.max(state.longest_node, line.wanted_width)
  else
    item.line = nil
  end

  return line
end

---Sets the cursor at the specified node.
---@param state neotree.State The current state of the source.
---@param id string? The id of the node to set the cursor at.
---@return boolean boolean True if the node was found and focused, false
---otherwise.
M.focus_node = function(state, id, do_not_focus_window, relative_movement, bottom_scroll_padding)
  if not id and not relative_movement then
    log.debug("focus_node called with no id and no relative movement")
    return false
  end
  relative_movement = relative_movement or 0
  bottom_scroll_padding = bottom_scroll_padding or 0

  local tree = state.tree
  if not tree then
    log.debug("focus_node called with no tree")
    return false
  end
  local node, linenr = tree:get_node(id)
  if not node then
    log.debug("focus_node cannot find node with id ", id)
    return false
  end
  id = node:get_id() -- in case nil was passed in for id, meaning current node

  local bufnr = utils.get_value(state, "bufnr", 0, true)
  if bufnr == 0 then
    log.debug("focus_node: state has no bufnr ", state.bufnr, " / ", state.winid)
    return false
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    log.debug("focus_node: bufnr is not valid")
    return false
  end

  if M.window_exists(state) then
    if not linenr then
      M.expand_to_node(state, node)
      node, linenr = assert(tree:get_node(id))
      if not linenr then
        log.debug("focus_node cannot get linenr for node with id ", id)
        return false
      end
    end
    local focus_window = not do_not_focus_window
    if focus_window then
      vim.api.nvim_set_current_win(state.winid)
    end

    -- focus the correct line
    linenr = linenr + relative_movement
    local col = 0
    if node.indent then
      col = string.len(node.indent)
    end
    local success, err = pcall(vim.api.nvim_win_set_cursor, state.winid, { linenr, col })

    if success then
      -- forget about cursor position as it is overwritten
      M.position.clear(state)
      -- now ensure that the window is scrolled correctly
      local execute_win_command = function(cmd)
        if vim.api.nvim_get_current_win() == state.winid then
          vim.cmd(cmd)
        else
          vim.cmd("call win_execute(" .. state.winid .. [[, "]] .. cmd .. [[")]])
        end
      end

      -- make sure we are not scrolled down if it can all fit on the screen
      local lines = vim.api.nvim_buf_line_count(state.bufnr)
      local win_height = vim.api.nvim_win_get_height(state.winid)
      local virtual_bottom_line = vim.fn.line("w0", state.winid)
        + win_height
        - bottom_scroll_padding
      if virtual_bottom_line <= linenr then
        execute_win_command("normal! " .. (linenr + bottom_scroll_padding) .. "zb")
        pcall(vim.api.nvim_win_set_cursor, state.winid, { linenr, col })
      elseif virtual_bottom_line > lines then
        execute_win_command("normal! " .. (lines + bottom_scroll_padding) .. "zb")
        pcall(vim.api.nvim_win_set_cursor, state.winid, { linenr, col })
      elseif linenr < (win_height / 2) then
        execute_win_command("normal! zz")
      end
    else
      log.debug("Failed to set cursor: " .. err)
    end
    return success
  end
  log.debug("focus_node: window does not exist")
  return false
end

M.get_all_visible_nodes = function(tree)
  local nodes = {}

  local function process(node)
    table.insert(nodes, node)
    if node:is_expanded() then
      if node:has_children() then
        for _, child in ipairs(tree:get_nodes(node:get_id())) do
          process(child)
        end
      end
    end
  end

  for _, node in ipairs(tree:get_nodes()) do
    process(node)
  end
  return nodes
end

M.get_expanded_nodes = function(tree, root_node_id)
  local node_ids = {}

  local function process(node)
    local id = node:get_id()
    if node:is_expanded() then
      table.insert(node_ids, id)
    end
    if node:has_children() then
      for _, child in ipairs(tree:get_nodes(id)) do
        process(child)
      end
    end
  end

  if root_node_id then
    local root_node = tree:get_node(root_node_id)
    if root_node then
      process(root_node)
    end
  else
    for _, node in ipairs(tree:get_nodes()) do
      process(node)
    end
  end
  return node_ids
end

M.collapse_all_nodes = function(tree, root_node_id)
  local expanded = M.get_expanded_nodes(tree, root_node_id)
  for _, id in ipairs(expanded) do
    local node = tree:get_node(id)
    if utils.is_expandable(node) then
      node:collapse(id)
    end
  end
  -- but make sure the root is expanded
  local root = tree:get_nodes()[1]
  if root then
    root:expand()
  end
end

M.expand_to_node = function(state, node)
  if not M.tree_is_visible(state) then
    return
  end
  local tree = state.tree
  if type(node) == "string" then
    node = tree:get_node(node)
  end
  local parentId = node:get_parent_id()
  while parentId do
    local parent = tree:get_node(parentId)
    parent:expand()
    parentId = parent:get_parent_id()
  end
  render_tree(state)
end

---Functions to save and restore the focused node.
M.position = {}
---@param state neotree.State
M.position.save = function(state)
  if state.position.topline and state.position.lnum then
    log.debug("There's already a position saved to be restored. Cannot save another.")
    return
  end
  if state.tree and M.window_exists(state) then
    local win_state = vim.api.nvim_win_call(state.winid, vim.fn.winsaveview)
    state.position.topline = win_state.topline
    state.position.lnum = win_state.lnum
    log.debug("Saved cursor position with lnum: " .. state.position.lnum)
    log.debug("Saved window position with topline: " .. state.position.topline)
  end
end
---@param state neotree.State
M.position.set = function(state, node_id)
  if type(node_id) ~= "string" or node_id == "" then
    return
  end
  if state.tree then
    local node = state.tree:get_node(node_id)
    if node and node.skip_node then
      return
    end
  end
  state.position.node_id = node_id
end
---@param state neotree.State
M.position.clear = function(state)
  log.debug("Forget about cursor position.")
  -- Clear saved position, so that we can save another position later.
  state.position.topline = nil
  state.position.lnum = nil
  -- After focusing a node, we clear it so that subsequent renderer.position.restore don't
  -- focus on it anymore
  state.position.node_id = nil
end
---@param state neotree.State
M.position.restore = function(state)
  if state.position.topline and state.position.lnum then
    log.debug("Restoring window position to topline: " .. state.position.topline)
    log.debug("Restoring cursor position to lnum: " .. state.position.lnum)
    vim.api.nvim_win_call(state.winid, function()
      vim.fn.winrestview({ topline = state.position.topline, lnum = state.position.lnum })
    end)
  end
  if state.position.node_id then
    log.debug("Focusing on node_id: " .. state.position.node_id)
    M.focus_node(state, state.position.node_id, true)
  end
  M.position.clear(state)
end

---Redraw the tree without relaoding from the source.
---@param state neotree.State State of the tree.
M.redraw = function(state)
  if state.tree and M.tree_is_visible(state) then
    log.trace("Redrawing tree", state.name, state.id)
    -- every now and then this will fail because the window was closed in
    -- betweeen the start of an async refresh and the redraw call.
    -- This is not a problem, so we just ignore the error.
    local success = pcall(render_tree, state)
    if success then
      log.trace("  Redrawing tree done", state.name, state.id)
    else
      log.trace("  Redrawing tree failed, maybe it was closed?", state.name, state.id)
    end
  end
end
---Visit all nodes ina tree recursively and reduce to a single value.
---@param tree table NuiTree
---@param memo any Value that is passed to the accumulator function
---@param func function Accumulator function that is called for each node
---@return any any The final memo value.
M.reduce_nodes = function(tree, memo, func)
  if type(func) ~= "function" then
    error("func must be a function")
  end
  local visit
  visit = function(node)
    func(node, memo)
    if node:has_children() then
      for _, child in ipairs(tree:get_nodes(node:get_id())) do
        visit(child)
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    visit(node)
  end
  return memo
end

---Visits all nodes in the tree and returns a list of all nodes that match the
---given predicate.
---@param tree table The NuiTree to search.
---@param selector_func function The predicate function, should return true for
---nodes that should be included in the result.
---@return table table A list of nodes that match the predicate.
M.select_nodes = function(tree, selector_func, limit)
  if type(selector_func) ~= "function" then
    error("selector_func must be a function")
  end
  local found_nodes = {}
  local visit
  visit = function(node)
    if selector_func(node) then
      table.insert(found_nodes, node)
      if limit and #found_nodes >= limit then
        return
      end
    end
    if node:has_children() then
      for _, child in ipairs(tree:get_nodes(node:get_id())) do
        visit(child)
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    visit(node)
    if limit and #found_nodes >= limit then
      break
    end
  end
  return found_nodes
end

M.set_expanded_nodes = function(tree, expanded_nodes)
  M.collapse_all_nodes(tree)
  log.debug("Setting expanded nodes")
  for _, id in ipairs(expanded_nodes or {}) do
    local node = tree:get_node(id)
    if node ~= nil then
      node:expand()
    end
  end
end

create_tree = function(state)
  if state.tree and state.tree.bufnr == state.bufnr then
    if buffer_is_usable(state.tree.bufnr) then
      log.debug("Tree already exists and buffer is valid, skipping creation", state.name, state.id)
      state.tree.winid = state.winid
      return
    end
  end
  state.tree = NuiTree({
    ns_id = highlights.ns_id,
    winid = state.winid,
    bufnr = state.bufnr,
    get_node_id = function(node)
      return node.id
    end,
    prepare_node = function(data)
      return prepare_node(data, state)
    end,
  })
end

---@return NuiTree.Node[]?
local get_selected_nodes = function(state)
  if state.winid ~= vim.api.nvim_get_current_win() then
    return nil
  end
  local start_pos = vim.fn.getpos("'<")[2]
  local end_pos = vim.fn.getpos("'>")[2]
  if end_pos < start_pos then
    -- I'm not sure if this could actually happen, but just in case
    start_pos, end_pos = end_pos, start_pos
  end
  local selected_nodes = {}
  while start_pos <= end_pos do
    local node = state.tree:get_node(start_pos)
    if node then
      table.insert(selected_nodes, node)
    end
    start_pos = start_pos + 1
  end
  return selected_nodes
end

---@class neotree.State.ResolvedMapping
---@field text string
---@field handler function

---@param state neotree.StateWithTree
local set_buffer_mappings = function(state)
  ---@type table<string, neotree.State.ResolvedMapping?>
  local resolved_mappings = {}
  local skip_this_mapping = {
    ["none"] = true,
    ["nop"] = true,
    ["noop"] = true,
  }
  local mappings = state.window.mappings or {}
  local mapping_options = state.window.mapping_options or { noremap = true }
  for cmd, func in pairs(mappings) do
    ---@type neotree.TreeCommandVisual?
    local vfunc
    local config = {}
    repeat
      if not utils.truthy(func) then
        break
      end
      if skip_this_mapping[func] then
        log.trace("Skipping mapping for %s", cmd)
        break
      end
      local oldfunc = func
      local map_options = vim.deepcopy(mapping_options)
      local desc
      if type(func) == "table" then
        ---@cast func neotree.Config.Window.Command.Configured
        for key, value in pairs(func) do
          if key ~= "command" and key ~= 1 and key ~= "config" then
            map_options[key] = value
          end
        end
        desc = func.desc
        config = func.config or {}
        func = func.command or func[1]
      end

      ---@type string?
      local helptext
      if type(func) == "string" then
        helptext = desc or func
        map_options.desc = map_options.desc or func
        vfunc = state.commands[func .. "_visual"]
        func = state.commands[func]
      elseif type(func) == "function" then
        ---@cast func neotree.TreeCommand
        helptext = desc or "<function>"
      else
        error("mapping needs to be either a function or a valid name of a command")
      end

      if type(func) ~= "function" then
        local invalid_desc = desc or func or oldfunc
        log.warn("Invalid mapping for ", cmd, ": ", invalid_desc)
        resolved_mappings[cmd] = {
          text = ("<invalid> (%s)"):format(invalid_desc),
          handler = function() end,
        }
        break
      end
      local fallback = utils.keycode(cmd)
      resolved_mappings[cmd] = {
        text = helptext,
        handler = function()
          state.config = config
          state.fallback = fallback
          return func(state)
        end,
      }
      keymap.set(state.bufnr, "n", cmd, resolved_mappings[cmd].handler, map_options)
      if type(vfunc) == "function" then
        keymap.set(state.bufnr, "v", cmd, function()
          vim.api.nvim_feedkeys(ESC_KEY, "i", true)
          vim.schedule(function()
            local selected_nodes = get_selected_nodes(state)
            if utils.truthy(selected_nodes) then
              ---@cast selected_nodes -nil
              state.config = config
              vfunc(state, selected_nodes)
            end
          end)
        end, map_options)
      end
    until true
  end
  state.resolved_mappings = resolved_mappings
end

local function create_floating_window(state, win_options, bufname)
  state.force_float = nil
  -- First get the default options for floating windows.
  local title = utils.resolve_config_option(state, "window.popup.title", function(current_state)
    return "Neo-tree " .. current_state.name:gsub("^%l", string.upper)
  end)
  win_options = popups.popup_options(title, 40, win_options)
  win_options.win_options = nil
  win_options.zindex = 40

  -- Then override with source specific options.
  local b = win_options.border
  win_options.size = utils.resolve_config_option(state, "window.popup.size", default_popup_size)
  win_options.position = utils.resolve_config_option(state, "window.popup.position", "50%")
  win_options.border = utils.resolve_config_option(state, "window.popup.border", b)

  ---@class NuiPopup
  local win = NuiPopup(win_options)
  win:mount()
  win.source_name = state.name
  win.original_options = state.window
  table.insert(floating_windows, win)

  win:on({ "BufHidden" }, function()
    vim.schedule(function()
      win:unmount()
    end)
  end, { once = true })
  state.winid = win.winid
  state.bufnr = win.bufnr
  log.debug("Created floating window with winid: ", win.winid, " and bufnr: ", win.bufnr)
  vim.api.nvim_buf_set_name(state.bufnr, bufname)

  -- why is this necessary?
  vim.api.nvim_set_current_win(win.winid)
  return win
end

local get_buffer = function(bufname, state)
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr > 0 then
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      return bufnr
    else
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = 0
    end
  end
  if bufnr < 1 then
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "neo-tree"
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].undolevels = -1
    autocmd.buf.define(bufnr, "BufDelete", function()
      M.position.save(state)
    end)
  end
  return bufnr
end

M.acquire_window = function(state)
  if M.window_exists(state) then
    return state.winid
  end

  -- used by tests to determine if the tree is ready for testing
  state._ready = false

  local default_position = utils.resolve_config_option(state, "window.position", "left")
  local relative = utils.resolve_config_option(state, "window.relative", "editor")
  state.current_position = state.current_position or default_position

  local bufname = string.format("neo-tree %s [%s]", state.name, state.id)
  local size_opt, default_size
  if state.current_position == "top" or state.current_position == "bottom" then
    size_opt, default_size = "window.height", "15"
  else
    size_opt, default_size = "window.width", "40"
  end
  local win_options = {
    ns_id = highlights.ns_id,
    size = utils.resolve_config_option(state, size_opt, default_size),
    position = state.current_position,
    relative = relative,
    buf_options = {
      buftype = "nofile",
      modifiable = false,
      swapfile = false,
      filetype = "neo-tree",
      undolevels = -1,
    },
    win_options = {
      colorcolumn = "",
      signcolumn = "no",
    },
  }

  local event_args = {
    position = state.current_position,
    source = state.name,
    tabnr = tabid_to_tabnr(state.tabid), -- for compatibility
    tabid = state.tabid,
  }
  events.fire_event(events.NEO_TREE_WINDOW_BEFORE_OPEN, event_args)

  local win
  if state.current_position == "float" then
    M.close_all_floating_windows()
    M.close(state)
    win = create_floating_window(state, win_options, bufname)
  elseif state.current_position == "current" then
    -- state.id is always the window id or tabnr that this state was created for
    -- in the case of a position = current state object, it will be the window id
    local winid = state.id
    if not vim.api.nvim_win_is_valid(winid) then
      log.warn("Window ", winid, "  is no longer valid!")
      return
    end
    state.winid = winid
    state.bufnr = get_buffer(bufname, state)
    vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  else
    local close_old_window = function(new_winid)
      if state.winid and new_winid ~= state.winid then
        -- This state may be showing in another window, close it first because
        -- each state can only be shown in one window at a time.
        M.close(state, false)
      end
    end
    local location = windows.get_location(state.current_position)
    if location.winid > 0 then
      close_old_window(location.winid)
      state.bufnr = get_buffer(bufname, state)
      state.winid = location.winid
      vim.api.nvim_win_set_buf(state.winid, state.bufnr)
    else
      close_old_window()
      win = NuiSplit(win_options)
      win:mount()
      state.bufnr = win.bufnr
      state.winid = win.winid
      location.winid = state.winid
    end
    location.source = state.name
  end
  event_args.winid = state.winid
  events.fire_event(events.NEO_TREE_WINDOW_AFTER_OPEN, event_args)

  if type(state.bufnr) == "number" then
    vim.api.nvim_buf_set_var(state.bufnr, "neo_tree_source", state.name)
    vim.api.nvim_buf_set_var(state.bufnr, "neo_tree_tabnr", tabid_to_tabnr(state.tabid))
    vim.api.nvim_buf_set_var(state.bufnr, "neo_tree_tabid", state.tabid)
    vim.api.nvim_buf_set_var(state.bufnr, "neo_tree_position", state.current_position)
    vim.api.nvim_buf_set_var(state.bufnr, "neo_tree_winid", state.winid)
  end

  if win ~= nil then
    vim.api.nvim_buf_set_name(state.bufnr, bufname)
    vim.api.nvim_set_current_win(state.winid)
    -- Used to track the position of the cursor within the tree as it gains and loses focus
    win:on({ "BufDelete" }, function()
      M.position.save(state)
    end)
    win:on({ "BufDelete" }, function()
      vim.schedule(function()
        win:unmount()
      end)
    end, { once = true })
  end

  set_buffer_mappings(state)
  return state.winid
end

M.update_floating_window_layouts = function()
  update_floating_windows()
  for _, win in ipairs(floating_windows) do
    local opt = {
      relative = "win",
    }
    opt.size = utils.resolve_config_option(win.original_options, "popup.size", default_popup_size)
    opt.position = utils.resolve_config_option(win.original_options, "popup.position", "50%")
    win:update_layout(opt)
  end
end

---Determines is the givin winid is valid and the window still exists.
---@param winid any
---@return boolean
M.is_window_valid = function(winid)
  if winid == nil then
    return false
  end
  if type(winid) == "number" and winid > 0 then
    return vim.api.nvim_win_is_valid(winid)
  else
    return false
  end
end

---Determines if the window exists and is valid.
---@param state neotree.State The current state of the plugin.
---@return boolean True if the window exists and is valid, false otherwise.
M.window_exists = function(state)
  local window_exists
  local winid = utils.get_value(state, "winid", 0, true)
  local bufnr = utils.get_value(state, "bufnr", 0, true)
  local default_position = utils.get_value(state, "window.position", "left", true)
  local position = state.current_position or default_position

  if winid == 0 then
    window_exists = false
  elseif position == "current" then
    window_exists = vim.api.nvim_win_is_valid(winid)
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_win_get_buf(winid) == bufnr
  else
    local isvalid = M.is_window_valid(winid)
    window_exists = isvalid and (vim.api.nvim_win_get_number(winid) > 0)
    if window_exists then
      local winbufnr = vim.api.nvim_win_get_buf(winid)
      if winbufnr < 1 then
        return false
      else
        if winbufnr ~= bufnr then
          return false
        end
        local success, buf_position = pcall(vim.api.nvim_buf_get_var, bufnr, "neo_tree_position")
        if not success then
          return false
        end
        if buf_position ~= position then
          return false
        end
      end
    end
  end
  return window_exists
end

---Determines if a specific tree is open.
---@param state neotree.State The current state of the plugin.
---@return boolean
M.tree_is_visible = function(state)
  return M.window_exists(state) and vim.api.nvim_win_get_buf(state.winid) == state.bufnr
end

---Renders the given tree and expands window width if needed
--@param state neotree.State The state containing tree to render. Almost same as state.tree:render()
render_tree = function(state)
  local add_blank_line_at_top = require("neo-tree").config.add_blank_line_at_top
  local should_auto_expand = state.window.auto_expand_width and state.current_position ~= "float"
  local should_pre_render = should_auto_expand or state.current_position == "current"

  log.debug("render_tree: Saving position")
  M.position.save(state)

  if should_pre_render and M.tree_is_visible(state) then
    log.trace("pre-rendering tree")
    state._in_pre_render = true
    if add_blank_line_at_top then
      state.tree:render(2)
    else
      state.tree:render()
    end
    state._in_pre_render = false
    local textoffset = vim.fn.getwininfo(state.winid)[1].textoff or 0
    local desired_width = state.longest_node + textoffset
    state.window.last_user_width = vim.api.nvim_win_get_width(state.winid)
    if should_auto_expand and desired_width > state.window.last_user_width then
      log.trace(string.format("auto_expand_width: on. Expanding width to %s.", state.longest_node))
      vim.api.nvim_win_set_width(state.winid, desired_width)
      state.win_width = desired_width
    end
  end
  if M.tree_is_visible(state) then
    if add_blank_line_at_top then
      state.tree:render(2)
    else
      state.tree:render()
    end
  end

  log.debug("render_tree: Restoring position")
  M.position.restore(state)
end

---Draws the given nodes on the screen.
---@param nodes NuiTree.Node[] The nodes to draw.
---@param state neotree.State The current state of the source.
draw = function(nodes, state, parent_id)
  -- If we are going to redraw, preserve the current set of expanded nodes.
  local expanded_nodes = {}
  if parent_id == nil and state.tree ~= nil then
    if state.force_open_folders then
      log.trace("Force open folders")
      state.force_open_folders = nil
    else
      log.trace("Preserving expanded nodes")
      expanded_nodes = M.get_expanded_nodes(state.tree)
    end
  end
  if state.default_expanded_nodes then
    for _, id in ipairs(state.default_expanded_nodes) do
      table.insert(expanded_nodes, id)
    end
  end

  -- Create the tree if it doesn't exist.
  if parent_id then
    if not M.window_exists(state) then
      log.trace("Window is gone, aborting lazy load of folder")
      return
    end
  else
    M.acquire_window(state)
    create_tree(state)
  end

  -- draw the given nodes
  local success, msg = pcall(state.tree.set_nodes, state.tree, nodes, parent_id)
  if not success then
    log.error("Error setting nodes: ", msg)
    log.error(vim.inspect(state.tree:get_nodes()))
  end
  if parent_id ~= nil then
    -- this is a dynamic fetch of children that were not previously loaded
    local node = assert(state.tree:get_node(parent_id))
    node.loaded = true
    node:expand()
  else
    M.set_expanded_nodes(state.tree, expanded_nodes)
  end

  -- This is to ensure that containers are always the right size
  state.win_width = utils.get_inner_win_width(state.winid)
  start_resize_monitor()

  render_tree(state)

  -- draw winbar / statusbar
  require("neo-tree.ui.selector").set_source_selector(state)

  state._ready = true
end

local function group_empty_dirs(node)
  if node.children == nil then
    return node
  end

  local first_child = node.children[1]
  if #node.children == 1 and first_child.type == "directory" then
    -- this is the only path that changes the tree
    -- at each step where we discover an empty directory, merge it's name with the parent
    -- then skip over it
    first_child.name = node.name .. utils.path_separator .. first_child.name
    return group_empty_dirs(first_child)
  else
    for i, child in ipairs(node.children) do
      node.children[i] = group_empty_dirs(child)
    end
    return node
  end
end

---Shows the given items as a tree.
---@param sourceItems table? The list of items to transform.
---@param state neotree.State The current state of the plugin.
---@param parentId string? The id of the parent node to display these nodes at
---@param callback function? The id of the parent node to display these nodes at
M.show_nodes = function(sourceItems, state, parentId, callback)
  --local id = string.format("show_nodes %s:%s [%s]", state.name, state.force_float, state.tabid)
  --utils.debounce(id, function()
  if not sourceItems then
    return
  end
  events.fire_event(events.BEFORE_RENDER, state)
  state.longest_width_exact = 0
  local parent
  local level = 0
  if parentId ~= nil then
    local success
    success, parent = pcall(state.tree.get_node, state.tree, parentId)
    if success and parent then
      level = parent:get_depth()
    end
    state.longest_node = state.longest_node or 0
  else
    state.longest_node = 0
  end

  local config = require("neo-tree").config
  if config.hide_root_node then
    if not parentId then
      sourceItems[1].skip_node = true
      if not (sourceItems[1].children and #sourceItems[1].children > 0) then
        sourceItems[1].is_empty_with_hidden_root = true
      end
    end
    if not config.retain_hidden_root_indent then
      level = level - 1
    end
  end

  if state.group_empty_dirs then
    if parent then
      local scan_mode = require("neo-tree").config.filesystem.scan_mode
      if scan_mode == "deep" then
        for i, item in ipairs(sourceItems) do
          sourceItems[i] = group_empty_dirs(item)
        end
      else
        -- this is a lazy load of a single sub folder
        group_empty_dirs(sourceItems)
        if #sourceItems == 1 and sourceItems[1].type == "directory" then
          -- This folder needs to be grouped.
          -- The goal is to just update the existing node in place.
          -- To avoid digging into private internals of Nui, we will just export the entire level and replace
          -- the one node. This keeps it in the right order, because nui doesn't have methods to replace something
          -- in place.
          -- We can't just mutate the existing node because we have to change it's id which would break Nui's
          -- internal state.
          local item = sourceItems[1]
          parentId = parent:get_parent_id()
          local siblings = state.tree:get_nodes(parentId)
          for i, node in pairs(siblings) do
            if node.id == parent.id then
              item.name = parent.name .. utils.path_separator .. item.name
              item.level = level - 1
              item.loaded = utils.truthy(item.children)
              siblings[i] = NuiTree.Node(item, item.children)
              break
            end
          end
          sourceItems = nil -- this is a signal to skip the rest of the processing
          state.tree:set_nodes(siblings, parentId)
        end
      end
    else
      -- if we are rendering a whole tree, just group the children because we don'the
      -- want to change the root nodes
      for _, item in ipairs(sourceItems) do
        if item.children ~= nil then
          for i, child in ipairs(item.children) do
            item.children[i] = group_empty_dirs(child)
          end
        end
      end
    end
  end

  if sourceItems then
    -- normal path
    local nodes = create_nodes(sourceItems, state, level)
    draw(nodes, state, parentId)
  else
    -- this was a force grouping of a lazy loaded folder
    state.win_width = utils.get_inner_win_width(state.winid)
    render_tree(state)
  end

  vim.schedule(function()
    events.fire_event(events.AFTER_RENDER, state)
  end)
  if type(callback) == "function" then
    vim.schedule(callback)
  end
  --end, 100)
end

return M
