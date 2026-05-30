package escalation

import (
	"fmt"
	"os"
	"time"

	"github.com/secretcon/secretcon-watchdog/config"
	"github.com/secretcon/secretcon-watchdog/logutil"
)

func WriteMarker(cfg *config.Config, reason string) error {
	dir := `C:\secretcon`
	_ = os.MkdirAll(dir, 0755)
	body := fmt.Sprintf("unhealthy_at=%s\nservice=%s\nreason=%s\n",
		time.Now().UTC().Format(time.RFC3339), cfg.ServiceName, reason)
	if err := os.WriteFile(cfg.MarkerPath, []byte(body), 0644); err != nil {
		return err
	}
	logutil.Append(cfg.LogPath, "wrote unhealthy marker: "+reason)
	return nil
}
