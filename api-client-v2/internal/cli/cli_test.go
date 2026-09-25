package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func execute(t *testing.T, args []string, input string) (string, error) {
	t.Helper()
	cmd := NewCommand()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(io.Discard)
	cmd.SetIn(strings.NewReader(input))
	cmd.SetArgs(args)
	err := cmd.ExecuteContext(context.Background())
	return out.String(), err
}

func TestRuntimeRequests(t *testing.T) {
	tests := []struct {
		args               []string
		method, path, body string
	}{
		{[]string{"status"}, "GET", "/status", ""},
		{[]string{"scenes"}, "GET", "/scenes", ""},
		{[]string{"scene", "art", "--generator", "cube", "--seed", "0"}, "PUT", "/scene", `{"base":"art","generator":"cube","seed":0}`},
		{[]string{"scene", "art", "--generator", "terrain", "--seed", "7"}, "PUT", "/scene", `{"base":"art","generator":"terrain","seed":7}`},
		{[]string{"config", "set", "--generator", "terrain"}, "PATCH", "/config", `{"generator":"terrain"}`},
		{[]string{"scene", "clock", "--font", "mini", "--digits", "outline", "--spread", "0"}, "PUT", "/scene", `{"base":"clock","clock":{"font":"mini","digits":"outline","spread":0}}`},
		{[]string{"brightness", "50", "--epoch", "12", "--request-id", "ab"}, "POST", "/action", `{"action":"brightness","brightness":50,"epoch":12,"request_id":"ab"}`},
		{[]string{"reseed", "0"}, "POST", "/action", `{"action":"reseed","seed":0}`},
		{[]string{"arm-stream"}, "POST", "/action", `{"action":"arm_stream"}`},
		{[]string{"power", "off"}, "POST", "/action", `{"action":"power","power":false}`},
		{[]string{"input", "rotary", "ccw", "--steps", "3"}, "POST", "/input", `{"control":"rotary","event":"ccw","steps":3}`},
		{[]string{"notify", "Hello World", "--colour", "00ff80", "--duration", "3", "--transition", "slide", "--direction", "left"}, "POST", "/notify", `{"text":"Hello World","colour":"00ff80","duration_s":3,"transition":"slide","direction":"left"}`},
		{[]string{"notify", "hi", "--transition", "ripple", "--easing", "ease_out"}, "POST", "/notify", `{"text":"hi","transition":"ripple","easing":"ease_out"}`},
		{[]string{"config", "set", "--discovery-controls=true"}, "PATCH", "/config", `{"discovery_controls":true}`},
		{[]string{"config", "set", "--discovery-controls=false"}, "PATCH", "/config", `{"discovery_controls":false}`},
		{[]string{"config", "get"}, "GET", "/config", ""},
		{[]string{"config", "set", "--brightness", "20", "--clock-colour", "001122", "--night=false", "--timezone", "Europe/Amsterdam"}, "PATCH", "/config", `{"brightness":20,"clock_colour":"001122","night":false,"timezone":"Europe/Amsterdam"}`},
		{[]string{"config", "set", "--data", `{"generator_params":[{"scene":"cube","name":"speed","value":"2"}]}`}, "PATCH", "/config", `{"generator_params":[{"scene":"cube","name":"speed","value":"2"}]}`},
		{[]string{"config", "save", "--revision", "0"}, "POST", "/config/save", `{"revision":0}`},
		{[]string{"mqtt", "get"}, "GET", "/mqtt", ""},
		{[]string{"mqtt", "set", "--enabled=false", "--port", "1883", "--password", "000123"}, "PUT", "/mqtt", `{"enabled":false,"port":1883,"password":"000123"}`},
		{[]string{"mqtt", "status"}, "GET", "/mqtt/status", ""},
		{[]string{"ntfy", "get"}, "GET", "/ntfy", ""},
		{[]string{"ntfy", "set", "--url", "https://ntfy.example", "--topic", "1234", "--insecure=false"}, "PUT", "/ntfy", `{"url":"https://ntfy.example","topic":"1234","insecure":false}`},
		{[]string{"canvas", "get"}, "GET", "/canvas", ""},
		{[]string{"canvas", "put", "--data", `{"elements":[]}`}, "PUT", "/canvas", `{"elements":[]}`},
		{[]string{"canvas", "patch", "--data", `{"values":[{"id":"temp","text":"21"}]}`}, "PATCH", "/canvas", `{"values":[{"id":"temp","text":"21"}]}`},
		{[]string{"canvas", "clear"}, "DELETE", "/canvas", ""},
		{[]string{"icons"}, "GET", "/icons", ""},
		{[]string{"sprites", "list"}, "GET", "/sprites", ""},
		{[]string{"sprites", "delete", "sun"}, "DELETE", "/sprites/sun", ""},
		{[]string{"sounds", "list"}, "GET", "/sounds", ""},
		{[]string{"sounds", "play", "chime", "--volume", "42", "--loop=false"}, "POST", "/sound", `{"name":"chime","volume":42,"loop":false}`},
		{[]string{"sounds", "stop"}, "POST", "/sound", `{"stop":true}`},
		{[]string{"sounds", "delete", "chime"}, "DELETE", "/sounds/chime", ""},
		{[]string{"berry"}, "GET", "/berry", ""},
		{[]string{"scripts", "list"}, "GET", "/berry/scripts", ""},
		{[]string{"scripts", "get", "demo"}, "GET", "/berry/scripts/demo", ""},
		{[]string{"scripts", "run", "demo"}, "POST", "/berry/scripts/demo/run", ""},
		{[]string{"scripts", "delete", "demo"}, "DELETE", "/berry/scripts/demo", ""},
		{[]string{"tokens", "list"}, "GET", "/tokens", ""},
		// a token holds scopes, not a rank: the runtime dropped roles in b53f679 and its parser
		// refuses unknown fields, so the old `{"role":...}` body was a 400 on every create.
		{[]string{"tokens", "create", "ha", "--scope", "notify", "--scope", "display"}, "POST", "/tokens", `{"name":"ha","scopes":["notify","display"]}`},
		{[]string{"tokens", "rotate", "ha", "--scope", "status"}, "POST", "/tokens/ha/rotate", `{"scopes":["status"]}`},
		{[]string{"tokens", "rotate", "ha"}, "POST", "/tokens/ha/rotate", `{}`},
		{[]string{"tokens", "revoke", "ha"}, "DELETE", "/tokens/ha", ""},
		{[]string{"screen", "--format", "raw"}, "GET", "/screen?format=raw", ""},
		{[]string{"logs", "--after", "12"}, "GET", "/logs?after=12", ""},
		{[]string{"request", "GET", "/status"}, "GET", "/status", ""},
		// the routes the client used to leave to `request`: a named notification that queues and
		// holds, its dismissal, the block face's fade on both the transient and the durable side,
		// a reboot, and the reboot scope on a named token.
		{[]string{"notify", "doorbell", "--name", "door", "--stack", "--hold"}, "POST", "/notify", `{"text":"doorbell","name":"door","stack":true,"hold":true}`},
		{[]string{"dismiss", "door"}, "POST", "/notify/dismiss", `{"name":"door"}`},
		// a name may be as long as the device allows: 255 characters
		{[]string{"dismiss", strings.Repeat("d", 255)}, "POST", "/notify/dismiss", `{"name":"` + strings.Repeat("d", 255) + `"}`},
		{[]string{"notify", "hi", "--name", strings.Repeat("n", 255)}, "POST", "/notify", `{"text":"hi","name":"` + strings.Repeat("n", 255) + `"}`},
		{[]string{"dismiss"}, "POST", "/notify/dismiss", `{}`},
		{[]string{"dismiss", "--request-id", "ab"}, "POST", "/notify/dismiss", `{"request_id":"ab"}`},
		{[]string{"scene", "clock", "--font", "block", "--fade"}, "PUT", "/scene", `{"base":"clock","clock":{"font":"block","fade":true}}`},
		{[]string{"scene", "clock", "--fade=false"}, "PUT", "/scene", `{"base":"clock","clock":{"fade":false}}`},
		{[]string{"config", "set", "--clock-fade=true"}, "PATCH", "/config", `{"clock_fade":true}`},
		{[]string{"reboot"}, "POST", "/reboot", ""},
		{[]string{"tokens", "create", "ops", "--scope", "status", "--scope", "reboot"}, "POST", "/tokens", `{"name":"ops","scopes":["status","reboot"]}`},
		// a document notification and a canvas that is shown without being saved
		{[]string{"notify", "--data", `{"elements":[{"type":"rect","at":[0,0],"size":[52,16]}],"hold":true,"name":"updating"}`}, "POST", "/notify", `{"elements":[{"type":"rect","at":[0,0],"size":[52,16]}],"hold":true,"name":"updating"}`},
		{[]string{"notify", "parcel", "--data", `{"elements":[{"type":"rect","at":[0,0],"size":[4,4]}]}`}, "POST", "/notify", `{"text":"parcel","elements":[{"type":"rect","at":[0,0],"size":[4,4]}]}`},
		{[]string{"canvas", "put", "--data", `{"elements":[]}`, "--persist=false"}, "PUT", "/canvas", `{"elements":[],"persist":false}`},
		{[]string{"canvas", "put", "--data", `{"elements":[]}`}, "PUT", "/canvas", `{"elements":[]}`},
	}
	for _, tt := range tests {
		t.Run(strings.Join(tt.args, " "), func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != tt.method || r.URL.RequestURI() != "/api/v1"+tt.path {
					t.Errorf("request = %s %s", r.Method, r.URL.RequestURI())
				}
				if r.Header.Get("Authorization") != "Bearer "+testToken {
					t.Error("missing bearer token")
				}
				body, _ := io.ReadAll(r.Body)
				if tt.body == "" {
					if len(body) != 0 {
						t.Errorf("unexpected body: %s", body)
					}
				} else {
					if r.Header.Get("Content-Type") != "application/json" {
						t.Error("missing json content type")
					}
					var got, want any
					if err := json.Unmarshal(body, &got); err != nil {
						t.Error(err)
					}
					_ = json.Unmarshal([]byte(tt.body), &want)
					if !reflect.DeepEqual(got, want) {
						t.Errorf("body = %s, want %s", body, tt.body)
					}
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = io.WriteString(w, `{"ok":true}`)
			}))
			defer server.Close()
			args := append([]string{"--server", server.URL, "--token", testToken}, tt.args...)
			out, err := execute(t, args, "")
			if err != nil {
				t.Fatal(err)
			}
			if calls != 1 {
				t.Errorf("calls = %d", calls)
			}
			if !strings.Contains(out, `"ok": true`) {
				t.Errorf("output = %q", out)
			}
		})
	}
}

func TestValidationBeforeNetwork(t *testing.T) {
	for _, args := range [][]string{
		{"scene", "ip"}, {"scene", "clock", "--generator", "unknown"}, {"brightness", "0"}, {"brightness", "101"},
		{"notify", "hello", "--duration", "301"}, {"notify", "héllo"}, {"notify", "hi", "--colour", "zzzzzz"},
		{"input", "left", "cw"}, {"input", "left", "long"}, {"input", "middle", "click", "--steps", "2"},
		{"input", "rotary", "cw", "--steps", "17"}, {"power", "maybe"}, {"reseed", "-1"},
		{"scene", "art", "--transition-ms", "5001"}, {"scene", "art", "--request-id", "zz"},
		{"config", "set"}, {"config", "set", "--data", "null"}, {"config", "set", "--data", `{}`, "--night"},
		{"scripts", "run", "../x"}, {"sprites", "delete", "longerthan8"}, {"tokens", "create", ".hidden"},
		{"request", "GET", "https://elsewhere/status"}, {"request", "GET", "/../status"},
		// a notification name is letters, digits, _ or -: no dot, unlike a token or script name
		{"notify", "hi", "--name", "door.bell"}, {"dismiss", "door.bell"}, {"dismiss", strings.Repeat("d", 256)}, {"notify", "hi", "--name", strings.Repeat("n", 256)}, {"reboot", "now"},
		// a notification needs its text or a document, and data does not mix with field flags
		{"notify"}, {"notify", "hi", "--data", "{}", "--hold"}, {"notify", "héllo", "--data", "{}"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			_, err := execute(t, args, "")
			if err == nil {
				t.Fatal("expected usage error")
			}
			if ExitCode(err) != 2 {
				t.Errorf("expected usage error, got %v", err)
			}
		})
	}
}

func TestCompletion(t *testing.T) {
	for _, tt := range []struct {
		args []string
		want string
	}{
		{[]string{"scene", "--generator", ""}, "plasma"},
		{[]string{"scene", ""}, "canvas"},
		{[]string{"input", "rotary", ""}, "cw"},
		{[]string{"config", "set", "--clock-font", ""}, "segment"},
		{[]string{"tokens", "create", "ha", "--scope", ""}, "status"},
		{[]string{"notify", "hi", "--transition", ""}, "rain_random"},
		{[]string{"notify", "hi", "--transition", ""}, "interlace"},
		{[]string{"notify", "hi", "--transition", ""}, "shrink"},
		{[]string{"scene", "art", "--easing", ""}, "ease_in_out"},
		{[]string{"screen", "--format", ""}, "raw"},
		{[]string{"config", "set", "--"}, "--night"},
	} {
		out, err := execute(t, append([]string{"__complete"}, tt.args...), "")
		if err != nil || !strings.Contains(out, tt.want) {
			t.Errorf("%v: output=%q err=%v", tt.args, out, err)
		}
	}
	for _, shell := range []string{"bash", "zsh"} {
		out, err := execute(t, []string{"completion", shell}, "")
		if err != nil || !strings.Contains(out, "__complete") {
			t.Errorf("%s: %v, %q", shell, err, out)
		}
	}
}

func TestMedia(t *testing.T) {
	for _, tt := range []struct {
		args                             []string
		input, method, path, contentType string
	}{
		{[]string{"scripts", "put", "demo", "-"}, "print('Hello')\n", "PUT", "/berry/scripts/demo", "text/plain"},
		{[]string{"sprites", "put", "sun", "-"}, strings.Repeat("x", 192), "PUT", "/sprites/sun", "application/octet-stream"},
		{[]string{"frame", "-", "--duration", "2"}, strings.Repeat("x", 2496), "POST", "/frame?duration_s=2", "application/octet-stream"},
		{[]string{"canvas", "put", "--data", "-"}, `{"elements":[]}`, "PUT", "/canvas", "application/json"},
	} {
		t.Run(tt.path, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				if string(body) != tt.input || r.Method != tt.method || r.URL.RequestURI() != "/api/v1"+tt.path || r.Header.Get("Content-Type") != tt.contentType {
					t.Errorf("unexpected request: %s %s %s %q", r.Method, r.URL, r.Header.Get("Content-Type"), body)
				}
				_, _ = io.WriteString(w, `{}`)
			}))
			defer srv.Close()
			_, err := execute(t, append([]string{"-s", srv.URL, "--token", testToken}, tt.args...), tt.input)
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSoundChunksAndOutputFile(t *testing.T) {
	data := strings.Repeat("x", 8192) + "end"
	var chunks [][]byte
	var queries []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		chunks = append(chunks, b)
		queries = append(queries, r.URL.RawQuery)
		if r.Method != "PUT" || r.URL.Path != "/api/v1/sounds/chime" {
			t.Error("wrong upload route")
		}
		_, _ = io.WriteString(w, `{"stored":true}`)
	}))
	defer srv.Close()
	out, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "sounds", "upload", "chime", "-"}, data)
	if err != nil {
		t.Fatal(err)
	}
	if string(bytes.Join(chunks, nil)) != data || len(chunks) != 3 {
		t.Fatalf("bad chunks: %d", len(chunks))
	}
	if !reflect.DeepEqual(queries, []string{"offset=0", "offset=4096", "final=1&offset=8192"}) {
		t.Errorf("queries=%v", queries)
	}
	if strings.Count(out, "stored") != 1 {
		t.Errorf("output=%q", out)
	}
	raw := []byte{0, 1, 2, 255}
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(raw)
	}))
	defer srv2.Close()
	file := filepath.Join(t.TempDir(), "screen.rgb")
	out, err = execute(t, []string{"-s", srv2.URL, "--token", testToken, "screen", "--format", "raw", "--out", file}, "")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(file)
	if !bytes.Equal(b, raw) || out != "" {
		t.Errorf("file=%v stdout=%q", b, out)
	}
}

func TestCommandAuthSelection(t *testing.T) {
	admin := strings.Repeat("a", 64)
	file := filepath.Join(t.TempDir(), "tokens")
	if err := os.WriteFile(file, []byte("control="+testToken+"\nadmin="+admin+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"status"}, {"config", "set", "--brightness", "20"}, {"scripts", "run", "demo"}, {"sounds", "play", "chime"}, {"reboot"}, {"dismiss"}} {
		want := testToken
		if args[0] == "config" || args[0] == "scripts" || args[0] == "reboot" {
			want = admin
		}
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer "+want {
				t.Error("wrong token role")
			}
			_, _ = io.WriteString(w, `{}`)
		}))
		_, err := execute(t, append([]string{"-s", srv.URL, "--token-file", file}, args...), "")
		srv.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}
