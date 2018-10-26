do
  local Nil = { __tag = "Nil" }
  local function Cons(x) return { __tag = "Cons", x } end
  local function filter(f, o)
    if o.__tag == "Nil" then
      return Nil
    elseif o.__tag == "Cons" then
      local fq = o[1]
      local x, xs = fq._1, fq._2
      if f(x) then
        return Cons({ _1 = x, _2 = filter(f, xs) })
      end
      return filter(f, xs)
    end
  end
  local function filter0(f) return function(o) return filter(f, o) end end
  local bottom = nil
  bottom(filter0)
end