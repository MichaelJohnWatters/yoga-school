package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"firebase.google.com/go/v4/messaging"

	"github.com/studio52/yoga-school/server/internal/api"
	"github.com/studio52/yoga-school/server/internal/auth"
	"github.com/studio52/yoga-school/server/internal/blob"
	"github.com/studio52/yoga-school/server/internal/jobs"
	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/push"
	"github.com/studio52/yoga-school/server/internal/secrets"
	"github.com/studio52/yoga-school/server/internal/store"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dbPath := flag.String("db", "dev.db", "sqlite database path")
	migrate := flag.Bool("migrate", false, "apply schema.sql then exit")
	seed := flag.Bool("seed", false, "apply the all-SQL dev seed after migrate")
	bootstrapAPI := flag.Bool("bootstrap-api", false,
		"seed a minimal bootstrap then build the rest through the real audited "+
			"store methods (populates audit_log); applied after migrate")
	flag.Parse()

	ctx := context.Background()
	st, err := store.Open(ctx, *dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer st.Close()

	if *migrate {
		root := projectRoot()
		if err := st.ApplySQLFile(ctx, filepath.Join(root, "db", "schema.sql")); err != nil {
			log.Fatalf("schema: %v", err)
		}
		log.Printf("applied schema")
		if *seed {
			if err := st.SeedDev(ctx); err != nil {
				log.Fatalf("seed: %v", err)
			}
			log.Printf("applied seed")
		}
		if *bootstrapAPI {
			// Wire media storage so the seed can populate the image library
			// through the real UploadMedia path. Optional: when no bucket is
			// configured the seed's media step skips cleanly and is listed in
			// the bootstrap's skipped-steps summary.
			if bucket := os.Getenv("FIREBASE_STORAGE_BUCKET"); bucket != "" {
				if app, err := auth.NewApp(ctx); err != nil {
					log.Printf("media seed: firebase init failed, skipping uploads: %v", err)
				} else if mb, err := blob.New(ctx, app, bucket); err != nil {
					log.Printf("media seed: storage init failed, skipping uploads: %v", err)
				} else {
					st.SetMediaStorage(mb)
				}
			}
			if err := st.SeedDevAPI(ctx); err != nil {
				log.Fatalf("bootstrap-api: %v", err)
			}
			log.Printf("applied bootstrap-api seed")
		}
		return
	}

	app, err := auth.NewApp(ctx)
	if err != nil {
		log.Fatalf("firebase init: %v", err)
	}
	fb, err := app.Auth(ctx)
	if err != nil {
		log.Fatalf("firebase auth init: %v", err)
	}
	emu := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if emu != "" {
		log.Printf("using Firebase Auth emulator at %s", emu)
	}

	// Wire FCM dispatch into the store. The Cloud Messaging service has no
	// emulator equivalent, so when we're running against the Auth emulator
	// we deliberately skip building the messaging client — the Notifier
	// runs in log-only mode and prints the push payloads to the server log
	// instead of trying to reach real FCM with no creds.
	var messagingClient *messaging.Client
	if emu == "" {
		mc, err := app.Messaging(ctx)
		if err != nil {
			log.Printf("messaging init failed (push disabled): %v", err)
		} else {
			messagingClient = mc
		}
	} else {
		log.Print("auth emulator active — FCM dispatch will log-only")
	}
	st.SetPushDispatcher(push.New(messagingClient, st.DB()))

	// Wire manager image uploads to Firebase Storage. Enabled only when a
	// bucket is named (FIREBASE_STORAGE_BUCKET); dev can point at the Storage
	// emulator via STORAGE_EMULATOR_HOST. Unset is fine — the media endpoints
	// then return a clear "not configured" 503 instead of failing to boot,
	// the same posture as the optional Stripe wiring below.
	if bucket := os.Getenv("FIREBASE_STORAGE_BUCKET"); bucket != "" {
		mb, err := blob.New(ctx, app, bucket)
		if err != nil {
			log.Printf("media storage init failed (uploads disabled): %v", err)
		} else {
			st.SetMediaStorage(mb)
			log.Printf("media uploads enabled (bucket=%s)", bucket)
		}
	} else {
		log.Print("FIREBASE_STORAGE_BUCKET unset — image uploads disabled")
	}

	// Stripe is mandatory for a running server — there is no "Stripe disabled"
	// mode. The encryption master (STRIPE_KEY_ENC_MASTER) is required so the
	// studio's keys can be sealed/unsealed, and the live gateway is always
	// wired (card purchases always go through Stripe; the dev_stub path is
	// test-only). The -migrate / -bootstrap-api flows return before this, so
	// schema/seed runs don't need the master.
	sealer, err := secrets.SealerFromEnv()
	if err != nil {
		log.Fatalf("secrets: %v", err)
	}
	if sealer == nil {
		log.Fatalf("STRIPE_KEY_ENC_MASTER is required (a 32-byte hex master key) — Stripe is mandatory; set it in the environment (.env in dev)")
	}
	st.SetSealer(sealer)
	// The gateway holds no key itself — each call resolves the studio's secret
	// via LoadStripeKeysForUse — so it's safe to set unconditionally.
	st.SetPaymentGateway(payments.NewStripeGateway())
	log.Print("Stripe payment gateway enabled")

	// Root context cancelled on SIGINT/SIGTERM — drives both the HTTP server's
	// graceful shutdown and the janitor goroutine.
	rootCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Background janitor: reconciles stale pending purchases against Stripe and
	// sweeps entitlement status. Ticks every 5 min; reconciles intents older
	// than 15 min so an in-progress checkout isn't cut short.
	janitor := jobs.NewJanitor(st, 5*time.Minute, 15*time.Minute)
	go janitor.Run(rootCtx)

	srv := &http.Server{
		Addr:              *addr,
		Handler:           api.NewServer(st, fb).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	// Serve in a goroutine so main can block on the shutdown signal.
	go func() {
		log.Printf("listening on %s (db=%s)", *addr, *dbPath)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	<-rootCtx.Done()
	log.Print("shutdown signal received — draining")
	stop() // restore default signal handling so a second Ctrl-C force-quits.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
	log.Print("stopped")
}

// projectRoot walks up from the binary's CWD looking for db/schema.sql.
func projectRoot() string {
	cwd, _ := os.Getwd()
	for d := cwd; d != "/" && d != ""; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "db", "schema.sql")); err == nil {
			return d
		}
	}
	return cwd
}
