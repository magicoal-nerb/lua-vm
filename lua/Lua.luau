--!strict

-- Converts a source file into an AST. We use this
-- to create the bytecode, and we can also use this for
-- interpreted output.

-- The grammar follows the lua5.1 grammar specification here:
-- https://parrot.github.io/parrot-docs0/0.4.7/html/languages/lua/doc/lua51.bnf.html
-- magicoal_nerb :3

local Lexer = require("@lua/Lexer")

local Lua = {}

export type Type = "return"
	| "break"
	| "tableconstructor"
	| "constant"
	| "not"
	| "len"
	| "unm"
	| "function"
	| "variadic"
	| "variable"
	| "methodcall"
	| "index"
	| "call"
	| "operator"
	| "for_increment"
	| "for_iterator"
	| "if"
	| "local_var"
	| "local_func"
	| "closure"
	| "do"
	| "while"
	| "repeat"
	| "assignment"
	| "func_name"
	| "func_method"
	| "compound_stmt"
	| "if_else_expr"
	| "continue"

local function createConstantExpr(value: any): BasicExpr
	-- helper function to create constants
	-- in our prefix expr parse
	return {
		type = "constant",
		value = value,
	} :: BasicExpr
end

export type ReturnStmt = {
	type: Type,
	explist: Explist,
}

export type Block = { Statement }
function Lua.parseBlock(lexer: Lexer.Lexer, shouldReturn: boolean): Block
	-- block ::= {stat [`;`]} [laststat[`;`]]
	local block = {}
	while not lexer:eof() do
		local stat = Lua.parseStat(lexer)
		if not stat then
			break
		end

		table.insert(block, stat)

		-- consume an optional semicolon
		lexer:expectKey(';')
	end

	-- laststat ::= return [explist1]  |  break
	if lexer:expectKey("return") then
		-- [laststat[`;´]]
		table.insert(block, {
			type = "return",
			explist = Lua.parseExplist(lexer)
		})

		-- one of us!! one of us
		lexer:expectKey(';')
	elseif lexer:expectKey("break") then
		-- break[`;`]
		table.insert(block, {
			type = "break",
		})

		lexer:expectKey(';')
	elseif lexer:expectKey("continue") then
		-- continue[`;`]
		table.insert(block, {
			type = "continue",
		})

		lexer:expectKey(';')
	elseif shouldReturn then
		-- empty return
		table.insert(block, {
			type = "return",
			explist = {}
		})
	end

	return block
end

export type TableField = {
	index: (Expression | string)?,
	value: Expression,
}

function Lua.parseField(lexer: Lexer.Lexer): TableField
	-- field ::= `[` exp `]` `=` exp | Name `=` exp | exp
	if lexer:expectKey('[') then
		-- field ::= `[` exp `]` `=` exp
		local index = Lua.parseExp(lexer)
		lexer:assert(lexer:expectKey(']'), "table field expected closing ]")
		lexer:assert(lexer:expectKey('='), "table field expected `=`")

		local value = Lua.parseExp(lexer)
		return {
			index = index :: Expression,
			value = value :: Expression,
		}
	elseif lexer:advance().key == '=' then
		-- field ::= Name `=` exp
		local index = assert(lexer:expect("literal"), "table field expected literal")
		lexer:pop() -- pop the =

		local value = Lua.parseExp(lexer)
		return {
			index = createConstantExpr(index),
			value = value :: Expression,
		}
	else
		-- field ::= exp
		return {
			value = Lua.parseExp(lexer) :: Expression,
		}
	end
end

export type TableExpr = { 
	type: Type,
	list: { Expression },
	records: { TableField },
}

function Lua.parseTable(lexer: Lexer.Lexer): TableExpr
	-- tableconstructor ::= `{` [fieldlist] `}`
	-- fieldlist ::= field {fieldsep field} [fieldsep]
	-- fieldsep ::= `,` | `;`
	if lexer:expectKey('}') then
		return {
			type = "tableconstructor",
			records = {},
			list = {},
		}
	end

	local records = {}
	local list = {}
	while not lexer:isKey('}') do
		-- fieldlist ::= field {fieldsep field} [fieldsep]
		local field = Lua.parseField(lexer)
		if field.index then
			-- if the field has an index, then its
			-- a record
			table.insert(records, field)
		else
			-- if the field has no index, then its
			-- part of the array
			table.insert(list, field.value)
		end

		if lexer:expectKey(',')
			or lexer:expectKey(';') then
			-- fieldsep
			continue
		else
			break
		end
	end

	lexer:assert(lexer:expectKey('}'), "table constructor expected closing }")

	return {
		type = "tableconstructor",

		records = records,
		list = list,
	}
end

export type BasicExpr = {
	type: Type,
	value: any,
}

export type UnopExpr = {
	type: Type,
	expr: Expression,
}

export type IfExprRoutine = {
	expr: Expression,
	body: Expression,
}

export type IfElseExpr = {
	type: Type,

	routines: { IfExprRoutine },
	default: Expression,
}

function Lua.parseIfElseExpr(lexer: Lexer.lexer)
	-- ifelseexp ::= 'if' exp 'then' exp {'elseif' exp 'then' exp} 'else' exp
	local routines: { IfExprRoutine } = {}

	repeat
		local ifExpr = Lua.parseExp(lexer)
		lexer:assert(lexer:expectKey("then"), "If-else expression expected 'then'")

		local bodyExpr = Lua.parseExp(lexer)
		table.insert(routines, {
			expr = ifExpr,
			body = bodyExpr,
		})

	until not lexer:expectKey("elseif")

	lexer:assert(lexer:expectKey("else"), "If-else expression expected 'else'")
	local defaultExpr = Lua.parseExp(lexer)

	lexer:assert(defaultExpr, "If-else expression expected Expression")

	return {
		type = "if_else",
		routines = routines,
		default = defaultExpr,
	} :: IfElseExpr
end

function Lua.parsePrefixExpr(lexer: Lexer.Lexer): Expression?
	-- exp ::=  nil  |  false  |  true  |  Number  |  String  |  `...´  |
	--		function  |  prefixexp  |  tableconstructor  |  exp binop exp  |  unop exp
	local unopPriority = 8
	if lexer:is("string") then
		-- string
		return createConstantExpr(lexer:pop()) :: BasicExpr
	elseif lexer:expectKey('(') then
		-- `(` exp `)`
		local expr = Lua.parseExp(lexer)
		lexer:assert(lexer:expectKey(')'), "expr expected end")

		return expr
	elseif lexer:expectKey("if") then
		-- expects an ifelse expr
		return Lua.parseIfElseExpr(lexer)
	elseif lexer:expectKey("not") then
		-- unop exp
		local expr = Lua.parseExp(lexer, unopPriority) :: BasicExpr
		if expr.type == "constant" then
			return createConstantExpr(not expr.value)
		else
			return {
				type = "not",
				expr = expr,
			} :: UnopExpr
		end
	elseif lexer:expectKey('#') then
		-- unop exp
		local expr = Lua.parseExp(lexer, unopPriority) :: BasicExpr
		if expr.type == "constant" then
			return createConstantExpr(#expr.value)
		else
			return {
				type = "len",
				expr = expr,
			} :: UnopExpr
		end
	elseif lexer:expectKey('-') then
		-- unop exp
		local expr = Lua.parseExp(lexer, unopPriority) :: BasicExpr
		if expr.type == "constant" then
			return createConstantExpr(-expr.value)
		else
			return {
				type = "unm",
				expr = expr,
			} :: UnopExpr
		end
	end

	if lexer:isKey("true")
		or lexer:isKey("false") then
		-- boolean
		return createConstantExpr(lexer:pop() == "true") :: BasicExpr
	elseif lexer:isKey("nil") then
		-- nil
		lexer:pop()
		return createConstantExpr(nil) :: BasicExpr
	elseif lexer:is("number") then
		-- number
		return createConstantExpr(tonumber(lexer:pop())) :: BasicExpr
	elseif lexer:expectKey("function") then
		-- function ::= function funcbody
		return {
			-- make an unnamed function here
			type = "function",
			body = Lua.parseFuncBody(lexer),
		} :: BasicExpr
	elseif lexer:expectKey("...") then
		-- ...
		return {
			type = "variadic",
		} :: BasicExpr
	elseif lexer:expectKey('{') then
		-- exp ::= tableconstructor
		return Lua.parseTable(lexer) :: TableExpr
	elseif lexer:is("literal") then
		-- var ::= Name | prefixexp `[` exp `]` | prefixexp `.` Name
		return {
			type = "variable",
			value = lexer:pop(),
		} :: BasicExpr
	else
		-- Nothing :c
		return nil
	end	
end

export type Expr = {
	type: Type,
	left: Expression?,
	right: Expression?,
}

export type MethodExpr = {
	type: Type,
	left: Expression?,
	right: Expression?,
	args: { Expression },
}

export type Expression = BasicExpr 
	| MethodExpr
	| TableExpr 
	| UnopExpr
	| Expr

function Lua.parsePrimaryExp(lexer: Lexer.Lexer): Expression?
	-- prefixexp ::= ifelseexp
	-- prefixexp ::= var  |  functioncall  |  `(´ exp `)´
	-- functioncall ::=  prefixexp args  |  prefixexp `:´ Name args
	local currentExpr = Lua.parsePrefixExpr(lexer)
	if not currentExpr then
		return nil
	end
	
	while not lexer:eof() do
		if lexer:expectKey('.') then
			-- var ::= prefixexp `.´ Name
			local name = lexer:assert(lexer:expect("literal"), "expected literal for .")
			currentExpr = {
				type = "index",
				left = currentExpr,
				right = createConstantExpr(name),
			} :: Expression
		elseif lexer:expectKey(':') then
			-- functioncall ::= prefixexp `:` Name args
			local name = lexer:assert(lexer:expect("literal"), "expected name for .")
			currentExpr = {
				type = "methodcall",
				left = currentExpr,
				right = createConstantExpr(name),
				args = Lua.parseArgs(lexer),
			} :: Expression
		elseif lexer:expectKey('[') then
			-- var ::= prefixexp `[` exp `]`
			currentExpr = {
				type = "index",
				left = currentExpr,
				right = Lua.parseExp(lexer),
			} :: Expression

			lexer:assert(lexer:expectKey(']'), "prefixexp expected closing ]")
		else
			local args = Lua.parseArgs(lexer)
			if args then
				-- functioncall ::= prefixexp args
				currentExpr = {
					type = "call",
					left = currentExpr,
					right = args
				}

				continue
			else
				-- no args lol
				break
			end
		end
	end

	return currentExpr
end

function Lua.parseArgs(lexer: Lexer.Lexer): Explist?
	if lexer:expectKey('(') then
		-- functioncall ::= prefixexp args
		-- args ::= `(` explist1 `)`
		local expList = Lua.parseExplist(lexer)
		lexer:assert(lexer:expectKey(')'), "function call needs closing )")

		return expList
	elseif lexer:expectKey('{') then
		-- args ::= tableconstructor
		local tab = Lua.parseTable(lexer)		
		return { tab }
	elseif lexer:is("string") then
		-- args ::= string
		return { createConstantExpr(lexer:pop()) }
	end

	return nil
end

local LuaOperators = table.freeze({
	-- operator names
	['+'] = "add",
	['-'] = "sub",
	['*'] = "mul",
	['/'] = "div",
	['%'] = "mod",
	['^'] = "pow",

	['..'] = "concat",
	["and"] = "and",
	["or"] = "or",

	['>'] = "gt",
	['<'] = "lt",
	['~='] = "neq",
	['=='] = "eq",
	['>='] = "gte",
	['<='] = "lte",
})

local LuaPrecedence = table.freeze({
	-- https://www.lua.org/pil/3.5.html
	["pow"] = 10,

	-- * / %
	["mul"] = 7,
	["div"] = 7,
	["mod"] = 7,

	-- + -
	["add"] = 6,
	["sub"] = 6,

	-- ..
	["concat"] = 5,

	-- comparison
	["lt"] = 3,
	["gt"] = 3,
	["lte"] = 3,
	["gte"] = 3,
	["neq"] = 3,
	["eq"] = 3,

	-- ternary
	["and"] = 2,
	["or"] = 1,
})

local LuaOperatorsConstantFold = {
	-- constant versions of certain
	-- binary operations
	['+'] = function(a: number, b: number): number return a + b end,
	['-'] = function(a: number, b: number): number return a - b end,
	['*'] = function(a: number, b: number): number return a * b end,
	['^'] = function(a: number, b: number): number return a ^ b end,
	['%'] = function(a: number, b: number): number return a % b end,
	['/'] = function(a: number, b: number): number return a / b end,
	
	['<'] = function(a: number, b: number): boolean return a < b end,
	['<='] = function(a: number, b: number): boolean return a <= b end,
	['>'] = function(a: number, b: number): boolean return a > b end,
	['>='] = function(a: number, b: number): boolean return a >= b end,
	['=='] = function(a: any, b: any): boolean return a == b end,
	['~='] = function(a: any, b: any): boolean return a ~= b end,

	['..'] = function(a: string, b: string): string return a .. b end,

	["and"] = function(a: any, b: any): boolean return a and b end,
	["or"] = function(a: any, b: any): boolean return a or b end,
}

function Lua.parseOperator(lexer: Lexer.Lexer): string?
	-- checks if our operator exists here
	return LuaOperators[lexer:peek().key] 
end

function Lua.parseExp(lexer: Lexer.Lexer, maybeLimit: number?): Expression?
	-- functioncall ::=  prefixexp args  |  prefixexp `:´ Name args
	-- prefixexp ::= var  |  functioncall  |  `(´ exp `)´
	-- exp ::= exp binop exp  |  unop exp
	local primaryExpr = Lua.parsePrimaryExp(lexer)
	if not primaryExpr then
		return nil
	end

	local limit = maybeLimit or 0
	local op = Lua.parseOperator(lexer)

	while op and LuaPrecedence[op] > limit do
		local operator = lexer:pop()

		-- Read next expression with a higher priority
		local right = Lua.parseExp(lexer, LuaPrecedence[op])
		if primaryExpr.type == "constant"
			and (right :: Expression).type == "constant" then
			-- Do constant folding here
			local value = LuaOperatorsConstantFold[operator](
				(primaryExpr :: BasicExpr).value,
				(right :: BasicExpr).value
			)

			-- Create a constant expression
			primaryExpr = createConstantExpr(value)
		else
			-- Do a normal expression here
			primaryExpr = {
				type = "operator",
				operator = operator,
				
				left = primaryExpr,
				right = right,
			}
		end

		op = Lua.parseOperator(lexer)
	end

	return primaryExpr
end

export type Namelist = { string }
function Lua.parseNamelist(lexer: Lexer.Lexer): Namelist
	-- namelist ::= Name {`,´ Name}
	local list = {}
	repeat
		local name = lexer:assert(lexer:expect("literal"), "namelist expected a name")
		table.insert(list, name)
	until not lexer:expectKey(',')

	return list
end

export type Explist = { Expression }
function Lua.parseExplist(lexer: Lexer.Lexer): Explist
	-- explist1 ::= {exp `,´} exp
	local expr = Lua.parseExp(lexer)
	if not expr then
		return {}
	end

	local list = { expr }
	while lexer:expectKey(',') do
		expr = Lua.parseExp(lexer)
		lexer:assert(expr, "expected an expression, got nil")
		table.insert(list, expr)
	end

	return list
end

export type ForIStmt = {
	type: Type,

	-- this is for foriprep
	name: string,
	start: Expression?,
	finish: Expression?,
	increment: Expression?,
	block: Block,
}

export type ForPStmt = {
	type: Type,

	-- this is for forprep
	namelist: Namelist,
	explist: Explist,
	block: Block,
}

export type ForStmt = ForPStmt | ForIStmt

function Lua.parseFor(lexer: Lexer.Lexer): ForStmt
	local name = lexer:expect("literal") :: string
	lexer:assert(name, "expected name")

	if lexer:peek().key == '=' then
		-- for Name `=` exp `,` exp [`,` exp] do block end
		-- pop the eq
		lexer:pop()

		local start = Lua.parseExp(lexer)
		lexer:assert(lexer:expectKey(','), "for loop expected ,")

		local finish = Lua.parseExp(lexer)
		local increment

		if lexer:expectKey(',') then
			-- increment
			increment = Lua.parseExp(lexer)
		end

		lexer:assert(lexer:expectKey("do"), "for loop expected `do`")
		local block = Lua.parseBlock(lexer, false)	
		lexer:assert(lexer:expectKey("end"), "for loop needs a closing end")

		return {
			type = "for_increment",
			name = name,
			start = start,
			finish = finish,
			increment = increment,
			block = block,
		} :: ForIStmt
	else
		-- for namelist in explist do block end
		local namelist
		if lexer:expectKey(',') then
			namelist = Lua.parseNamelist(lexer)
			table.insert(namelist, 1, name)
		else
			namelist = { name }
		end

		lexer:assert(lexer:expectKey("in"), "generic for loop expected `in`")
		local explist = Lua.parseExplist(lexer)

		lexer:assert(lexer:expectKey("do"), "generic for loop expected `do`")
		local block = Lua.parseBlock(lexer, false)
		lexer:assert(lexer:expectKey("end"), "generic for loop needs a closing end")

		return {
			type = "for_iterator",

			namelist = namelist,
			explist = explist,
			block = block,
		} :: ForPStmt
	end
end

export type FuncBody = {
	args: { string },
	block: Block,
}

function Lua.parseFuncBody(lexer: Lexer.Lexer): FuncBody
	-- funcbody ::= `(´ [parlist1] `)´ block end
	lexer:assert(lexer:expectKey('('), "func body needs opening (")

	local args = {}
	while lexer:is("literal") do
		-- parlist
		table.insert(args, lexer:pop())
		lexer:expectKey(',')
	end

	-- consume any vargs if that exists
	lexer:expectKey("...")
	lexer:assert(lexer:expectKey(')'), "func body needs closing )")

	local block = Lua.parseBlock(lexer, true)
	lexer:assert(lexer:expectKey("end"), "func body needs a closing end")

	return {
		block = block,
		args = args,
	}
end

export type FuncStmt = {
	type: Type,
	flags: number,
	left: Expression?,
	body: FuncBody,
}

function Lua.parseFunction(lexer: Lexer.Lexer): FuncStmt
	-- funcname ::= Name {`.´ Name} [`:´ Name]
	-- stat ::= function funcname funcbody
	if not lexer:is("literal") then
		-- function value
		return {
			type = "function",
			body = Lua.parseFuncBody(lexer),
		} :: FuncStmt
	end

	-- funcname ::= Name {`.´ Name} [`:´ Name]
	local expr = createConstantExpr(lexer:pop())
	expr.type = "variable"

	while lexer:expectKey('.') do
		-- funcname ::= Name {`.` Name}
		local name = assert(lexer:expect("literal"), "index expected literal")
		expr = {
			type = "index",
			left = expr,
			right = createConstantExpr(name)
		}
	end

	if lexer:expectKey(':') then
		-- funcname ::= [`:´ Name]
		local methodName = assert(lexer:expect("literal"), "index expected literal")
		expr = {
			type = "index",
			left = expr,
			right = createConstantExpr(methodName)
		}

		-- add self because its a method call
		local body = Lua.parseFuncBody(lexer)
		table.insert(body.args, 1, "self")

		return {
			type = "function",
			body = body,
			left = expr,
		} :: FuncStmt
	else
		return {
			type = "function",
			body = Lua.parseFuncBody(lexer),
			left = expr,
		} :: FuncStmt
	end
end

export type IfRoutine = {
	expr: Expression,
	block: Block,
}

export type IfStmt = {
	type: Type,

	routines: { IfRoutine },
	elseBlock: Block?,
}

function Lua.parseIf(lexer: Lexer.Lexer): IfStmt
	-- if exp then block {elseif exp then block} [else block] end
	local function parseIfRoutine(): IfRoutine
		-- exp then
		local expr = Lua.parseExp(lexer) :: Expression
		lexer:assert(lexer:expectKey("then"), "if/elseif/else clause expected `then`")

		local block = Lua.parseBlock(lexer, false) :: Block
		return {
			expr = expr,
			block = block,
		}
	end

	local ifStmt = {
		type = "if",
		routines = { parseIfRoutine() },
		elseBlock = nil,
	} :: IfStmt

	while not lexer:eof() do
		if lexer:expectKey("elseif") then
			-- {elseif exp then block}
			table.insert(ifStmt.routines, parseIfRoutine())
		elseif lexer:expectKey("else") then
			-- [else block]
			local block = Lua.parseBlock(lexer, false) :: Block
			ifStmt.elseBlock = block
		else
			--lexer:assert(false, "if statement expected elseif or else")
			break
		end
	end

	lexer:assert(lexer:expectKey("end"), "if statement needs a closing end")
	return ifStmt :: IfStmt
end

export type LocalVarStmt = {
	type: Type,
	namelist: Namelist,
	explist: Explist
}

export type LocalFuncStmt = {
	type: Type,
	name: string,
	body: FuncBody,
}

export type LocalStmt = LocalFuncStmt | LocalVarStmt

function Lua.parseLocal(lexer: Lexer.Lexer): LocalStmt?
	if lexer:is("literal") then
		-- stat ::= local namelist [`=` explist1]
		local namelist = Lua.parseNamelist(lexer)
		if lexer:expectKey('=') then
			-- has an explist
			return {
				type = "local_var",
				namelist = namelist,
				explist = Lua.parseExplist(lexer),
			} :: LocalVarStmt
		else
			-- no explist
			return {
				type = "local_var",
				namelist = namelist,
				explist = {},
			} :: LocalVarStmt
		end
	elseif lexer:expectKey("function") then
		-- stat ::= local function Name funcbody
		local name = lexer:assert(lexer:expect("literal"), "local function requires a literal name")
		local body = Lua.parseFuncBody(lexer)

		return {
			type = "local_func",
			name = name,
			body = body,
		} :: LocalFuncStmt
	else
		lexer:assert(false, "cannot parse local, expected literal or `function`")
		return nil
	end
end

export type DoStmt = {
	type: Type,
	block: Block,
}

function Lua.parseDo(lexer: Lexer.Lexer): DoStmt
	-- do block end
	local block = Lua.parseBlock(lexer, false)
	lexer:assert(lexer:expectKey("end"), "do block expected end")

	return {
		type = "do",
		block = block,
	} :: DoStmt
end

export type WhileStmt = {
	type: Type,
	exp: Expression,
	block: Block,
}

function Lua.parseWhile(lexer: Lexer.Lexer): WhileStmt
	-- while exp do block end
	local exp = Lua.parseExp(lexer)
	lexer:assert(lexer:expectKey("do"), "while statement expected do")

	local block = Lua.parseBlock(lexer, false)
	lexer:assert(lexer:expectKey("end"), "while body expected end")

	return {
		type = "while",
		exp = exp,
		block = block,
	} :: WhileStmt
end

export type RepeatStmt = {
	type: Type,
	exp: Expression,
	block: Block,
}

function Lua.parseRepeat(lexer: Lexer.Lexer): RepeatStmt
	-- stat ::= repeat block until exp
	local block = Lua.parseBlock(lexer, false)

	lexer:assert(lexer:expectKey("until"), "repeat expected until")

	local exp = Lua.parseExp(lexer)
	return {
		type = "repeat",
		block = block,
		exp = exp,
	} :: RepeatStmt
end

export type AssignStmt = {
	type: Type,
	varlist: { Expression },
	explist: { Expression },
}

function Lua.parseAssignment(lexer: Lexer.Lexer, current: Expression): AssignStmt
	-- assignment ::= varlist `=` explist
	local varlist = { current }
	while lexer:expectKey(',') do
		table.insert(varlist, Lua.parsePrimaryExp(lexer) :: Expression)
	end

	assert(lexer:expectKey('='), "expected `=` for assignment")

	local explist = Lua.parseExplist(lexer)
	return {
		type = "assignment",
		varlist = varlist,
		explist = explist,
	} :: AssignStmt
end

export type CompoundStmt = {
	type: Type,
	left: Expression,
	right: Expression,
}

function Lua.parseCompoundStmt(lexer: Lexer.Lexer, current: Expression): CompoundStmt
	local operator = lexer:pop()
	local right = Lua.parseExp(lexer) :: Expression
	return {
		type = "compound_stmt",
		operator = operator,
		left = current,
		right = right,
	}
end

export type Statement = DoStmt
	| WhileStmt
	| RepeatStmt
	| IfStmt
	| FuncStmt
	| LocalStmt
	| ForStmt
	| AssignStmt
	| CompoundStmt
	| Expression
	| Expr

function Lua.parseStat(lexer: Lexer.Lexer): Statement?
	if lexer:expectKey("do") then
		-- do statement
		return Lua.parseDo(lexer)
	elseif lexer:expectKey("while") then
		-- while statement
		return Lua.parseWhile(lexer)
	elseif lexer:expectKey("repeat") then
		-- repeat statement
		return Lua.parseRepeat(lexer)
	elseif lexer:expectKey("if") then
		-- if statement
		return Lua.parseIf(lexer)
	elseif lexer:expectKey("function") then
		-- function statement
		return Lua.parseFunction(lexer)
	elseif lexer:expectKey("local") then
		-- local statement
		return Lua.parseLocal(lexer)
	elseif lexer:expectKey("for") then
		-- for statement
		return Lua.parseFor(lexer)
	end

	-- parse an expression instead and hope
	local expr = Lua.parseExp(lexer) :: Expression
	if expr and (expr :: any).type == "call" then
		-- if it's a call, don't mess with it..?
	elseif lexer:isKey(',') or lexer:isKey('=') then
		-- has to be an assignment
		return Lua.parseAssignment(lexer, expr :: Expression)
	end

	local key = lexer:getKey()
	if key:sub(2) == '=' then
		-- has to be a compound statement!
		return Lua.parseCompoundStmt(lexer, expr :: Expression)
	end

	return expr
end

function Lua.parse(lexer: Lexer.Lexer): Block
	-- entrypoint parse
	return Lua.parseBlock(lexer, true)
end

return Lua