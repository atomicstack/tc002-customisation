package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/atomicstack/tc002-customisation/api-client-v2/internal/cli"
)

func main() { os.Exit(run()) }
func run() int {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	err := cli.NewCommand().ExecuteContext(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
	}
	return cli.ExitCode(err)
}
