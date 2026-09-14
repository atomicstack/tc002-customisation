// package client provides authenticated access to the tc002 http api.
package client

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maxBodyBytes = 8192

// Options selects the device, credential, and request timeout.
type Options struct {
	Server, Token, TokenFile string
	Admin                    bool
	Timeout                  time.Duration
}

// Request describes a route relative to /api/v1. successful bodies belong to the caller.
type Request struct {
	Method, Path, ContentType string
	Query                     url.Values
	Body                      []byte
	Stream                    bool
}

// Client is safe for concurrent requests after construction.
type Client struct {
	base     url.URL
	token    string
	timeout  time.Duration
	ordinary *http.Client
	stream   *http.Client
}

// APIError contains an unsuccessful response with a bounded body.
type APIError struct {
	StatusCode int
	Body       string
}

func (e *APIError) Error() string {
	if e.Body == "" {
		return fmt.Sprintf("api returned http %d", e.StatusCode)
	}
	return fmt.Sprintf("api returned http %d: %s", e.StatusCode, e.Body)
}

// New validates the server and loads the selected credential without making requests.
func New(opts Options) (*Client, error) {
	base, err := parseServer(opts.Server)
	if err != nil {
		return nil, err
	}
	token, err := loadToken(opts)
	if err != nil {
		return nil, err
	}
	if opts.Timeout < 0 {
		return nil, errors.New("timeout must be positive")
	}
	if opts.Timeout == 0 {
		opts.Timeout = 10 * time.Second
	}
	transport := &http.Transport{
		// fresh connections prevent net/http from automatically retrying reused connections.
		DisableKeepAlives:      true,
		DialContext:            (&net.Dialer{Timeout: opts.Timeout}).DialContext,
		TLSHandshakeTimeout:    opts.Timeout,
		ResponseHeaderTimeout:  opts.Timeout,
		MaxResponseHeaderBytes: 8192,
	}
	rejectRedirect := func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &Client{
		base: *base, token: token, timeout: opts.Timeout,
		ordinary: &http.Client{Transport: transport, Timeout: opts.Timeout, CheckRedirect: rejectRedirect},
		stream:   &http.Client{Transport: transport, CheckRedirect: rejectRedirect},
	}, nil
}

// Do sends one authenticated request. the caller must close a successful response body.
// stream requests retain dial and header timeouts without imposing a total body deadline.
func (c *Client) Do(ctx context.Context, req Request) (*http.Response, error) {
	if len(req.Body) > maxBodyBytes {
		return nil, errors.New("request body exceeds 8192 bytes")
	}
	if err := validatePath(req.Path); err != nil {
		return nil, err
	}
	target := c.base
	target.Path = "/api/v1/" + strings.TrimPrefix(req.Path, "/")
	target.RawQuery = req.Query.Encode()
	requestCtx, cancel := context.WithCancel(ctx)
	request, err := http.NewRequestWithContext(requestCtx, req.Method, target.String(), bytes.NewReader(req.Body))
	if err != nil {
		cancel()
		return nil, errors.New("invalid http request")
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	if req.ContentType != "" {
		request.Header.Set("Content-Type", req.ContentType)
	}
	sender := c.ordinary
	if req.Stream {
		sender = c.stream
	}
	response, err := sender.Do(request)
	if err != nil {
		cancel()
		return nil, &requestError{cause: err}
	}
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		response.Body = &cancelBody{ReadCloser: response.Body, cancel: cancel}
		return response, nil
	}
	defer cancel()
	defer response.Body.Close()
	// unsuccessful stream responses must not hang while their diagnostic body is read.
	timer := time.AfterFunc(c.timeout, cancel)
	defer timer.Stop()
	body, readErr := io.ReadAll(io.LimitReader(response.Body, maxBodyBytes))
	if readErr != nil && len(body) == 0 {
		body = []byte("unable to read error response")
	}
	return nil, &APIError{StatusCode: response.StatusCode, Body: strings.ReplaceAll(string(body), c.token, "<redacted>")}
}

type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b *cancelBody) Close() error {
	err := b.ReadCloser.Close()
	b.cancel()
	return err
}

// requestError preserves errors.Is/As without printing URLs or echoed protocol data.
type requestError struct{ cause error }

func (e *requestError) Error() string {
	if errors.Is(e.cause, context.Canceled) {
		return "request canceled"
	}
	var timeout net.Error
	if errors.As(e.cause, &timeout) && timeout.Timeout() {
		return "request timed out"
	}
	return "http request failed"
}
func (e *requestError) Unwrap() error { return e.cause }

func parseServer(server string) (*url.URL, error) {
	invalid := errors.New("server must be an http or https host with optional /api/v1 path")
	if server == "" || strings.ContainsAny(server, "?#") {
		return nil, invalid
	}
	if !strings.Contains(server, "://") {
		server = "http://" + server
	}
	parsed, err := url.Parse(server)
	if err != nil {
		return nil, invalid
	}
	validScheme := parsed.Scheme == "http" || parsed.Scheme == "https"
	if !validScheme || parsed.Hostname() == "" || parsed.User != nil {
		return nil, invalid
	}
	switch parsed.Path {
	case "", "/", "/api/v1", "/api/v1/":
	default:
		return nil, invalid
	}
	if parsed.RawPath != "" || parsed.Opaque != "" {
		return nil, invalid
	}
	parsed.Path = "/api/v1"
	return parsed, nil
}

func validatePath(route string) error {
	invalid := errors.New("request path must be a relative api route without traversal, query, or fragment")
	if route == "" || strings.ContainsAny(route, "?#\\%") || strings.HasPrefix(route, "//") {
		return invalid
	}
	parsed, err := url.Parse(route)
	if err != nil || parsed.IsAbs() || parsed.Host != "" {
		return invalid
	}
	route = strings.TrimPrefix(route, "/")
	if route == "api/v1" || strings.HasPrefix(route, "api/v1/") {
		return invalid
	}
	for part := range strings.SplitSeq(route, "/") {
		if part == ".." || part == "." {
			return invalid
		}
	}
	return nil
}
