// Lucairn quickstart — Go.
//
// Sends a synthetic German medical PII prompt through gateway.lucairn.eu and
// prints the redacted response together with the verifiable certificate URL.
//
// Run:
//
//	export LUCAIRN_API_KEY=lcr_live_...
//	export ANTHROPIC_API_KEY=sk-ant-...
//	go run quickstart.go
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const prompt = "Bitte fasse den folgenden Patientenbefund auf Deutsch in 2 Sätzen zusammen.\n\n" +
	"Patientin: Anna Schmidt, geboren 12.03.1985, " +
	"IBAN DE89 3704 0044 0532 0130 00.\n" +
	"Diagnose: Hypertonie. Empfehlung: Tägliche Blutdruck-Messung, " +
	"Reduktion Salzkonsum, Beta-Blocker 50mg."

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type request struct {
	Model     string    `json:"model"`
	MaxTokens int       `json:"max_tokens"`
	Messages  []message `json:"messages"`
}

type contentBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type compliance struct {
	RequestID          string   `json:"request_id"`
	VeilCertificateURL string   `json:"veil_certificate_url,omitempty"`
	VeilSummaryURL     string   `json:"veil_summary_url,omitempty"`
	PIIInAI            *bool    `json:"pii_in_ai,omitempty"`
	IdentityInAI       *bool    `json:"identity_in_ai,omitempty"`
	SanitizerLayers    []string `json:"sanitizer_layers,omitempty"`
	RedactionCount     int      `json:"redaction_count"`
	LatencyMs          int64    `json:"latency_ms"`
}

type response struct {
	Content  []contentBlock `json:"content"`
	Metadata *struct {
		DSACompliance compliance `json:"dsa_compliance"`
	} `json:"metadata,omitempty"`
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func run() error {
	lucairnKey := os.Getenv("LUCAIRN_API_KEY")
	anthropicKey := os.Getenv("ANTHROPIC_API_KEY")
	if lucairnKey == "" || anthropicKey == "" {
		return fmt.Errorf("set LUCAIRN_API_KEY and ANTHROPIC_API_KEY env vars before running")
	}
	gateway := envOr("LUCAIRN_GATEWAY_URL", "https://gateway.lucairn.eu")
	model := envOr("LUCAIRN_MODEL", "claude-sonnet-4-6")

	body, err := json.Marshal(request{
		Model:     model,
		MaxTokens: 256,
		Messages:  []message{{Role: "user", Content: prompt}},
	})
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, gateway+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("x-api-key", lucairnKey)
	req.Header.Set("X-Upstream-Key", anthropicKey)
	req.Header.Set("content-type", "application/json")

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("gateway call: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("gateway returned %d: %s", resp.StatusCode, string(raw))
	}

	var parsed response
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	var sb strings.Builder
	for _, b := range parsed.Content {
		if b.Type == "text" {
			if sb.Len() > 0 {
				sb.WriteByte('\n')
			}
			sb.WriteString(b.Text)
		}
	}
	fmt.Println("── LLM response ────────────────────────────────────────")
	if sb.Len() == 0 {
		fmt.Println("(no text content)")
	} else {
		fmt.Println(sb.String())
	}
	fmt.Println()

	fmt.Println("── Compliance metadata ─────────────────────────────────")
	if parsed.Metadata != nil {
		pretty, _ := json.MarshalIndent(parsed.Metadata.DSACompliance, "", "  ")
		fmt.Println(string(pretty))
		fmt.Println()
		if url := parsed.Metadata.DSACompliance.VeilCertificateURL; url != "" {
			parts := strings.Split(url, "/")
			requestID := parts[len(parts)-1]
			fmt.Println("── Verify the cert ─────────────────────────────────────")
			fmt.Printf("Open: https://lucairn.eu/verify?cert=%s\n", requestID)
		}
	} else {
		fmt.Println("{}")
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}
