local uv = vim.uv or vim.loop
local utils = require("neo-tree.utils")
local _compat = require("neo-tree.utils._compat")

---@enum neotree.command.ParserArgument.Type
local argtype = {
  FLAG = "<FLAG>",
  LIST = "<LIST>",
  PATH = "<PATH>",
  REF = "<REF>",
}

---@class neotree.command.Parser
---@field argtypes table<string, neotree.command.ParserArgument.Type>
local M = {
  argtypes = argtype,
}

---@param all_source_names string[]
M.setup = function(all_source_names)
  local source_names = vim.deepcopy(all_source_names, _compat.noref())
  table.insert(source_names, "migrations")

  -- A special source referring to the last used source.
  table.insert(source_names, "last")

  ---@class neotree.command.ParserArgument
  ---@field type neotree.command.ParserArgument.Type

  -- For lists, the first value is the default value.
  ---@class neotree.command.ParserArguments
  ---@field [string] neotree.command.ParserArgument
  ---@field values string[]
  local arguments = {
    action = {
      type = M.argtypes.LIST,
      values = {
        "close",
        "focus",
        "show",
      },
    },
    position = {
      type = M.argtypes.LIST,
      values = {
        "left",
        "right",
        "top",
        "bottom",
        "float",
        "current",
      },
    },
    source = {
      type = M.argtypes.LIST,
      values = source_names,
    },
    dir = { type = M.argtypes.PATH, stat_type = "directory" },
    reveal_file = { type = M.argtypes.PATH, stat_type = "file" },
    git_base = { type = M.argtypes.REF },
    toggle = { type = M.argtypes.FLAG },
    reveal = { type = M.argtypes.FLAG },
    reveal_force_cwd = { type = M.argtypes.FLAG },
    selector = { type = M.argtypes.FLAG },
  }

  local arg_type_lookup = {}
  local list_args = {}
  local path_args = {}
  local ref_args = {}
  local flag_args = {}
  local reverse_lookup = {}
  for name, def in pairs(arguments) do
    arg_type_lookup[name] = def.type
    if def.type == M.argtypes.LIST then
      table.insert(list_args, name)
      for _, vv in ipairs(def.values) do
        reverse_lookup[tostring(vv)] = name
      end
    elseif def.type == M.argtypes.PATH then
      table.insert(path_args, name)
    elseif def.type == M.argtypes.FLAG then
      table.insert(flag_args, name)
      reverse_lookup[name] = M.argtypes.FLAG
    elseif def.type == M.argtypes.REF then
      table.insert(ref_args, name)
    else
      error("Unknown type: " .. def.type)
    end
  end

  M.arguments = arguments
  M.list_args = list_args
  M.path_args = path_args
  M.ref_args = ref_args
  M.flag_args = flag_args
  M.argtype_lookup = arg_type_lookup
  M.reverse_lookup = reverse_lookup
end

---@param path string
---@param validate_type string?
M.resolve_path = function(path, validate_type)
  path = vim.fs.normalize(path)
  local expanded = vim.fn.expand(path)
  local abs_path = vim.fn.fnamemodify(expanded, ":p")
  if validate_type then
    local stat = uv.fs_stat(abs_path)
    if not stat or stat.type ~= validate_type then
      vim.notify("Invalid path: " .. path .. " is not a " .. validate_type, vim.log.levels.ERROR)
    end
  end
  return abs_path
end

---@param ref string
M.verify_git_ref = function(ref)
  local ok, _ = utils.execute_command("git rev-parse --verify " .. ref)
  return ok
end

---@class neotree.command.Parser.Parsed
---@field [string] string|boolean

---@param result neotree.command.Parser.Parsed
---@param arg string
local parse_arg = function(result, arg)
  if type(arg) ~= "string" then
    return
  end
  local eq = arg:find("=")
  if eq then
    local key = arg:sub(1, eq - 1)
    local value = arg:sub(eq + 1)
    local def = M.arguments[key]
    if not def.type then
      error("Invalid argument: " .. arg)
    end

    if def.type == M.argtypes.PATH then
      result[key] = M.resolve_path(value, def.stat_type)
    elseif def.type == M.argtypes.FLAG then
      if value == "true" then
        result[key] = true
      elseif value == "false" then
        result[key] = false
      else
        error("Invalid value for " .. key .. ": " .. value)
      end
    elseif def.type == M.argtypes.REF then
      if not M.verify_git_ref(value) then
        error("Invalid value for " .. key .. ": " .. value)
      end
      result[key] = value
    else
      result[key] = value
    end
  else
    local value = arg
    local key = M.reverse_lookup[value]
    if key == nil then
      -- maybe it's a git ref
      if M.verify_git_ref(value) then
        result["git_base"] = value
        return
      end
      -- maybe it's a path
      local path = M.resolve_path(value)
      local stat = uv.fs_stat(path)
      if stat then
        if stat.type == "directory" then
          result["dir"] = path
        elseif stat.type == "file" then
          result["reveal_file"] = path
        end
      else
        error("Invalid argument: " .. arg)
      end
    elseif key == M.argtypes.FLAG then
      result[value] = true
    else
      result[key] = value
    end
  end
end

---@param args string|string[]
---@param strict_checking boolean
---@return neotree.command.Parser.Parsed parsed_args
M.parse = function(args, strict_checking)
  require("neo-tree").ensure_config()
  local result = {}

  if type(args) == "string" then
    args = utils.split(args, " ")
  end
  -- read args from user
  for _, arg in ipairs(args) do
    local success, err = pcall(parse_arg, result, arg)
    if strict_checking and not success then
      error(err)
    end
  end

  return result
end

return M
