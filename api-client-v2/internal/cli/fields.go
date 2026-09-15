package cli

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
)

// fields keep validation and completion attached to the wire schema.
type field struct {
	name, kind, choices string
	// when set, the command-line flag differs from the json field: `--scope` fills `scopes`
	flag     string
	min, max int64
}

func textField(name string) field { return field{name: name, kind: "string"} }
func enumField(name, choices string) field {
	return field{name: name, kind: "string", choices: choices}
}
func numberField(name string, min, max int64) field {
	return field{name: name, kind: "number", min: min, max: max}
}
func boolField(name string) field { return field{name: name, kind: "bool"} }

// the scopes a named client token may hold. `tokens` is deliberately absent: minting is the one
// authority the runtime will not delegate (clients.zig `grantable`).
var grantableScopes = []string{"status", "screen", "logs", "notify", "display", "sound", "input", "content", "scripts", "settings"}

// a repeatable flag that becomes a json array. `--scope notify --scope display` -> ["notify","display"].
// tokens hold a set of scopes rather than a rank, so this is the shape the api wants.
func listField(flag, jsonName string) field {
	return field{name: jsonName, kind: "list", choices: strings.Join(grantableScopes, " "), flag: flag}
}
func colourField(name string) field { return field{name: name, kind: "colour"} }
func flagName(name string) string {
	if name == "token" {
		return "subscription-token"
	}
	if name == "duration_s" {
		return "duration"
	}
	return strings.ReplaceAll(name, "_", "-")
}

func addFields(c *cobra.Command, fields []field) {
	for _, f := range fields {
		name := fieldFlag(f)
		switch f.kind {
		case "list":
			c.Flags().StringSlice(name, nil, "add one "+f.name[:len(f.name)-1]+" (repeatable): "+strings.ReplaceAll(f.choices, " ", "|"))
		case "bool":
			c.Flags().Bool(name, false, "set "+f.name)
		default:
			description := "set " + f.name
			if f.choices != "" {
				description += " (" + strings.ReplaceAll(f.choices, " ", "|") + ")"
			}
			if f.kind == "number" {
				description += fmt.Sprintf(" (%d..%d)", f.min, f.max)
			}
			c.Flags().String(name, "", description)
		}
		choices := strings.Fields(f.choices)
		if f.kind == "bool" {
			choices = []string{"true", "false"}
		}
		_ = c.RegisterFlagCompletionFunc(name, func(_ *cobra.Command, _ []string, prefix string) ([]string, cobra.ShellCompDirective) {
			return matching(choices, prefix), cobra.ShellCompDirectiveNoFileComp
		})
	}
}
func matching(choices []string, prefix string) []string {
	out := []string{}
	for _, s := range choices {
		if strings.HasPrefix(s, prefix) {
			out = append(out, s)
		}
	}
	return out
}
func positional(c *cobra.Command, choices ...string) {
	c.ValidArgsFunction = func(_ *cobra.Command, args []string, prefix string) ([]string, cobra.ShellCompDirective) {
		if len(args) > 0 {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}
		return matching(choices, prefix), cobra.ShellCompDirectiveNoFileComp
	}
}
func fieldFlag(f field) string {
	if f.flag != "" {
		return f.flag
	}
	return flagName(f.name)
}

func collect(c *cobra.Command, fields []field) (map[string]any, error) {
	out := map[string]any{}
	for _, f := range fields {
		name := fieldFlag(f)
		if !c.Flags().Changed(name) {
			continue
		}
		if f.kind == "bool" {
			v, _ := c.Flags().GetBool(name)
			out[f.name] = v
			continue
		}
		if f.kind == "list" {
			v, _ := c.Flags().GetStringSlice(name)
			for _, item := range v {
				if !slices.Contains(strings.Fields(f.choices), item) {
					return nil, fmt.Errorf("%s must be one of: %s", name, f.choices)
				}
			}
			out[f.name] = v
			continue
		}
		v, _ := c.Flags().GetString(name)
		if f.choices != "" && !slices.Contains(strings.Fields(f.choices), v) {
			return nil, fmt.Errorf("%s must be one of: %s", name, f.choices)
		}
		switch f.kind {
		case "number":
			n, err := parseNumber(v, f.min, f.max)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", name, err)
			}
			out[f.name] = n
		case "float":
			n, err := strconv.ParseFloat(v, 64)
			if err != nil || !(n >= float64(f.min) && n <= float64(f.max)) {
				return nil, fmt.Errorf("%s must be %d..%d", name, f.min, f.max)
			}
			out[f.name] = n
		case "colour":
			if _, err := parseColour(v); err != nil {
				return nil, fmt.Errorf("%s: %w", name, err)
			}
			out[f.name] = v
		case "json":
			var raw any
			if err := json.Unmarshal([]byte(v), &raw); err != nil {
				return nil, fmt.Errorf("%s must be valid json", name)
			}
			out[f.name] = raw
		default:
			out[f.name] = v
		}
	}
	if v, ok := out["request_id"]; ok {
		s := v.(string)
		if len(s) < 1 || len(s) > 16 {
			return nil, errors.New("request-id must be 1..16 hex digits")
		}
		if _, err := strconv.ParseUint(s, 16, 64); err != nil {
			return nil, errors.New("request-id must be 1..16 hex digits")
		}
	}
	return out, nil
}
func parseNumber(s string, min, max int64) (int64, error) {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < min || n > max {
		return 0, fmt.Errorf("value must be %d..%d", min, max)
	}
	return n, nil
}
func parseColour(s string) ([]byte, error) {
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 3 {
		return nil, errors.New("colour must be six rrggbb hex digits")
	}
	return b, nil
}
func validName(s string, max int) error {
	if len(s) == 0 || len(s) > max || s[0] == '.' {
		return fmt.Errorf("name must be 1..%d letters, digits, dash, underscore or dot, without a leading dot", max)
	}
	for _, c := range s {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.') {
			return errors.New("name contains an invalid character")
		}
	}
	return nil
}
func readInput(c *cobra.Command, path string, max int) ([]byte, error) {
	var r io.Reader = c.InOrStdin()
	if path != "-" {
		f, err := os.Open(path)
		if err != nil {
			return nil, fmt.Errorf("open input: %w", err)
		}
		defer f.Close()
		r = f
	}
	b, err := io.ReadAll(io.LimitReader(r, int64(max)+1))
	if err != nil {
		return nil, fmt.Errorf("read input: %w", err)
	}
	if len(b) > max {
		return nil, fmt.Errorf("input exceeds %d bytes", max)
	}
	return b, nil
}
func dataFlag(c *cobra.Command) {
	c.Flags().String("data", "", "json object, @file, or - for stdin")
	_ = c.RegisterFlagCompletionFunc("data", completeDataFile)
}
func jsonData(c *cobra.Command, fields []field) (map[string]any, error) {
	values, err := collect(c, fields)
	if err != nil {
		return nil, err
	}
	if !c.Flags().Changed("data") {
		return values, nil
	}
	if len(values) > 0 {
		return nil, errors.New("data cannot be combined with field flags")
	}
	value, _ := c.Flags().GetString("data")
	b := []byte(value)
	if value == "-" || strings.HasPrefix(value, "@") {
		path := strings.TrimPrefix(value, "@")
		b, err = readInput(c, path, 8192)
		if err != nil {
			return nil, err
		}
	}
	if len(b) > 8192 {
		return nil, errors.New("json exceeds 8192 bytes")
	}
	var object map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(b)))
	decoder.UseNumber()
	if err := decoder.Decode(&object); err != nil || object == nil {
		return nil, errors.New("data must be a json object")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("data must contain exactly one json object")
	}
	return object, nil
}

var identityFields = []field{textField("request_id"), numberField("epoch", 0, 4294967295)}
var transitionFields = []field{
	enumField("transition", "fade cut slide swipe_out swipe_in collapse expand wipe dissolve split_out split_in blinds flip rain rain_random"),
	enumField("direction", "left right up down"), numberField("transition_ms", 0, 5000), enumField("exit", "reverse same none"),
}
var clockFields = []field{
	enumField("font", "classic mini segment big block hires"), enumField("colour_mode", "solid gradient"), colourField("colour"), colourField("colour2"),
	enumField("gradient", "horizontal vertical diagonal"), numberField("spread", 0, 255), enumField("digits", "solid outline shadow"),
}

// completeDataFile preserves the @ prefix which distinguishes a file from inline json.
func completeDataFile(_ *cobra.Command, _ []string, prefix string) ([]string, cobra.ShellCompDirective) {
	directive := cobra.ShellCompDirectiveNoFileComp
	if !strings.HasPrefix(prefix, "@") {
		return matching([]string{"-", "@"}, prefix), directive | cobra.ShellCompDirectiveNoSpace
	}
	path := strings.TrimPrefix(prefix, "@")
	dir, partial := filepath.Split(path)
	searchDir := dir
	if searchDir == "" {
		searchDir = "."
	}
	entries, err := os.ReadDir(searchDir)
	if err != nil {
		return nil, directive
	}
	candidates := []string{}
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), partial) {
			continue
		}
		candidate := "@" + dir + entry.Name()
		if entry.IsDir() {
			candidate += "/"
			directive |= cobra.ShellCompDirectiveNoSpace
		}
		candidates = append(candidates, candidate)
	}
	return candidates, directive
}
