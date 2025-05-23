-- This file is for functions that mutate the filesystem.

-- This code started out as a copy from:
-- https://github.com/mhartington/dotfiles
-- and modified to fit neo-tree's api.
-- Permalink: https://github.com/mhartington/dotfiles/blob/7560986378753e0c047d940452cb03a3b6439b11/config/nvim/lua/mh/filetree/init.lua
local api = vim.api
local uv = vim.uv or vim.loop
local scan = require("plenary.scandir")
local utils = require("neo-tree.utils")
local inputs = require("neo-tree.ui.inputs")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local Path = require("plenary").path

local M = {}

---@param a uv.fs_stat.result?
---@param b uv.fs_stat.result?
---@return boolean equal Whether a and b are stats of the same file
local same_file = function(a, b)
  return a and b and a.dev == b.dev and a.ino == b.ino or false
end

---Checks to see if a file can safely be renamed to its destination without data loss.
---Also prevents renames from going through if the rename will not do anything.
---Has an additional check for case-insensitive filesystems (e.g. for windows)
---@param source string
---@param destination string
---@return boolean rename_is_safe
local function rename_is_safe(source, destination)
  local destination_file = uv.fs_stat(destination)
  if not destination_file then
    return true
  end

  local src = utils.normalize_path(source)
  local dest = utils.normalize_path(destination)
  local changing_casing = src ~= dest and src:lower() == dest:lower()
  if changing_casing then
    local src_file = uv.fs_stat(src)
    -- We check that the two paths resolve to the same canonical filename and file.
    return same_file(src_file, destination_file)
      and uv.fs_realpath(src) == uv.fs_realpath(destination)
  end
  return false
end

local function find_replacement_buffer(for_buf)
  local bufs = vim.api.nvim_list_bufs()

  -- make sure the alternate buffer is at the top of the list
  local alt = vim.fn.bufnr("#")
  if alt ~= -1 and alt ~= for_buf then
    table.insert(bufs, 1, alt)
  end

  -- find the first valid real file buffer
  for _, buf in ipairs(bufs) do
    if buf ~= for_buf then
      local is_valid = vim.api.nvim_buf_is_valid(buf)
      if is_valid then
        local buftype = vim.bo[buf].buftype
        if buftype == "" then
          return buf
        end
      end
    end
  end
  return -1
end

local function clear_buffer(path)
  local buf = utils.find_buffer_by_name(path)
  if buf < 1 then
    return
  end
  local alt = find_replacement_buffer(buf)
  -- Check all windows to see if they are using the buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      -- if there is no alternate buffer yet, create a blank one now
      if alt < 1 or alt == buf then
        alt = vim.api.nvim_create_buf(true, false)
      end
      -- replace the buffer displayed in this window with the alternate buffer
      vim.api.nvim_win_set_buf(win, alt)
    end
  end
  local success, msg = pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not success then
    log.error("Could not clear buffer: ", msg)
  end
end

---Opens new_buf in each window that has old_buf currently open.
---Useful during file rename.
---@param old_buf number
---@param new_buf number
local function replace_buffer_in_windows(old_buf, new_buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == old_buf then
      vim.api.nvim_win_set_buf(win, new_buf)
    end
  end
end

local function rename_buffer(old_path, new_path)
  local force_save = function()
    vim.cmd("silent! write!")
  end

  for _, buf in pairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      local new_buf_name = nil
      if old_path == buf_name then
        new_buf_name = new_path
      elseif utils.is_subpath(old_path, buf_name) then
        new_buf_name = new_path .. buf_name:sub(#old_path + 1)
      end
      if utils.truthy(new_buf_name) then
        local new_buf = vim.fn.bufadd(new_buf_name)
        vim.fn.bufload(new_buf)
        vim.bo[new_buf].buflisted = true
        replace_buffer_in_windows(buf, new_buf)

        if vim.bo[buf].buftype == "" then
          local modified = vim.bo[buf].modified
          if modified then
            local old_buffer_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, old_buffer_lines)

            local msg = buf_name .. " has been modified. Save under new name? (y/n) "
            inputs.confirm(msg, function(confirmed)
              if confirmed then
                vim.api.nvim_buf_call(new_buf, force_save)
                log.trace("Force saving renamed buffer with changes")
              else
                vim.cmd("echohl WarningMsg")
                vim.cmd(
                  [[echo "Skipping force save. You'll need to save it with `:w!` when you are ready to force writing with the new name."]]
                )
                vim.cmd("echohl NONE")
              end
            end)
          end
        end
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end
end

local function create_all_parents(path)
  local function create_all_as_folders(in_path)
    if not uv.fs_stat(in_path) then
      local parent, _ = utils.split_path(in_path)
      if parent then
        create_all_as_folders(parent)
      end
      uv.fs_mkdir(in_path, 493)
    end
  end

  local parent_path, _ = utils.split_path(path)
  create_all_as_folders(parent_path)
end

-- Gets a non-existing filename from the user and executes the callback with it.
---@param source string
---@param destination string
---@param using_root_directory boolean
---@param name_chosen_callback fun(string)
---@param first_message string?
local function get_unused_name(
  source,
  destination,
  using_root_directory,
  name_chosen_callback,
  first_message
)
  if not rename_is_safe(source, destination) then
    local parent_path, name
    if not using_root_directory then
      parent_path, name = utils.split_path(destination)
    elseif #using_root_directory > 0 then
      parent_path = destination:sub(1, #using_root_directory)
      name = destination:sub(#using_root_directory + 2)
    else
      parent_path = nil
      name = destination
    end

    local message = first_message or name .. " already exists. Please enter a new name: "
    inputs.input(message, name, function(new_name)
      if new_name and string.len(new_name) > 0 then
        local new_path = parent_path and parent_path .. utils.path_separator .. new_name or new_name
        get_unused_name(source, new_path, using_root_directory, name_chosen_callback)
      end
    end)
  else
    name_chosen_callback(destination)
  end
end

-- Move Node
M.move_node = function(source, destination, callback, using_root_directory)
  log.trace(
    "Moving node: ",
    source,
    " to ",
    destination,
    ", using root directory: ",
    using_root_directory
  )
  local _, name = utils.split_path(source)
  get_unused_name(source, destination or source, using_root_directory, function(dest)
    -- Resolve user-inputted relative paths out of the absolute paths
    dest = vim.fs.normalize(dest)
    if utils.is_windows then
      dest = utils.windowize_path(dest)
    end
    local function move_file()
      create_all_parents(dest)
      uv.fs_rename(source, dest, function(err)
        if err then
          log.error("Could not move the files from", source, "to", dest, ":", err)
          return
        end
        vim.schedule(function()
          rename_buffer(source, dest)
        end)
        vim.schedule(function()
          events.fire_event(events.FILE_MOVED, {
            source = source,
            destination = dest,
          })
          if callback then
            callback(source, dest)
          end
        end)
      end)
    end
    local event_result = events.fire_event(events.BEFORE_FILE_MOVE, {
      source = source,
      destination = dest,
      callback = move_file,
    }) or {}
    if event_result.handled then
      return
    end
    move_file()
  end, 'Move "' .. name .. '" to:')
end

---Plenary path.copy() when used to copy a recursive structure, can return a nested
-- table with for each file a Path instance and the success result.
---@param copy_result table The output of Path.copy()
---@param flat_result table Return value containing the flattened results
local function flatten_path_copy_result(flat_result, copy_result)
  if not copy_result then
    return
  end
  for k, v in pairs(copy_result) do
    if type(v) == "table" then
      flatten_path_copy_result(flat_result, v)
    else
      table.insert(flat_result, { destination = k.filename, success = v })
    end
  end
end

-- Check if all files were copied successfully, using the flattened copy result
local function check_path_copy_result(flat_result)
  if not flat_result then
    return
  end
  for _, file_result in ipairs(flat_result) do
    if not file_result.success then
      return false
    end
  end
  return true
end

-- Copy Node
M.copy_node = function(source, _destination, callback, using_root_directory)
  local _, name = utils.split_path(source)
  get_unused_name(source, _destination or source, using_root_directory, function(destination)
    local parent_path, _ = utils.split_path(destination)
    if source == parent_path then
      log.warn("Cannot copy a file/folder to itself")
      return
    end

    local event_result = events.fire_event(events.BEFORE_FILE_ADD, destination) or {}
    if event_result.handled then
      return
    end

    local source_path = Path:new(source)
    if source_path:is_file() then
      -- When the source is a file, then Path.copy() currently doesn't create
      -- the potential non-existing parent directories of the destination.
      create_all_parents(destination)
    end
    local success, result = pcall(source_path.copy, source_path, {
      destination = destination,
      recursive = true,
      parents = true,
    })
    if not success then
      log.error("Could not copy the file(s) from", source, "to", destination, ":", result)
      return
    end

    -- It can happen that the Path.copy() function returns successfully but
    -- the copy action still failed. In this case the copy() result contains
    -- a nested table of Path instances for each file copied, and the success
    -- result.
    local flat_result = {}
    flatten_path_copy_result(flat_result, result)
    if not check_path_copy_result(flat_result) then
      log.error("Could not copy the file(s) from", source, "to", destination, ":", flat_result)
      return
    end

    vim.schedule(function()
      events.fire_event(events.FILE_ADDED, destination)
      if callback then
        callback(source, destination)
      end
    end)
  end, 'Copy "' .. name .. '" to:')
end

--- Create a new directory
M.create_directory = function(in_directory, callback, using_root_directory)
  local base
  if type(using_root_directory) == "string" then
    if in_directory == using_root_directory then
      base = ""
    elseif #using_root_directory > 0 then
      base = in_directory:sub(#using_root_directory + 2) .. utils.path_separator
    else
      base = in_directory .. utils.path_separator
    end
  else
    base = vim.fn.fnamemodify(in_directory .. utils.path_separator, ":~")
    using_root_directory = false
  end

  inputs.input("Enter name for new directory:", base, function(destinations)
    if not destinations then
      return
    end

    for _, destination in ipairs(utils.brace_expand(destinations)) do
      if not destination or destination == base then
        return
      end

      if using_root_directory then
        destination = utils.path_join(using_root_directory, destination)
      else
        destination = vim.fn.fnamemodify(destination, ":p")
      end

      local event_result = events.fire_event(events.BEFORE_FILE_ADD, destination) or {}
      if event_result.handled then
        return
      end

      if uv.fs_stat(destination) then
        log.warn("Directory already exists")
        return
      end

      create_all_parents(destination)
      uv.fs_mkdir(destination, 493)

      vim.schedule(function()
        events.fire_event(events.FILE_ADDED, destination)
        if callback then
          callback(destination)
        end
      end)
    end
  end)
end

--- Create Node
M.create_node = function(in_directory, callback, using_root_directory)
  local base
  if type(using_root_directory) == "string" then
    if in_directory == using_root_directory then
      base = ""
    elseif #using_root_directory > 0 then
      base = in_directory:sub(#using_root_directory + 2) .. utils.path_separator
    else
      base = in_directory .. utils.path_separator
    end
  else
    base = vim.fn.fnamemodify(in_directory .. utils.path_separator, ":~")
    using_root_directory = false
  end

  local dir_ending = '"/"'
  if utils.path_separator ~= "/" then
    dir_ending = dir_ending .. string.format(' or "%s"', utils.path_separator)
  end
  local msg = "Enter name for new file or directory (dirs end with a " .. dir_ending .. "):"
  inputs.input(msg, base, function(destinations)
    if not destinations then
      return
    end

    for _, destination in ipairs(utils.brace_expand(destinations)) do
      if not destination or destination == base then
        return
      end
      local is_dir = vim.endswith(destination, "/")
        or vim.endswith(destination, utils.path_separator)

      if using_root_directory then
        destination = utils.path_join(using_root_directory, destination)
      else
        destination = vim.fn.fnamemodify(destination, ":p")
      end

      destination = utils.normalize_path(destination)
      if uv.fs_stat(destination) then
        log.warn("File already exists")
        return
      end

      local complete = vim.schedule_wrap(function()
        events.fire_event(events.FILE_ADDED, destination)
        if callback then
          callback(destination)
        end
      end)
      local event_result = events.fire_event(events.BEFORE_FILE_ADD, destination) or {}
      if event_result.handled then
        complete()
        return
      end

      create_all_parents(destination)
      if is_dir then
        uv.fs_mkdir(destination, 493)
      else
        local open_mode = uv.constants.O_CREAT + uv.constants.O_WRONLY + uv.constants.O_TRUNC
        local fd = uv.fs_open(destination, open_mode, 420)
        if not fd then
          if not uv.fs_stat(destination) then
            log.error("Could not create file " .. destination)
            return
          else
            log.warn("Failed to complete file creation of " .. destination)
          end
        else
          uv.fs_close(fd)
        end
      end
      complete()
    end
  end)
end

---Recursively delete a directory and its children.
---@param dir_path string Directory to delete.
---@return boolean success Whether the directory was deleted.
local function delete_dir(dir_path)
  local handle = uv.fs_scandir(dir_path)
  if type(handle) == "string" then
    log.error(handle)
    return false
  end

  if not handle then
    log.error("could not scan dir " .. dir_path)
    return false
  end

  while true do
    local child_name, t = uv.fs_scandir_next(handle)
    if not child_name then
      break
    end

    local child_path = dir_path .. "/" .. child_name
    if t == "directory" then
      local success = delete_dir(child_path)
      if not success then
        log.error("failed to delete ", child_path)
        return false
      end
    else
      local success = uv.fs_unlink(child_path)
      if not success then
        return false
      end
      clear_buffer(child_path)
    end
  end
  return uv.fs_rmdir(dir_path) or false
end

-- Delete Node
M.delete_node = function(path, callback, noconfirm)
  local _, name = utils.split_path(path)
  local msg = string.format("Are you sure you want to delete '%s'?", name)

  log.trace("Deleting node: ", path)
  local _type = "unknown"
  local stat = uv.fs_stat(path)
  if stat then
    _type = stat.type
    if _type == "link" then
      local link_to = uv.fs_readlink(path)
      if not link_to then
        log.error("Could not read link")
        return
      end
      local target_file = uv.fs_stat(link_to)
      if target_file then
        _type = target_file.type
      end
      _type = uv.fs_stat(link_to).type
    end
    if _type == "directory" then
      local children = scan.scan_dir(path, {
        hidden = true,
        respect_gitignore = false,
        add_dirs = true,
        depth = 1,
      })
      if #children > 0 then
        msg = "WARNING: Dir not empty! " .. msg
      end
    end
  else
    log.warn("Could not read file/dir:", path, stat, ", attempting to delete anyway...")
    -- Guess the type by whether it appears to have an extension
    if path:match("%.(.+)$") then
      _type = "file"
    else
      _type = "directory"
    end
    return
  end

  local do_delete = function()
    local complete = vim.schedule_wrap(function()
      events.fire_event(events.FILE_DELETED, path)
      if callback then
        callback(path)
      end
    end)

    local event_result = events.fire_event(events.BEFORE_FILE_DELETE, path) or {}
    if event_result.handled then
      complete()
      return
    end

    if _type == "directory" then
      -- first try using native system commands, which are recursive
      local success = false
      if utils.is_windows then
        local result =
          vim.fn.system({ "cmd.exe", "/c", "rmdir", "/s", "/q", vim.fn.shellescape(path) })
        local error = vim.v.shell_error
        if error ~= 0 then
          log.debug("Could not delete directory '", path, "' with rmdir: ", result)
        else
          log.info("Deleted directory ", path)
          success = true
        end
      else
        local result = vim.fn.system({ "trashbhuwan", "-p", path })
        local error = vim.v.shell_error
        if error ~= 0 then
          log.debug("Could not delete directory '", path, "' with trashbhuwan: ", result)
        else
          log.info("Deleted directory ", path)
          success = true
        end
      end
      -- Fallback to using libuv if native commands fail
      if not success then
        success = delete_dir(path)
        if not success then
          return log.error("Could not remove directory: " .. path)
        end
      end
    else
      local success = vim.fn.system({ "trashbhuwan", "-p", path })
      if not success then
        return log.error("Could not remove file: " .. path)
      end
      clear_buffer(path)
    end
    complete()
  end

  if noconfirm then
    do_delete()
  else
    inputs.confirm(msg, function(confirmed)
      if confirmed then
        do_delete()
      end
    end)
  end
end

M.delete_nodes = function(paths_to_delete, callback)
  local msg = "Are you sure you want to delete " .. #paths_to_delete .. " items?"
  inputs.confirm(msg, function(confirmed)
    if not confirmed then
      return
    end

    for _, path in ipairs(paths_to_delete) do
      M.delete_node(path, nil, true)
    end

    if callback then
      vim.schedule(function()
        callback(paths_to_delete[#paths_to_delete])
      end)
    end
  end)
end

local rename_node = function(msg, name, get_destination, path, callback)
  inputs.input(msg, name, function(new_name)
    -- If cancelled
    if not new_name or new_name == "" then
      log.info("Operation canceled")
      return
    end

    local destination = get_destination(new_name)

    if not rename_is_safe(path, destination) then
      log.warn(destination, " already exists, canceling")
      return
    end

    local complete = vim.schedule_wrap(function()
      rename_buffer(path, destination)
      events.fire_event(events.FILE_RENAMED, {
        source = path,
        destination = destination,
      })
      if callback then
        callback(path, destination)
      end
      log.info("Renamed " .. new_name .. " successfully")
    end)

    local function fs_rename()
      uv.fs_rename(path, destination, function(err)
        if err then
          log.warn("Could not rename the files")
          return
        end
        complete()
      end)
    end

    local event_result = events.fire_event(events.BEFORE_FILE_RENAME, {
      source = path,
      destination = destination,
      callback = fs_rename,
    }) or {}
    if event_result.handled then
      complete()
      return
    end
    fs_rename()
  end)
end

-- Rename Node
M.rename_node = function(path, callback)
  local parent_path, name = utils.split_path(path)
  local msg = string.format('Enter new name for "%s":', name)

  local get_destination = function(new_name)
    return parent_path .. utils.path_separator .. new_name
  end

  rename_node(msg, name, get_destination, path, callback)
end

-- Rename Node Base Name
M.rename_node_basename = function(path, callback)
  local parent_path, name = utils.split_path(path)
  local base_name = vim.fn.fnamemodify(path, ":t:r")
  local extension = vim.fn.fnamemodify(path, ":e")

  local msg = string.format('Enter new base name for "%s":', name)

  local get_destination = function(new_base_name)
    return parent_path
      .. utils.path_separator
      .. new_base_name
      .. (extension:len() == 0 and "" or "." .. extension)
  end

  rename_node(msg, base_name, get_destination, path, callback)
end

return M
