# a script that owns the pixels. it draws with the same calls a canvas document uses; what
# differs is that push() renders them and sends the frame, rather than installing a document
# for the renderer to animate.
panel.stream()

var f = 0
while f < 5
  panel.clear()
  panel.rect(0, 0, 52, 16, 0x000000, 1)
  panel.rect(f * 10, 4, 8, 8, 0x00ff00, 1)
  var seq = panel.push()
  assert(seq == f + 1, 'the sequence number counts frames, got ' + str(seq))
  f += 1
end
