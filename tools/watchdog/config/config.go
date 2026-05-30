package config

import (
	"encoding/json"
	"fmt"
	"os"
)

type HTTPProbe struct {
	URL          string `json:"url"`
	BannerNeedle string `json:"banner_needle,omitempty"`
	TimeoutSec   int    `json:"timeout_sec,omitempty"`
}

type TCPProbe struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

type Config struct {
	ServiceName           string   `json:"service_name"`
	WatchPaths            []string `json:"watch_paths"`
	AllowedFiles          []string `json:"allowed_files,omitempty"`
	HealthIntervalSec     int      `json:"health_interval_sec"`
	RecheckAfterSec       int      `json:"recheck_after_sec"`
	ConsecutiveFailLimit  int      `json:"consecutive_fail_limit"`
	MarkerPath            string   `json:"marker_path"`
	LogPath               string   `json:"log_path"`
	TCPProbe              *TCPProbe `json:"tcp_probe,omitempty"`
	HTTPProbe             *HTTPProbe `json:"http_probe,omitempty"`
	KillProcessNames      []string `json:"kill_process_names,omitempty"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

func (c *Config) validate() error {
	if c.ServiceName == "" {
		return fmt.Errorf("service_name is required")
	}
	if c.HealthIntervalSec <= 0 {
		c.HealthIntervalSec = 15
	}
	if c.RecheckAfterSec <= 0 {
		c.RecheckAfterSec = 10
	}
	if c.ConsecutiveFailLimit <= 0 {
		c.ConsecutiveFailLimit = 2
	}
	if c.MarkerPath == "" {
		c.MarkerPath = `C:\secretcon\watchdog-unhealthy.marker`
	}
	if c.LogPath == "" {
		c.LogPath = `C:\secretcon\watchdog.log`
	}
	return nil
}
