local pickers = require "telescope.pickers"
local previewers = require "telescope.previewers"
local finders = require "telescope.finders"
local conf = require"telescope.config".values
local putils = require "telescope.previewers.utils"
local entry_display = require "telescope.pickers.entry_display"
local action_state = require "telescope.actions.state"
local actions = require "telescope.actions"
local utils = require "telescope.utils"
local strings = require "plenary.strings"

local function get_root(opts)
    return utils.get_os_command_output({'hg', 'root'}, opts.cwd)[1] .. '/'
end

local M = {};

M.logthis = function(opts)
    opts = opts or {}
    opts.current_file = vim.F.if_nil(opts.current_file, vim.fn.expand "%:p")
    opts.entry_maker = function(entry)
        if entry == "" then return nil end

        entry = entry:gsub("^[^%d]+", "")
        local rev, msg, by = string.match(entry, "%s*(%d+)%s+(.+)(%([^%(]+%))$")

        if not msg then
            rev = entry
            msg = "<empty commit message>"
        end

        local displayer = entry_display.create {
            separator = " ",
            items = {{width = 5}, {remaining = true}, {remaining = true}}
        }

        return {
            value = rev,
            ordinal = rev .. " " .. msg .. " " .. by,
            msg = msg,
            by = by,
            display = function(_entry)
                return displayer {
                    {_entry.value, "TelescopeResultsIdentifier"}, _entry.msg,
                    {_entry.by, "TelescopeResultsSpecialComment"}
                }
            end,
            current_file = opts.current_file
        }
    end

    local command = {
        "hg", "log",
        '--template={rev} {if(tags,\'[{tags}] \')}{desc|strip|firstline} ({author|user} {date|age})\n',
        opts.current_file
    }

    pickers.new(opts, {
        prompt_title = "Commits",
        finder = finders.new_oneshot_job(command, opts),
        previewer = {
            previewers.new_buffer_previewer {
                title = 'hg diff',
                define_preview = function(self, entry)
                    local cmd = {
                        "hg", "diff", "-c", entry.value, opts.current_file
                    }
                    putils.job_maker(cmd, self.state.bufnr, {
                        value = entry.value,
                        bufname = self.state.bufname,
                        cwd = opts.cwd
                    })
                    putils.regex_highlighter(self.state.bufnr, "diff")
                end
            }
        },
        sorter = conf.file_sorter(opts),
        attach_mappings = function(_, map)
            local get_buffer_of_orig = function(selection)
                local content = utils.get_os_command_output({
                    "hg", "cat", "-r", selection.value, selection.current_file
                }, opts.cwd)
                local bufnr = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
                vim.api.nvim_buf_set_name(bufnr, "Original")
                return bufnr
            end

            local vimdiff = function(selection, cmd)
                local ft = vim.bo.filetype
                vim.cmd "diffthis"

                local bufnr = get_buffer_of_orig(selection)
                vim.cmd(string.format("%s %s", cmd, bufnr))
                vim.bo.filetype = ft
                vim.cmd "diffthis"

                vim.cmd(string.format(
                            "autocmd WinClosed <buffer=%s> ++nested ++once :lua vim.api.nvim_buf_delete(%s, { force = true })",
                            bufnr, bufnr))
            end

            actions.select_default:replace(
                function(prompt_bufnr)
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    print(selection.current_file)
                    vimdiff(selection, "leftabove vert sbuffer")
                end)

            local function revert(prompt_bufnr)
                local cwd = action_state.get_current_picker(prompt_bufnr).cwd
                local selection = action_state.get_selected_entry()
                if selection == nil then
                    print "[telescope] Nothing currently selected"
                    return
                end
                actions.close(prompt_bufnr)
                print('revert to rev ' .. selection.value)
                utils.get_os_command_output({
                    "hg", "revert", '-r', selection.value,
                    selection.current_file
                }, cwd)
            end

            map("i", "<c-r>", revert)
            map("n", "<c-r>", revert)

            return true
        end
    }):find()
end

local function entry_get_rev(entry)
    if entry == nil then return nil end
    if entry.rev ~= nil then return entry.rev end
    if entry[1] == nil then return nil end
    local line = entry[1]:gsub("^[^%d]+", "")
    if line == "" then return nil end
    local rev = string.match(line, "(%d+) (.+)")
    return rev
end

local checkout = function(prompt_bufnr)
    local cwd = action_state.get_current_picker(prompt_bufnr).cwd
    local selection = action_state.get_selected_entry()
    if selection == nil then
        actions.close(prompt_bufnr)
        print "[telescope] Nothing currently selected"
        return
    end
    local rev = entry_get_rev(selection)
    if rev == nil then
        actions.close(prompt_bufnr)
        print "no rev found"
        return
    end
    actions.close(prompt_bufnr)
    print('checkout rev ' .. rev)
    local msg, ret, stderr = utils.get_os_command_output({
        "hg", "checkout", '-r', rev
    }, cwd)
    if ret == 0 then
        print(msg[1])
    else
        print(string.format('Error when checking out: %s. Returned: "%s"', rev,
                            table.concat(stderr, "  ")))
    end
end

local highlight_glog = function(line)
    local highlights = {}
    local hstart, hend = line:find "%d+"
    if hstart then
        if hend < #line then
            table.insert(highlights,
                         {{hstart - 1, hend}, "TelescopeResultsIdentifier"});
        end
    end
    -- local _, cstart = line:find "%d+%s+"
    -- if cstart then
    --     local cend = line:find " %([^%)]+%)$"
    --     if cend then
    --         table.insert(highlights,
    --                      {{cstart - 1, cend - 1}, "TelescopeResultsConstant"});
    --     end
    -- end
    local dstart, _ = line:find " %([^%)]+%)$"
    if dstart then
        table.insert(highlights,
                     {{dstart, #line}, "TelescopeResultsSpecialComment"});
    end
    return highlights
end

M.log = function(opts)
    opts = opts or {}
    local command = {
        "hg", "log", "-G",
        '--template={rev} {if(tags,\'[{tags}] \')}{desc|strip|firstline} ({author|user} {date|age})\n'
    }
    opts.entry_maker = function(entry)
        local rev = string.match(entry, "(%d+) (.+)")
        return {
            value = entry,
            ordinal = entry,
            rev = rev,
            display = function(self)
                return self.value, highlight_glog(self.value)
            end
        }
    end

    pickers.new(opts, {
        prompt_title = "Commits",
        finder = finders.new_oneshot_job(command, opts),
        previewer = {
            previewers.new_buffer_previewer {
                title = 'hg diff',
                define_preview = function(self, entry)
                    local rev = entry_get_rev(entry)
                    if rev == nil then return end
                    local cmd = {"hg", "diff", "-c", rev}
                    putils.job_maker(cmd, self.state.bufnr, {
                        value = rev,
                        bufname = self.state.bufname,
                        cwd = opts.cwd
                    })
                    putils.regex_highlighter(self.state.bufnr, "diff")
                end
            }
        },
        sorter = conf.file_sorter(opts),
        attach_mappings = function()
            actions.select_default:replace(checkout)
            return true
        end
    }):find()
end

local hightlightlog = function(bufnr, content)
    local ns_previewer = vim.api.nvim_create_namespace "telescope.previewers"
    for i = 1, #content do
        local line = content[i]
        local hstart, hend = line:find "%d+"
        if hstart then
            if hend < #line then
                vim.api.nvim_buf_add_highlight(bufnr, ns_previewer,
                                               "TelescopeResultsIdentifier",
                                               i - 1, hstart - 1, hend)
            end
        end
        local _, cstart = line:find "%d+%s*-%s*"
        if cstart then
            local cend = string.find(line, "%(")
            if cend then
                vim.api.nvim_buf_add_highlight(bufnr, ns_previewer,
                                               "TelescopeResultsConstant",
                                               i - 1, cstart - 1, cend - 1)
            end
        end
        local dstart, _ = line:find " %(%d"
        if dstart then
            vim.api.nvim_buf_add_highlight(bufnr, ns_previewer,
                                           "TelescopeResultsSpecialComment",
                                           i - 1, dstart, #line)
        end
    end
end

M.branches = function(opts)
    opts = opts or {}
    local command = {
        "hg", "branches",
        '--template=\'{branch}\'\'{date|isodate}\'\'{date(date, \'%Y-%m-%d %H:%M\')}\'\'{rev}\'\'{node|short}\'\'{graphnode}\'\'{user|person}\'\n'
    }
    local output = utils.get_os_command_output(command, opts.cwd)
    local results = {}
    local widths = {branch = 0}
    for _, line in ipairs(output) do
        local a = vim.split(string.sub(line, 2, -2), "''", true)
        local entry = {
            branch = a[1],
            isodate = a[2],
            date = a[3],
            rev = a[4],
            node = a[5],
            current = a[6] == '@',
            user = a[7]
        }
        for key, value in pairs(widths) do
            widths[key] = math.max(value,
                                   strings.strdisplaywidth(entry[key] or ""))
        end
        table.insert(results, #results + 1, entry)
    end
    if #results == 0 then return end
    table.sort(results, function(a, b) return a.isodate > b.isodate end)
    local displayer = entry_display.create {
        separator = " ",
        items = {{width = widths.branch + 4}, {remaining = true}}
    }
    local make_display = function(entry)
        local current = ""
        if entry.current then current = "@ " end
        return displayer {
            {current .. entry.branch, "TelescopeResultsIdentifier"},
            {entry.date}
        }
    end
    pickers.new(opts, {
        prompt_title = "Branches",
        finder = finders.new_table {
            results = results,
            entry_maker = function(entry)
                entry.value = entry.branch
                entry.ordinal = entry.branch
                entry.display = make_display
                return entry
            end
        },
        previewer = {
            previewers.new_buffer_previewer {
                title = 'hg log',
                define_preview = function(self, entry)
                    if entry.branch == nil then return end
                    local cmd = {
                        "hg", "log",
                        '--template={rev} - {if(tags,\'[{tags}] \')}{desc|strip|firstline} ({author|user} {date|age})\n',
                        '-b', entry.branch
                    }
                    putils.job_maker(cmd, self.state.bufnr, {
                        value = entry.branch,
                        bufname = self.state.bufname,
                        cwd = opts.cwd,
                        callback = function(bufnr, content)
                            if not content then
                                return
                            end
                            hightlightlog(bufnr, content)
                        end
                    })
                end
            }
        },
        sorter = conf.file_sorter(opts),
        attach_mappings = function()
            actions.select_default:replace(checkout)
            return true
        end

    }):find()
end

M.status = function(opts)
    opts = opts or {}
    local root = get_root(opts)
    local command = {"hg", "status"}
    local output = utils.get_os_command_output(command, opts.cwd)
    local displayer = entry_display.create {
        separator = " ",
        items = {{width = 3}, {remaining = true}}
    }
    pickers.new(opts, {
        prompt_title = "status",
        finder = finders.new_table {
            results = output,
            entry_maker = function(entry)
                if entry == "" then return nil end
                local status, file = string.match(entry, "(.) (.*)")
                return {
                    status = status,
                    value = root .. file,
                    file = file,
                    ordinal = status .. " " .. file,
                    root = root .. '/',
                    display = function(_entry)
                        return displayer {
                            {_entry.status},
                            {_entry.file, "TelescopeResultsIdentifier"}
                        }
                    end
                }
            end
        },
        previewer = {
            previewers.new_buffer_previewer {
                title = 'hg diff',
                define_preview = function(self, entry)
                    if entry.status == '?' then
                        conf.buffer_previewer_maker(root .. entry.file,
                                                    self.state.bufnr, {
                            bufname = self.state.bufname,
                            winid = self.state.winid,
                            preview = opts.preview
                        })
                        return
                    end
                    local cmd = {"hg", "diff", root .. entry.file}
                    putils.job_maker(cmd, self.state.bufnr, {
                        value = entry.value,
                        bufname = self.state.bufname,
                        cwd = opts.cwd
                    })
                    putils.regex_highlighter(self.state.bufnr, "diff")
                end
            }
        },
        sorter = conf.file_sorter(opts)
    }):find()
end

M.files = function(opts)
    opts = opts or {}
    local show_untracked = utils.get_default(opts.show_untracked, true)

    local results = utils.get_os_command_output({'hg', 'files'}, opts.cwd)
    if show_untracked then
        local untracked = utils.get_os_command_output({'hg', 'status', '-u'},
                                                      opts.cwd)
        if untracked ~= nil and #untracked ~= 0 then
            for k, v in pairs(untracked) do
                v = v:gsub("^%s*?%s*", "")
                table.insert(results, #results + 1, v)
            end
        end
    end
    if #results == 0 then return end

    pickers.new(opts, {
        prompt_title = "Hg Files",
        finder = finders.new_table {
            results = results,
            entry_maker = require'telescope.make_entry'.gen_from_file(opts)
        },
        previewer = conf.file_previewer(opts),
        sorter = conf.file_sorter(opts)
    }):find()
end
return M
