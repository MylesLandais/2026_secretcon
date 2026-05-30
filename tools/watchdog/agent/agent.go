package agent

import (
	"fmt"
	"os/exec"
	"time"

	"github.com/secretcon/secretcon-watchdog/config"
	"github.com/secretcon/secretcon-watchdog/escalation"
	"github.com/secretcon/secretcon-watchdog/fswatch"
	"github.com/secretcon/secretcon-watchdog/health"
	"github.com/secretcon/secretcon-watchdog/logutil"
)

type Agent struct {
	cfg              *config.Config
	consecutiveFails int
}

func New(cfg *config.Config) *Agent {
	return &Agent{cfg: cfg}
}

func (a *Agent) Run() {
	logutil.Append(a.cfg.LogPath, "watchdog agent started")
	fswatch.Run(a.cfg, func(path string) {
		fswatch.HandleUnexpected(a.cfg, path)
		a.consecutiveFails = 0
	})

	ticker := time.NewTicker(time.Duration(a.cfg.HealthIntervalSec) * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		a.tick()
	}
}

func (a *Agent) tick() {
	if health.LivenessOK(a.cfg) {
		if a.consecutiveFails > 0 {
			logutil.Append(a.cfg.LogPath, "liveness restored")
		}
		a.consecutiveFails = 0
		return
	}
	a.consecutiveFails++
	logutil.Append(a.cfg.LogPath, fmt.Sprintf("liveness fail count=%d", a.consecutiveFails))

	if a.consecutiveFails == 1 {
		if health.TryRecover(a.cfg, "first failure") {
			a.consecutiveFails = 0
		}
		return
	}
	if a.consecutiveFails >= a.cfg.ConsecutiveFailLimit {
		reason := fmt.Sprintf("consecutive_failures=%d", a.consecutiveFails)
		_ = escalation.WriteMarker(a.cfg, reason)
		a.writeEventLog(reason)
	}
}

func (a *Agent) writeEventLog(reason string) {
	script := fmt.Sprintf(
		`$src='SecretConWatchdog'; if (-not [System.Diagnostics.EventLog]::SourceExists($src)) { New-EventLog -LogName Application -Source $src | Out-Null }; Write-EventLog -LogName Application -Source $src -EntryType Warning -EventId 9050 -Message '%s'`,
		reason,
	)
	_ = exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script).Run()
}

const agentServiceName = "SecretConWatchdog"

// CheckMode is the scheduled-task supervisor entry: ensure the watchdog service is up.
func CheckMode(cfg *config.Config) error {
	if !health.ServiceRunning(agentServiceName) {
		logutil.Append(cfg.LogPath, "check: SecretConWatchdog not running; attempting sc start")
		_ = exec.Command("sc.exe", "start", agentServiceName).Run()
		time.Sleep(time.Duration(cfg.RecheckAfterSec) * time.Second)
		if !health.ServiceRunning(agentServiceName) {
			return fmt.Errorf("agent service %s still not running after check", agentServiceName)
		}
	}
	if !health.LivenessOK(cfg) {
		logutil.Append(cfg.LogPath, "check: challenge liveness failed; attempting recover")
		if !health.TryRecover(cfg, "supervisor check") {
			return fmt.Errorf("challenge service %s unhealthy after supervisor recover", cfg.ServiceName)
		}
	}
	return nil
}
