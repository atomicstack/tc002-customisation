# autoexec -- the one name that runs by itself
#
# a stored script sits there until something runs it. `autoexec` is the exception: the supervisor
# hands berryd the whole store and then runs the script called `autoexec`, which is what makes a
# script survive a power cycle. everything else has to be started deliberately, with
# `POST /api/v1/berry/scripts/<name>/run` or the console's "run saved".
#
# there is no import and no require here -- berryd has no filesystem, and one script cannot call
# another. to have several of the scripts in this directory running at once, concatenate them into
# `autoexec`:
#
#     cat night-mode.be mqtt-gauge.be > autoexec.be
#     curl -X PUT --data-binary @autoexec.be -H "authorization: Bearer $ADMIN" \
#          -H 'content-type: text/plain' http://<device>/api/v1/berry/scripts/autoexec
#
# every script here prefixes its globals with its own initials for exactly that reason, so nothing
# collides when two of them are pasted together. two limits decide how many fit: one script is at
# most 8,000 bytes, and compiled berry is about 2.3 times its source on this cpu, against a 256 kb
# heap.
#
# what follows is a starter. it takes nothing over: no scene change, no brightness change, nothing
# drawn. it says hello and then reports in.

import string
import time

var AX_ANNOUNCE = true                    # a notification when the vm comes up
var AX_TOPIC = 'tc002/berry/boot'         # '' to publish nothing
var AX_HEARTBEAT_S = 600                  # 0 to stay quiet after the first message

var ax_started = time.time()

def ax_report(what)
  if AX_TOPIC == ''
    return
  end
  try
    tc002.publish(AX_TOPIC, string.format('{"event":"%s","up_s":%d}', what, time.time() - ax_started))
  except .. as e, m
    # mqtt may simply be off, which is not an error worth losing the rest of the script over
    print('autoexec: the publish was refused: ' + str(m))
  end
end

if AX_ANNOUNCE
  tc002.notify('scripts up', 0x44ff88, 3)
end
ax_report('start')

if AX_HEARTBEAT_S > 0
  tc002.every(AX_HEARTBEAT_S * 1000, def ()
    ax_report('alive')
  end)
end
