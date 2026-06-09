package testutil

import (
	"context"
	"strings"
	"testing"

	"github.com/routerarchitects/olg-server-vyos-client-natagent/internal/renderervyos"
)

/*
TC-TESTUTIL-FIXTURES-001
Type: Positive
Title: Minimal desired config renders with real renderer
Summary:
Builds the shared minimal desired config fixture and runs it through
the real VyOS renderer adapter. The default minimal fixture should be
safe for future tests that expect a renderable desired payload.

Validates:
  - MinimalDesiredConfig renders without error
  - rendered output contains VyOS set commands
*/
func TestMinimalDesiredConfigRendersWithRealRenderer(t *testing.T) {
	adapter, err := renderervyos.New()
	if err != nil {
		t.Fatalf("new renderer adapter: %v", err)
	}

	out, err := adapter.Render(context.Background(), MinimalDesiredConfig())
	if err != nil {
		t.Fatalf("render minimal desired config: %v", err)
	}
	if !strings.Contains(out.Text, "set interfaces bridge") {
		t.Fatalf("rendered text got=%q want bridge set commands", out.Text)
	}
}

/*
TC-TESTUTIL-FIXTURES-002
Type: Positive
Title: Placeholder desired config remains explicit
Summary:
Builds the placeholder-only desired config fixture and renders it with
the real renderer adapter. The fixture intentionally preserves the old
empty payload behavior under a name that limits its scope.

Validates:
  - MinimalPlaceholderDesiredConfig renders without adapter errors
  - placeholder-only payload renders empty command text
*/
func TestMinimalPlaceholderDesiredConfigIsExplicitlyPlaceholderOnly(t *testing.T) {
	adapter, err := renderervyos.New()
	if err != nil {
		t.Fatalf("new renderer adapter: %v", err)
	}

	out, err := adapter.Render(context.Background(), MinimalPlaceholderDesiredConfig())
	if err != nil {
		t.Fatalf("render placeholder desired config: %v", err)
	}
	if out.Text != "" {
		t.Fatalf("placeholder rendered text got=%q want empty", out.Text)
	}
}
