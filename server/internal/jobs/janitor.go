// Package jobs holds the server's in-process background workers. There's no
// external scheduler — these run as goroutines tied to the server's lifecycle
// context, so they stop cleanly on shutdown.
package jobs

import (
	"context"
	"log"
	"time"
)

// Reconciler is the slice of the store the janitor depends on. Kept as an
// interface so the janitor is unit-testable with a fake.
type Reconciler interface {
	ReconcilePendingPurchases(ctx context.Context, olderThan time.Duration) (confirmed, voided int, err error)
	ReconcileStalePendingCheckouts(ctx context.Context, minAge time.Duration) (confirmed, voided int, err error)
	SweepEntitlements(ctx context.Context) (expired, depleted int, err error)
	// ReconcileSubscriptions expires membership checkouts that were started
	// but never completed (the student opened Checkout and walked away).
	ReconcileSubscriptions(ctx context.Context, olderThan time.Duration) (expired int, err error)
}

// Janitor runs periodic housekeeping: reconciling stale pending purchases
// against Stripe and sweeping entitlement status.
type Janitor struct {
	store      Reconciler
	interval   time.Duration
	pendingAge time.Duration
}

// NewJanitor builds a janitor. interval is how often it ticks; pendingAge is
// how old a pending purchase must be before it's reconciled (so we don't race
// a purchase the customer is still completing).
func NewJanitor(store Reconciler, interval, pendingAge time.Duration) *Janitor {
	return &Janitor{store: store, interval: interval, pendingAge: pendingAge}
}

// Run blocks until ctx is cancelled, ticking on the interval. Run it in a
// goroutine; cancel the context to stop it.
func (j *Janitor) Run(ctx context.Context) {
	t := time.NewTicker(j.interval)
	defer t.Stop()
	log.Printf("janitor: started (interval=%s, pending-age=%s)", j.interval, j.pendingAge)
	for {
		select {
		case <-ctx.Done():
			log.Print("janitor: stopped")
			return
		case <-t.C:
			j.tick(ctx)
		}
	}
}

// tick runs one housekeeping pass. Errors are logged, never fatal — a bad tick
// must not take the worker down; the next tick retries.
func (j *Janitor) tick(ctx context.Context) {
	if c, v, err := j.store.ReconcilePendingPurchases(ctx, j.pendingAge); err != nil {
		log.Printf("janitor: reconcile pending: %v", err)
	} else if c > 0 || v > 0 {
		log.Printf("janitor: reconciled pending purchases (confirmed=%d voided=%d)", c, v)
	}
	// Web checkout (cs_) pendings whose expired/completed webhook was missed.
	// 25h is past Stripe's 24h session lifetime, so an unpaid one is truly dead.
	if c, v, err := j.store.ReconcileStalePendingCheckouts(ctx, 25*time.Hour); err != nil {
		log.Printf("janitor: reconcile stale checkouts: %v", err)
	} else if c > 0 || v > 0 {
		log.Printf("janitor: reconciled stale checkouts (confirmed=%d voided=%d)", c, v)
	}
	if e, d, err := j.store.SweepEntitlements(ctx); err != nil {
		log.Printf("janitor: sweep entitlements: %v", err)
	} else if e > 0 || d > 0 {
		log.Printf("janitor: swept entitlements (expired=%d depleted=%d)", e, d)
	}
	if n, err := j.store.ReconcileSubscriptions(ctx, j.pendingAge); err != nil {
		log.Printf("janitor: reconcile subscriptions: %v", err)
	} else if n > 0 {
		log.Printf("janitor: expired abandoned subscription checkouts (%d)", n)
	}
}
