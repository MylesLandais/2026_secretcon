package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cfg.json")
	if err := os.WriteFile(path, []byte(`{"service_name":"TestSvc"}`), 0644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.HealthIntervalSec != 15 {
		t.Fatalf("interval=%d want 15", c.HealthIntervalSec)
	}
	if c.MarkerPath == "" {
		t.Fatal("marker path empty")
	}
}
