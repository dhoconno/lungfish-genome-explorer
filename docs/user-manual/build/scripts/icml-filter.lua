-- icml-filter.lua
-- Maps pandoc AST nodes to InDesign ICML paragraph/character style names.
-- The target style names are defined in build/indesign/styles/style-map.yaml.

function Header(el)
  local level = el.level
  if level == 1 then
    el.attributes["custom-style"] = "H1"
  elseif level == 2 then
    el.attributes["custom-style"] = "H2"
  elseif level == 3 then
    el.attributes["custom-style"] = "H3"
  end
  return el
end

function CodeBlock(el)
  el.attributes["custom-style"] = "Code"
  return el
end

function Code(el)
  return pandoc.Span(el.text, pandoc.Attr("", {}, {{"custom-style", "InlineCode"}}))
end

function BlockQuote(el)
  el.attributes = el.attributes or {}
  return pandoc.Div(el.content, pandoc.Attr("", {}, {{"custom-style", "Callout"}}))
end

function Image(el)
  -- Wrap images in a figure with the ScreenshotFrame object style hint.
  return pandoc.Div({el}, pandoc.Attr("", {}, {{"custom-style", "ScreenshotFrame"}}))
end
