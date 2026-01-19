--!strict

-- Made another lexer :P
-- magicoal_nerb

local function generateClassifierTable(): { number }
	-- creates a lookup table that we'll use
	-- for checking individual characters
	local classifier = table.create(256, 0)
	local operators = {} :: {[number]: boolean}

	for char in string.gmatch([==[!@#$^%&*()[]{},./:\-=+>|<?;~]==], '.')do
		operators[string.byte(char)] = true
	end
	
	for i = 0, 255 do
		local flags = 0
		local char = string.char(i)

		flags += char:match('[%a_]') and 1 or 0 -- Letter
		flags += char:match('%d') and 2 or 0 -- Number
		flags += char:match('[%d%w_xb%.%-]') and 4 or 0 -- Number contd.
		flags += char:match([==[[`'"]]==]) and 8 or 0 -- String start
		flags += char:match([==[[`'"=]]==]) and 16 or 0 -- String contd.
		flags += operators[i] and 32 or 0 -- Operator

		classifier[i + 1] = flags
	end

	return classifier
end

local function generateLookupTable(): {[number]: string}
	-- generates a lookup table of operators
	local lookup = {}
	for phrase in string.gmatch([==[>= <= .. == ~= += -= *= /= %= ^=]==], '[^%s]+')do
		local pack = table.pack(string.byte(phrase, 1, -1))
		local code = 0
		for j = #pack, 1, -1 do
			code += bit32.lshift(pack[j], (j-1)*8)
		end

		lookup[code] = phrase
	end
	
	return lookup
end

local function generateReservedTable(str: string)
	-- generates the reserved table
	local lookup = {}
	for phrase in str:gmatch("%w+") do
		lookup[phrase] = true
	end
	
	return lookup
end

local LEX_CLASSIFIER = generateClassifierTable()
local LEX_LOOKUP = generateLookupTable()
local LEX_RESERVED = generateReservedTable([[
	and break do else elseif
	end false for function if
	in local nil not or
	repeat return then true until while
	continue
]])

export type KeyType = string
export type Token = "literal"
	| "number"
	| "string"
	| "operator"
	| "comment"
	| "reserved"

export type Lexeme = {
	-- string contents of the lexeme
	key: KeyType,

	-- current token of the lexeme
	token: Token,
}

local Lexer = {}
Lexer.__index = Lexer

export type Lexer = typeof(setmetatable({} :: {
	-- buffer we're reading from
	content: buffer,
	
	-- current lexeme
	lexeme: Lexeme,

	-- length of the buffer
	length: number,

	-- cursor within our buffer
	read: number,
}, Lexer))

local function lexMask(content: buffer, read: number, what: number): boolean
	-- helper function to check if a character falls under
	-- a certain type
	return bit32.btest(LEX_CLASSIFIER[buffer.readu8(content, read) + 1], what)
end

function Lexer.new(str: string): Lexer
	local self = setmetatable({
		content = buffer.fromstring(str),
		lexeme = {} :: Lexeme,

		length = #str,
		read = 0,
	}, Lexer) :: Lexer
	
	self:lex()
	return self
end

function Lexer.createToken(
	self: Lexer,
	from: number,
	to: number,
	token: Token
)
	-- [from to)
	-- includes `from`, but not `to`
	local lexeme = self.lexeme
	lexeme.key = buffer.readstring(self.content, from, to - from)
	lexeme.token = token
end

function Lexer.peek(self: Lexer): Lexeme
	-- gets the current lexeme
	return self.lexeme
end

function Lexer.advance(self: Lexer): Lexeme
	-- maintain the LALR(1) parse property
	local lexeme = self.lexeme
	
	local previousToken = lexeme.token
	local previousKey = lexeme.key
	local previousRead = self.read
	self:lex()
	
	local clone = table.clone(lexeme)
	lexeme.token = previousToken :: Token
	lexeme.key = previousKey :: KeyType
	self.read = previousRead
	
	return clone
end

function Lexer.pop(self: Lexer): KeyType
	-- returns the previous lexeme's key
	local key = self.lexeme.key
	self:lex()
	return key
end

function Lexer.expectKey(self: Lexer, key: KeyType): boolean
	-- check if our current lexeme matches
	-- the specified key
	local lexeme = self.lexeme
	if lexeme.key == key then
		-- it did!
		self:lex()
		return true
	end

	-- it didnt :c
	return false
end

function Lexer.expect(self: Lexer, token: Token): KeyType?
	-- checks if our current lexeme's type matches
	local lexeme = self.lexeme
	if lexeme.token == token then
		local key = lexeme.key
		self:lex()
		return key
	end
	
	return nil
end

function Lexer.eof(self: Lexer): boolean
	-- returns if we reached the end of the buffer
	return self.length <= self.read
end

function Lexer.isKey(self: Lexer, key: string): boolean
	-- checks if the current lexeme's key matches ours
	-- without immediately lexing again
	return self.lexeme.key == key
end

function Lexer.getKey(self: Lexer): string
	return self.lexeme.key
end

function Lexer.is(self: Lexer, token: Token): boolean
	-- checks if the current lexeme type matches our
	-- without immediately lexing again
	return self.lexeme.token == token
end

function Lexer.lex(self: Lexer)
	-- current lexer state
	local content = self.content
	local length = self.length
	local finale = length - 1
	local read = self.read
	
	-- make sure that we are not reading whitespace
	while read < length and LEX_CLASSIFIER[buffer.readu8(content, read) + 1] == 0 do
		read += 1
	end
	
	if length <= read then
		self.read = length
		return
	end
	
	local char = buffer.readu8(content, read)
	local id = LEX_CLASSIFIER[char + 1]
	if bit32.btest(id, 0x1) then
		-- alphanumeric
		local start = read
		while read < length and lexMask(content, read, 0x3) do
			read += 1
		end

		self:createToken(start, read, "literal")
		if LEX_RESERVED[self.lexeme.key] then
			-- set it to reserved if the key is
			-- a reserved keyword
			self.lexeme.token = "reserved"
		end
	elseif bit32.btest(id, 0x2) then
		-- number
		local start = read
		while read < length and lexMask(content, read, 0x4) do
			read += 1
		end

		self:createToken(start, read, "number")
	elseif bit32.btest(id, 0x8) then
		-- string
		read += 1
		local start = read
		while read < length and buffer.readu8(content, read) ~= char do
			read += 1
		end

		self:createToken(start, read, "string")
		read += 1
	elseif char == 46 then
		-- .
		if bit32.btest(LEX_CLASSIFIER[buffer.readu8(content, read+1) + 1], 0x2) then
			-- number
			local start = read
			while read < length and lexMask(content, read, 0x4) do
				read += 1
			end

			self:createToken(start, read, "number")
		else
			-- . | .. | ...
			local size = 0
			for i = 1, 3 do
				if buffer.readu8(content, read) == 46 then
					size += 1
					read += 1
				else
					break
				end
			end

			self:createToken(read - size, read, "operator")
		end
	elseif read < finale and buffer.readu16(content, read) == 0x2D2D then
		-- comment
		read += 2

		local code = buffer.readu16(content, read)
		if code == 0x5B5B then
			-- block comment
			read += 2

			while read < length and buffer.readu16(content, read) ~= 0x5D5D do
				read += 1
			end

			read += 2
		else
			-- keep on reading until we reach a newline
			while read < length and buffer.readu8(content, read) ~= 0xA do
				read += 1
			end
		end
		
		-- skip the comment and just keep going
		self.read = read
		return self:lex()
	elseif bit32.btest(id, 0x20) then
		-- operator
		local code = read < finale
			and buffer.readu16(content, read)
			or 0
		
		if code == 0x5B5B then
			-- block string
			read += 2

			local start = read
			while read < length and buffer.readu16(content, read) ~= 0x5D5D do
				read += 1
			end

			self:createToken(start, read, "string")
			read += 2
		elseif LEX_LOOKUP[code] then
			-- operator with 2 characters
			self:createToken(read, read + 2, "operator")
			read += 2
		else
			-- operator with only 1 character
			self:createToken(read, read + 1, "operator")
			read += 1
		end
	else
		-- none of these, just skip
		read = read + 1
	end
	
	self.read = read
end

function Lexer.assert<T>(self: Lexer, condition: T?, str: string): T
	if condition then
		-- its true so we early
		-- return
		return condition
	end

	self.read = math.clamp(self.read, 0, self.length - 1)
	
	-- go trace back to the previous newline
	local left = self.read
	local right = self.read
	
	local content = self.content
	while 0 <= left and buffer.readu8(content, left) ~= 10 do
		left -= 1
	end
	
	while right < self.length and buffer.readu8(content, right) ~= 10 do
		right += 1
	end
	
	-- trace lines
	local line = 1
	for i = 0, left do
		if buffer.readu8(content, i) == 10 then
			line += 1
		end
	end
	
	error(`syntax error on line: {line}, column: {self.read - left}, {str}\nline: {buffer.readstring(content, left, right-left)}\ncurrent sym: {self.lexeme.key}`)
end

return Lexer