# watch my clock -- the device subscribing to its own state, and saying when it does not like it
#
# the runtime publishes its whole status document on `<prefix>/state`, retained, whenever it
# changes. a script can subscribe to that: it is the device's own traffic, not a command topic, so
# the supervisor allows it -- what it would refuse is a filter like `<prefix>/cmd/#`, which would
# swallow the commands sent to the clock.
#
# so the clock watches itself. it notices the renderer restarting, the time falling out of sync,
# the broker reconnecting, memory going, and settings that have been changed but never saved. that
# last one matters here more than it looks: everything in /tmp is gone after a power cycle, and an
# unsaved revision is work you are about to lose.

import json
import string
import time

var WC_PREFIX = 'tc002'            # must match the mqtt prefix setting
var WC_PUBLISH_TO = 'tc002/berry/health'   # '' to publish nothing
var WC_PUBLISH_EVERY_S = 300
var WC_MEMORY_FLOOR_KB = 4000
var WC_UNSAVED_GRACE_S = 900       # how long settings may sit unsaved before it says so
var WC_NOTIFY = true

var wc_restarts = nil
var wc_reconnects = nil
var wc_time_state = ''
var wc_unsaved_since = 0
var wc_last_publish = 0
var wc_last = nil

def wc_say(text, colour)
  print('watch: ' + text)
  if WC_NOTIFY
    tc002.notify(text, colour, 6)
  end
end

def wc_int(doc, key)
  var v = doc.find(key, nil)
  if type(v) == 'int'
    return v
  end
  if type(v) == 'real'
    return int(v)
  end
  return nil
end

tc002.subscribe(WC_PREFIX + '/state', def (topic, payload)
  if type(payload) != 'string' || size(payload) == 0 || payload[0] != '{'
    return
  end
  var doc = json.load(payload)
  if !isinstance(doc, map)
    return
  end
  wc_last = doc
  var now = time.time()

  var restarts = wc_int(doc, 'restarts')
  if restarts != nil
    if wc_restarts != nil && restarts > wc_restarts
      wc_say('renderer restarted', 0xff5555)
    end
    wc_restarts = restarts
  end

  var mqtt_doc = doc.find('mqtt', nil)
  if isinstance(mqtt_doc, map)
    var reconnects = wc_int(mqtt_doc, 'reconnects')
    if reconnects != nil
      if wc_reconnects != nil && reconnects > wc_reconnects
        wc_say('broker reconnect', 0xffaa33)
      end
      wc_reconnects = reconnects
    end
  end

  var time_doc = doc.find('time', nil)
  if isinstance(time_doc, map)
    var state = time_doc.find('state', '')
    if type(state) == 'string' && state != wc_time_state
      if wc_time_state != '' && state != 'synced'
        wc_say('time ' + state, 0xffaa33)
      end
      wc_time_state = state
    end
  end

  var free_kb = wc_int(doc, 'memory_available_kb')
  if free_kb != nil && WC_MEMORY_FLOOR_KB > 0 && free_kb < WC_MEMORY_FLOOR_KB
    wc_say('low memory', 0xff5555)
  end

  var live = wc_int(doc, 'config_revision')
  var saved = wc_int(doc, 'saved_revision')
  if live != nil && saved != nil
    if live == saved
      wc_unsaved_since = 0
    elif wc_unsaved_since == 0
      wc_unsaved_since = now
    elif now - wc_unsaved_since > WC_UNSAVED_GRACE_S
      wc_say('unsaved config', 0xffaa33)
      wc_unsaved_since = now
    end
  end
end)

tc002.every(30000, def ()
  if WC_PUBLISH_TO == '' || wc_last == nil
    return
  end
  var now = time.time()
  if now - wc_last_publish < WC_PUBLISH_EVERY_S
    return
  end
  wc_last_publish = now
  var summary = {}
  summary['uptime_s'] = wc_int(wc_last, 'uptime_s')
  summary['free_kb'] = wc_int(wc_last, 'memory_available_kb')
  summary['restarts'] = wc_restarts
  summary['reconnects'] = wc_reconnects
  summary['time'] = wc_time_state
  summary['unsaved'] = wc_unsaved_since != 0
  try
    tc002.publish(WC_PUBLISH_TO, json.dump(summary))
  except .. as e, m
    print('watch: the publish was refused: ' + str(m))
  end
end)
