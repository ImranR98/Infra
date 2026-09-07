package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"

	"github.com/http-wasm/http-wasm-guest-tinygo/handler"
	"github.com/http-wasm/http-wasm-guest-tinygo/handler/api"
)

type Config struct {
	TrustedHeaders []string `json:"trustedHeaders,omitempty"`
	Blocking       string   `json:"blocking,omitempty"`
}

func init() {
	var config Config
	if err := json.Unmarshal(handler.Host.GetConfig(), &config); err != nil {
		handler.Host.Log(api.LogLevelError, fmt.Sprintf("Could not load config %v", err))
		os.Exit(1)
	}
	if len(config.TrustedHeaders) == 0 {
		config.TrustedHeaders = []string{"Remote-User"}
	}

	handler.HandleRequestFn = func(req api.Request, resp api.Response) (next bool, reqCtx uint32) {
		if config.Blocking != "true" {
			return true, 0
		}
		for _, h := range config.TrustedHeaders {
			if value, ok := req.Headers().Get(h); !ok || value == "" {
				resp.SetStatusCode(http.StatusUnauthorized)
				return false, 0
			}
		}
		return true, 0
	}
}
