# button macros -- give the three buttons a long press, and make them publish
#
# the firmware has no long press on the three buttons: they report press and release and nothing
# else, and only the knob reports long. so this times the gap itself with a timer, which gives all
# three a second gesture and turns the clock into a three-button remote for whatever is on your
# broker.
#
# the buttons keep doing their own job as well -- left, middle and right select the clock, art and
# canvas bases, and a script cannot swallow that. set BM_RESTORE_BASE if you would rather the panel
# went back to one thing afterwards.
#
# every press is also published by the runtime itself on `<prefix>/input/<control>`, without any
# script at all. what this adds is the long press and the mapping to a topic that means something.

var BM_HOLD_MS = 600
var BM_TICK_MS = 100
var BM_RESTORE_BASE = ''        # 'clock', 'art', 'canvas', or '' to leave the base alone
var BM_FEEDBACK = true          # flash a word on the panel so you know which gesture landed

# control-gesture -> [topic, payload]. delete a line to leave that gesture doing nothing.
var BM_ACTIONS = {
  'left-short': ['home/tc002/left', 'press'],
  'left-long': ['home/scene/set', 'goodnight'],
  'middle-short': ['home/tc002/middle', 'press'],
  'middle-long': ['home/scene/set', 'movie'],
  'right-short': ['home/tc002/right', 'press'],
  'right-long': ['home/light/study/set', 'toggle']
}

var bm_held = {}
var bm_fired = {}

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
  if control != 'left' && control != 'middle' && control != 'right'
    return
  end
  if event == 'press'
    bm_held[control] = 0
    bm_fired[control] = false
  elif event == 'release'
    # a release the script never saw the press for is not a short press, it is a lost event
    if !bm_held.contains(control)
      return
    end
    var was_long = bm_fired.find(control, false)
    bm_held.remove(control)
    bm_fired.remove(control)
    if !was_long
      bm_fire(control + '-short')
    end
  end
end)

tc002.every(BM_TICK_MS, def ()
  for control : bm_held.keys()
    var held = bm_held[control] + BM_TICK_MS
    bm_held[control] = held
    if held >= BM_HOLD_MS && !bm_fired.find(control, false)
      bm_fired[control] = true
      bm_fire(control + '-long')
    end
  end
end)
