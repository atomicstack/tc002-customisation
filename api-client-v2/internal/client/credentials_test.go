package client

import (
	"strings"
	"testing"
)

// regression: the runtime writes `client=<name>,<scope|scope|...>,<64 hex>` rows once a named token
// is issued (credfile.zig). this parser only accepted the old `read`/`control` rank in that middle
// field and failed the whole file otherwise, so one issued token made every credentials file
// unreadable to this client.
func TestNamedClientAcceptsScopeSets(t *testing.T) {
	hex := strings.Repeat("ab", 32)
	for _, middle := range []string{"notify|display", "status", "content|scripts|settings", "read", "control"} {
		if name, ok := namedClient("kitchen," + middle + "," + hex); !ok || name != "kitchen" {
			t.Errorf("namedClient rejected %q (name=%q ok=%v)", middle, name, ok)
		}
	}
	if _, ok := namedClient("kitchen,notify|nonsense," + hex); ok {
		t.Error("an unknown scope name should still be refused")
	}
}
