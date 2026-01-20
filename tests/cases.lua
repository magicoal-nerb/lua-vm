--!nocheck
--!nolint

describe("Cursed Code", function()
	it("should give five", function()
		local function five()
			--trig+logs+string->number
			s=table.concat({string.char(53)},"")
			n=tonumber(s) or 5
			a=math.abs(math.sin(n)/math.sin(n)==1 and n or tonumber(s) or 5)
			return math.floor(math.sqrt(n*n)+0.5)
		end

		expect(five()).to.equal(5)
	end)
	
	it("should decode", function()
		local function decode(s)
			out={}
			for i=1,#s do
			c=s:sub(i,i)
			out[#out+1]=string.char(string.byte(c))
			for _=1,3 do _=(#out)*1 end end
			return table.concat(out)
		end

		expect(decode("hello")).to.equal("hello")
	end)
end)

describe("Operators", function()
	it("should be commutative", function()
		local a, b, c = 5, 8, 11
		expect(a + b + c).to.equal(c + b + a)
	end)

	it("should be associative", function()
		local a, b, c = 7, 4, 9
		expect((a + b) + c).to.equal(a + (b + c))
	end)

	it("should have proper inlined precedence", function()
		expect(7 * 9 + 3 - 6 / 2 + 2^2 - 11).to.equal(56)
	end)

	it("should have proper variable operator precedence", function()
		local values = { 7, 9, 3, 6, 2, 2, 2, 11 }
		expect(values[1] * values[2] + values[3] - values[4] / values[5] + values[6]^values[7] - values[8]).to.equal(56)
	end)

	it("should properly concatenate this string", function()
		local a = "something so i dont get "
		local b = "automatically inlined"
		local c = " ok"
		expect(a .. b .. c).to.equal("something so i dont get automatically inlined ok")
	end)

	it("should properly fold the string", function()
		expect("something so i dont get " .. "automatically inlined" .. " ok").to.equal("something so i dont get automatically inlined ok")
	end)
end)

describe("If-else expression", function()
	it("should evaluate correctly", function()
		local calls = 0
		local function someFunc(num)
			calls += 1
			return calls + num
		end

		local value = if someFunc(someFunc(0) + 3) < 8
			then "works"
			else "doesn't work"

		expect(value).to.equal("works")
	end)

	it("should evaluate nested if-else exprs", function()
		local calls = 0
		local function someFunc(num)
			calls += 1
			return calls + num
		end

		local value = if (if calls < 8 then calls + 3 else someFunc(0)) > 10 then "doesn't work"
			elseif calls < 10 then "works"
			else "doesn't work"

		expect(value).to.equal("works")
	end)
end)

describe("Methods", function()
	it("should have self in args", function()
		local object = {}

		function object.foo(what, thing)
			assert(what == object)
		end

		object:foo()
	end)

	it("should have self in vars", function()
		local object = {}

		function object:foo(thing)
			assert(self == object)
		end

		object:foo()
	end)
end)

describe("Closures", function()
	it("should have an upvalue change", function()
		local upvalue = "no change"

		local function changeUpvalue()
			upvalue = "changed"
		end

		changeUpvalue()
		expect(upvalue).to.equal("changed")
	end)

	it("should have a table upvalue", function()
		local upvalue = {
			something = "here"
		}

		local function changeUpvalue()
			local function nested()
				upvalue.something = "changed"
			end

			nested()
		end

		changeUpvalue()
		expect(upvalue.something).to.equal("changed")
	end)

	it("should close upvalues", function()
		local upvalue

		do
			local upvalue2 = "something"
			local upvalue = "another thing to confuse it maybe"
		end

		expect(upvalue).to.equal(nil)
	end)

	it("should close nested upvalues", function()
		local upvalue1

		do
			local upvalue2
			do
				upvalue2 = "initialized it to soemthing"
				do
					do
						upvalue2 = "ok"
					end
				end
			end

			expect(upvalue2).to.equal("ok")
		end

		expect(upvalue1).to.equal(nil)
	end)
end)

describe("Control flow", function()
	it("should properly increment", function()
		local times = 0
		for i = 1, 32 do
			times += 1
			i += 3
		end

		expect(times).to.equal(32)
	end)

	it("should break out immediately", function()
		local i = 1
		repeat
			i += 2
		until i < 5

		expect(i).to.equal(3)
	end)

	it("should break out", function()
		local i = 1
		repeat
			i += 2
		until i > 5

		expect(i).to.equal(7)
	end)

	it("should continue on for loops", function()
		local sum = 0
		for i = 1, 32 do
			if i > 10 then
				continue
			end

			sum += i
		end

		expect(sum).to.equal(55)
	end)

	it("should continue on while loops", function()
		local sum = 0
		local itr = 0
		while itr < 32 do
			itr += 1
			if itr > 10 then
				continue
			end

			sum += itr
		end

		expect(sum).to.equal(55)
	end)

	it("should continue on repeats", function()
		local sum = 0
		local itr = 0
		repeat
			itr += 1
			if itr > 10 then
				continue
			end

			sum += itr
		until itr >= 32
		
		expect(sum).to.equal(55)
	end)
end)

describe("Compound assignments", function()
	it("should add table fields", function()
		local tbl = { x = 32, y = 64 }

		tbl.x += 32

		for i = 1, 8 do
			tbl.x += i
		end

		expect(tbl.x).to.equal(100)
	end)

	it("should work on upvals", function()
		local upval = 0
		local function test()
			upval += 3
		end

		test()

		expect(upval).to.equal(3)
	end)

	it("should do compound ops correctly", function()
		local x = 30
		x *= 2
		x ^= 2
		x /= 2
		x += 2
		x -= 2
		x %= 2

		expect(x).to.equal(0)
	end)

	it("should handle side-effects", function()
		local calls = 0
		local function sideeffect()
			calls += 1
			return 69
		end

		sideeffect() += 420
		expect(calls).to.equal(1)
	end)

	it("should handle side-effects", function()
		local called = false
		local function sideeffect()
			local function add(ok, what)
				called = true
			end

			return setmetatable({ x = 2 }, { __add = add })
		end

		sideeffect() += 420
		expect(called).to.equal(true)
	end)

	it("should handle side-effects 2", function()
		local called = false
		local obj
		local function sideeffect()
			obj = { x = 2 }
			return obj
		end

		sideeffect().x += 420
		expect(obj.x).to.equal(422)
	end)
end)

describe("Vargs", function()
	it("should pass in other args and vargs correctly", function()
		local function testVargs(...)
			return 3, 4, 6, ...
		end

		local a, b, c, d, e, f = testVargs(1, 2, 3)
		expect(a).to.equal(3)
		expect(b).to.equal(4)
		expect(c).to.equal(6)
		expect(d).to.equal(1)
		expect(e).to.equal(2)
		expect(f).to.equal(3)
	end)

	it("should pass in vargs correctly", function()
		local function testVargs(...)
			return ...
		end

		local a, b, c = testVargs(1, 2, 3)
		expect(a).to.equal(1)
		expect(b).to.equal(2)
		expect(c).to.equal(3)
	end)

	it("should cast vargs", function()
		local function testVargs(...)
			return { 1, ... }
		end

		local tab = testVargs(1, 2, 3)
		expect(tab[1]).to.equal(1)
		expect(tab[2]).to.equal(1)
		expect(tab[3]).to.equal(2)
		expect(tab[4]).to.equal(3)
	end)

	it("should truncate vargs", function()
		local function testVargs(...)
			return { 1, ..., 2 }
		end

		local tab = testVargs(1, 2, 3)
		expect(tab[1]).to.equal(1)
		expect(tab[2]).to.equal(1)
		expect(tab[3]).to.equal(2)
		expect(tab[4]).to.equal(nil)
	end)

	it("should pass in vargs", function()
		local function testVargs(...)
			return select(2, pcall(function(...)
				return select('#', ...)
			end, ...))
		end

		local len = testVargs(1, 2, 3)
		expect(len).to.equal(3)
	end)
end)

describe("Functions", function()
	it("should call this unnamed function", function()
		local x, y, z = (function()
			return 1, 2, 3
		end)()

		expect(x).to.equal(1)
		expect(y).to.equal(2)
		expect(z).to.equal(3)
	end)

	it("should call this function variable", function()
		local x = function()
			return 1, 2, 3
		end

		local args = { x() }
		expect(args[1]).to.equal(1)
		expect(args[2]).to.equal(2)
		expect(args[3]).to.equal(3)
	end)

	it("should be able to pass in function params", function()
		local function reduce(list, comp)
			local output = {}
			for i, v in pairs(list) do
				if comp(v) then
					table.insert(output, v)
				end
			end

			return output
		end

		local output = reduce({ "thing", "lol", "hello guys", "hello world", "neighbor hello" }, function(w)
			return string.match(w, "%w+") == "hello"
		end)

		expect(output[1]).to.equal("hello guys")
		expect(output[2]).to.equal("hello world")
	end)
end)

describe("Assignment", function()
	it("should swap variables correctly", function()
		local a = 30
		local b = 15
		a, b = b, a

		expect(a).to.equal(15)
		expect(b).to.equal(30)
	end)

	it("should set variables correctly", function()
		local a = 30
		local b = 15
		a, b = b, b

		expect(a).to.equal(15)
		expect(b).to.equal(15)
	end)
end)

describe("Return", function()
	it("should unpack correctly", function()
		local function test()
			return 1, 2, 3, 4
		end

		local a, b, c, d, e = test()
		expect(a).to.equal(1)
		expect(b).to.equal(2)
		expect(c).to.equal(3)
		expect(d).to.equal(4)
		expect(e).to.equal(nil)
	end)

	it("should convert this to table entries", function()
		local function test()
			return 1, 2, 3, 4
		end

		local tab = { test() }
		expect(#tab).to.equal(4)
		expect(tab[1]).to.equal(1)
		expect(tab[2]).to.equal(2)
		expect(tab[3]).to.equal(3)
		expect(tab[4]).to.equal(4)
	end)
end)