// Command api is the hunters-map backend on Cloud Run.
//
// Environment:
//
//	PORT                  listen port (Cloud Run sets it; default 8080)
//	GOOGLE_CLOUD_PROJECT  GCP / Firebase project id
//	FIRESTORE_DATABASE    Firestore database id (default "hunters-map")
//	DEV_MODE              "1" for local development: in-memory store and "dev:<uid>:<name>"
//	                      tokens instead of Firestore and Firebase. Refused on Cloud Run.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"cloud.google.com/go/firestore"
	firebase "firebase.google.com/go/v4"

	"github.com/ransoni/hunters-map/backend/internal/api"
	"github.com/ransoni/hunters-map/backend/internal/auth"
	"github.com/ransoni/hunters-map/backend/internal/service"
	"github.com/ransoni/hunters-map/backend/internal/store"
)

func main() {
	// JSON logs with "severity" and "message", the field names Cloud Logging understands.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.LevelKey:
				a.Key = "severity"
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	}))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var (
		st       store.Store
		verifier auth.Verifier
		accounts auth.AccountDeleter
	)
	if os.Getenv("DEV_MODE") == "1" {
		if os.Getenv("K_SERVICE") != "" {
			return errors.New("DEV_MODE is not allowed on Cloud Run")
		}
		log.Warn("DEV_MODE: in-memory store, unverified dev tokens")
		st, verifier, accounts = store.NewMemory(), auth.Dev{}, auth.Dev{}
	} else {
		project := os.Getenv("GOOGLE_CLOUD_PROJECT")
		if project == "" {
			return errors.New("GOOGLE_CLOUD_PROJECT is not set")
		}
		database := envOr("FIRESTORE_DATABASE", "hunters-map")
		fs, err := firestore.NewClientWithDatabase(ctx, project, database)
		if err != nil {
			return err
		}
		defer fs.Close()
		app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: project})
		if err != nil {
			return err
		}
		fbAuth, err := app.Auth(ctx)
		if err != nil {
			return err
		}
		fb := auth.Firebase{Client: fbAuth}
		st, verifier, accounts = store.NewFirestore(fs), fb, fb
		log.Info("starting", "project", project, "database", database)
	}

	srv := &http.Server{
		Addr:              ":" + envOr("PORT", "8080"),
		Handler:           api.New(service.New(st, nil), verifier, accounts, log).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("listening", "addr", srv.Addr)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	// Cloud Run sends SIGTERM and allows 10 s before killing the instance.
	shutdown, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
