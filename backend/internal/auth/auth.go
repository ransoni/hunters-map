// Package auth verifies Firebase ID tokens (Google / Apple sign-in) on API requests.
package auth

import (
	"context"
	"errors"
	"net/http"
	"strings"

	fbauth "firebase.google.com/go/v4/auth"

	"github.com/ransoni/hunters-map/backend/internal/service"
)

// Verifier turns a bearer token into the signed-in identity.
type Verifier interface {
	Verify(ctx context.Context, token string) (service.Identity, error)
}

// AccountDeleter deletes the sign-in account (DELETE /v1/me).
type AccountDeleter interface {
	DeleteAccount(ctx context.Context, uid string) error
}

// Firebase verifies tokens issued by Firebase Authentication for this project.
type Firebase struct {
	Client *fbauth.Client
}

func (f Firebase) Verify(ctx context.Context, token string) (service.Identity, error) {
	t, err := f.Client.VerifyIDToken(ctx, token)
	if err != nil {
		return service.Identity{}, err
	}
	id := service.Identity{UID: t.UID}
	id.Name, _ = t.Claims["name"].(string)
	id.Email, _ = t.Claims["email"].(string)
	return id, nil
}

func (f Firebase) DeleteAccount(ctx context.Context, uid string) error {
	err := f.Client.DeleteUser(ctx, uid)
	if fbauth.IsUserNotFound(err) {
		return nil
	}
	return err
}

// Dev accepts "dev:<uid>:<name>" tokens without any check. For local development only:
// main refuses to use it on Cloud Run.
type Dev struct{}

func (Dev) Verify(_ context.Context, token string) (service.Identity, error) {
	rest, ok := strings.CutPrefix(token, "dev:")
	if !ok {
		return service.Identity{}, errors.New(`dev tokens look like "dev:<uid>:<name>"`)
	}
	uid, name, _ := strings.Cut(rest, ":")
	if uid == "" {
		return service.Identity{}, errors.New("dev token without uid")
	}
	return service.Identity{UID: uid, Name: name, Email: uid + "@dev.local"}, nil
}

func (Dev) DeleteAccount(context.Context, string) error { return nil }

type ctxKey struct{}

// Middleware rejects requests without a valid "Authorization: Bearer <token>" header and
// puts the identity in the request context.
func Middleware(v Verifier, onError func(http.ResponseWriter, int, string, string)) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				onError(w, http.StatusUnauthorized, "unauthenticated", "missing bearer token")
				return
			}
			id, err := v.Verify(r.Context(), token)
			if err != nil {
				onError(w, http.StatusUnauthorized, "unauthenticated", "invalid token")
				return
			}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, id)))
		})
	}
}

// FromContext returns the identity put there by Middleware.
func FromContext(ctx context.Context) service.Identity {
	id, _ := ctx.Value(ctxKey{}).(service.Identity)
	return id
}
