package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type client struct {
	apiKey  string
	baseURL string
	http    *http.Client
}

func newClient() (*client, error) {
	key, ok := apiKey()
	if !ok {
		return nil, fmt.Errorf("no API key found; set %s, or put it in a .env file next to the project", strings.Join(keyNames, " or "))
	}
	base := envOr("OPENAI_BASE_URL", "https://api.openai.com/v1")
	return &client{
		apiKey:  key,
		baseURL: strings.TrimRight(base, "/"),
		http:    &http.Client{Timeout: 5 * time.Minute},
	}, nil
}

type speechRequest struct {
	Model          string  `json:"model"`
	Input          string  `json:"input"`
	Voice          string  `json:"voice"`
	Speed          float64 `json:"speed,omitempty"`
	ResponseFormat string  `json:"response_format,omitempty"`
	Instructions   string  `json:"instructions,omitempty"`
}

// speech returns the audio stream for req. The caller closes it.
func (c *client) speech(ctx context.Context, req speechRequest) (io.ReadCloser, error) {
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/audio/speech", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("calling the OpenAI API: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		defer resp.Body.Close()
		return nil, apiError(resp)
	}
	return resp.Body, nil
}

// apiError turns a non-200 response into the message OpenAI put in the body.
func apiError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))

	var wrapper struct {
		Error struct {
			Message string `json:"message"`
			Code    string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &wrapper) == nil && wrapper.Error.Message != "" {
		return fmt.Errorf("OpenAI API %s: %s", resp.Status, wrapper.Error.Message)
	}

	text := strings.TrimSpace(string(body))
	if text == "" {
		return fmt.Errorf("OpenAI API %s", resp.Status)
	}
	return fmt.Errorf("OpenAI API %s: %s", resp.Status, text)
}
