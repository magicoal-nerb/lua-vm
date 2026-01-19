--!strict

-- Used to compile bytecode from the AST
-- magicoal_nerb :D

local LuaBuffer = require("@lua/Buffer")
local LuaInst = require("@lua/Constants")
local Lua = require("@lua/Lua")

local Codegen = {}
Codegen.__index = Codegen

-- generic lua type
export type Type = Lua.Type

-- basic scope
export type Scope = {
	-- variables
	variables: { [string]: number },

	-- current variable pointer
	numVariables: number,
}

export type Closure = {
	-- id
	id: number,

	-- variables in the scope
	variables: { [string]: number },

	-- num args
	numArgs: number,

	-- num variables
	numVariables: number,

	-- num upvalues
	numUpvalues: number,

	-- num labels
	numLabels: number,

	-- labels in the closure(usually just line number)
	labels: { number },

	-- upvalues used in the scope
	upvalues: { string },

	-- helper field to prevent potential logn
	numInstructions: number,

	-- current instructions
	instructions: { number },

	-- current upvalue pointer
	pointer: number,

	-- closure parent
	parent: Closure?,
}

-- class that generates bytecode
export type Codegen = typeof(setmetatable({} :: {	
	-- scope stack
	scopes: { Scope },

	-- closure stack
	closures: { Closure },

	-- current closure
	closure: Closure,

	-- jump stack
	jumps: { number },

	-- helper field to prevent potential logn
	numConstants: number,

	-- helper field to prevent potential logn
	numInstructions: number,

	-- current instructions
	instructions: { number },

	-- constants
	constants: { [any]: number },
}, Codegen))

local function hasVariadicUnpack(expr: Lua.Statement): boolean
	-- checks if an expression can have multiple
	-- return values
	return expr and (expr.type == "call" or expr.type == "methodcall" or expr.type == "variadic")
end

function Codegen.new(block: Lua.Block): Codegen
	local closure = {
		id = 1,
		numArgs = 0,
		
		numLabels = 0,
		labels = {},

		numUpvalues = 0,
		upvalues = {},

		numVariables = 0,
		variables = {},

		numInstructions = 0,
		instructions = {},
	} :: Closure

	local self = setmetatable({
		-- closure
		closures = { closure },
		closure = closure,

		-- scope
		scopes = { },

		-- instructions
		numInstructions = 0,
		instructions = closure.instructions,

		-- jmp
		jumps = {},

		-- constants
		numConstants = 0,
		constants = {},
	}, Codegen) :: Codegen
	
	self:visitBlock(block)
	return self
end

function Codegen.pushClosure(self: Codegen): Closure
	local parent = self.closure
	parent.numInstructions = self.numInstructions

	self.closure = {
		id = #self.closures + 1,
		numArgs = 0,
		
		numLabels = 0,
		labels = {},

		numUpvalues = 0,
		upvalues = {},

		numVariables = 0,
		variables = {},

		numInstructions = 0,
		instructions = {},
		parent = self.closure,
	} :: Closure

	table.insert(self.closures, self.closure)

	-- Load state
	self.instructions = self.closure.instructions
	self.numInstructions = 0

	return self.closure
end

function Codegen.popClosure(self: Codegen)
	local closure = self.closure
	closure.numInstructions = self.numInstructions

	-- check if parent exists
	local parent = closure.parent :: Closure
	assert(parent)

	-- load state
	self.numInstructions = parent.numInstructions
	self.instructions = parent.instructions
	self.closure = parent
end

function Codegen.pushScope(self: Codegen)
	-- copy the scopes and just put into
	-- the scope stack
	local closure = self.closure
	table.insert(self.scopes, {
		variables = table.clone(closure.variables),
		numVariables = closure.numVariables,
	})
end

function Codegen.popScope(self: Codegen)
	-- reverts the scope to its
	-- previous variables
	local pop = table.remove(self.scopes) :: Scope
	local closure = self.closure

	closure.numVariables = pop.numVariables
	closure.variables = pop.variables
end

function Codegen.addVariable(
	self: Codegen,
	name: string?,
	register: number
)
	-- adds a variable to the current scope
	if name then
		self.closure.variables[name] = register
	end

	self.closure.numVariables = math.max(
		self.closure.numVariables,
		register + 1
	)
end

function Codegen.getInstPtr(self: Codegen): number
	-- gets the instruction pointer
	return self.numInstructions + 1
end

function Codegen.emitConstant(self: Codegen, constant: any): number
	-- attempts to create a constant
	local num = self.constants[constant]
	if num then
		return num
	end

	self.numConstants += 1
	self.constants[constant] = self.numConstants
	return self.numConstants
end

function Codegen.patchJmps(
	self: Codegen,
	from: number,

	start: number,
	finish: number
)
	-- sets dangling jmps(breaks rn)
	-- to the end of the scope
	local jmps = self.jumps
	for i = #jmps, from + 1, -1 do
		-- Remove the jmps at a time
		local jmp = table.remove(jmps) :: number
		if jmp > 0 then
			-- if it is positive, it's a break
			self:setSbx(jmp, finish - jmp)
		else
			-- if it is negative, it's a continue
			self:setSbx(-jmp, start + jmp)
		end
	end
end

function Codegen.setABC(
	self: Codegen,
	ptr: number,
	a: number,
	b: number,
	c: number
): number
	-- arguments a, b, c exist and are
	-- unsigned	
	self.instructions[ptr] = bit32.lshift(c, 23)
		+ bit32.lshift(b, 14)
		+ bit32.lshift(a, 6)
		+ bit32.band(self.instructions[ptr], 0x3F)
	return a
end

function Codegen.setABx(
	self: Codegen,
	ptr: number,
	a: number,
	b: number
): number
	-- only arguments a and b exist and are
	-- unsigned
	self.instructions[ptr] = bit32.lshift(b, 14)
		+ bit32.lshift(a, 6)
		+ bit32.band(self.instructions[ptr], 0x3F)
	return a
end

function Codegen.setSbx(
	self: Codegen,
	ptr: number,
	b: number
)
	if b < 0 then
		-- b is negative so flip the
		-- sign bit
		self.instructions[ptr] = bit32.lshift(-b, 6)
			+ 0x80000000
			+ bit32.band(self.instructions[ptr], 0x3F)
	else
		-- b is positive, don't do anything
		self.instructions[ptr] = bit32.lshift(b, 6)
			+ bit32.band(self.instructions[ptr], 0x3F)
	end
end

function Codegen.emitABC(
	self: Codegen,
	inst: number,
	a: number,
	b: number,
	c: number
): number
	-- arguments a, b, c exist and are
	-- unsigned
	local output = bit32.lshift(c, 23)
		+ bit32.lshift(b, 14)
		+ bit32.lshift(a, 6)
		+ inst
	
	self.numInstructions += 1
	table.insert(self.instructions, output)
	return a
end

function Codegen.emitSbx(
	self: Codegen,
	inst: number,
	b: number
)
	if b < 0 then
		-- b is negative so flip the
		-- sign bit
		local output = bit32.lshift(-b, 6)
			+ 0x80000000
			+ inst

		self.numInstructions += 1
		table.insert(self.instructions, output)
	else
		-- b is positive, don't do anything
		local output = bit32.lshift(b, 6)
			+ inst

		self.numInstructions += 1
		table.insert(self.instructions, output)
	end
end

function Codegen.emitABx(
	self: Codegen,
	inst: number,
	a: number,
	b: number
): number
	-- only arguments a and b exist and are
	-- unsigned
	local output = bit32.lshift(b, 14)
		+ bit32.lshift(a, 6)
		+ inst

	self.numInstructions += 1
	table.insert(self.instructions, output)
	return a
end

local LuaVarType = {
	global = 1,
	upvalue = 2,
	stack = 3,
}

export type LValue = {
	type: number,
	id: number,
}

function Codegen.analyzeVariable(
	self: Codegen,
	name: string
): LValue
	local closure = self.closure

	local id = closure.variables[name]
	
	-- todo: respect upvalues too
	if id then
		-- its on the stack
		return {
			type = LuaVarType.stack,
			id = id,
		}
	end

	local uid = table.find(closure.upvalues, name)
	if uid then
		-- there is an id for this upvalue here
		return {
			type = LuaVarType.upvalue,
			id = uid,
		}
	end

	local parent = closure.parent
	while parent do
		if not parent.variables[name] then
			parent = parent.parent
			continue
		end

		-- add this to the upvalue list
		table.insert(closure.upvalues, name)
		closure.numUpvalues += 1

		return {
			type = LuaVarType.upvalue,
			id = closure.numUpvalues
		}
	end

	-- this is a global
	local constant = self:emitConstant(name)
	return {
		type = LuaVarType.global,
		id = constant,
	}
end

function Codegen.visitConstant(
	self: Codegen,
	expr: Lua.BasicExpr,
	where: number
): number
	local t = typeof(expr.value)	
	if t == "nil" then
		-- nil
		return self:emitABx(LuaInst.loadnil, where, 1)
	elseif t == "boolean" then
		-- boolean
		return self:emitABx(LuaInst.loadbool, where, expr.value and 1 or 0)
	else
		-- other type of constant like a number or string
		local id = self:emitConstant(expr.value)
		return self:emitABx(LuaInst.loadk, where, id)
	end
end

function Codegen.visitVariable(
	self: Codegen,
	expr: Lua.BasicExpr,
	where: number
): number
	local lvalue = self:analyzeVariable(expr.value)
	if lvalue.type == LuaVarType.stack then
		-- it's a stack variable... so have to do something to it?
		return lvalue.id
	elseif lvalue.type == LuaVarType.global then
		-- global
		return self:emitABx(
			LuaInst.getglobal,
			where,
			lvalue.id
		)
	elseif lvalue.type == LuaVarType.upvalue then
		-- upvalue
		return self:emitABx(
			LuaInst.getupval,
			where,
			lvalue.id
		)
	end
	
	error("invalid variable type :c")
end

function Codegen.visitDot(
	self: Codegen,
	expr: Lua.Expr,
	where: number
): number
	local left = self:visit(expr.left :: Lua.BasicExpr, where + 1)
	
	local right = expr.right :: Lua.BasicExpr
	if right.type == "constant" then
		-- slightly more optimized version through
		-- using a constant
		local id = self:emitConstant(right.value)
		return self:emitABC(
			LuaInst.gettablek,
			where,
			left,
			id
		)
	else
		return self:emitABC(
			LuaInst.gettable,
			where,
			left,
			self:visit(expr.right :: Lua.BasicExpr, where + 2) :: number
		)
	end
end

local LuaOperatorsConstant = {
	-- constant versions of certain
	-- binary operations
	["+"] = LuaInst["addk"],
	["-"] = LuaInst["subk"],
	["*"] = LuaInst["mulk"],
	["^"] = LuaInst["powk"],
	["%"] = LuaInst["modk"],
	["/"] = LuaInst["divk"],

	["=="] = LuaInst["eqk"],
	["~="] = LuaInst["neqk"],
}

local LuaOperators = {
	-- normal versions of binary operators
	-- good for general case
	["+"] = LuaInst["add"],
	["-"] = LuaInst["sub"],
	["*"] = LuaInst["mul"],
	["^"] = LuaInst["pow"],
	["%"] = LuaInst["mod"],
	["/"] = LuaInst["div"],

	["<"] = LuaInst["lt"],
	["<="] = LuaInst["le"],
	[">"] = LuaInst["gt"],
	[">="] = LuaInst["ge"],
	["=="] = LuaInst["eq"],
	["~="] = LuaInst["neq"],

	[".."] = LuaInst["concat"],

	["and"] = LuaInst["and"],
	["or"] = LuaInst["or"],
}

function Codegen.visitCompound(
	self: Codegen,
	expr: Lua.CompoundStmt,
	where: number
)
	local right = (expr.right :: Lua.BasicExpr)
	local left = (expr.left :: Lua.BasicExpr)

	local operator = (expr :: any).operator:sub(1, 1)
	if left.type == "index" then
		-- Index the left side
		local object = self:visit(left.left, where + 1)
		local indexer = left.right

		if indexer.type == "constant" then
			-- Get from constant variable
			self:emitABC(
				LuaInst.gettablek,
				where,
				object,
				self:emitConstant(indexer.value)
			)
		else
			-- Get from expression
			self:emitABC(
				LuaInst.gettable,
				where,
				object,
				self:visit(right, where + 2)
			)
		end

		-- Then, we do our operation
		if right.type == "constant" and LuaOperatorsConstant[operator] then
			-- Get the constant variant of the operator
			self:emitABC(
				LuaOperatorsConstant[operator],
				where,
				where,
				self:emitConstant(right.value)
			)
		else
			-- Otherwise, no need to
			self:emitABC(
				LuaOperators[operator],
				where,
				where,
				self:visit(right :: Lua.BasicExpr, where + 2) :: number
			)
		end

		if indexer.type == "constant" then
			-- Set from constant variable
			self:emitABC(
				LuaInst.settablek,
				object,
				self:emitConstant(indexer.value),
				where
			)
		else
			-- Get from expression
			self:emitABC(
				LuaInst.settable,
				object,
				self:visit(indexer, where + 2),
				where
			)
		end
	else
		-- Default case where we don't need to worry
		-- about side effects
		local obj = self:visit(left, where + 1)
		if right.type == "constant" and LuaOperatorsConstant[operator] then
			-- Get the constant variant of the operator
			self:emitABC(
				LuaOperatorsConstant[operator],
				where,
				obj,
				self:emitConstant(right.value)
			)
		else
			-- Otherwise, no need to
			self:emitABC(
				LuaOperators[operator],
				where,
				obj,
				self:visit(right :: Lua.BasicExpr, where + 2) :: number
			)
		end

		self:emitABx(
			LuaInst.move,
			obj,
			where
		)
	end
end

function Codegen.visitOperator(
	self: Codegen,
	expr: Lua.Expr,
	where: number
): number
	local right = (expr.right :: Lua.BasicExpr)
	local left = (expr.left :: Lua.BasicExpr)
	
	local operator = (expr :: any).operator
	if right.type == "constant" and LuaOperatorsConstant[operator] then
		-- Get the constant variant of the operator
		return self:emitABC(
			LuaOperatorsConstant[operator],
			where,
			self:visit(left, where + 1),
			self:emitConstant(right.value)
		)
	else
		-- Otherwise, no need to
		local op = LuaOperators[operator]
		return self:emitABC(
			op,
			where,
			self:visit(left, where + 1),
			self:visit(right :: Lua.BasicExpr, where + 2) :: number
		)
	end
end

function Codegen.visitMethodCall(
	self: Codegen,
	stmt: Lua.MethodExpr,
	where: number,
	ret: number?
): number
	local object = self:visit(stmt.left :: Lua.Expression, where)
	local method = self:emitConstant((stmt.right :: Lua.BasicExpr).value)
	self:emitABC(LuaInst.self, where, object, method)

	-- read the assignment and go
	-- add 1 because we are adding self now
	local length = #stmt.args + 1
	for i, stmt in stmt.args do
		self:visitMove(stmt, where + i + 1)
	end

	if 1 < length and hasVariadicUnpack(stmt.args[length - 1]) then
		-- then it could be a tuple passed in so
		-- beware
		return self:emitABC(
			LuaInst.call,
			where,
			0,
			ret or 0
		)
	else
		-- we have a fixed length because it didnt
		-- end with a function call
		return self:emitABC(
			LuaInst.call,
			where,
			length + 1,
			ret or 0
		)
	end
end

function Codegen.visitCall(
	self: Codegen,
	expr: Lua.Expr,
	where: number,
	ret: number?
): number
	self:visitMove(expr.left :: Lua.BasicExpr, where)
	
	-- read the assignment and go
	local right = expr.right :: any -- Lua.Explist
	self:visitTempExprList(right, 0, where + 1)

	local length = #right
	if 0 < length and hasVariadicUnpack(right[length]) then
		-- then it could be a tuple passed in so
		-- beware
		return self:emitABC(
			LuaInst.call,
			where,
			0,
			ret or 0
		)
	else
		-- we have a fixed length because it didnt
		-- end with a function call
		return self:emitABC(
			LuaInst.call,
			where,
			length + 1,
			ret or 0
		)
	end
end

function Codegen.visitExprTemp(
	self: Codegen,
	expr: Lua.Expression,
	where: number,
	count: number
)
	if expr.type == "call" then
		-- its a call, deduce the number of
		-- returns we need for this
		self:visitCall(expr :: Lua.Expr, where, count)
	elseif expr.type == "methodcall" then
		-- its a call, deduce the number of
		-- returns we need for this
		self:visitMethodCall(expr :: Lua.MethodExpr, where, count)
	elseif expr.type == "variadic" then
		-- its a variadic so yeah
		self:emitABx(LuaInst.vargs, where, count)
	else
		-- Found an rvalue, increment the pointer
		self:visitMove(expr, where)
	end
end

function Codegen.visitTempExprList(
	self: Codegen,
	exps: { Lua.Expression },
	numVars: number,
	where: number,
	allocRegs: number?
): number
	-- visits an expression list
	-- and ensures that it follows the numvars
	-- rule
	local numExps = #exps
	if numExps == 0 then
		return self:emitABx(LuaInst.loadnil, where, numVars)
	end

	for i = 1, numExps - 1 do
		self:visitExprTemp(
			exps[i],
			where + i - 1,
			2
		)
	end

	local lastExpr = exps[numExps]
	self:visitExprTemp(
		lastExpr,
		where + numExps - 1,
		allocRegs and (numExps - allocRegs) + 1 or 0 
	)

	if numVars > numExps and not hasVariadicUnpack(lastExpr) then
		-- make sure that we fill this
		-- with nils so vargs don't overflow
		self:emitABx(LuaInst.loadnil, where + numExps, numVars - numExps)
	end

	return where + math.max(numExps, numVars)
end

function Codegen.visitLocalVar(
	self: Codegen,
	expr: Lua.LocalVarStmt,
	where: number
)
	-- A more optimized version of an assignment
	-- because it's just a local lol
	local namelist = expr.namelist
	self:visitTempExprList(
		expr.explist,
		#namelist,
		where
	)

	for i, name in namelist do
		-- Create a variable within the specified register
		local register = where + i - 1
		self:addVariable(name, register)
	end
end

function Codegen.emitSet(
	self: Codegen,
	lvalue: Lua.Expression,
	where: number,
	temp: number
): number
	if lvalue.type == "index" then
		-- we can emit the custom
		-- set table instruction		
		-- table portion
		local res = lvalue :: Lua.Expr

		local rhs = res.right :: Lua.BasicExpr
		local lhs = self:visit(
			res.left :: Lua.BasicExpr,
			temp
		)

		if rhs.type == "constant" then
			-- slightly more optimized version through
			-- using a constant
			return self:emitABC(
				LuaInst.settablek,
				lhs,
				self:emitConstant(rhs.value),
				where
			)
		else
			-- Default settable
			return self:emitABC(
				LuaInst.settable,
				lhs,
				self:visit(rhs, temp + 1),
				where
			)
		end
	elseif lvalue.type == "variable" then
		-- we can emit a move
		local var = self:analyzeVariable((lvalue :: Lua.BasicExpr).value)
		if var.type == LuaVarType.stack then
			-- its a stack variable, so move is the best option here
			return self:emitABx(LuaInst.move, var.id, where)
		elseif var.type == LuaVarType.global then
			-- its a global variable, so setglobal is the best option here
			return self:emitABx(LuaInst.setglobal, var.id, where)
		elseif var.type == LuaVarType.upvalue then
			-- its an upvalue, so setupvalue is the best option here
			return self:emitABx(LuaInst.setupval, var.id, where)
		end
	end

	error(`codegen cannot generate bytecode for emitSet!!`)
	return -1
end

function Codegen.visitAssignment(
	self: Codegen,
	expr: Lua.AssignStmt,
	where: number
): number
	-- first pass, just compile the right hand
	-- side lol
	local temp = self:visitTempExprList(
		expr.explist,
		#expr.varlist,
		where
	)

	for i, pair in expr.varlist do
		self:emitSet(
			pair,
			where + i - 1,
			temp + i - 1
		)
	end

	return where
end

function Codegen.visitTable(
	self: Codegen,
	expr: Lua.TableExpr,
	where: number
): number
	-- create the table
	self:emitABC(
		LuaInst.newtable,
		where,
		#expr.list,
		#expr.records
	)

	-- put down records here
	for i, field in expr.records do
		local index = field.index :: Lua.BasicExpr
		local value = field.value :: Lua.BasicExpr
		if index.type == "constant" then
			-- Slightly more optimized version through
			-- using a constant
			self:emitABC(
				LuaInst.settablek,
				where,
				self:emitConstant(index.value),
				self:visit(value, where + 2)
			)
		else
			-- Default settable
			self:emitABC(
				LuaInst.settable,
				where,
				self:visit(index, where + 1),
				self:visit(value, where + 2)
			)
		end
	end

	-- put down the array component
	local counter = #expr.list
	self:visitTempExprList(
		expr.list,
		counter,
		where + 1
	)

	-- for i, field in expr.list do
	-- 	self:visit(field.value, where + i)
	-- end

	if counter == 0 then
		return where
	elseif hasVariadicUnpack(expr.list[counter]) then
		-- set down list components
		return self:emitABC(
			LuaInst.setlist,
			where,
			0,
			where + 1
		)
	else
		-- set down list components
		return self:emitABC(
			LuaInst.setlist,
			where,
			counter + 1,
			where + 1
		)
	end
end

function Codegen.visitNot(
	self: Codegen,
	stmt: Lua.UnopExpr,
	where: number
): number
	-- visits a unary operator `not`
	-- which is cool i guess
	return self:emitABx(
		LuaInst.ne,
		where,
		self:visit(stmt.expr, where)
	)
end

function Codegen.visitLen(
	self: Codegen,
	stmt: Lua.UnopExpr,
	where: number
): number
	-- visits a unary operator `#`
	-- which gets the length of stuff
	return self:emitABx(
		LuaInst.len,
		where,
		self:visit(stmt.expr, where)
	)
end

function Codegen.visitUnm(
	self: Codegen,
	stmt: Lua.UnopExpr,
	where: number
): number
	-- visits a unary operator `-`
	-- (which negates stuff)
	return self:emitABx(
		LuaInst.unm,
		where,
		self:visit(stmt.expr, where)
	)
end

function Codegen.visitVariadic(
	self: Codegen,
	stmt: Lua.BasicExpr,
	where: number
)
	-- the ... inside of function args/params
	-- are usually empty unless specified
	return where
end

function Codegen.visitForIncrement(
	self: Codegen,
	stmt: Lua.ForIStmt,
	where: number
)
	local jmp = #self.jumps

	self:visitMove(stmt.start :: Lua.BasicExpr, where)
	self:visitMove(stmt.finish :: Lua.BasicExpr, where + 1)
	if not stmt.increment then
		-- load a 1 in
		self:emitABx(
			LuaInst.loadk,
			where + 2,
			self:emitConstant(1)
		)
	else
		-- load in the increment
		self:visitMove(stmt.increment, where + 2)
	end

	-- create a prep
	local prepPtr = self:getInstPtr()
	self:emitABx(LuaInst.forprep, where, 0)

	-- add the variable
	local name = stmt.name
	self:pushScope()

	-- so we dont accidentally override start, finish, increment
	-- also make a temporary variable to store our current value
	self:addVariable(name, where + 3)

	-- visit the block
	local start = self:getInstPtr()
	self:visitBlock(stmt.block)

	-- emit a forloop at the end of
	-- the block
	local length = self:getInstPtr() - prepPtr
	self:emitABx(LuaInst.forloop, where, length - 1)
	self:setABx(prepPtr, where, length)

	self:patchJmps(jmp, self:getInstPtr(), self:getInstPtr())
	self:popScope()
end

function Codegen.visitForIterator(
	self: Codegen,
	stmt: Lua.ForPStmt,
	where: number
): number
	-- visit
	local jmp = #self.jumps

	-- set variable names
	local index = stmt.namelist[1]
	local value = stmt.namelist[2]

	-- create temporaries
	self:visitTempExprList(
		stmt.explist,
		#stmt.namelist,
		where,
		3
	)

	self:pushScope()

	-- archive the jmp
	local jmpPtr = self:getInstPtr()
	self:emitSbx(LuaInst.jmp, 0)

	-- visit the block
	self:addVariable(index, where + 3)
	self:addVariable(value, where + 4)

	local start = self:getInstPtr()
	self:visitBlock(stmt.block)

	-- create the tforloop
	local distance = self:getInstPtr() - jmpPtr
	self:setSbx(jmpPtr, distance)
	self:emitABx(LuaInst.tforloop, where, distance - 1)

	-- revert scope state
	self:patchJmps(jmp, start, self:getInstPtr())
	self:popScope()

	return where
end

function Codegen.visitRepeat(
	self: Codegen,
	stmt: Lua.RepeatStmt,
	where: number
): number
	local begin = self:getInstPtr()
	local jmp = #self.jumps

	self:pushScope()
	self:visitBlock(stmt.block)
	
	-- make the comparison, if its true then
	-- we go outside of the loop
	local register = self:visit(stmt.exp, where)
	self:emitSbx(LuaInst.test, register)

	-- make the comparison, if its true
	local finish = self:getInstPtr()
	self:emitSbx(LuaInst.jmp, begin - finish)
	self:emitSbx(LuaInst.jmp, 1)

	-- revert scope state
	self:patchJmps(jmp, self:getInstPtr(), self:getInstPtr())
	self:popScope()

	return where
end

function Codegen.visitWhile(
	self: Codegen,
	stmt: Lua.WhileStmt,
	where: number
): number
	local jmp = #self.jumps
	local begin = self:getInstPtr()
	self:pushScope()

	local start = self:getInstPtr()
	local register = self:visit(stmt.exp, where)
	self:emitSbx(LuaInst.test, register)

	-- archive the jmp
	local jmpPtr = self:getInstPtr()
	self:emitSbx(LuaInst.jmp, 0)
	self:visitBlock(stmt.block)

	-- revert scope state
	self:popScope()

	-- ok set jmp
	local finish = self:getInstPtr()
	self:emitSbx(LuaInst.jmp, begin - finish)
	self:patchJmps(jmp, start, self:getInstPtr())
	self:setSbx(jmpPtr, self:getInstPtr() - jmpPtr)

	return where
end

function Codegen.visitIf(
	self: Codegen,
	stmt: Lua.IfStmt,
	where: number
): number
	local callbacks = {}
	self:pushScope()

	local hasElseBlock = stmt.elseBlock ~= nil
	local numRoutines = #stmt.routines

	local previous
	for i, routine in stmt.routines do
		-- jump here for the test
		local ptr = self:getInstPtr()
		if previous then
			self:setSbx(previous, ptr - previous)
		end

		-- register
		local register = self:visit(routine.expr, where)
		self:emitSbx(LuaInst.test, register)

		-- set jmp
		previous = self:getInstPtr()
		self:emitSbx(LuaInst.jmp, 0)

		-- save scope state
		self:pushScope()
		self:visitBlock(routine.block)

		-- revert scope state
		self:popScope()

		if hasElseBlock or i < numRoutines then
			table.insert(callbacks, self:getInstPtr())
			self:emitSbx(LuaInst.jmp, 0)
		end
	end

	local ptr = self:getInstPtr()
	self:setSbx(previous, ptr - previous)
	
	if hasElseBlock then
		-- save scope state
		self:pushScope()
		self:visitBlock(stmt.elseBlock :: Lua.Block)

		-- revert scope state
		self:popScope()
	end

	-- set the callbacks like eyy
	ptr = self:getInstPtr()
	for i, callback in callbacks do
		self:setSbx(callback, ptr - callback)
	end

	self:popScope()

	return where
end

function Codegen.visitDo(self: Codegen, doStmt: Lua.DoStmt)
	-- do statements just pop the scope
	-- after the block
	self:pushScope()
	self:visitBlock(doStmt.block)
	self:popScope()
end

function Codegen.visitBreak(self: Codegen)
	-- Used for breaks and stuff
	table.insert(self.jumps, self:getInstPtr())
	self:emitSbx(LuaInst.jmp, 0)
end

function Codegen.visitContinue(self: Codegen)
	-- Used for breaks and stuff
	table.insert(self.jumps, -self:getInstPtr())
	self:emitSbx(LuaInst.jmp, 0)
end

function Codegen.tryEmitClosure(
	self: Codegen,
	where: number,
	target: number
)
	local closure = self.closures[target]
	if closure.numUpvalues == 0 then
		-- no need to emit a closure because
		-- it didnt use upvalues here
		self:emitABx(
			LuaInst.closure,
			where,
			closure.id
		)

		return
	end

	-- emit a closure and its
	-- upvalues
	self:emitABx(
		LuaInst.closure,
		where,
		closure.id
	)

	for i, upvalue in closure.upvalues do
		-- check the upvalues
		local var = self:analyzeVariable(upvalue)
		if var.type == LuaVarType.stack then
			-- move
			self:emitABx(
				LuaInst.move,
				where + i,
				var.id
			)
		elseif var.type == LuaVarType.upvalue then
			-- its an upvalue
			self:emitABx(
				LuaInst.getupval,
				where + i,
				var.id
			)
		end
	end
end

function Codegen.visitFuncBody(
	self: Codegen,
	body: Lua.FuncBody
): Closure
	-- create a new closure
	local closure = self:pushClosure()
	closure.numArgs = #body.args

	-- create arg variables
	local block = body.block
	for i, var in body.args do
		self:addVariable(var, i)
	end

	self:visitBlock(block)
	self:popClosure()

	return closure
end

function Codegen.visitFunction(
	self: Codegen,
	funcStmt: Lua.FuncStmt,
	where: number
)
	local body = funcStmt.body
	local closure = self:visitFuncBody(body)

	if not funcStmt.left then
		-- anonymous function
		self:tryEmitClosure(where, closure.id)
		return where
	else
		-- create a named function
		self:tryEmitClosure(where, closure.id)
		self:emitSet(
			funcStmt.left,
			where,
			where + 1
		)

		return where
	end
end

function Codegen.visitLocalFunc(
	self: Codegen,
	funcStmt: Lua.LocalFuncStmt,
	where: number
)
	local body = funcStmt.body
	local name = funcStmt.name
	self:addVariable(name, where)

	-- are there upvalues remaining here?
	local closure = self:visitFuncBody(body)
	self:tryEmitClosure(where, closure.id)

	return where 
end

function Codegen.visitReturn(
	self: Codegen,
	retStmt: Lua.ReturnStmt,
	where: number
)
	-- read the list and go
	local explist = retStmt.explist
	local length = #explist

	self:visitTempExprList(
		explist,
		0,
		where
	)

	if 0 < length and hasVariadicUnpack(explist[length]) then
		-- then it could be a tuple passed in so
		-- beware
		return self:emitABx(
			LuaInst.ret,
			where,
			0
		)
	else
		-- we have a fixed length because it didnt
		-- end with a function call
		return self:emitABx(
			LuaInst.ret,
			where,
			length
		)
	end
end

local LuaVisitors = {
	["continue"] = Codegen.visitContinue,
	["return"] = Codegen.visitReturn,
	["break"] = Codegen.visitBreak,

	["tableconstructor"] = Codegen.visitTable,
	["constant"] = Codegen.visitConstant,
	["not"] = Codegen.visitNot,
	["len"] = Codegen.visitLen,
	["unm"] = Codegen.visitUnm,
	["function"] = Codegen.visitFunction,
	["variadic"] = Codegen.visitVariadic,
	["variable"] = Codegen.visitVariable,
	["index"] = Codegen.visitDot,
	
	["call"] = Codegen.visitCall,
	["compound_stmt"] = Codegen.visitCompound,
	["operator"] = Codegen.visitOperator,
	["for_increment"] = Codegen.visitForIncrement,
	["for_iterator"] = Codegen.visitForIterator,
	["methodcall"] = Codegen.visitMethodCall,
	["if"] = Codegen.visitIf,
	["local_var"] = Codegen.visitLocalVar,
	["local_func"] = Codegen.visitLocalFunc,
	["do"] = Codegen.visitDo,
	["while"] = Codegen.visitWhile,
	["repeat"] = Codegen.visitRepeat,
	["assignment"] = Codegen.visitAssignment,
}

function Codegen.emitBytecode(self: Codegen): buffer
	self.closure.numInstructions = self.numInstructions

	local constantList = {}
	for value, id in self.constants do
		constantList[id] = value
	end

	-- first, create the constants table by marking number of constants
	-- and their types
	local data = LuaBuffer.newBuffer()
	data:writeu32(self.numConstants)
	for i, constant in constantList do
		local t = typeof(constant)
		if t == "string" then
			-- string
			data:writeu8(0)
			data:writestring(constant)
		elseif t == "number" then
			-- number, assume its a double
			data:writeu8(1)
			data:writef64(constant)
		else
			-- invalid :c
			error(`unsupported constant type: {t}`)
		end
	end

	-- then, we just loop through all the closures and emit their
	-- bytecode
	data:writeu32(#self.closures)
	for i, closure in self.closures do
		-- emit a closure object
		data:writeu32(closure.numInstructions)
		data:writeu32(closure.numVariables)
		data:writeu32(closure.numUpvalues)
		data:writeu32(closure.numLabels)
		data:writeu32(closure.numArgs)

		-- write down labels for args
		for i, label in closure.labels do
			data:writeu32(label)
		end

		-- write all of the instructions
		for i, inst in closure.instructions do
			data:writeu32(inst)
		end
	end

	return data:getData()
end

function Codegen.visit(self: Codegen, stmt: Lua.Statement?, where: number): number
	if not stmt then
		-- no statement, no logic
		-- required
		return where
	end

	return LuaVisitors[stmt.type](self, stmt, where)
end

function Codegen.visitMove(self: Codegen, stmt: Lua.Statement, where: number): number?
	if not stmt then
		-- no statement, no logic
		-- required
		return where
	end
	
	local address = LuaVisitors[stmt.type](self, stmt, where)
	if address ~= where then
		-- might have been a stack variable, so just
		-- copy it over
		self:emitABx(LuaInst.move, where, address)
	end

	return address
end

function Codegen.visitBlock(self: Codegen, block: Lua.Block)
	-- visits an ast block
	local closure = self.closure
	for i, stmt in block do
		LuaVisitors[stmt.type](
			self,
			stmt,
			closure.numVariables
		)
	end
end

return Codegen