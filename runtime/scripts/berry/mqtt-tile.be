# mqtt tile -- an icon and a reading, the shape most dashboards actually want
#
# give it a json payload with a condition and a number: the condition picks one of the sixty-one
# built-in icons, the number is drawn beside it. a weather feed is the obvious use, but anything
# with a state and a value fits -- a washing machine, a car charger, a bin day.
#
# the icons are monochrome and take the element's colour, so the colour is yours to choose. an
# unknown condition falls back rather than raising: the panel showing the wrong icon is better than
# a handler that stops running.

import json
import string
import time

var TI_TOPIC = 'home/weather'
var TI_STATE_FIELD = 'condition'
var TI_VALUE_FIELD = 'temp'
var TI_SUFFIX = 'c'          # the icon takes twelve pixels, so about six characters fit beside it
var TI_DECIMALS = 0
var TI_DEFAULT_ICON = 'thermometer'
var TI_COLOUR = 0xffaa33
var TI_STALE_S = 1800
var TI_TAKE_OVER = false

# condition -> icon name. every name here is one `GET /api/v1/icons` lists.
var TI_ICONS = {
  'clear': 'sun',
  'sunny': 'sun',
  'night': 'moon',
  'cloud': 'cloud',
  'cloudy': 'cloud',
  'partlycloudy': 'cloud',
  'rain': 'cloud-rain',
  'rainy': 'cloud-rain',
  'pouring': 'cloud-rain',
  'snow': 'cloud-snow',
  'snowy': 'cloud-snow',
  'storm': 'storm',
  'lightning': 'storm',
  'fog': 'fog',
  'windy': 'fan',
  'hot': 'flame',
  'cold': 'snowflake'
}

var ti_icon = TI_DEFAULT_ICON
var ti_text = '--'
var ti_at = 0
var ti_dirty = false

def ti_draw()
  ti_dirty = false
  var colour = TI_COLOUR
  if TI_STALE_S > 0 && ti_at > 0 && time.time() - ti_at > TI_STALE_S
    colour = 0x606060
  end
  panel.clear()
  try
    panel.icon(2, 4, ti_icon, colour)
  except .. as e, m
    # an icon name that is not one of the sixty-one is a configuration mistake, not a reason to
    # stop drawing the reading
    panel.icon(2, 4, 'question', colour)
  end
  panel.text(14, 4, ti_text, colour)
  panel.show()
end

tc002.subscribe(TI_TOPIC, def (topic, payload)
  if type(payload) != 'string' || size(payload) == 0 || payload[0] != '{'
    return
  end
  var doc = json.load(payload)
  if !isinstance(doc, map)
    return
  end
  var state = doc.find(TI_STATE_FIELD, nil)
  if type(state) == 'string'
    ti_icon = TI_ICONS.find(string.tolower(state), TI_DEFAULT_ICON)
  end
  var value = doc.find(TI_VALUE_FIELD, nil)
  if type(value) == 'int' || type(value) == 'real'
    ti_text = string.format('%.' + str(TI_DECIMALS) + 'f', value) + TI_SUFFIX
  elif type(value) == 'string' && size(value) > 0 && size(value) <= 6
    ti_text = value
  end
  ti_at = time.time()
  ti_dirty = true
end)

tc002.every(500, def ()
  if ti_dirty
    ti_draw()
  end
end)

tc002.every(30000, def ()
  if TI_STALE_S > 0 && ti_at > 0
    ti_dirty = true
  end
end)

if TI_TAKE_OVER
  tc002.scene('canvas')
end
ti_draw()
