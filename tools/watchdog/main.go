package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/secretcon/secretcon-watchdog/agent"
	"github.com/secretcon/secretcon-watchdog/config"
)

func main() {
	configPath := flag.String("config", `C:\secretcon\watchdog-config.json`, "path to watchdog JSON config")
	check := flag.Bool("check", false, "supervisor mode: ensure target Windows service is running")
	install := flag.Bool("install", false, "register SecretConWatchdog Windows service (Windows only)")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	if *install {
		if err := installWatchdogService(os.Args[0], *configPath); err != nil {
			fmt.Fprintf(os.Stderr, "install: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if *check {
		if err := agent.CheckMode(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "check: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := runWatchdog(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "run: %v\n", err)
		os.Exit(1)
	}
}
