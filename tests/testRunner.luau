local LuaLuau = require("@lua/")
local fs = require("@lune/fs")

-- runner
local Codegen = LuaLuau.Codegen
local Lexer = LuaLuau.Lexer
local Lua = LuaLuau.Lua
local Vm = LuaLuau.Vm

local env = getfenv()
env._env = env

local function runBytecode(name: string)
	-- this runs bytecode from a file
	local bytecode = fs.readFile(`{name}.out`)
	local data = buffer.fromstring(bytecode)
	return Vm.fromBytecode(data, env)()
end

local function runSource(src: string)
	local lex = Lexer.new(src)
	local root = Lua.parse(lex)

	-- generate bytecode
	local gen = Codegen.new(root)
	local bytecode = gen:emitBytecode()
	return Vm.fromBytecode(bytecode, env)()
end

local function runScript(name: string)
	-- create a lexer and a parser
	local src: string = fs.readFile(name)
	local lex = Lexer.new(src)
	local root = Lua.parse(lex)
	assert(lex:eof(), "could not properly parse script :c")

	-- generate bytecode
	local gen = Codegen.new(root)
	local bytecode = gen:emitBytecode()
	fs.writeFile(`{name}.out`, bytecode)
	return Vm.fromBytecode(bytecode, env)()
end

-- run the tests
runScript("tests/testez.lua")(env)
runScript("tests/cases.lua")
runScript("tests/mergesort.lua")
runScript("tests/priorityqueue.lua")