-- tests/browser_opening_test.lua
-- Test suite for util.open_in_browser() improvements
-- Run with: nvim --headless -c "set rtp+=." -c "luafile tests/browser_opening_test.lua" -c "qa!"

local util = require("markdown_preview.util")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("FAIL: %s\n  expected: %s\n  actual:   %s", msg, tostring(expected), tostring(actual)))
	end
end

local function assert_true(val, msg)
	if not val then
		error(string.format("FAIL: %s\n  expected: truthy\n  actual:   %s", msg, tostring(val)))
	end
end

local function assert_false(val, msg)
	if val then
		error(string.format("FAIL: %s\n  expected: falsy\n  actual:   %s", msg, tostring(val)))
	end
end

local saved = {}

local function mock(fn_name, fn)
	table.insert(saved, { name = fn_name, orig = _G[fn_name] })
	_G[fn_name] = fn
end

local function mock_vim_fn(name, fn)
	table.insert(saved, { name = "vim.fn." .. name, orig = vim.fn[name] })
	vim.fn[name] = fn
end

local function restore_all()
	for i = #saved, 1, -1 do
		local entry = saved[i]
		local name = entry.name
		if name:find("%.") then
			local parts = {}
			for p in name:gmatch("[^.]+") do
				table.insert(parts, p)
			end
			local obj = _G[parts[1]]
			for j = 2, #parts - 1 do
				obj = obj[parts[j]]
			end
			obj[parts[#parts]] = entry.orig
		else
			_G[name] = entry.orig
		end
	end
	saved = {}
end

local function setup_platform(platforms, execs)
	mock_vim_fn("has", function(feature)
		if platforms[feature] then return 1 end
		return 0
	end)
	mock_vim_fn("executable", function(bin)
		if execs and execs[bin] then return 1 end
		return 0
	end)
end

local function run_test(name, func)
	local ok, err = pcall(func)
	if ok then
		print("    PASS: " .. name)
		passed = passed + 1
	else
		print("    FAIL: " .. name)
		print("      " .. tostring(err))
		failed = failed + 1
	end
	restore_all()
end

-- ========================================================================
-- Context: URL notification
-- ========================================================================

local function test_url_notification()
	print("\n  Context: URL notification")

	run_test("vim.notify is always called with the URL", function()
		local notified = {}
		local orig_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notified, { msg = msg, level = level })
		end
		table.insert(saved, { name = "vim.notify", orig = orig_notify })

		setup_platform({ unix = true }, { ["xdg-open"] = true })
		mock_vim_fn("jobstart", function() end)

		util.open_in_browser("http://localhost:8421/")

		assert_eq(#notified, 1, "should have exactly 1 notification")
		assert_eq(notified[1].msg, "Markdown preview: http://localhost:8421/", "notification message")
		assert_eq(notified[1].level, vim.log.levels.INFO, "notification level should be INFO")
	end)
end

-- ========================================================================
-- Context: vim.ui.open fallback (Neovim 0.10+)
-- ========================================================================

local function test_vim_ui_open_fallback()
	print("\n  Context: vim.ui.open fallback (Neovim 0.10+)")

	run_test("vim.ui.open is used as first fallback when no browser override", function()
		local ui_open_called = false
		local ui_open_url = nil
		local orig_ui = vim.ui
		vim.ui = vim.tbl_deep_extend("force", vim.ui or {}, {
			open = function(url)
				ui_open_called = true
				ui_open_url = url
			end,
		})
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		setup_platform({ unix = true }, { ["xdg-open"] = true })
		mock_vim_fn("jobstart", function() end)

		util.open_in_browser("http://localhost:9999/")

		assert_true(ui_open_called, "vim.ui.open should be called")
		assert_eq(ui_open_url, "http://localhost:9999/", "vim.ui.open URL")
	end)

	run_test("vim.ui.open failure falls through to system commands", function()
		local orig_ui = vim.ui
		vim.ui = vim.tbl_deep_extend("force", vim.ui or {}, {
			open = function()
				error("simulated failure")
			end,
		})
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		setup_platform({ unix = true }, { ["xdg-open"] = true })
		local jobstart_called = false
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_called = true
			jobstart_cmd = cmd
		end)

		util.open_in_browser("http://localhost:8421/")

		assert_true(jobstart_called, "jobstart should be called after vim.ui.open fails")
		assert_eq(jobstart_cmd[1], "xdg-open", "should fall back to xdg-open")
	end)

	run_test("vim.ui.open is skipped when browser override is provided", function()
		local ui_open_called = false
		local orig_ui = vim.ui
		vim.ui = vim.tbl_deep_extend("force", vim.ui or {}, {
			open = function()
				ui_open_called = true
			end,
		})
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		setup_platform({ unix = true }, {})
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_cmd = cmd
		end)

		util.open_in_browser("http://localhost:8421/", "firefox")

		assert_false(ui_open_called, "vim.ui.open should NOT be called when browser override is set")
		assert_eq(jobstart_cmd[1], "firefox", "should use browser override directly")
	end)
end

-- ========================================================================
-- Context: Browser override (config.browser)
-- ========================================================================

local function test_browser_override()
	print("\n  Context: Browser override (config.browser)")

	run_test("Browser string override on macOS uses 'open -a'", function()
		setup_platform({ mac = true }, {})
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_cmd = cmd
		end)

		util.open_in_browser("http://localhost:8421/", "Firefox")

		assert_eq(jobstart_cmd[1], "open", "first arg should be 'open'")
		assert_eq(jobstart_cmd[2], "-a", "second arg should be '-a'")
		assert_eq(jobstart_cmd[3], "Firefox", "third arg should be browser name")
		assert_eq(jobstart_cmd[4], "http://localhost:8421/", "fourth arg should be URL")
	end)

	run_test("Browser string override on non-macOS uses direct binary", function()
		setup_platform({ unix = true }, {})
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_cmd = cmd
		end)

		util.open_in_browser("http://localhost:8421/", "firefox")

		assert_eq(jobstart_cmd[1], "firefox", "first arg should be browser binary")
		assert_eq(jobstart_cmd[2], "http://localhost:8421/", "second arg should be URL")
	end)

	run_test("Browser table override passes full command with URL appended", function()
		setup_platform({ unix = true }, {})
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_cmd = cmd
		end)

		util.open_in_browser("http://localhost:8421/", { "google-chrome", "--incognito" })

		assert_eq(#jobstart_cmd, 3, "command should have 3 elements")
		assert_eq(jobstart_cmd[1], "google-chrome", "first arg")
		assert_eq(jobstart_cmd[2], "--incognito", "second arg")
		assert_eq(jobstart_cmd[3], "http://localhost:8421/", "URL appended as last arg")
	end)
end

-- ========================================================================
-- Context: System default browser (no override)
-- ========================================================================

local function test_system_default()
	print("\n  Context: System default browser (no override)")

	run_test("Unix — uses xdg-open when available", function()
		setup_platform({ unix = true }, { ["xdg-open"] = true })
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_cmd = cmd
		end)

		local orig_ui = vim.ui
		vim.ui = {}
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		util.open_in_browser("http://localhost:8421/")

		assert_eq(jobstart_cmd[1], "xdg-open", "should use xdg-open")
		assert_eq(jobstart_cmd[2], "http://localhost:8421/", "URL argument")
	end)

	run_test("Unix — warns when xdg-open is missing", function()
		local notifications = {}
		local orig_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
		table.insert(saved, { name = "vim.notify", orig = orig_notify })

		setup_platform({ unix = true }, { ["xdg-open"] = false })
		local jobstart_called = false
		mock_vim_fn("jobstart", function()
			jobstart_called = true
		end)

		local orig_ui = vim.ui
		vim.ui = {}
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		util.open_in_browser("http://localhost:8421/")

		assert_false(jobstart_called, "jobstart should NOT be called when xdg-open is missing")
		local found_warning = false
		for _, n in ipairs(notifications) do
			if n.level == vim.log.levels.WARN and n.msg:find("xdg%-open") then
				found_warning = true
			end
		end
		assert_true(found_warning, "should warn that xdg-open was not found")
	end)

	run_test("WSL — uses explorer.exe", function()
		setup_platform({ wsl = true }, {})
		local jobstart_cmd = nil
		mock_vim_fn("jobstart", function(cmd)
			jobstart_cmd = cmd
		end)

		local orig_ui = vim.ui
		vim.ui = {}
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		util.open_in_browser("http://localhost:8421/")

		assert_eq(jobstart_cmd[1], "explorer.exe", "should use explorer.exe on WSL")
		assert_eq(jobstart_cmd[2], "http://localhost:8421/", "URL argument")
	end)
end

-- ========================================================================
-- Context: Error handling (on_exit callback)
-- ========================================================================

local function test_error_handling()
	print("\n  Context: Error handling (on_exit callback)")

	run_test("Non-zero exit code triggers warning notification", function()
		local notifications = {}
		local orig_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
		table.insert(saved, { name = "vim.notify", orig = orig_notify })

		setup_platform({ unix = true }, { ["xdg-open"] = true })

		local captured_opts = nil
		mock_vim_fn("jobstart", function(_, opts)
			captured_opts = opts
		end)

		local orig_ui = vim.ui
		vim.ui = {}
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		util.open_in_browser("http://localhost:8421/")

		assert_true(captured_opts ~= nil, "jobstart should be called")
		assert_true(captured_opts.on_exit ~= nil, "on_exit callback should be set")

		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end

		captured_opts.on_exit(nil, 1)

		local found_warning = false
		for _, n in ipairs(notifications) do
			if n.level == vim.log.levels.WARN and n.msg:find("exit code: 1") then
				found_warning = true
			end
		end
		assert_true(found_warning, "should notify warning with exit code")
	end)

	run_test("Zero exit code is silent (no extra notification)", function()
		local warning_count = 0
		local orig_notify = vim.notify
		vim.notify = function(msg, level)
			if level == vim.log.levels.WARN then
				warning_count = warning_count + 1
			end
		end
		table.insert(saved, { name = "vim.notify", orig = orig_notify })

		setup_platform({ unix = true }, { ["xdg-open"] = true })

		local captured_opts = nil
		mock_vim_fn("jobstart", function(_, opts)
			captured_opts = opts
		end)

		local orig_ui = vim.ui
		vim.ui = {}
		table.insert(saved, { name = "vim.ui", orig = orig_ui })

		util.open_in_browser("http://localhost:8421/")

		captured_opts.on_exit(nil, 0)

		assert_eq(warning_count, 0, "should not warn on exit code 0")
	end)
end

-- ========================================================================
-- Main
-- ========================================================================

local function main()
	print("==============================================")
	print("open_in_browser() test suite")
	print("==============================================")

	test_url_notification()
	test_vim_ui_open_fallback()
	test_browser_override()
	test_system_default()
	test_error_handling()

	print("\n==============================================")
	if failed == 0 then
		print(string.format("ALL %d TESTS PASSED", passed))
		print("==============================================")
	else
		print(string.format("%d PASSED, %d FAILED", passed, failed))
		print("==============================================")
		vim.cmd("cq 1")
	end
end

main()
