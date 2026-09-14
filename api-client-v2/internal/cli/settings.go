package cli

import (
	"errors"

	"github.com/spf13/cobra"
)

var configFields = []field{
	numberField("brightness", 1, 100), enumField("base", "clock art canvas"), enumField("generator", "popsquares plasma cube"),
	textField("timezone"), textField("ntp_server"), numberField("ntp_interval_s", 300, 600), numberField("frame_timeout_ms", 100, 2000),
	numberField("metrics_interval_s", 0, 3600), boolField("discovery"), textField("discovery_prefix"), numberField("expected_revision", 0, 4294967295),
	enumField("clock_font", "classic mini segment big block hires"), enumField("clock_colour_mode", "solid gradient"),
	colourField("clock_colour"), colourField("clock_colour2"), enumField("clock_gradient", "horizontal vertical diagonal"),
	numberField("clock_spread", 0, 255), enumField("clock_digit", "solid outline shadow"),
	{name: "generator_params", kind: "json"}, enumField("ip_mode", "lines mini scroll big"), boolField("night"),
	numberField("night_brightness", 1, 100), numberField("night_lead_min", 0, 120),
	{name: "latitude", kind: "float", min: -90, max: 90}, {name: "longitude", kind: "float", min: -180, max: 180},
	boolField("location_auto"), boolField("berry_enabled"), numberField("berry_heap_kb", 16, 256), numberField("berry_handler_ms", 10, 1000),
	boolField("sound_enabled"), numberField("sound_volume", 1, 100),
}
var mqttFields = []field{
	boolField("enabled"), textField("host"), numberField("port", 1, 65535), textField("username"), textField("password"),
	textField("client_id"), textField("prefix"), boolField("tls"),
}
var ntfyFields = []field{
	boolField("enabled"), textField("url"), textField("topic"), textField("token"), textField("username"), textField("password"),
	numberField("duration_s", 1, 300), boolField("insecure"), textField("ca"),
}

func addSettings(root *cobra.Command, o *options) {
	for _, resource := range []struct {
		name, method string
		fields       []field
		readAdmin    bool
	}{
		{"config", "PATCH", configFields, false}, {"mqtt", "PUT", mqttFields, true}, {"ntfy", "PUT", ntfyFields, true},
	} {
		parent := group(root, resource.name, "inspect or change "+resource.name+" settings")
		o.simple(parent, "get", "read effective settings", "GET", "/"+resource.name, resource.readAdmin)
		set := o.command("set", "patch settings using flags or --data (admin)", 0, func(c *cobra.Command, _ []string) (operation, error) {
			body, err := jsonData(c, resource.fields)
			if err != nil {
				return operation{}, err
			}
			if len(body) == 0 {
				return operation{}, errors.New("provide at least one setting")
			}
			if resource.name == "config" {
				// the wire schema has two discontinuous numeric ranges.
				if n, ok := body["ntp_interval_s"].(int64); ok && n != 300 && n != 600 {
					return operation{}, errors.New("ntp-interval-s must be 300 or 600")
				}
				if n, ok := body["metrics_interval_s"].(int64); ok && n != 0 && n < 10 {
					return operation{}, errors.New("metrics-interval-s must be 0 or 10..3600")
				}
			}
			return jsonOperation(resource.method, "/"+resource.name, body, true)
		})
		addFields(set, resource.fields)
		dataFlag(set)
		parent.AddCommand(set)
		if resource.name == "mqtt" {
			o.simple(parent, "status", "show mqtt connection status", "GET", "/mqtt/status", false)
		}
		if resource.name == "config" {
			fields := []field{numberField("revision", 0, 4294967295)}
			save := o.command("save", "persist effective settings (admin)", 0, func(c *cobra.Command, _ []string) (operation, error) {
				body, err := collect(c, fields)
				if err != nil {
					return operation{}, err
				}
				return jsonOperation("POST", "/config/save", body, true)
			})
			addFields(save, fields)
			parent.AddCommand(save)
		}
	}
	canvas := group(root, "canvas", "manage the canvas document and element values")
	o.simple(canvas, "get", "read the canvas document", "GET", "/canvas", false)
	o.simple(canvas, "clear", "clear the active canvas", "DELETE", "/canvas", false)
	for _, verb := range []string{"put", "patch"} {
		c := o.command(verb, "send a canvas document with --data", 0, func(c *cobra.Command, _ []string) (operation, error) {
			if !c.Flags().Changed("data") {
				return operation{}, errors.New("data is required")
			}
			body, err := jsonData(c, nil)
			if err != nil {
				return operation{}, err
			}
			method := "PUT"
			if verb == "patch" {
				method = "PATCH"
			}
			return jsonOperation(method, "/canvas", body, verb == "put")
		})
		dataFlag(c)
		canvas.AddCommand(c)
	}
}
