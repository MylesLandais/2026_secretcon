package fswatch

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/fsnotify/fsnotify"
	"github.com/secretcon/secretcon-watchdog/config"
	"github.com/secretcon/secretcon-watchdog/health"
	"github.com/secretcon/secretcon-watchdog/logutil"
)

func allowed(name string, allow []string) bool {
	if len(allow) == 0 {
		return false
	}
	base := filepath.Base(name)
	for _, a := range allow {
		if strings.EqualFold(base, a) {
			return true
		}
	}
	return false
}

func Run(cfg *config.Config, onUnexpected func(path string)) {
	if len(cfg.WatchPaths) == 0 {
		return
	}
	w, err := fsnotify.NewWatcher()
	if err != nil {
		logutil.Append(cfg.LogPath, "fsnotify init failed: "+err.Error())
		return
	}
	defer w.Close()

	for _, root := range cfg.WatchPaths {
		_ = os.MkdirAll(root, 0755)
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() {
				_ = w.Add(path)
			}
			return nil
		})
		_ = w.Add(root)
	}

	go func() {
		for {
			select {
			case ev, ok := <-w.Events:
				if !ok {
					return
				}
				if ev.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Rename) == 0 {
					continue
				}
				if allowed(ev.Name, cfg.AllowedFiles) {
					continue
				}
				logutil.Append(cfg.LogPath, "fs event: "+ev.String())
				onUnexpected(ev.Name)
			case err, ok := <-w.Errors:
				if !ok {
					return
				}
				logutil.Append(cfg.LogPath, "fs error: "+err.Error())
			}
		}
	}()
}

func HandleUnexpected(cfg *config.Config, path string) {
	_ = health.RestartService(cfg)
	logutil.Append(cfg.LogPath, "cleaned after fs event at "+path)
}
