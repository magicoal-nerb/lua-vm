--!optimize 2
--!native
--!strict

-- Virtual machine used to run our bytecode
-- magicoal_nerb :^)

local LuaBuffer = require("@lua/Buffer")
local LuaInst = require("@lua/Constants")
local Codegen = require("@lua/Codegen")

local Vm = {}
Vm.__index = Vm

local function createLookup(fmt: string): { number }
	-- creates a lookup table for opcodes
	local memo = {
		abx = 0,
		abc = 1,
		sbx = 2,
	}

	-- gets the length of the opcode table
	local length = 0
	for word in LuaInst do
		length += 1
	end

	-- create final lookup table
	local lookup = table.create(length, 0)
	local word = fmt:gmatch("%w+")
	repeat
		local key = word()
		if not key then
			-- break because there are no keys
			-- left
			break
		end

		local value = word()
		local opcode = assert(LuaInst[value], `could not find opcode '{value}'`)
		lookup[opcode] = memo[key]
	until not key

	return lookup
end

-- todo: optimize the ifs in binary search
-- order so its quicker lol
local VmOpcodes = createLookup([[
	abx vargs abx ret abx closure
	abx getupval abx setupval
	abx forprep abx tforloop
	abx forloop
	abx getglobal abx setglobal
	abx loadnil abx loadk
	abx loadbool
	abx ne abx len
	abx unm abx move
	sbx test sbx jmp
	abc gettablek abc gettable
	abc settable abc settablek
	abc newtable abc setlist
	abc self
	abc call
	abc concat
	abc and abc or
	abc add abc sub
	abc mul abc pow
	abc mod abc div
	abc neq abc eq
	abc addk abc subk
	abc mulk abc powk
	abc modk abc divk
	abc neqk abc eqk
	abc gt abc lt
	abc le abc ge
]])

export type LuaState = { 
	numInstructions: number,
	numVariables: number,
	numUpvalues: number,
	numLabels: number,
	numArgs: number,

	instructions: { number },
	labels: { number },
}

export type Vm = typeof(setmetatable({} :: {
	closures: { LuaState },
	constants: { string | number },
	env: any,
}, Vm))

local function printState(state: LuaState)
	-- debug that prints out all of the
	-- current instructions
	local memo = {}
	for name, value in LuaInst do
		memo[value] = name
	end

	for i, inst in state.instructions do
		local code = bit32.band(inst, 0x3F)
		local flags = VmOpcodes[code]
		if flags == 1 then
			-- this is ABC
			local a = bit32.band(bit32.rshift(inst, 6), 0xFF)
			local b = bit32.band(bit32.rshift(inst, 14), 0x1FF)
			local c = bit32.rshift(inst, 23)

			print(`{memo[code]} {a} {b} {c}`)
		elseif flags == 2 then
			-- this is sBx
			local b = bit32.rshift(inst, 6)
			if bit32.btest(inst, 0x80000000) then
				-- flip b
				b = -bit32.rshift(bit32.band(inst, 0x7FFFFFFF), 6)
			end

			print(`{memo[code]} {b}`)
		else
			-- this is ABx
			local a = bit32.band(bit32.rshift(inst, 6), 0xFF)
			local b = bit32.rshift(inst, 14)

			print(`{memo[code]} {a} {b}`)
		end
	end

	print('\n')
end

export type LuaWrap = () -> ()

function Vm.fromBytecode(raw: buffer, env: any): LuaWrap
	-- runs bytecode
	local data = LuaBuffer.fromBuffer(raw)
	local numConstants = data:readu32()

	local constants = table.create(numConstants, 0) :: { string | number }
	for i = 1, numConstants do
		local typ = data:readu8()
		if typ == 0 then
			-- its a string
			constants[i] = data:readstring()
		elseif typ == 1 then
			-- its a number
			constants[i] = data:readf64()
		else
			error(`invalid constant enum: {typ}`)
		end
	end

	local numClosures = data:readu32()
	local closures = table.create(numClosures, nil) :: { LuaState }
	for i = 1, numClosures do
		local closure = {
			numInstructions = data:readu32(),
			numVariables = data:readu32(),
			numUpvalues = data:readu32(),
			numLabels = data:readu32(),
			numArgs = data:readu32(),
		} :: LuaState

		-- reserve list sizes for instructions and labels
		closure.instructions = table.create(closure.numInstructions, 0)
		closure.labels = table.create(closure.numLabels, 0)

		-- write down labels for debugging
		for j = 1, closure.numLabels do
			closure.labels[j] = data:readu32()
		end

		-- write all of the instructions
		for j = 1, closure.numInstructions do
			closure.instructions[j] = data:readu32()
		end

		closures[i] = closure
	end

	-- send metatable
	local self = setmetatable({
		constants = constants,
		closures = closures,
		env = env,
	}, Vm)

	return self:wrapLuaFunc(closures[1], {})
end

function Vm.fromCodegen(gen: Codegen.Codegen, env: any): LuaWrap
	-- ensure that constants are accurate
	-- also, this is mostly just for debugging purposes
	local constants = {}
	for value, id in gen.constants do
		constants[id] = value
	end

	-- send metatable
	local self = setmetatable({
		constants = constants,
		closures = {},
		env = env,
	}, Vm)

	for i, closure in gen.closures do
		self.closures[i] = {
			-- instructions
			numInstructions = #closure.instructions,

			-- variables and upvalues
			numVariables = closure.numVariables,
			numUpvalues = closure.numUpvalues,
			numArgs = closure.numArgs,

			instructions = closure.instructions,
			labels = {},
		} :: LuaState

		printState(self.closures[i])
	end

	-- Run the first closure(because this is the main entry)
	return self:wrapLuaFunc(self.closures[1], {})
end

export type LuaUpval = {
	-- stack for this upvalue
	stack: { any },

	-- stack id for this upvalue
	ref: number,
}

function Vm.wrapLuaFunc(
	self: Vm,
	state: LuaState,
	upvals: { LuaUpval }
): LuaWrap
	return function(...)
		-- run that function pls
		return self:runLuaFunc(
			state,
			upvals,
			{ ... }
		)
	end
end

function Vm.runLuaFunc(
	self: Vm,
	state: LuaState,

	upvals: { LuaUpval },
	args: { any }
)
	-- environment shenanigans
	local constants = self.constants
	local env = self.env

	-- stack
	local instructions = state.instructions
	local stack = table.create(state.numVariables) :: { any }
	local numArgs = state.numArgs

	-- current vargs list
	local vargs = {}
	table.move(args, numArgs + 1, #args, 1, vargs)
	table.move(args, 1, numArgs, 1, stack)

	local top = -1
	local pc = 1
	while true do
		local inst = instructions[pc]
		local code = bit32.band(inst, 0x3F)
		local flags = VmOpcodes[code]

		if flags == 1 then
			-- this is ABC
			local a = bit32.band(bit32.rshift(inst, 6), 0xFF)
			local b = bit32.band(bit32.rshift(inst, 14), 0x1FF)
			local c = bit32.rshift(inst, 23)

			if code == LuaInst.call then				
				-- call
				if b == 0 then
					-- vargs
					b = top - a
				else
					-- fixed size
					b = b - 1
				end

				local argc = {}
				table.move(stack, a + 1, a + b, 1, argc)

				local ret = { stack[a](table.unpack(argc)) }
				if c == 0 then
					local len = #ret
					top = a + len - 1
					table.move(ret, 1, #ret + 1, a, stack)
				else
					table.move(ret, 1, c - 1, a, stack)
				end
			elseif code == LuaInst.self then
				-- self
				stack[a + 1] = stack[b] -- object
				stack[a] = stack[b][constants[c]] -- method
			elseif code == LuaInst.setlist then
				-- setlist
				local list = stack[a]
				if b == 0 then
					table.move(stack, a + 1, top, 1, list)
				else
					table.move(stack, a + 1, a + b - 1, 1, list)
				end
			elseif code == LuaInst.newtable then
				-- newtable
				stack[a] = table.create(b, 0)
			elseif code == LuaInst.gettable then
				-- gettable
				stack[a] = stack[b][stack[c]]
			elseif code == LuaInst.settable then
				-- settable
				stack[a][stack[b]] = stack[c]
			elseif code == LuaInst.settablek then
				-- settablek
				stack[a][constants[b]] = stack[c]
			elseif code == LuaInst.add then
				-- add
				stack[a] = stack[b] + stack[c]
			elseif code == LuaInst.sub then
				-- sub
				stack[a] = stack[b] - stack[c]
			elseif code == LuaInst.mul then
				-- mul
				stack[a] = stack[b] * stack[c]
			elseif code == LuaInst.div then
				-- div
				stack[a] = stack[b] / stack[c]
			elseif code == LuaInst.mod then
				-- mod
				stack[a] = stack[b] % stack[c]
			elseif code == LuaInst.pow then
				-- pow
				stack[a] = stack[b] ^ stack[c]

			-- logic
			elseif code == LuaInst.eq then
				-- eq
				stack[a] = stack[b] == stack[c]
			elseif code == LuaInst.neq then
				-- neq
				stack[a] = stack[b] ~= stack[c]
			elseif code == LuaInst.lt then
				-- lt
				stack[a] = stack[b] < stack[c]
			elseif code == LuaInst.gt then
				-- gt
				stack[a] = stack[b] > stack[c]
			elseif code == LuaInst.le then
				-- le
				stack[a] = stack[b] <= stack[c]
			elseif code == LuaInst.ge then
				-- ge
				stack[a] = stack[b] >= stack[c]
			elseif code == LuaInst["and"] then
				-- and
				stack[a] = stack[b] and stack[c]
			elseif code == LuaInst["or"] then
				-- or
				stack[a] = stack[b] or stack[c]
			elseif code == LuaInst.concat then
				-- concat
				stack[a] = stack[b] .. stack[c]

			-- constant variants
			elseif code == LuaInst.gettablek then
				-- gettablek
				stack[a] = stack[b][constants[c]]
			elseif code == LuaInst.addk then
				-- addk
				stack[a] = stack[b] + constants[c]
			elseif code == LuaInst.subk then
				-- subk
				stack[a] = stack[b] - constants[c]
			elseif code == LuaInst.mulk then
				-- mulk
				stack[a] = stack[b] * constants[c]
			elseif code == LuaInst.divk then
				-- divk
				stack[a] = stack[b] / constants[c]
			elseif code == LuaInst.modk then
				-- modk
				stack[a] = stack[b] % constants[c]
			elseif code == LuaInst.powk then
				-- powk
				stack[a] = stack[b] ^ constants[c]
			elseif code == LuaInst.eqk then
				-- eqk
				stack[a] = stack[b] == constants[c]
			elseif code == LuaInst.neqk then
				-- neqk
				stack[a] = stack[b] ~= constants[c]
			end
		elseif flags == 2 then
			-- this is sBx
			local b = bit32.rshift(inst, 6)
			if bit32.btest(inst, 0x80000000) then
				-- flip b
				b = -bit32.rshift(bit32.band(inst, 0x7FFFFFFF), 6)
			end
			
			if code == LuaInst.jmp then
				-- jmp
				pc += b
				continue
			elseif code == LuaInst.test then
				-- test
				if stack[b] then
					pc += 1
				end
			end
		else
			-- this is ABx
			local a = bit32.band(bit32.rshift(inst, 6), 0xFF)
			local b = bit32.rshift(inst, 14)

			if code == LuaInst.vargs then
				-- varg
				if b == 0 then
					local len = #vargs
					top = a + len - 1
					table.move(vargs, 1, len, a, stack)
				else
					local len = b - 1
					top = a + len
					table.move(vargs, 1, len, a, stack)
				end
			elseif code == LuaInst.ret then
				-- return
				if b == 0 then
					return table.unpack(stack, a, top)
				else
					return table.unpack(stack, a, a + b - 1)
				end
			elseif code == LuaInst.closure then
				-- closure
				local closure = self.closures[b]
				if b == 0 then
					-- no upvalues
					stack[a] = self:wrapLuaFunc(closure, {})
					pc += 1
					continue
				end

				local retUpvalues = {} :: { LuaUpval }
				for i = 1, closure.numUpvalues do
					local upvInst = instructions[pc + i]
					local upvTyp = bit32.band(upvInst, 0x3F)
					-- local upvA = bit32.band(bit32.rshift(upvInst, 6), 0xFF)
					local upvB = bit32.rshift(upvInst, 14)

					if upvTyp == LuaInst.move then
						-- copy this variable over
						retUpvalues[i] = {
							stack = stack,
							ref = upvB,
						}
					else
						-- its another upvalue somewhere else
						retUpvalues[i] = upvals[upvB]
					end
				end

				stack[a] = self:wrapLuaFunc(closure, retUpvalues)
				pc += closure.numUpvalues
			elseif code == LuaInst.getupval then
				-- getupval
				local upval = upvals[b]
				stack[a] = upval.stack[upval.ref]
			elseif code == LuaInst.setupval then
				-- setupval
				local upval = upvals[a]
				upval.stack[upval.ref] = stack[b]
			elseif code == LuaInst.forprep then
				-- forprep
				local init = assert(tonumber(stack[a]), "for initial gotta be a number")
				local limit = assert(tonumber(stack[a + 1]), "for limit gotta be a number")
				local step = assert(tonumber(stack[a + 2]), "for step gotta be a number")

				-- reinitialize vars pls
				local value = init - step
				stack[a] = value
				stack[a + 1] = limit
				stack[a + 2] = step
				stack[a + 3] = value

				pc += b - 1
			elseif code == LuaInst.tforloop then
				-- tforloop
				local index, value = stack[a](stack[a+1], stack[a+2])
				if index then
					stack[a + 2] = index
					stack[a + 3] = index
					stack[a + 4] = value
					pc -= b + 1
				end
			elseif code == LuaInst.forloop then
				-- forloop
				local limit = stack[a + 1]
				local step = stack[a + 2]
				local value = stack[a] + step

				-- set the variable version
				-- of it too maybe lol
				stack[a + 3] = value
				stack[a] = value

				local shouldJmp = if step >= 0
					then value <= limit
					else value >= limit

				if shouldJmp then
					pc -= b
					continue
				end
			elseif code == LuaInst.getglobal then
				-- getglobal
				stack[a] = env[constants[b]]
			elseif code == LuaInst.loadnil then
				-- loadnil
				for j = a, a + b - 1 do
					stack[j] = nil
				end
			elseif code == LuaInst.setglobal then
				-- setglobal
				env[constants[a]] = stack[b]
			elseif code == LuaInst.loadk then
				-- loadk
				stack[a] = constants[b]
			elseif code == LuaInst.ne then
				-- not
				stack[a] = not stack[b]
			elseif code == LuaInst.len then
				-- len
				stack[a] = #stack[b]
			elseif code == LuaInst.unm then
				-- unm
				stack[a] = -stack[b]
			elseif code == LuaInst.move then
				-- move
				stack[a] = stack[b]
			elseif code == LuaInst.loadbool then
				-- loadbool
				stack[a] = b == 1
			end
		end

		pc += 1
	end
end

return Vm