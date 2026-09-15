package client

import (
	"encoding/hex"
	"errors"
	"io"
	"os"
	"slices"
	"strings"
)

// firmware can encode 11331 bytes at its current 99-client capacity; allow crlf too.
const maxCredentialBytes = 16384

func loadToken(opts Options) (string, error) {
	if opts.Token != "" {
		if !validToken(opts.Token) {
			return "", errors.New("token must contain exactly 64 hexadecimal characters")
		}
		return opts.Token, nil
	}
	if opts.TokenFile == "" {
		return "", errors.New("a token or token file is required")
	}
	file, err := os.Open(opts.TokenFile)
	if err != nil {
		return "", errors.New("cannot open token file")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxCredentialBytes+1))
	if err != nil {
		return "", errors.New("cannot read token file")
	}
	if len(data) > maxCredentialBytes {
		return "", errors.New("token file exceeds 16384 bytes")
	}
	// textual single tokens take precedence over ambiguous 64-byte legacy files.
	text := strings.TrimSpace(string(data))
	if validToken(text) {
		return text, nil
	}
	if len(data) == 64 {
		offset := 0
		if opts.Admin {
			offset = 32
		}
		return hex.EncodeToString(data[offset : offset+32]), nil
	}
	role := "control"
	if opts.Admin {
		role = "admin"
	}
	found := map[string]string{}
	namedClients := map[string]struct{}{}
	for line := range strings.SplitSeq(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if key == "client" && ok {
			name, valid := namedClient(value)
			if !valid {
				return "", errors.New("invalid named client in token file")
			}
			if _, exists := namedClients[name]; exists {
				return "", errors.New("duplicate named client in token file")
			}
			namedClients[name] = struct{}{}
			continue
		}
		if !ok || (key != "control" && key != "admin") {
			return "", errors.New("invalid labelled token file")
		}
		if _, exists := found[key]; exists {
			return "", errors.New("duplicate role in token file")
		}
		if !validToken(value) {
			return "", errors.New("invalid credential in token file")
		}
		found[key] = value
	}
	token, ok := found[role]
	if !ok {
		return "", errors.New("token file does not contain the requested " + role + " role")
	}
	return token, nil
}

func validToken(token string) bool {
	if len(token) != 64 {
		return false
	}
	_, err := hex.DecodeString(token)
	return err == nil
}

// every scope the runtime will write into a client row, plus the two legacy rank words. `tokens`
// is absent because minting cannot be delegated (clients.zig `grantable`).
var knownScopes = []string{
	"status", "screen", "logs", "notify", "display", "sound", "input", "content", "scripts", "settings",
	"read", "control",
}

// namedClient validates firmware client rows without selecting their credentials.
func namedClient(value string) (string, bool) {
	fields := strings.Split(value, ",")
	if len(fields) != 3 {
		return "", false
	}
	name, scopes, token := fields[0], fields[1], fields[2]
	if len(name) == 0 || len(name) > 32 || name[0] == '.' {
		return "", false
	}
	for _, c := range name {
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		digit := c >= '0' && c <= '9'
		punctuation := c == '-' || c == '_' || c == '.'
		if !letter && !digit && !punctuation {
			return "", false
		}
	}
	// the middle field is a `|`-joined set of scope names -- a token holds a set, not a rank.
	// `read` and `control` are still accepted so a credentials file written before b53f679 keeps
	// working; refusing them would strand an older install.
	for _, scope := range strings.Split(scopes, "|") {
		if !slices.Contains(knownScopes, scope) {
			return "", false
		}
	}
	return name, validToken(token)
}
