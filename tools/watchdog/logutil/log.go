package logutil

import (
	"fmt"
	"os"
	"sync"
	"time"
)

var mu sync.Mutex

func Append(path, msg string) {
	mu.Lock()
	defer mu.Unlock()
	stamp := time.Now().UTC().Format(time.RFC3339)
	line := fmt.Sprintf("[%s] %s\n", stamp, msg)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line)
}
