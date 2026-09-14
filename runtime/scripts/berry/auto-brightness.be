# auto brightness -- follow a light sensor on the broker
#
# the clock has no light sensor of its own, but almost every home has one somewhere: a room sensor,
# a phone, a camera, another esp. point this at whatever publishes lux and the panel stops being
# blinding at night and washed out at noon.
#
# two things keep it from twitching. the reading is a rolling average, and a new brightness has to
# differ from the last one by AB_STEP_MIN before it is applied at all -- without that, a sensor
# sitting on a boundary would rewrite the brightness every few seconds for ever.

import json
import math

var AB_TOPIC = 'home/study/lux'
var AB_FIELD = 'value'        # the json field to read; '' when the payload is a bare number
var AB_LUX_DARK = 2           # at or below this, the panel goes to AB_MIN
var AB_LUX_BRIGHT = 400       # at or above this, it goes to AB_MAX
var AB_MIN = 5
var AB_MAX = 90
var AB_SMOOTH = 4             # readings in the rolling average
var AB_STEP_MIN = 4           # the smallest change worth making
var AB_APPLY_MS = 5000

var ab_samples = []
var ab_applied = 0

def ab_number(payload)
  if type(payload) != 'string'
    return nil
  end
  var text = payload
  if AB_FIELD != '' && size(text) > 0 && text[0] == '{'
    var doc = json.load(text)
    if !isinstance(doc, map)
      return nil
    end
    var v = doc.find(AB_FIELD, nil)
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

def ab_level(lux)
  var span = AB_LUX_BRIGHT - AB_LUX_DARK
  if span <= 0
    return AB_MAX
  end
  var through = (lux - AB_LUX_DARK) / span
  if through < 0
    through = 0
  end
  if through > 1
    through = 1
  end
  # the eye is not linear in light and neither is this: the square root spends more of the range
  # where the difference between ten and twenty percent is actually visible
  through = math.sqrt(through)
  return AB_MIN + int((AB_MAX - AB_MIN) * through)
end

tc002.subscribe(AB_TOPIC, def (topic, payload)
  var v = ab_number(payload)
  if v == nil || v < 0
    return
  end
  ab_samples.push(v)
  while size(ab_samples) > AB_SMOOTH
    ab_samples.remove(0)
  end
end)

tc002.every(AB_APPLY_MS, def ()
  if size(ab_samples) == 0
    return
  end
  var total = 0
  for v : ab_samples
    total += v
  end
  var want = ab_level(total / size(ab_samples))
  if ab_applied > 0 && math.abs(want - ab_applied) < AB_STEP_MIN
    return
  end
  try
    tc002.brightness(want)
    ab_applied = want
  except .. as e, m
    print('auto brightness: the brightness was refused: ' + str(m))
  end
end)
