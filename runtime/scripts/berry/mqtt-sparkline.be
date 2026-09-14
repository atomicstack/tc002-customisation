# mqtt sparkline -- the last hour of a number, as a row of columns
#
# the panel's own sparkline element takes up to fifty-two samples, one per column, but a script
# builds its chart out of drawing primitives and a canvas document holds twenty-four elements in
# total. so this draws columns rather than pixels: twelve of them, four pixels wide, which is a
# legible chart and leaves room for the labels.
#
# samples are taken on a timer, not on arrival. a chart whose columns are "whenever the sensor felt
# like publishing" is not a chart of anything.

import json
import string
import time

var SP_TOPIC = 'home/study/temp'
var SP_FIELD = 'value'       # the json field to read; '' when the payload is a bare number
var SP_LABEL = 'temp'
var SP_DECIMALS = 1
var SP_COLUMNS = 12          # at most twenty: the document holds twenty-four elements in all
var SP_PERIOD_MS = 60000     # one column per minute, so twelve columns is the last twelve minutes
var SP_MIN = 0               # leave SP_MIN equal to SP_MAX to scale to whatever has arrived
var SP_MAX = 0
var SP_COLOUR = 0x44aaff
var SP_TAKE_OVER = false

var sp_latest = nil
var sp_samples = []

if SP_COLUMNS > 20
  SP_COLUMNS = 20
end
if SP_COLUMNS < 1
  SP_COLUMNS = 1
end

def sp_number(payload)
  if type(payload) != 'string'
    return nil
  end
  var text = payload
  if SP_FIELD != '' && size(text) > 0 && text[0] == '{'
    var doc = json.load(text)
    if !isinstance(doc, map)
      return nil
    end
    var v = doc.find(SP_FIELD, nil)
    if type(v) == 'int' || type(v) == 'real'
      return v
    end
    if type(v) != 'string'
      return nil
    end
    text = v
  end
  var digits = false
  for i : 0 .. size(text) - 1
    var c = text[i]
    if c >= '0' && c <= '9'
      digits = true
    elif c != '-' && c != '+' && c != '.'
      return nil
    end
  end
  if !digits
    return nil
  end
  return number(text)
end

def sp_draw()
  panel.clear()
  panel.text(2, 0, SP_LABEL, 0x707070)
  if sp_latest != nil
    var text = string.format('%.' + str(SP_DECIMALS) + 'f', sp_latest)
    var x = 52 - 6 * size(text)
    if x < 0
      x = 0
    end
    panel.text(x, 0, text, SP_COLOUR)
  end
  var n = size(sp_samples)
  if n == 0
    panel.show()
    return
  end
  var lo = SP_MIN
  var hi = SP_MAX
  if lo == hi
    lo = sp_samples[0]
    hi = sp_samples[0]
    for v : sp_samples
      if v < lo
        lo = v
      end
      if v > hi
        hi = v
      end
    end
  end
  var span = hi - lo
  # a flat line is flat, not a full-height block
  if span <= 0
    span = 1
  end
  var w = int(48 / SP_COLUMNS)
  if w < 1
    w = 1
  end
  var i = 0
  while i < n
    var through = (sp_samples[i] - lo) / span
    if through < 0
      through = 0
    end
    if through > 1
      through = 1
    end
    var h = int(through * 7) + 1
    panel.rect(2 + i * w, 16 - h, w - 1, h, SP_COLOUR, 1)
    i += 1
  end
  panel.show()
end

tc002.subscribe(SP_TOPIC, def (topic, payload)
  var v = sp_number(payload)
  if v != nil
    sp_latest = v
  end
end)

tc002.every(SP_PERIOD_MS, def ()
  if sp_latest == nil
    return
  end
  sp_samples.push(sp_latest)
  while size(sp_samples) > SP_COLUMNS
    sp_samples.remove(0)
  end
  sp_draw()
end)

if SP_TAKE_OVER
  tc002.scene('canvas')
end
sp_draw()
