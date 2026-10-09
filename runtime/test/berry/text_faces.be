# panel.text takes a face by name, and panel.text_width measures in it
assert(panel.text_width('12:34') == 29, 'small is five columns a glyph and one between: ' + str(panel.text_width('12:34')))
assert(panel.text_width('12:34', 'phoenix') == 40, 'phoenix is eight a glyph')
assert(panel.text_width('20°C', 'ibm-vga') == 32, 'utf-8 is measured in characters')
assert(panel.text_width('') == 0, 'nothing is nothing wide')

panel.clear()
panel.text(0, 0, 'hi', 0xffffff, 'tiny5')
panel.text(0, 8, 'Жизнь', 0xffffff, 'ibm-vga')

var refused = false
try
  panel.text(0, 0, 'hi', 0xffffff, 'comic')
except ..
  refused = true
end
assert(refused, 'a face that does not exist must be refused')

refused = false
try
  panel.text_width('hi', 'comic')
except ..
  refused = true
end
assert(refused, 'measuring in a face that does not exist must be refused too')
