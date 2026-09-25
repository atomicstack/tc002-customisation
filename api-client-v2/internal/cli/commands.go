package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/atomicstack/tc002-customisation/api-client-v2/internal/client"
	"github.com/spf13/cobra"
)

func jsonOperation(method, path string, body map[string]any, admin bool) (operation, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return operation{}, err
	}
	if len(b) > 8192 {
		return operation{}, errors.New("request body exceeds 8192 bytes")
	}
	return operation{request: client.Request{Method: method, Path: path, ContentType: "application/json", Body: b}, admin: admin}, nil
}
func plainOperation(method, path string, admin bool) operation {
	return operation{request: client.Request{Method: method, Path: path}, admin: admin}
}
func group(root *cobra.Command, name, short string) *cobra.Command {
	c := &cobra.Command{Use: name, Short: short, RunE: func(c *cobra.Command, args []string) error {
		if len(args) > 0 {
			return usage(fmt.Errorf("unknown command %q", args[0]))
		}
		return c.Help()
	}}
	root.AddCommand(c)
	return c
}
func (o *options) simple(parent *cobra.Command, name, short, method, path string, admin bool) *cobra.Command {
	c := o.command(name, short, 0, func(_ *cobra.Command, _ []string) (operation, error) { return plainOperation(method, path, admin), nil })
	parent.AddCommand(c)
	return c
}
func addCommands(root *cobra.Command, o *options) {
	for _, r := range []struct{ name, path, help string }{
		{"status", "/status", "show runtime status"}, {"scenes", "/scenes", "list scenes and generator parameter schemas"},
		{"icons", "/icons", "list built-in icons"}, {"berry", "/berry", "show script interpreter status"},
	} {
		o.simple(root, r.name, r.help, "GET", r.path, false)
	}
	addControl(root, o)
	addSettings(root, o)
	addMedia(root, o)
	addTokens(root, o)
	events := o.command("events", "stream runtime events until interrupted", 0, func(_ *cobra.Command, _ []string) (operation, error) {
		op := plainOperation("GET", "/events", false)
		op.request.Stream = true
		return op, nil
	})
	root.AddCommand(events)
	logsFields := []field{numberField("after", 0, 4294967295)}
	logs := o.command("logs", "read the supervisor log ring", 0, func(c *cobra.Command, _ []string) (operation, error) {
		body, err := collect(c, logsFields)
		if err != nil {
			return operation{}, err
		}
		op := plainOperation("GET", "/logs", false)
		op.request.Query = url.Values{}
		if n, ok := body["after"]; ok {
			op.request.Query.Set("after", fmt.Sprint(n))
		}
		return op, nil
	})
	addFields(logs, logsFields)
	root.AddCommand(logs)
	screenFields := []field{enumField("format", "json raw")}
	screen := o.command("screen", "read the current framebuffer (raw is 2496 rgb888 bytes)", 0, func(c *cobra.Command, _ []string) (operation, error) {
		body, err := collect(c, screenFields)
		if err != nil {
			return operation{}, err
		}
		op := plainOperation("GET", "/screen", false)
		op.request.Query = url.Values{}
		if format, ok := body["format"]; ok {
			op.request.Query.Set("format", format.(string))
		}
		return op, nil
	})
	addFields(screen, screenFields)
	root.AddCommand(screen)
	addRaw(root, o)
}
func addControl(root *cobra.Command, o *options) {
	sceneFields := slices.Concat(identityFields, transitionFields, []field{enumField("generator", "popsquares plasma cube terrain"), numberField("seed", 0, 4294967295)})
	scene := o.command("scene <clock|art|canvas>", "select the base scene and transient style", 1, func(c *cobra.Command, args []string) (operation, error) {
		if !slices.Contains([]string{"clock", "art", "canvas"}, args[0]) {
			return operation{}, errors.New("base must be clock, art or canvas")
		}
		body, err := collect(c, sceneFields)
		if err != nil {
			return operation{}, err
		}
		clock, err := collect(c, clockFields)
		if err != nil {
			return operation{}, err
		}
		body["base"] = args[0]
		if len(clock) > 0 {
			body["clock"] = clock
		}
		return jsonOperation("PUT", "/scene", body, false)
	})
	addFields(scene, sceneFields)
	addFields(scene, clockFields)
	positional(scene, "clock", "art", "canvas")
	root.AddCommand(scene)
	for _, action := range []string{"brightness", "reseed", "arm-stream", "power"} {
		use := action
		nargs := 0
		switch action {
		case "brightness":
			use += " <1..100>"
			nargs = 1
		case "reseed":
			use += " [seed]"
		case "power":
			use += " <on|off>"
			nargs = 1
		}
		c := o.command(use, "apply the "+action+" action", nargs, func(c *cobra.Command, args []string) (operation, error) {
			body, err := collect(c, identityFields)
			if err != nil {
				return operation{}, err
			}
			body["action"] = strings.ReplaceAll(action, "-", "_")
			switch action {
			case "brightness":
				n, err := parseNumber(args[0], 1, 100)
				if err != nil {
					return operation{}, err
				}
				body["brightness"] = n
			case "reseed":
				if len(args) > 0 {
					n, err := parseNumber(args[0], 0, 4294967295)
					if err != nil {
						return operation{}, err
					}
					body["seed"] = n
				}
			case "power":
				if args[0] != "on" && args[0] != "off" {
					return operation{}, errors.New("power must be on or off")
				}
				body["power"] = args[0] == "on"
			}
			return jsonOperation("POST", "/action", body, false)
		})
		if action == "reseed" {
			c.Args = func(c *cobra.Command, args []string) error { return usage(cobra.MaximumNArgs(1)(c, args)) }
		}
		if action == "power" {
			positional(c, "on", "off")
		}
		addFields(c, identityFields)
		root.AddCommand(c)
	}
	notifyFields := slices.Concat(identityFields, transitionFields, []field{colourField("colour"), numberField("duration_s", 1, 300), textField("name"), boolField("stack"), boolField("hold")})
	notify := o.command("notify [text]", "show a temporary notification: text, or a canvas document with --data", 0, func(c *cobra.Command, args []string) (operation, error) {
		// --data carries a document (and any other notify field) and, like everywhere else, does
		// not mix with the field flags; the text argument is then the summary the events carry
		if c.Flags().Changed("data") {
			body, err := jsonData(c, notifyFields)
			if err != nil {
				return operation{}, err
			}
			if len(args) == 1 {
				if err := validText(args[0]); err != nil {
					return operation{}, err
				}
				body["text"] = args[0]
			}
			return jsonOperation("POST", "/notify", body, false)
		}
		if len(args) == 0 {
			return operation{}, errors.New("give the text, or --data with a document")
		}
		text := args[0]
		if err := validText(text); err != nil {
			return operation{}, err
		}
		body, err := collect(c, notifyFields)
		if err != nil {
			return operation{}, err
		}
		if name, ok := body["name"]; ok {
			if name == "" {
				return operation{}, errNotificationName
			}
			if err := validNotificationName(name.(string)); err != nil {
				return operation{}, err
			}
		}
		body["text"] = text
		return jsonOperation("POST", "/notify", body, false)
	})
	notify.Args = func(c *cobra.Command, args []string) error { return usage(cobra.MaximumNArgs(1)(c, args)) }
	addFields(notify, notifyFields)
	dataFlag(notify)
	root.AddCommand(notify)
	// a dismissal names the notification to drop; without a name it drops the current one
	dismiss := o.command("dismiss [name]", "dismiss the current notification, or the first one of that name", 0, func(c *cobra.Command, args []string) (operation, error) {
		body, err := collect(c, identityFields)
		if err != nil {
			return operation{}, err
		}
		if len(args) == 1 {
			if args[0] == "" {
				return operation{}, errNotificationName
			}
			if err := validNotificationName(args[0]); err != nil {
				return operation{}, err
			}
			body["name"] = args[0]
		}
		return jsonOperation("POST", "/notify/dismiss", body, false)
	})
	dismiss.Args = func(c *cobra.Command, args []string) error { return usage(cobra.MaximumNArgs(1)(c, args)) }
	addFields(dismiss, identityFields)
	root.AddCommand(dismiss)
	// the runtime puts "rebooting..." on the panel and reboots. the route takes no body and
	// needs the reboot scope, which only the admin token holds among the built-in pair.
	o.simple(root, "reboot", "reboot the clock behind its notice (admin)", "POST", "/reboot", true)
	inputFields := slices.Concat(identityFields, []field{numberField("steps", 1, 16)})
	input := o.command("input <control> <event>", "press a button or turn the rotary control", 2, func(c *cobra.Command, args []string) (operation, error) {
		control, event := args[0], args[1]
		if !slices.Contains([]string{"left", "middle", "right", "knob", "rotary"}, control) {
			return operation{}, errors.New("control must be left, middle, right, knob or rotary")
		}
		if !slices.Contains(inputEvents(control), event) {
			return operation{}, errors.New("event is not valid for this control")
		}
		body, err := collect(c, inputFields)
		if err != nil {
			return operation{}, err
		}
		if n, ok := body["steps"]; ok && control != "rotary" && n.(int64) != 1 {
			return operation{}, errors.New("steps applies to rotary events only")
		}
		body["control"] = control
		body["event"] = event
		return jsonOperation("POST", "/input", body, false)
	})
	addFields(input, inputFields)
	input.ValidArgsFunction = func(_ *cobra.Command, args []string, prefix string) ([]string, cobra.ShellCompDirective) {
		values := []string{}
		if len(args) == 0 {
			values = []string{"left", "middle", "right", "knob", "rotary"}
		}
		if len(args) == 1 {
			values = inputEvents(args[0])
		}
		return matching(values, prefix), cobra.ShellCompDirectiveNoFileComp
	}
	root.AddCommand(input)
}
func validText(text string) error {
	if len(text) < 1 || len(text) > 128 {
		return errors.New("text must be 1..128 printable ascii characters")
	}
	for _, ch := range []byte(text) {
		if ch < 32 || ch > 126 {
			return errors.New("text must be printable ascii")
		}
	}
	return nil
}
func inputEvents(control string) []string {
	switch control {
	case "rotary":
		return []string{"cw", "ccw"}
	case "knob":
		return []string{"press", "release", "click", "long"}
	case "left", "middle", "right":
		return []string{"press", "release", "click"}
	}
	return nil
}
func addTokens(root *cobra.Command, o *options) {
	tokens := group(root, "tokens", "manage named client tokens (admin)")
	o.simple(tokens, "list", "list named clients", "GET", "/tokens", true)
	for _, verb := range []string{"create", "rotate", "revoke"} {
		// a token holds a set of scopes, not a rank. the runtime dropped roles in b53f679 and
		// its parser refuses unknown fields, so sending `role` made create and rotate 400.
		scopes := []field{listField("scope", "scopes")}
		c := o.command(verb+" <name>", verb+" a client token (admin)", 1, func(c *cobra.Command, args []string) (operation, error) {
			if err := validName(args[0], 32); err != nil {
				return operation{}, err
			}
			if verb == "revoke" {
				return plainOperation("DELETE", "/tokens/"+args[0], true), nil
			}
			body, err := collect(c, scopes)
			if err != nil {
				return operation{}, err
			}
			path := "/tokens/" + args[0] + "/rotate"
			if verb == "create" {
				path = "/tokens"
				body["name"] = args[0]
				if _, ok := body["scopes"]; !ok {
					return operation{}, fmt.Errorf("give at least one --scope: %s", strings.Join(grantableScopes, " "))
				}
			}
			return jsonOperation("POST", path, body, true)
		})
		if verb != "revoke" {
			addFields(c, scopes)
		}
		tokens.AddCommand(c)
	}
}
func addRaw(root *cobra.Command, o *options) {
	c := o.command("request <method> <path>", "send a request beneath the custom runtime's /api/v1", 2, func(c *cobra.Command, args []string) (operation, error) {
		method := strings.ToUpper(args[0])
		if !slices.Contains([]string{"GET", "POST", "PUT", "PATCH", "DELETE"}, method) {
			return operation{}, errors.New("method must be GET, POST, PUT, PATCH or DELETE")
		}
		parsed, err := url.Parse(args[1])
		if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.Fragment != "" {
			return operation{}, errors.New("path must be a local runtime route, for example /status")
		}
		path := "/" + strings.TrimPrefix(parsed.Path, "/")
		for _, segment := range strings.Split(path, "/") {
			if segment == ".." || segment == "." {
				return operation{}, errors.New("path may not contain dot segments")
			}
		}
		if strings.Contains(path, "\\") || strings.Contains(args[1], "%") || strings.HasPrefix(path, "/api/") {
			return operation{}, errors.New("path must be relative to /api/v1 without escaping")
		}
		op := plainOperation(method, path, false)
		op.request.Query = parsed.Query()
		queries, _ := c.Flags().GetStringArray("query")
		for _, pair := range queries {
			k, v, ok := strings.Cut(pair, "=")
			if !ok || k == "" {
				return operation{}, errors.New("query must be key=value")
			}
			op.request.Query.Add(k, v)
		}
		if c.Flags().Changed("data") {
			data, err := jsonData(c, nil)
			if err != nil {
				return operation{}, err
			}
			op.request.Body, err = json.Marshal(data)
			if err != nil {
				return operation{}, err
			}
			op.request.ContentType = "application/json"
		}
		return op, nil
	})
	dataFlag(c)
	c.Flags().StringArray("query", nil, "query parameter key=value (repeatable)")
	c.ValidArgsFunction = func(_ *cobra.Command, args []string, prefix string) ([]string, cobra.ShellCompDirective) {
		choices := []string{}
		if len(args) == 0 {
			choices = []string{"GET", "POST", "PUT", "PATCH", "DELETE"}
		}
		if len(args) == 1 {
			choices = []string{"/status", "/scenes", "/scene", "/action", "/config", "/config/save", "/notify", "/frame", "/icons", "/sprites", "/canvas", "/mqtt", "/mqtt/status", "/ntfy", "/screen", "/logs", "/events", "/sounds", "/sound", "/berry", "/berry/scripts", "/tokens", "/streams", "/notify/dismiss", "/reboot"}
		}
		return matching(choices, prefix), cobra.ShellCompDirectiveNoFileComp
	}
	root.AddCommand(c)
}
