package cli

import (
	"bytes"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/spf13/cobra"
)

func addMedia(root *cobra.Command, o *options) {
	scripts := group(root, "scripts", "manage stored berry scripts")
	o.simple(scripts, "list", "list stored scripts", "GET", "/berry/scripts", false)
	for _, verb := range []string{"get", "put", "delete", "run"} {
		nargs := 1
		use := verb + " <name>"
		if verb == "put" {
			nargs = 2
			use += " <file|->"
		}
		c := o.command(use, verb+" a stored berry script", nargs, func(c *cobra.Command, args []string) (operation, error) {
			if err := validName(args[0], 32); err != nil {
				return operation{}, err
			}
			path := "/berry/scripts/" + args[0]
			method := "GET"
			switch verb {
			case "put":
				method = "PUT"
			case "delete":
				method = "DELETE"
			case "run":
				method = "POST"
				path += "/run"
			}
			// every per-script route is the `scripts` scope, reading included -- the control
			// token does not hold it, so `scripts get` needs admin like the rest. this used to
			// pass `verb != "get"` and 403'd on exactly the one read it offers.
			op := plainOperation(method, path, true)
			if verb == "put" {
				b, err := readInput(c, args[1], 8000)
				if err != nil {
					return operation{}, err
				}
				op.request.Body = b
				op.request.ContentType = "text/plain"
			}
			return op, nil
		})
		if verb == "put" {
			fileArgument(c, 1)
		}
		scripts.AddCommand(c)
	}
	sprites := group(root, "sprites", "manage rgb888 sprites")
	o.simple(sprites, "list", "list stored sprites", "GET", "/sprites", false)
	for _, verb := range []string{"put", "delete"} {
		nargs := 1
		use := verb + " <id>"
		if verb == "put" {
			nargs = 2
			use += " <file|->"
		}
		c := o.command(use, verb+" an 8x8 or 16x16 rgb888 sprite", nargs, func(c *cobra.Command, args []string) (operation, error) {
			if err := validName(args[0], 8); err != nil {
				return operation{}, err
			}
			if strings.Contains(args[0], ".") {
				return operation{}, errors.New("sprite id must use letters, digits, dash or underscore")
			}
			// DELETE /sprites/{id} is the `content` scope, not a control one
			op := plainOperation("DELETE", "/sprites/"+args[0], true)
			if verb == "put" {
				b, err := readInput(c, args[1], 768)
				if err != nil {
					return operation{}, err
				}
				if len(b) != 192 && len(b) != 768 {
					return operation{}, errors.New("sprite must be 192 or 768 rgb888 bytes")
				}
				op.request.Method = "PUT"
				op.request.Body = b
				op.request.ContentType = "application/octet-stream"
				op.admin = true
			}
			return op, nil
		})
		if verb == "put" {
			fileArgument(c, 1)
		}
		sprites.AddCommand(c)
	}
	sounds := group(root, "sounds", "upload and play sounds")
	o.simple(sounds, "list", "list stored sounds", "GET", "/sounds", false)
	stop := o.command("stop", "stop sound playback", 0, func(_ *cobra.Command, _ []string) (operation, error) {
		return jsonOperation("POST", "/sound", map[string]any{"stop": true}, false)
	})
	sounds.AddCommand(stop)
	fields := []field{numberField("volume", 1, 100), boolField("loop")}
	play := o.command("play <name>", "play a stored sound", 1, func(c *cobra.Command, args []string) (operation, error) {
		if err := validName(args[0], 32); err != nil {
			return operation{}, err
		}
		body, err := collect(c, fields)
		if err != nil {
			return operation{}, err
		}
		body["name"] = args[0]
		return jsonOperation("POST", "/sound", body, false)
	})
	addFields(play, fields)
	sounds.AddCommand(play)
	del := o.command("delete <name>", "delete a stored sound (admin)", 1, func(_ *cobra.Command, args []string) (operation, error) {
		if err := validName(args[0], 32); err != nil {
			return operation{}, err
		}
		return plainOperation("DELETE", "/sounds/"+args[0], true), nil
	})
	sounds.AddCommand(del)
	upload := o.command("upload <name> <file|->", "upload a wav file in 4096-byte chunks (admin)", 2, func(c *cobra.Command, args []string) (operation, error) {
		if err := validName(args[0], 32); err != nil {
			return operation{}, err
		}
		b, err := readInput(c, args[1], 192*1024)
		if err != nil {
			return operation{}, err
		}
		if len(b) == 0 {
			return operation{}, errors.New("sound input is empty")
		}
		op := plainOperation("PUT", "/sounds/"+args[0], true)
		op.request.ContentType = "application/octet-stream"
		for chunk := range slices.Chunk(b, 4096) {
			op.chunks = append(op.chunks, chunk)
		}
		return op, nil
	})
	fileArgument(upload, 1)
	sounds.AddCommand(upload)
	fieldsFrame := slices.Concat(identityFields, transitionFields, []field{numberField("duration_s", 1, 300)})
	frame := o.command("frame [file|-]", "show a 52x16 rgb888 frame or solid colour", 0, func(c *cobra.Command, args []string) (operation, error) {
		body, err := collect(c, fieldsFrame)
		if err != nil {
			return operation{}, err
		}
		hasColour := c.Flags().Changed("colour")
		if (len(args) == 1) == hasColour {
			return operation{}, errors.New("provide either a frame file or --colour")
		}
		var b []byte
		if hasColour {
			colour, _ := c.Flags().GetString("colour")
			rgb, err := parseColour(colour)
			if err != nil {
				return operation{}, err
			}
			b = bytes.Repeat(rgb, 832)
		} else {
			b, err = readInput(c, args[0], 2496)
			if err != nil {
				return operation{}, err
			}
		}
		if len(b) != 2496 {
			return operation{}, errors.New("frame must be exactly 2496 rgb888 bytes")
		}
		if _, ok := body["duration_s"]; !ok {
			body["duration_s"] = 5
		}
		query := url.Values{}
		for k, v := range body {
			query.Set(k, fmt.Sprint(v))
		}
		op := plainOperation("POST", "/frame", false)
		op.request.ContentType = "application/octet-stream"
		op.request.Body = b
		op.request.Query = query
		return op, nil
	})
	frame.Args = func(c *cobra.Command, args []string) error { return usage(cobra.MaximumNArgs(1)(c, args)) }
	addFields(frame, fieldsFrame)
	addFields(frame, []field{colourField("colour")})
	fileArgument(frame, 0)
	root.AddCommand(frame)
}
func fileArgument(c *cobra.Command, index int) {
	c.ValidArgsFunction = func(_ *cobra.Command, args []string, _ string) ([]string, cobra.ShellCompDirective) {
		if len(args) == index {
			return nil, cobra.ShellCompDirectiveDefault
		}
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
}
