// package cli implements the custom runtime command line interface.
package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/atomicstack/tc002-customisation/api-client-v2/internal/client"
)

// Version is set at build time using -ldflags.
var Version = "dev"

type usageError struct{ err error }

func (e *usageError) Error() string { return e.err.Error() }
func (e *usageError) Unwrap() error { return e.err }
func usage(err error) error {
	if err == nil {
		return nil
	}
	return &usageError{err: err}
}

// ExitCode separates usage mistakes, interrupted requests and runtime failures.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	if errors.Is(err, context.Canceled) {
		return 130
	}
	var u *usageError
	if strings.HasPrefix(err.Error(), "unknown command ") {
		return 2
	}
	if errors.As(err, &u) {
		return 2
	}
	return 1
}

type options struct {
	server, token, tokenFile, out string
	admin, compact                bool
	timeout                       time.Duration
}

type operation struct {
	request client.Request
	admin   bool
	// chunks is used only for sound uploads; each request waits for the previous result.
	chunks [][]byte
}

type builder func(*cobra.Command, []string) (operation, error)

// NewCommand returns an independent command tree suitable for embedding or testing.
func NewCommand() *cobra.Command {
	o := &options{}
	root := &cobra.Command{Use: "tc002", Short: "control the tc002 custom runtime", Version: Version, SilenceUsage: true, SilenceErrors: true}
	root.CompletionOptions.DisableDefaultCmd = true
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return usage(err) })
	f := root.PersistentFlags()
	f.StringVarP(&o.server, "server", "s", os.Getenv("TC002_SERVER"), "device host[:port] or root url (env: TC002_SERVER)")
	f.StringVar(&o.token, "token", "", "bearer token (env: TC002_TOKEN)")
	f.StringVar(&o.tokenFile, "token-file", os.Getenv("TC002_TOKEN_FILE"), "credentials file (env: TC002_TOKEN_FILE)")
	f.BoolVar(&o.admin, "admin", false, "select the admin token from the credentials file")
	f.DurationVar(&o.timeout, "timeout", 8*time.Second, "request timeout; connection/header timeout for events")
	f.StringVarP(&o.out, "out", "o", "", "write response to a file instead of stdout")
	f.BoolVar(&o.compact, "compact", false, "emit compact json; binary and text responses stay unchanged")
	_ = root.MarkPersistentFlagFilename("token-file")
	_ = root.MarkPersistentFlagFilename("out")
	root.SetUsageTemplate(strings.NewReplacer("Usage:", "usage:", "Aliases:", "aliases:", "Examples:", "examples:", "Available Commands:", "available commands:", "Flags:", "flags:", "Global Flags:", "global flags:", "Additional help topics:", "additional help topics:", "Use ", "use ").Replace(root.UsageTemplate()))
	root.SetVersionTemplate("{{.Name}} {{.Version}}\n")
	root.SetHelpCommand(&cobra.Command{Use: "help [command]", Short: "show help for a command", RunE: func(c *cobra.Command, args []string) error {
		target, rest, err := root.Find(args)
		if err != nil {
			return usage(err)
		}
		if len(rest) > 0 {
			return usage(fmt.Errorf("unknown command %q", strings.Join(rest, " ")))
		}
		return target.Help()
	}})
	root.RunE = func(c *cobra.Command, args []string) error {
		if len(args) > 0 {
			return usage(fmt.Errorf("unknown command %q", args[0]))
		}
		return c.Help()
	}
	addCommands(root, o)
	completion := &cobra.Command{Use: "completion <bash|zsh>", Short: "generate shell completion", ValidArgs: []string{"bash", "zsh"}, Args: func(c *cobra.Command, args []string) error {
		return usage(cobra.MatchAll(cobra.ExactArgs(1), cobra.OnlyValidArgs)(c, args))
	}, RunE: func(c *cobra.Command, args []string) error {
		if args[0] == "bash" {
			return root.GenBashCompletionV2(c.OutOrStdout(), true)
		}
		return root.GenZshCompletion(c.OutOrStdout())
	}}
	root.AddCommand(completion)
	return root
}

func (o *options) command(use, short string, nargs int, build builder) *cobra.Command {
	cmd := &cobra.Command{Use: use, Short: short, Args: func(c *cobra.Command, args []string) error { return usage(cobra.ExactArgs(nargs)(c, args)) }, ValidArgsFunction: cobra.NoFileCompletions}
	cmd.RunE = func(c *cobra.Command, args []string) error {
		op, err := build(c, args)
		if err != nil {
			return usage(err)
		}
		if o.timeout <= 0 {
			return usage(errors.New("timeout must be positive"))
		}
		token := o.token
		if !c.Flags().Changed("token") {
			token = os.Getenv("TC002_TOKEN")
		}
		if c.Flags().Changed("token-file") && !c.Flags().Changed("token") {
			token = ""
		}
		if o.server == "" {
			return usage(errors.New("server is required: --server or TC002_SERVER"))
		}
		transport, err := client.New(client.Options{Server: o.server, Token: token, TokenFile: o.tokenFile, Admin: o.admin || op.admin, Timeout: o.timeout})
		if err != nil {
			return err
		}
		if len(op.chunks) > 0 {
			return o.uploadSound(c, transport, op)
		}
		response, err := transport.Do(c.Context(), op.request)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		return o.output(c, response.Body, op.request.Stream, response.Header.Get("Content-Type"))
	}
	return cmd
}

func (o *options) output(c *cobra.Command, r io.Reader, stream bool, contentType string) error {
	if stream {
		if o.out == "" {
			_, err := io.Copy(c.OutOrStdout(), r)
			return err
		}
		f, err := os.OpenFile(o.out, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			return fmt.Errorf("open output: %w", err)
		}
		_, copyErr := io.Copy(f, r)
		return errors.Join(copyErr, f.Close())
	}
	b, err := io.ReadAll(io.LimitReader(r, 4*1024*1024+1))
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if len(b) > 4*1024*1024 {
		return errors.New("response exceeds 4 mib")
	}
	mediaType, _, _ := mime.ParseMediaType(contentType)
	if mediaType == "application/json" && json.Valid(b) {
		var formatted bytes.Buffer
		if o.compact {
			err = json.Compact(&formatted, b)
		} else {
			err = json.Indent(&formatted, b, "", "  ")
		}
		if err != nil {
			return err
		}
		b = append(formatted.Bytes(), '\n')
	}
	if o.out != "" {
		return os.WriteFile(o.out, b, 0600)
	}
	_, err = c.OutOrStdout().Write(b)
	return err
}

func (o *options) uploadSound(c *cobra.Command, transport *client.Client, op operation) error {
	offset := 0
	for i, chunk := range op.chunks {
		req := op.request
		req.Body = chunk
		req.Query = map[string][]string{"offset": {fmt.Sprint(offset)}}
		if i == len(op.chunks)-1 {
			req.Query.Set("final", "1")
		}
		response, err := transport.Do(c.Context(), req)
		if err != nil {
			return fmt.Errorf("upload at offset %d: %w", offset, err)
		}
		if i == len(op.chunks)-1 {
			defer response.Body.Close()
			return o.output(c, response.Body, false, response.Header.Get("Content-Type"))
		}
		_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 8193))
		closeErr := response.Body.Close()
		if err != nil || closeErr != nil {
			return errors.Join(err, closeErr)
		}
		offset += len(chunk)
	}
	return nil
}
