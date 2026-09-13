# a canvas document built from a script, then shown
panel.clear()
panel.rect(0, 0, 52, 16, 0x001020, 1)
panel.text(2, 4, 'hi', 0xffffff)
panel.icon(40, 4, 'clock', 0xffaa00)
panel.pixel(51, 0, 0xff0000)
var n = panel.show()
assert(n == 4, 'four elements were drawn, got ' + str(n))
