-- borderless-table.lua
-- Pandoc Lua filter:
--   1. Wraps any Div with class "borderless-table" in a raw Typst call.
--   2. Promotes AlignDefault → AlignLeft on all table columns so that
--      Pandoc emits explicit `left` in the Typst output instead of `auto`.
--      Without this, cells inherit `center` from the figure wrapper that
--      Pandoc emits around every table, making all cell text centred.

function Table(el)
  for i, colspec in ipairs(el.colspecs) do
    if colspec[1] == "AlignDefault" then
      el.colspecs[i] = { "AlignLeft", colspec[2] }
    end
  end
  return el
end

function Div(el)
  if el.classes:includes("borderless-table") then
    local before = pandoc.RawBlock("typst", "#borderless-table[")
    local after  = pandoc.RawBlock("typst", "]")
    local result = { before }
    for _, block in ipairs(el.content) do
      table.insert(result, block)
    end
    table.insert(result, after)
    return result
  end
end
