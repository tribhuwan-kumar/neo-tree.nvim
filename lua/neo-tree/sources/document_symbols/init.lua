--This file should have all functions that are in the public api and either set
--or read the state of this source.

local manager = require("neo-tree.sources.manager")
local events = require("neo-tree.events")
local utils = require("neo-tree.utils")
local symbols = require("neo-tree.sources.document_symbols.lib.symbols_utils")
local renderer = require("neo-tree.ui.renderer")

---@class neotree.sources.DocumentSymbols : neotree.Source
local M = {
  name = "document_symbols",
  display_name = "  Symbols ",
}

local get_state = function()
  return manager.get_state(M.name)
end

---Refresh the source with debouncing
---@param args { afile: string }
local refresh_debounced = function(args)
  if utils.is_real_file(args.afile) == false then
    return
  end
  utils.debounce(
    "document_symbols_refresh",
    utils.wrap(manager.refresh, M.name),
    100,
    utils.debounce_strategy.CALL_LAST_ONLY
  )
end

---Internal function to follow the cursor
local follow_symbol = function()
  local state = get_state()
  if state.lsp_bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.lsp_winid)
  local node_id = symbols.get_symbol_by_loc(state.tree, { cursor[1] - 1, cursor[2] })
  if #node_id > 0 then
    renderer.focus_node(state, node_id, true)
  end
end

---@class neotree.sources.documentsymbols.DebounceArgs

---Follow the cursor with debouncing
---@param args { afile: string }
local follow_debounced = function(args)
  if utils.is_real_file(args.afile) == false then
    return
  end
  utils.debounce(
    "document_symbols_follow",
    utils.wrap(follow_symbol, args.afile),
    100,
    utils.debounce_strategy.CALL_LAST_ONLY
  )
end

---Navigate to the given path.
M.navigate = function(state, path, path_to_reveal, callback, async)
  state.lsp_winid, _ = utils.get_appropriate_window(state)
  state.lsp_bufnr = vim.api.nvim_win_get_buf(state.lsp_winid)
  state.path = vim.api.nvim_buf_get_name(state.lsp_bufnr)

  symbols.render_symbols(state)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

---@class neotree.Config.LspKindDisplay
---@field icon string
---@field hl string

---@class neotree.Config.DocumentSymbols.Renderers : neotree.Config.Renderers
---@field root neotree.Component.DocumentSymbols[]?
---@field symbol neotree.Component.DocumentSymbols[]?

---@class (exact) neotree.Config.DocumentSymbols : neotree.Config.Source
---@field follow_cursor boolean?
---@field client_filters neotree.lsp.ClientFilter?
---@field custom_kinds table<integer, string>?
---@field kinds table<string, neotree.Config.LspKindDisplay>?
---@field renderers neotree.Config.DocumentSymbols.Renderers?

---Configures the plugin, should be called before the plugin is used.
---@param config neotree.Config.DocumentSymbols
---@param global_config neotree.Config.Base
M.setup = function(config, global_config)
  symbols.setup(config)

  if config.before_render then
    manager.subscribe(M.name, {
      event = events.BEFORE_RENDER,
      handler = function(state)
        local this_state = get_state()
        if state == this_state then
          config.before_render(this_state)
        end
      end,
    })
  end

  local refresh_events = {
    events.VIM_BUFFER_ENTER,
    events.VIM_INSERT_LEAVE,
    events.VIM_TEXT_CHANGED_NORMAL,
  }
  for _, event in ipairs(refresh_events) do
    manager.subscribe(M.name, {
      event = event,
      handler = refresh_debounced,
    })
  end

  if config.follow_cursor then
    manager.subscribe(M.name, {
      event = events.VIM_CURSOR_MOVED,
      handler = follow_debounced,
    })
  end
end

return M
