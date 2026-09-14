package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestResponsePreservesTextAndBinary(t *testing.T) {
	for _, ct := range []string{"text/plain", "application/octet-stream"} {
		t.Run(ct, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", ct)
				_, _ = io.WriteString(w, "1234")
			}))
			defer srv.Close()
			out, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "status"}, "")
			if err != nil || out != "1234" {
				t.Fatalf("out=%q err=%v", out, err)
			}
		})
	}
}

func TestErrorsDoNotOverwriteOutput(t *testing.T) {
	file := filepath.Join(t.TempDir(), "output")
	_ = os.WriteFile(file, []byte("keep"), 0600)
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(403)
		_, _ = io.WriteString(w, `{"error":"forbidden"}`)
	}))
	defer srv.Close()
	out, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "--out", file, "status"}, "")
	if err == nil || ExitCode(err) != 1 || !strings.Contains(err.Error(), "403") || out != "" {
		t.Errorf("out=%q err=%v", out, err)
	}
	b, _ := os.ReadFile(file)
	if string(b) != "keep" || calls != 1 {
		t.Error("overwritten output or repeated request")
	}
}

func TestSoundStopsOnFailedChunk(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 2 {
			w.WriteHeader(409)
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer srv.Close()
	out, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "sounds", "upload", "chime", "-"}, strings.Repeat("x", 9000))
	if err == nil || calls != 2 || out != "" {
		t.Fatalf("calls=%d out=%q err=%v", calls, out, err)
	}
}

func TestEnvironmentAndExplicitCredentials(t *testing.T) {
	envToken := strings.Repeat("e", 64)
	fileToken := strings.Repeat("f", 64)
	file := filepath.Join(t.TempDir(), "credentials")
	_ = os.WriteFile(file, []byte(fileToken), 0600)
	t.Setenv("TC002_TOKEN", envToken)
	for _, tt := range []struct {
		args []string
		want string
	}{
		{[]string{"status"}, envToken},
		{[]string{"--token-file", file, "status"}, fileToken},
		{[]string{"--token", testToken, "status"}, testToken},
		{[]string{"--token", testToken, "--token-file", file, "status"}, testToken},
		{[]string{"--token", testToken, "ntfy", "set", "--subscription-token", "SecretCase"}, testToken},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer "+tt.want {
				t.Error("incorrect credential precedence")
			}
			if r.URL.Path == "/api/v1/ntfy" {
				b, _ := io.ReadAll(r.Body)
				if string(b) != `{"token":"SecretCase"}` {
					t.Errorf("body=%s", b)
				}
			}
			_, _ = io.WriteString(w, `{}`)
		}))
		t.Setenv("TC002_SERVER", srv.URL)
		_, err := execute(t, tt.args, "")
		srv.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestJSONFileAndCompletingFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "canvas.json")
	_ = os.WriteFile(file, []byte(`{"elements":[]}`), 0600)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if string(b) != `{"elements":[]}` {
			t.Errorf("body=%s", b)
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer srv.Close()
	_, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "canvas", "put", "--data", "@" + file}, "")
	if err != nil {
		t.Fatal(err)
	}
	out, err := execute(t, []string{"__complete", "canvas", "put", "--data", "@" + filepath.Dir(file) + "/can"}, "")
	if err != nil || !strings.Contains(out, "@"+file) {
		t.Fatalf("file completion=%q err=%v", out, err)
	}
}

func TestMoreValidation(t *testing.T) {
	for _, args := range [][]string{
		{"unknown"}, {"config", "unknown"}, {"--unknown"}, {"status", "extra"},
		{"ntfy", "set", "--duration", "0"}, {"config", "set", "--ntp-interval-s", "400"}, {"config", "set", "--metrics-interval-s", "1"},
		{"frame", "-"}, {"sprites", "put", "icon", "-"}, {"scripts", "put", "demo", "-"},
		{"scene", "art", "--request-id", "0xabc"},
	} {
		_, err := execute(t, args, strings.Repeat("x", 8001))
		if err == nil || ExitCode(err) != 2 {
			t.Errorf("%v: %v (exit %d)", args, err, ExitCode(err))
		}
	}
}

func TestEventsStreamAndCancellation(t *testing.T) {
	first := "event: applied\ndata: {\"source\":\"api\"}\n\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/events" {
			t.Error("wrong event route")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, first)
		w.(http.Flusher).Flush()
		time.Sleep(80 * time.Millisecond)
		_, _ = io.WriteString(w, first)
	}))
	defer srv.Close()
	out, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "--timeout", "40ms", "events"}, "")
	if err != nil || out != first+first {
		t.Fatalf("stream=%q err=%v", out, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cmd := NewCommand()
	cmd.SetArgs([]string{"-s", srv.URL, "--token", testToken, "events"})
	cmd.SetOut(io.Discard)
	cmd.SetErr(io.Discard)
	err = cmd.ExecuteContext(ctx)
	if !errors.Is(err, context.Canceled) || ExitCode(err) != 130 {
		t.Fatalf("cancellation=%v", err)
	}
}

func TestFrameColour(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if !bytes.Equal(b, bytes.Repeat([]byte{0, 255, 128}, 832)) || r.URL.Query().Get("duration_s") != "5" {
			t.Error("bad solid frame")
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer srv.Close()
	_, err := execute(t, []string{"-s", srv.URL, "--token", testToken, "frame", "--colour", "00ff80"}, "")
	if err != nil {
		t.Fatal(err)
	}
}

func TestHelpDoesNotRevealEnvironmentToken(t *testing.T) {
	token := strings.Repeat("b", 64)
	t.Setenv("TC002_TOKEN", token)
	for _, args := range [][]string{nil, {"--help"}, {"scene", "--help"}, {"ntfy", "set", "--help"}} {
		out, err := execute(t, args, "")
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(out, token) {
			t.Fatal("help reveals the environment token")
		}
	}
}

func TestSpriteIDRejectsDot(t *testing.T) {
	_, err := execute(t, []string{"sprites", "delete", "a.b"}, "")
	if err == nil || !strings.Contains(err.Error(), "sprite id") {
		t.Fatalf("expected sprite id validation, got %v", err)
	}
}
