package apply

import (
	"context"

	"github.com/routerarchitects/olg-server-vyos-client-natagent/internal/renderer"
)

// Engine applies rendered config for a target.
type Engine interface {
	Apply(ctx context.Context, rendered renderer.Output) error
}
