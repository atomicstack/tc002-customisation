# mqtt gauge -- one number from the broker, with a bar and a colour that means something
#
# point it at any topic carrying a number: co2, a tank level, a power reading, a queue depth. the
# payload may be a bare number or a json object with a field named in GA_FIELD.
#
# berry's number() answers 0 for anything it cannot read, so a payload that is not a number would
# otherwise draw a confident, wrong zero. the payload is checked character by character before it
# is believed -- a topic a script subscribed to is a topic anything on the broker can publish to.
#
# the redraw is throttled. a canvas document is a state change and bumps the revision, so a chatty
# topic would otherwise fill the event stream with a hundred revisions a second.

import json
import string
import time

var GA_TOPIC = 'home/study/co2'
var GA_FIELD = 'value'       # the json field to read; '' when the payload is a bare number
var GA_LABEL = 'co2'
var GA_DECIMALS = 0
var GA_MIN = 400             # the low end of the bar
var GA_MAX = 2000            # and the high end
var GA_WARN = 1000
var GA_ALERT = 1400
var GA_OK_COLOUR = 0x44ff88
var GA_WARN_COLOUR = 0xffaa33
var GA_ALERT_COLOUR = 0xff4444
var GA_STALE_S = 600         # grey the reading out when nothing has arrived for this long
var GA_REDRAW_MS = 500
var GA_TAKE_OVER = false     # select the canvas at load rather than waiting to be asked

var ga_value = nil
var ga_at = 0
var ga_dirty = false
var ga_stale = false

def ga_number(payload)
  if type(payload) != 'string'
    return nil
  end
  var text = payload
  if GA_FIELD != '' && size(text) > 0 && text[0] == '{'
    var doc = json.load(text)
    if !isinstance(doc, map)
      return nil
    end
    var v = doc.find(GA_FIELD, nil)
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

def ga_colour()
  if ga_stale
    return 0x606060
  end
  if ga_value >= GA_ALERT
    return GA_ALERT_COLOUR
  end
  if ga_value >= GA_WARN
    return GA_WARN_COLOUR
  end
  return GA_OK_COLOUR
end

def ga_draw()
  ga_dirty = false
  panel.clear()
  panel.text(2, 0, GA_LABEL, 0x707070)
  if ga_value == nil
    panel.text(26, 0, '--', 0x707070)
    panel.show()
    return
  end
  var colour = ga_colour()
  # berry's format has no '%.*f': the precision has to be built into the string
  var text = string.format('%.' + str(GA_DECIMALS) + 'f', ga_value)
  # there is one face available to a script, five pixels wide and one of gap, so the right edge of
  # an eight-character line is where the panel ends
  var x = 52 - 6 * size(text)
  if x < 0
    x = 0
  end
  panel.text(x, 0, text, colour)
  panel.rect(2, 10, 48, 4, 0x181818, 1)
  var span = GA_MAX - GA_MIN
  if span > 0
    var through = (ga_value - GA_MIN) / span
    if through < 0
      through = 0
    end
    if through > 1
      through = 1
    end
    var w = int(through * 46)
    if w > 0
      panel.rect(3, 11, w, 2, colour, 1)
    end
  end
  panel.show()
end

tc002.subscribe(GA_TOPIC, def (topic, payload)
  var v = ga_number(payload)
  if v == nil
    return
  end
  ga_value = v
  ga_at = time.time()
  ga_stale = false
  ga_dirty = true
end)

tc002.every(GA_REDRAW_MS, def ()
  if ga_dirty
    ga_draw()
  end
end)

tc002.every(15000, def ()
  if ga_value == nil || GA_STALE_S <= 0
    return
  end
  var old = ga_stale
  ga_stale = time.time() - ga_at > GA_STALE_S
  if ga_stale != old
    ga_dirty = true
  end
end)

if GA_TAKE_OVER
  tc002.scene('canvas')
end
ga_draw()
