local config = {
    default_source = "filesystem",
    filesystem = {
        window = {
            position = "left",
            width = 40,
            mappings = {
                ["<cr>"] = "open",
                ["<2-LeftMouse>"] = "open",
                ["<bs>"] = "up",
                ["."] = "set_root",
                ["H"] = "toggle_hidden",
                ["I"] = "toggle_gitignore",
                ["R"] = "refresh",
            }
        },
        filters = {
            show_hidden = false,
            respect_gitignore = true
        },
        bind_to_cwd = true,
        before_render = function(state)

        end,
        functions = {
            icon = function(config, node, state)
                local icon = config.default or " "
                local highlight = config.highlight
                if node.type == "directory" then
                    highlight = "NvimTreeFolderIcon"
                    if node:is_expanded() then
                        icon = config.folder_open or "-"
                    else
                        icon = config.folder_closed or "+"
                    end
                elseif node.type == "file" then
                    local success, web_devicons = pcall(require, 'nvim-web-devicons')
                    if success then
                        devicon, hl = web_devicons.get_icon(node.name, node.ext)
                        icon = devicon or icon
                        highlight = hl or highlight
                    else
                        highlight = "NvimTreeFileIcon"
                    end
                end
                return {
                    text = icon .. config.padding,
                    highlight = highlight
                }
            end,
            name = function(config, node, state)
                return {
                    text = node.name,
                    highlight = config.highlight or "NvimTreeNormal"
                }
            end,
        },
        renderers = {
            directory = {
                {
                    "icon",
                    folder_closed = "",
                    folder_open = "",
                    padding = " ",
                },
                { "name", highlight = "NvimTreeDirectory" }
            },
            file = {
                {
                    "icon",
                    default = "*",
                    padding = " ",
                },
                { "name" }
            }
        }
    }
}
return config
