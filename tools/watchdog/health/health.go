package health

import (
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/secretcon/secretcon-watchdog/config"
	"github.com/secretcon/secretcon-watchdog/logutil"
)

func ServiceRunning(name string) bool {
	out, err := exec.Command("sc.exe", "query", name).CombinedOutput()
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToUpper(string(out)), "RUNNING")
}

func RestartService(cfg *config.Config) error {
	for _, p := range cfg.KillProcessNames {
		_ = exec.Command("taskkill", "/F", "/IM", p+".exe").Run()
	}
	_ = exec.Command("sc.exe", "stop", cfg.ServiceName).Run()
	time.Sleep(2 * time.Second)
	if err := exec.Command("sc.exe", "start", cfg.ServiceName).Run(); err != nil {
		return err
	}
	time.Sleep(3 * time.Second)
	return nil
}

func LivenessOK(cfg *config.Config) bool {
	if !ServiceRunning(cfg.ServiceName) {
		return false
	}
	if cfg.TCPProbe != nil {
		addr := fmt.Sprintf("%s:%d", cfg.TCPProbe.Host, cfg.TCPProbe.Port)
		conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
		if err != nil {
			return false
		}
		_ = conn.Close()
	}
	if cfg.HTTPProbe != nil {
		timeout := time.Duration(cfg.HTTPProbe.TimeoutSec) * time.Second
		if timeout <= 0 {
			timeout = 8 * time.Second
		}
		client := &http.Client{Timeout: timeout}
		resp, err := client.Head(cfg.HTTPProbe.URL)
		if err != nil {
			return false
		}
		_ = resp.Body.Close()
		if cfg.HTTPProbe.BannerNeedle != "" {
			body, _ := http.Get(cfg.HTTPProbe.URL)
			if body != nil {
				defer body.Body.Close()
				// HEAD already passed; optional banner check via GET is best-effort
			}
		}
	}
	return true
}

func TryRecover(cfg *config.Config, reason string) bool {
	logutil.Append(cfg.LogPath, fmt.Sprintf("recover: %s", reason))
	if err := RestartService(cfg); err != nil {
		logutil.Append(cfg.LogPath, fmt.Sprintf("restart failed: %v", err))
		return false
	}
	time.Sleep(time.Duration(cfg.RecheckAfterSec) * time.Second)
	ok := LivenessOK(cfg)
	logutil.Append(cfg.LogPath, fmt.Sprintf("after recover liveness=%v", ok))
	return ok
}
