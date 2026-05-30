//go:build !windows

package main

import (
	"fmt"

	"github.com/secretcon/secretcon-watchdog/agent"
	"github.com/secretcon/secretcon-watchdog/config"
)

func runWatchdog(cfg *config.Config) error {
	agent.New(cfg).Run()
	return nil
}

func installWatchdogService(_, _ string) error {
	return fmt.Errorf("install only supported on Windows")
}
