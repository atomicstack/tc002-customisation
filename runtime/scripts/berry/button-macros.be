# button macros -- every button press and hold, published as something that means something
#
# all four buttons report `press`, `release` and `long`, so a hold is a gesture in its own right and
# this script only has to map it. an earlier version of this file timed the hold itself with a
# 100 ms timer, because the firmware had a long press on the knob and nowhere else; that is gone.
#
# a hold does **not** also select a base -- the runtime suppresses the tap when the hold has already
# reported itself. but the device does act on both gestures and a script cannot swallow either: a
# tap selects a base, and a hold shows that base and opens its settings menu. so the tap mappings
# below are the comfortable ones, and a hold mapping publishes with a settings menu on the panel.
# press the same button again to back out of it.
#
# every press is also published by the runtime itself on `<prefix>/input/<control>` with no script
# at all. what this adds is the mapping to a topic that means something to the rest of the house.

var BM_RESTORE_BASE = ''        # 'clock', 'art', 'canvas', or '' to leave the base alone
var BM_FEEDBACK = true          # flash the payload on the panel so you know which gesture landed

# control-gesture -> [topic, payload]. delete a line to leave that gesture doing nothing.
var BM_ACTIONS = {
  'left-release': ['home/tc002/left', 'press'],
  'left-long': ['home/scene/set', 'goodnight'],
  'middle-release': ['home/tc002/middle', 'press'],
  'middle-long': ['home/scene/set', 'movie'],
  'right-release': ['home/tc002/right', 'press'],
  'right-long': ['home/light/study/set', 'toggle'],
  'knob-long': ['home/scene/set', 'reading']
}

var bm_long = {}

def bm_fire(key)
  var action = BM_ACTIONS.find(key, nil)
  if action == nil
    return
  end
  try
    tc002.publish(action[0], action[1])
  except .. as e, m
    print('button macros: the publish was refused: ' + str(m))
    return
  end
  if BM_FEEDBACK
    tc002.notify(action[1], 0x66ccff, 2)
  end
  if BM_RESTORE_BASE != ''
    try
      tc002.scene(BM_RESTORE_BASE)
    except .. as e, m
      print('button macros: the scene was refused: ' + str(m))
    end
  end
end

tc002.on('button', def (control, event, steps)
  if control == 'rotary'
    return
  end
  if event == 'press'
    bm_long[control] = false
  elif event == 'long'
    bm_long[control] = true
    bm_fire(control + '-long')
  elif event == 'release'
    # the release after a hold is the end of that gesture, not a tap of its own. the runtime
    # already suppresses the base change for it; this suppresses the publish to match.
    if bm_long.find(control, false)
      bm_long[control] = false
      return
    end
    bm_fire(control + '-release')
  end
end)
