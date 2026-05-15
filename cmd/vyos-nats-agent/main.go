package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/routerarchitects/olg-server-vyos-client-natagent/internal/config"
)

func main() {
	os.Exit(runConfigCLI(os.Args[1:], os.Stdout, os.Stderr))
}

type cliOptions struct {
	configPath           string
	validateConfig       bool
	printEffectiveConfig bool
}

func runConfigCLI(args []string, stdout io.Writer, stderr io.Writer) int {
	opts, code, done := parseCLIArgs(args, stdout, stderr)
	if done {
		return code
	}

	cfg, err := loadAndValidateConfig(opts.configPath)
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}

	if opts.printEffectiveConfig {
		if err := printEffectiveConfig(stdout, *cfg); err != nil {
			fmt.Fprintf(stderr, "failed to marshal effective config yaml: %v\n", err)
			return 1
		}
	}

	if opts.validateConfig {
		fmt.Fprintln(stdout, "configuration valid")
		return 0
	}

	fmt.Fprintln(stdout, "phase 1 complete: config loader available; agent runtime not implemented yet")
	return 0
}

func parseCLIArgs(args []string, stdout io.Writer, stderr io.Writer) (cliOptions, int, bool) {
	var opts cliOptions
	fs := flag.NewFlagSet("vyos-nats-agent", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&opts.configPath, "config", "", "Path to YAML config file")
	fs.BoolVar(&opts.validateConfig, "validate-config", false, "Validate config and exit")
	fs.BoolVar(&opts.printEffectiveConfig, "print-effective-config", false, "Print sanitized effective config and continue")

	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			printUsage(stdout)
			return cliOptions{}, 0, true
		}
		fmt.Fprintf(stderr, "failed to parse flags: %v\n", err)
		return cliOptions{}, 2, true
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "failed to parse flags: unexpected positional arguments: %s\n", strings.Join(fs.Args(), " "))
		return cliOptions{}, 2, true
	}
	return opts, 0, false
}

func loadAndValidateConfig(configPath string) (*config.AppConfig, error) {
	cfg, _, err := config.LoadResolved(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load config: %w", err)
	}

	if _, err := cfg.ToAgentCoreConfig(); err != nil {
		return nil, fmt.Errorf("failed to convert config to agentcore.Config: %w", err)
	}
	return cfg, nil
}

func printEffectiveConfig(w io.Writer, cfg config.AppConfig) error {
	payload, err := config.MarshalRedactedYAML(cfg)
	if err != nil {
		return err
	}
	fmt.Fprint(w, string(payload))
	return nil
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage:")
	fmt.Fprintln(w, "  vyos-nats-agent [options]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Options:")
	fmt.Fprintln(w, "  --config <path>             Path to YAML config file")
	fmt.Fprintln(w, "  --validate-config           Validate config and exit")
	fmt.Fprintln(w, "  --print-effective-config    Print sanitized effective config and continue")
	fmt.Fprintln(w, "  --help                      Show help")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Config path resolution:")
	fmt.Fprintln(w, "  1. --config")
	fmt.Fprintln(w, "  2. VYOS_NATS_AGENT_CONFIG")
	fmt.Fprintln(w, "  3. /etc/vyos-nats-agent/config.yaml")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Phase 1 behavior:")
	fmt.Fprintln(w, "  This binary only loads, validates, prints, and converts configuration.")
	fmt.Fprintln(w, "  It does not connect to NATS or start the agent runtime yet.")
}
