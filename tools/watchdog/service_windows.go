//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/secretcon/secretcon-watchdog/agent"
	"github.com/secretcon/secretcon-watchdog/config"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/debug"
	"golang.org/x/sys/windows/svc/eventlog"
)

const winServiceName = "SecretConWatchdog"

type watchdogService struct {
	cfg *config.Config
}

func (m *watchdogService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	const cmdsAccepted = svc.AcceptStop | svc.AcceptShutdown
	changes <- svc.Status{State: svc.StartPending}
	changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}

	done := make(chan struct{})
	go func() {
		agent.New(m.cfg).Run()
		close(done)
	}()

	for {
		select {
		case <-done:
			changes <- svc.Status{State: svc.Stopped}
			return false, 0
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				changes <- svc.Status{State: svc.Stopped}
				return false, 0
			}
		}
	}
}

func runWatchdog(cfg *config.Config) error {
	isIntSess, err := svc.IsAnInteractiveSession()
	if err != nil {
		return err
	}
	run := svc.Run
	if isIntSess {
		run = debug.Run
	}
	if elog, err := eventlog.Open(winServiceName); err == nil {
		_ = elog.Info(1, "SecretConWatchdog starting")
		_ = elog.Close()
	}
	return run(winServiceName, &watchdogService{cfg: cfg})
}

func installWatchdogService(exeArg0, configPath string) error {
	exe, err := filepath.Abs(exeArg0)
	if err != nil {
		return err
	}
	binPathArg := fmt.Sprintf(`binPath= "%s" --config "%s"`, exe, configPath)
	_ = exec.Command("sc.exe", "stop", winServiceName).Run()
	_ = exec.Command("sc.exe", "delete", winServiceName).Run()
	out, err := exec.Command("sc.exe", "create", winServiceName,
		binPathArg,
		"start= auto",
		"DisplayName= SecretCon Challenge Watchdog",
	).CombinedOutput()
	if err != nil && !strings.Contains(string(out), "SUCCESS") {
		return fmt.Errorf("%w: %s", err, out)
	}
	_, _ = exec.Command("sc.exe", "description", winServiceName,
		"SecretCon challenge box health agent (FS watch + liveness)").CombinedOutput()
	_, err = exec.Command("sc.exe", "start", winServiceName).CombinedOutput()
	return err
}
