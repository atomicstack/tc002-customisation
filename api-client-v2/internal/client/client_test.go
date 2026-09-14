package client_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/atomicstack/tc002-customisation/api-client-v2/internal/client"
)

const control = "abababababababababababababababababababababababababababababababab"
const admin = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"

func newClient(t *testing.T, opts client.Options) *client.Client {
	t.Helper()
	c, err := client.New(opts)
	if err != nil {
		t.Fatalf("create client: %v", err)
	}
	return c
}

func TestCredentialFormats(t *testing.T) {
	raw := append(bytes.Repeat([]byte{0xab}, 32), bytes.Repeat([]byte{0xcd}, 32)...)
	tests := []struct {
		name  string
		data  []byte
		admin bool
		want  string
	}{
		{name: "labelled control", data: []byte("control=" + control + "\nadmin=" + admin + "\n"), want: control},
		{name: "labelled admin reversed crlf", data: []byte("admin=" + admin + "\r\ncontrol=" + control + "\r\n"), admin: true, want: admin},
		{name: "named clients", data: []byte("control=" + control + "\nadmin=" + admin + "\nclient=Living.room-1_2,read," + strings.Repeat("ef", 32)), want: control},
		{name: "single hex ambiguity", data: []byte(control), want: control},
		{name: "single hex newline", data: []byte(control + "\n"), want: control},
		{name: "single hex admin", data: []byte(admin), admin: true, want: admin},
		{name: "raw control", data: raw, want: control},
		{name: "raw admin", data: raw, admin: true, want: admin},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "tokens")
			if err := os.WriteFile(file, tt.data, 0600); err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if got := r.Header.Get("Authorization"); got != "Bearer "+tt.want {
					t.Error("incorrect bearer credential")
				}
				w.WriteHeader(http.StatusNoContent)
			}))
			defer server.Close()
			c := newClient(t, client.Options{Server: server.URL, TokenFile: file, Admin: tt.admin})
			resp, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/status"})
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
		})
	}
}

func TestCredentialFailuresDoNotLeak(t *testing.T) {
	tests := []struct {
		name, data string
		admin      bool
	}{
		{name: "missing role", data: "control=" + control, admin: true},
		{name: "malformed value", data: "control=" + control + "oops"},
		{name: "unknown label", data: "secret=" + control},
		{name: "duplicate label", data: "control=" + control + "\ncontrol=" + admin},
		{name: "large file", data: strings.Repeat("secret", 4000)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "tokens")
			if err := os.WriteFile(file, []byte(tt.data), 0600); err != nil {
				t.Fatal(err)
			}
			_, err := client.New(client.Options{Server: "localhost:1", TokenFile: file, Admin: tt.admin})
			if err == nil {
				t.Fatal("expected credential error")
			}
			if strings.Contains(err.Error(), control) || strings.Contains(err.Error(), admin) || strings.Contains(err.Error(), tt.data) {
				t.Fatal("credential leaked")
			}
		})
	}
	for _, token := range []string{"", control + "x", strings.Repeat("g", 64), control + "\n"} {
		_, err := client.New(client.Options{Server: "localhost:1", Token: token})
		if err == nil {
			t.Fatal("expected invalid direct token error")
		}
		if token != "" && strings.Contains(err.Error(), token) {
			t.Fatal("direct token leaked")
		}
	}
}

func TestDirectTokenOverridesFile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+admin {
			t.Error("direct token ignored")
		}
	}))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: admin, TokenFile: "/missing"})
	resp, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/status"})
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
}

func TestRequestPreservesBodyAndQuery(t *testing.T) {
	payload := []byte{0, 255, 13, 10, 'A'}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/CaseSensitive" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if r.URL.Query().Get("value") != "a&b + C" {
			t.Error("query encoding changed value")
		}
		if r.Method != "POST" || r.Header.Get("Content-Type") != "application/octet-stream" {
			t.Error("request metadata changed")
		}
		got, err := io.ReadAll(r.Body)
		if err != nil || !bytes.Equal(got, payload) {
			t.Error("request body changed")
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(payload)
	}))
	defer server.Close()
	for _, suffix := range []string{"", "/", "/api/v1", "/api/v1/"} {
		t.Run("root"+suffix, func(t *testing.T) {
			c := newClient(t, client.Options{Server: strings.TrimPrefix(server.URL, "http://") + suffix, Token: control})
			resp, err := c.Do(t.Context(), client.Request{Method: "POST", Path: "/CaseSensitive", ContentType: "application/octet-stream", Query: url.Values{"value": {"a&b + C"}}, Body: payload})
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			got, err := io.ReadAll(resp.Body)
			if err != nil || !bytes.Equal(got, payload) {
				t.Fatal("response body changed")
			}
		})
	}
}

func TestRootValidation(t *testing.T) {
	for _, root := range []string{"", "ftp://localhost", "http://user:" + control + "@localhost", "http://localhost?secret=" + control, "http://localhost#fragment", "http://localhost/elsewhere", "http://localhost/api/v1/../x", "http:///missing", "http://localhost?", "http://localhost#"} {
		t.Run("invalid", func(t *testing.T) {
			_, err := client.New(client.Options{Server: root, Token: control})
			if err == nil {
				t.Fatalf("accepted invalid server %q", strings.ReplaceAll(root, control, "redacted"))
			}
			if strings.Contains(err.Error(), control) {
				t.Fatal("server credentials leaked")
			}
		})
	}
}

func TestRequestValidation(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1) }))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control})
	for _, path := range []string{"", "https://elsewhere/status", "//elsewhere/status", "/../status", "/a/../status", "/%2e%2e/status", "/status?token=" + control, "/status#fragment", "/api/v1/status", "/a\\..\\status"} {
		resp, err := c.Do(t.Context(), client.Request{Method: "GET", Path: path})
		if err == nil {
			resp.Body.Close()
			t.Errorf("accepted invalid path %q", strings.ReplaceAll(path, control, "redacted"))
		}
		if err != nil && strings.Contains(err.Error(), control) {
			t.Fatal("path credential leaked")
		}
	}
	_, err := c.Do(t.Context(), client.Request{Method: "POST", Path: "/status", Body: make([]byte, 8193)})
	if err == nil {
		t.Fatal("accepted oversized body")
	}
	if requests.Load() != 0 {
		t.Fatal("invalid request reached server")
	}
}

func TestAPIErrorBoundedAndRedirectsDisabled(t *testing.T) {
	var redirected atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { redirected.Add(1) }))
	defer target.Close()
	for _, status := range []int{302, 400, 401, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", target.URL)
				w.WriteHeader(status)
				io.WriteString(w, strings.Repeat("x", 16384))
			}))
			defer server.Close()
			c := newClient(t, client.Options{Server: server.URL, Token: control})
			resp, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/status"})
			if err == nil || resp != nil {
				t.Fatal("expected nil response and api error")
			}
			var apiErr *client.APIError
			if !errors.As(err, &apiErr) || apiErr.StatusCode != status {
				t.Fatalf("wrong api error: %v", err)
			}
			if len(apiErr.Body) > 8192 || len(err.Error()) > 8300 {
				t.Fatal("error response unbounded")
			}
		})
	}
	if redirected.Load() != 0 {
		t.Fatal("followed redirect")
	}
}

func TestCancellation(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(started); <-r.Context().Done() }))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control})
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := c.Do(ctx, client.Request{Method: "GET", Path: "/status"}); done <- err }()
	<-started
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation lost: %v", err)
	}
}

func TestResponseBodyTimeoutAndStreaming(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "ordinary", true: "stream"}[stream], func(t *testing.T) {
			release := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
				w.(http.Flusher).Flush()
				select {
				case <-release:
					io.WriteString(w, "late body")
				case <-r.Context().Done():
				}
			}))
			defer server.Close()
			c := newClient(t, client.Options{Server: server.URL, Token: control, Timeout: 40 * time.Millisecond})
			resp, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/logs", Stream: stream})
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			time.Sleep(100 * time.Millisecond)
			close(release)
			body, err := io.ReadAll(resp.Body)
			if stream {
				if err != nil || string(body) != "late body" {
					t.Fatalf("stream was cut off: %v", err)
				}
			} else if err == nil {
				t.Fatal("ordinary body exceeded timeout")
			}
		})
	}
}

func TestStreamHeaderTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control, Timeout: 40 * time.Millisecond})
	_, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/logs", Stream: true})
	if err == nil {
		t.Fatal("missing stream header timeout")
	}
}

func TestErrorDoesNotEchoCredential(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		io.WriteString(w, "invalid authorization: "+r.Header.Get("Authorization"))
	}))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control})
	_, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/status"})
	if err == nil {
		t.Fatal("expected api error")
	}
	if strings.Contains(err.Error(), control) {
		t.Fatal("echoed credential leaked")
	}
}

func TestNoRetries(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		conn.Close()
	}))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control})
	_, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/status"})
	if err == nil {
		t.Fatal("expected disconnected request error")
	}
	if requests.Load() != 1 {
		t.Fatalf("request attempted %d times", requests.Load())
	}
}

func TestStreamErrorBodyHasTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control, Timeout: 40 * time.Millisecond})
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	_, err := c.Do(ctx, client.Request{Method: "GET", Path: "/logs", Stream: true})
	var apiErr *client.APIError
	if !errors.As(err, &apiErr) || apiErr.StatusCode != 400 {
		t.Fatalf("wrong api error: %v", err)
	}
	if ctx.Err() != nil {
		t.Fatal("error body only stopped at caller deadline")
	}
}

func TestRequestBodyBoundary(t *testing.T) {
	var length int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
		}
		length = len(body)
	}))
	defer server.Close()
	c := newClient(t, client.Options{Server: server.URL, Token: control})
	resp, err := c.Do(t.Context(), client.Request{Method: "POST", Path: "/frame", Body: make([]byte, 8192)})
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if length != 8192 {
		t.Fatal("request body boundary rejected")
	}
}

func TestCredentialFileWithNamedClients(t *testing.T) {
	for _, useAdmin := range []bool{false, true} {
		t.Run(map[bool]string{false: "control", true: "admin"}[useAdmin], func(t *testing.T) {
			var contents strings.Builder
			contents.WriteString("control=" + control + "\r\nadmin=" + admin + "\r\n")
			// the firmware currently supports 99 clients, each with a 32-byte name.
			for i := range 99 {
				name := fmt.Sprintf("client_%025d", i)
				role := "control"
				if i == 0 {
					role = "read"
				}
				fmt.Fprintf(&contents, "client=%s,%s,%s\r\n", name, role, strings.Repeat("ef", 32))
			}
			if contents.Len() <= 8192 {
				t.Fatal("fixture does not exercise large firmware file")
			}
			file := filepath.Join(t.TempDir(), "tokens")
			if err := os.WriteFile(file, []byte(contents.String()), 0600); err != nil {
				t.Fatal(err)
			}
			want := control
			if useAdmin {
				want = admin
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer "+want {
					t.Error("named client changed selected built-in role")
				}
			}))
			defer server.Close()
			c := newClient(t, client.Options{Server: server.URL, TokenFile: file, Admin: useAdmin})
			resp, err := c.Do(t.Context(), client.Request{Method: "GET", Path: "/status"})
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
		})
	}
}

func TestMalformedNamedClientCredentials(t *testing.T) {
	for _, entry := range []string{
		"client=,read," + control,
		"client=.hidden,read," + control,
		"client=space name,read," + control,
		"client=path/name,read," + control,
		"client=" + strings.Repeat("a", 33) + ",read," + control,
		"client=valid,admin," + control,
		"client=valid,read,invalid",
		"client=valid,read",
		"client=valid,read," + control + ",extra",
		"client=valid,read," + control + "\nclient=valid,control," + admin,
		"unknown=valid,read," + control,
	} {
		t.Run("invalid named client", func(t *testing.T) {
			contents := "control=" + control + "\nadmin=" + admin + "\n" + entry + "\n"
			file := filepath.Join(t.TempDir(), "tokens")
			if err := os.WriteFile(file, []byte(contents), 0600); err != nil {
				t.Fatal(err)
			}
			_, err := client.New(client.Options{Server: "localhost:1", TokenFile: file})
			if err == nil {
				t.Fatal("accepted malformed named client row")
			}
			if strings.Contains(err.Error(), control) || strings.Contains(err.Error(), admin) {
				t.Fatal("credential leaked")
			}
		})
	}
}
