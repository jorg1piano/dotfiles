package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// keyNames are the variables checked for an API key, in order.
var keyNames = []string{"T2S", "OPENAI_API_KEY"}

// loadDotEnv reads the first .env file it finds and puts its values in the
// process environment. Real environment variables win over the file.
// Search order: $SAYTHIS_ENV_FILE, then .env in the working directory and each
// parent up to the home directory, then ~/.config/saythis/.env.
func loadDotEnv() {
	for _, path := range envFileCandidates() {
		if applyEnvFile(path) {
			return
		}
	}
}

func envFileCandidates() []string {
	var paths []string
	if p := os.Getenv("SAYTHIS_ENV_FILE"); p != "" {
		paths = append(paths, p)
	}

	home, _ := os.UserHomeDir()
	if dir, err := os.Getwd(); err == nil {
		for {
			paths = append(paths, filepath.Join(dir, ".env"))
			parent := filepath.Dir(dir)
			if parent == dir || dir == home {
				break
			}
			dir = parent
		}
	}
	if home != "" {
		paths = append(paths, filepath.Join(home, ".config", "saythis", ".env"))
	}
	return paths
}

// applyEnvFile reports whether path existed and was read.
func applyEnvFile(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		key, value, ok := parseEnvLine(scanner.Text())
		if !ok {
			continue
		}
		if _, set := os.LookupEnv(key); !set {
			os.Setenv(key, value)
		}
	}
	return true
}

// parseEnvLine handles KEY=value, optional export prefix, quotes and # comments.
func parseEnvLine(line string) (key, value string, ok bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", "", false
	}
	line = strings.TrimPrefix(line, "export ")

	key, value, ok = strings.Cut(line, "=")
	if !ok {
		return "", "", false
	}
	key = strings.TrimSpace(key)
	value = strings.TrimSpace(value)
	if key == "" {
		return "", "", false
	}

	switch {
	case len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"',
		len(value) >= 2 && value[0] == '\'' && value[len(value)-1] == '\'':
		value = value[1 : len(value)-1]
	default:
		// An unquoted value ends at the first comment marker.
		if i := strings.Index(value, " #"); i >= 0 {
			value = strings.TrimSpace(value[:i])
		}
	}
	return key, value, true
}

// apiKey returns the first key found among keyNames.
func apiKey() (string, bool) {
	for _, name := range keyNames {
		if v := strings.TrimSpace(os.Getenv(name)); v != "" {
			return v, true
		}
	}
	return "", false
}
