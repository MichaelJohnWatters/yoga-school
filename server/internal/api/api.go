package api

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	fbauth "firebase.google.com/go/v4/auth"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/studio52/yoga-school/server/internal/auth"
	"github.com/studio52/yoga-school/server/internal/store"
)

type Server struct {
	store    *store.Store
	fbClient *fbauth.Client
	// verify resolves a bearer token to a Firebase identity. Defaults to the
	// real Firebase Admin SDK path; tests swap in a stub to avoid needing
	// a live emulator + signed token.
	verify func(ctx context.Context, idToken string) (*auth.Verified, error)
}

func NewServer(s *store.Store, fb *fbauth.Client) *Server {
	srv := &Server{store: s, fbClient: fb}
	srv.verify = func(ctx context.Context, idToken string) (*auth.Verified, error) {
		return auth.Verify(ctx, srv.fbClient, idToken)
	}
	return srv
}

func (s *Server) Routes() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(cors)

	// Liveness + readiness in one — a deploy platform (Fly, k8s, ALB,
	// whatever) pings /healthz and gates traffic on a 2xx. We include a
	// trivial DB ping so "DB is unreachable" trips the health check too,
	// triggering a restart rather than letting the API serve 500s.
	// Unauthenticated by design: the prober isn't logging in.
	r.Get("/healthz", s.handleHealthz)

	// Dev-only test reset endpoint. Lets integration tests wipe
	// non-seed bookings/purchases/etc. between scenarios so each test
	// starts from a clean baseline without restarting the server. Gated
	// by the presence of FIREBASE_AUTH_EMULATOR_HOST — when we're talking
	// to the real Firebase, this route refuses with 404. Unauthenticated
	// on purpose: tests don't carry a token before they've signed in.
	r.Post("/dev/reset-test-state", s.handleDevResetTestState)
	// Companion to reset — fills a target class to capacity by booking
	// in eligible seed students. Used by the join-waitlist test to
	// guarantee the under-test student lands on a full class.
	r.Post("/dev/fill-class", s.handleDevFillClass)
	// Dev-only: point a studio at Stripe test keys so the checkout
	// integration test can create a real Checkout Session. Same emulator gate.
	r.Post("/dev/configure-stripe", s.handleDevConfigureStripe)
	r.Post("/dev/seed-membership", s.handleDevSeedMembership)

	// Stripe webhook — PUBLIC (no auth middleware): Stripe calls this
	// server-to-server, and the handler proves the request is genuine by
	// verifying the Stripe-Signature header against the studio's stored
	// webhook secret. Per-studio path so we know which secret to verify
	// against before parsing the body. This is the AUTHORITATIVE fulfilment
	// path: payment_intent.succeeded mints the pass even if the app never
	// returns to call /confirm.
	r.Post("/stripe/webhook/{studioID}", s.handleStripeWebhook)

	r.Route("/api/v1", func(r chi.Router) {
		r.Use(s.auth)
		// Staff routes — instructor + manager + owner. Read-only schedule
		// and roster views, attendance marking, check-in scan, and a few
		// lookups instructors need to teach.
		r.Group(func(r chi.Router) {
			r.Use(s.requireStaff)
			r.Get("/admin/classes", s.handleAdminClasses)
			r.Get("/admin/classes/{id}/roster", s.handleAdminRoster)
			r.Post("/admin/bookings/{id}/attendance", s.handleMarkAttendance)
			r.Post("/admin/classes/{id}/promote", s.handlePromoteWaitlist)
			r.Post("/admin/checkin/scan", s.handleAdminCheckinScan)
			r.Get("/admin/class-types", s.handleAdminListClassTypes)
			r.Get("/admin/instructors", s.handleAdminListInstructors)
			r.Get("/admin/rooms", s.handleAdminListRooms)
			r.Get("/admin/class-templates", s.handleAdminListClassTemplates)
			r.Get("/admin/enrollments", s.handleAdminListEnrollments)
			r.Get("/admin/enrollments/{id}/roster", s.handleAdminSeriesRoster)
			r.Get("/admin/students", s.handleAdminListStudents)
			r.Get("/admin/students/{id}", s.handleAdminGetStudent)
			// Student notes — staff-tier so instructors can read + write
			// context about students (injuries, preferences, etc).
			// Author-only edit/delete is enforced in the store.
			r.Get("/admin/students/{id}/notes", s.handleAdminListStudentNotes)
			r.Post("/admin/students/{id}/notes", s.handleAdminCreateStudentNote)
			r.Patch("/admin/notes/{id}", s.handleAdminUpdateStudentNote)
			r.Delete("/admin/notes/{id}", s.handleAdminDeleteStudentNote)
		})

		// Manager routes — manager + owner only. Money mutators, config,
		// taxonomy mutations, reports, dashboard (includes revenue),
		// audit log, staff CRUD, promotions. Instructors get 403 here.
		r.Group(func(r chi.Router) {
			r.Use(s.requireManager)
			r.Get("/admin/dashboard", s.handleAdminDashboard)
			r.Get("/admin/audit", s.handleAdminAudit)
			r.Get("/admin/reports", s.handleAdminReports)
			r.Get("/admin/reports/revenue", s.handleAdminReportRevenue)
			r.Get("/admin/reports/attendance", s.handleAdminReportAttendance)
			r.Get("/admin/reports/instructor-pay", s.handleAdminReportInstructorPay)
			r.Get("/admin/reports/customers", s.handleAdminReportCustomers)
			r.Get("/admin/reports/builder/schema", s.handleAdminBuilderSchema)
			r.Post("/admin/reports/builder/run", s.handleAdminBuilderRun)
			r.Get("/admin/themes", s.handleListThemes)
			r.Post("/admin/themes", s.handleCreateTheme)
			r.Patch("/admin/themes/{id}", s.handleUpdateTheme)
			r.Post("/admin/themes/{id}/activate", s.handleActivateTheme)
			// Media library — manager-uploaded images, reusable across the
			// app. Manager-only (this group); the role matrix enforces it.
			r.Get("/admin/media", s.handleListMedia)
			r.Post("/admin/media", s.handleUploadMedia)
			r.Delete("/admin/media/{id}", s.handleDeleteMedia)
			// Rooms management. Read sits on the staff group (above) so
			// instructors can see the list when teaching; create/rename/
			// delete are manager-only — same shape as themes.
			r.Post("/admin/rooms", s.handleAdminCreateRoom)
			r.Patch("/admin/rooms/{id}", s.handleAdminUpdateRoom)
			r.Delete("/admin/rooms/{id}", s.handleAdminDeleteRoom)
			r.Patch("/admin/studio/config", s.handleUpdateStudioConfig)
			r.Get("/admin/studio/stripe-credentials", s.handleGetStripeCredentials)
			r.Patch("/admin/studio/stripe-credentials", s.handleUpdateStripeCredentials)
			r.Get("/admin/products", s.handleAdminListProducts)
			r.Post("/admin/products", s.handleAdminCreateProduct)
			r.Patch("/admin/products/{id}", s.handleAdminUpdateProduct)
			r.Delete("/admin/products/{id}", s.handleAdminArchiveProduct)
			r.Post("/admin/class-types", s.handleAdminCreateClassType)
			r.Patch("/admin/class-types/{id}", s.handleAdminUpdateClassType)
			r.Post("/admin/classes", s.handleAdminCreateClass)
			r.Patch("/admin/classes/{id}", s.handleAdminUpdateClass)
			r.Delete("/admin/classes/{id}", s.handleAdminCancelClass)
			r.Post("/admin/class-templates", s.handleAdminCreateClassTemplate)
			r.Post("/admin/class-templates/{id}/undo", s.handleAdminUndoClassTemplate)
			r.Post("/admin/enrollments", s.handleAdminCreateSeries)
			r.Patch("/admin/enrollments/{id}", s.handleAdminUpdateEnrollment)
			r.Delete("/admin/enrollments/{id}", s.handleAdminArchiveEnrollment)
			r.Post("/admin/enrollments/{id}/enroll", s.handleAdminEnrollStudent)
			r.Post("/admin/students/{id}/grant", s.handleAdminGrantPass)
			r.Post("/admin/students/{id}/entitlements/{eid}/adjust",
				s.handleAdminAdjustCredits)
			r.Post("/admin/entitlements/{id}/void", s.handleAdminVoidEntitlement)
			// UK GDPR data-subject rights (manager-only — these surface or
			// destroy a person's full record, beyond an instructor's remit).
			r.Get("/admin/students/{id}/export", s.handleAdminExportStudent)
			r.Delete("/admin/students/{id}", s.handleAdminEraseStudent)
			r.Get("/admin/staff", s.handleAdminListStaff)
			r.Post("/admin/staff", s.handleAdminCreateStaff)
			r.Patch("/admin/staff/{id}", s.handleAdminUpdateStaff)
			r.Post("/admin/staff/{id}/deactivate", s.handleAdminDeactivateStaff)
			r.Post("/admin/staff/{id}/reactivate", s.handleAdminReactivateStaff)
			r.Get("/admin/promotions", s.handleAdminListPromotions)
			r.Post("/admin/promotions", s.handleAdminCreatePromotion)
			r.Patch("/admin/promotions/{id}", s.handleAdminUpdatePromotion)
			r.Delete("/admin/promotions/{id}", s.handleAdminArchivePromotion)
			r.Get("/admin/discounts", s.handleAdminListDiscounts)
			r.Post("/admin/discounts", s.handleAdminCreateDiscount)
			r.Patch("/admin/discounts/{id}", s.handleAdminUpdateDiscount)
			r.Delete("/admin/discounts/{id}", s.handleAdminArchiveDiscount)
			r.Post("/admin/purchases/{id}/refund", s.handleAdminRefundPurchase)
			r.Get("/admin/subscriptions", s.handleAdminListSubscriptions)
			r.Post("/admin/subscriptions/{id}/cancel", s.handleAdminCancelSubscription)
			r.Post("/admin/subscriptions/{id}/refund", s.handleAdminRefundSubscription)
			r.Post("/admin/subscriptions/{id}/resume", s.handleAdminResumeSubscription)
			// Stripe Terminal — in-person card payments at the front desk.
			r.Get("/admin/terminal/readers", s.handleAdminListTerminalReaders)
			r.Post("/admin/terminal/readers", s.handleAdminRegisterTerminalReader)
			r.Delete("/admin/terminal/readers/{id}", s.handleAdminRemoveTerminalReader)
			r.Post("/admin/terminal/charge", s.handleAdminTerminalCharge)
			r.Post("/admin/terminal/cancel", s.handleAdminTerminalCancel)
			// Chargebacks + past-due memberships needing a manager decision.
			r.Get("/admin/payments/attention", s.handleAdminPaymentsAttention)
			// Manager-initiated bookings: add a student to a class on
			// their behalf, or remove an existing booking with an
			// explicit refund / consume choice.
			r.Post("/admin/classes/{id}/bookings", s.handleAdminCreateBooking)
			r.Get("/admin/classes/{id}/eligible-entitlements",
				s.handleAdminEligibleEntitlements)
			r.Post("/admin/bookings/{id}/cancel", s.handleAdminCancelBooking)
		})
		r.Get("/me", s.handleMe)
		r.Get("/studio/config", s.handleStudioConfig)
		r.Get("/classes", s.handleListClasses)
		r.Get("/classes/{id}", s.handleClassDetail)
		r.Get("/classes/{id}/eligible-entitlements", s.handleEligibleEntitlements)
		r.Get("/enrollments", s.handleListEnrollments)
		r.Get("/enrollments/{id}", s.handleEnrollmentDetail)
		r.Post("/enrollments/{id}/join", s.handleJoinEnrollment)
		r.Get("/bookings", s.handleListBookings)
		r.Post("/bookings", s.handleCreateBooking)
		// Add a +1 to a class the caller is already booked on (the
		// "add a friend after the fact" flow). Charged to the parent
		// booking's entitlement — see AddPlusOneToBooking.
		r.Post("/classes/{id}/plus-one", s.handleAddPlusOne)
		r.Get("/bookings/preview", s.handleBookingPreview)
		r.Delete("/bookings/{id}", s.handleCancelBooking)
		r.Get("/bookings/{id}/cancel-preview", s.handleCancelPreview)
		r.Get("/products", s.handleListProducts)
		r.Get("/products/{id}", s.handleProductDetail)
		r.Post("/purchases", s.handleCreatePurchase)
		r.Post("/purchases/{id}/confirm", s.handleConfirmPurchase)
		r.Get("/purchases", s.handleListPurchases)
		// Mobile saved-cards: mints an ephemeral key scoped to the buyer's
		// Stripe Customer so the PaymentSheet can list/save their cards.
		r.Post("/payments/stripe-ephemeral-key", s.handleStripeEphemeralKey)
		// Saved-card management (the wallet's Payment methods).
		r.Get("/payments/methods", s.handleListPaymentMethods)
		r.Delete("/payments/methods/{id}", s.handleDetachPaymentMethod)
		r.Post("/payments/setup-intent", s.handleCreateSetupIntent)     // native
		r.Post("/payments/setup-checkout", s.handleCreateSetupCheckout) // web
		// Web payment surface: creates a hosted Stripe Checkout Session and
		// returns the URL the browser redirects to. Fulfilment lands via the
		// checkout.session.completed webhook.
		r.Post("/checkout/session", s.handleCreateCheckoutSession)
		// Web optimistic confirm: the success page calls this with the
		// returned session id to mint the pass without waiting on the webhook.
		r.Post("/checkout/session/confirm", s.handleConfirmCheckoutSession)
		// Membership (recurring subscription) surface: a hosted Checkout in
		// subscription mode + self-serve manage/cancel/resume. Fulfilment lands
		// via the invoice.paid / customer.subscription.* webhooks.
		r.Post("/checkout/subscription", s.handleCreateCheckoutSubscription)
		r.Get("/me/subscriptions", s.handleMySubscriptions)
		r.Post("/me/subscriptions/{id}/cancel", s.handleCancelMySubscription)
		r.Post("/me/subscriptions/{id}/resume", s.handleResumeMySubscription)
		r.Post("/me/billing-portal", s.handleBillingPortal)
		// Non-secret Stripe config the client needs to render the
		// PaymentSheet (publishable key, wallet toggles, merchant display).
		r.Get("/studio/payment-config", s.handlePaymentConfig)
		r.Get("/me/entitlements", s.handleMyEntitlements)
		r.Get("/me/attendance", s.handleMyAttendance)
		r.Get("/me/checkin-code", s.handleCheckInCode)
		r.Get("/me/achievements", s.handleMyAchievements)
		r.Get("/me/notifications", s.handleGetNotificationPrefs)
		r.Patch("/me/notifications", s.handleUpdateNotificationPrefs)
		r.Patch("/me/prefs", s.handleUpdateMyPrefs)
		r.Post("/me/devices", s.handleRegisterDevice)
		r.Get("/me/notifications/feed", s.handleNotificationsFeed)
		r.Post("/me/notifications/{id}/read", s.handleMarkNotificationRead)
		r.Post("/me/notifications/read-all", s.handleMarkAllNotificationsRead)
		r.Post("/me/notifications/clear-read", s.handleClearReadNotifications)
		r.Delete("/me/notifications/{id}", s.handleDeleteNotification)
		r.Post("/classes/{id}/waitlist", s.handleJoinWaitlist)
		r.Delete("/classes/{id}/waitlist", s.handleLeaveWaitlist)
		r.Get("/promotions", s.handleListPromotions)

		// Chat. Reading + posting + managing your own messages is open to
		// any authenticated member — the conversation_members ACL (enforced
		// in the store) is the real gate, not the role. Starting a new
		// conversation (group or dm) is staff-only: students never initiate.
		r.Get("/conversations", s.handleListConversations)
		r.Get("/conversations/{id}/messages", s.handleListMessages)
		r.Post("/conversations/{id}/messages", s.handleSendMessage)
		r.Patch("/conversations/{id}/messages/{mid}", s.handleEditMessage)
		r.Delete("/conversations/{id}/messages/{mid}", s.handleDeleteMessage)
		r.Post("/conversations/{id}/read", s.handleMarkConversationRead)
		// Class group chat. Open (or lazy-create) the chat for a class —
		// students reach it from the class detail / their booking; staff
		// from the class detail or the roster. Eligibility (booked /
		// waitlisted / instructor / staff) is enforced in the store.
		r.Post("/classes/{id}/chat", s.handleOpenClassChat)
		r.Group(func(r chi.Router) {
			r.Use(s.requireStaff)
			r.Post("/conversations", s.handleCreateConversation)
			r.Post("/conversations/{id}/members", s.handleAddConversationMembers)
		})
	})

	return r
}

// ---- auth ---------------------------------------------------------
//
// Verifies a Firebase ID token from `Authorization: Bearer <token>`, then
// resolves the internal user by email. Dev uses the Firebase Auth emulator
// (FIREBASE_AUTH_EMULATOR_HOST=localhost:9099); the SDK transparently uses
// it when that var is set.

type ctxKey int

const ctxUser ctxKey = 1

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(raw, prefix) {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		token := strings.TrimSpace(raw[len(prefix):])

		v, err := s.verify(r.Context(), token)
		if errors.Is(err, auth.ErrInvalidToken) {
			writeError(w, http.StatusUnauthorized, "invalid id token")
			return
		}
		if err != nil {
			log.Printf("verify: %v", err)
			writeError(w, http.StatusInternalServerError, "auth error")
			return
		}
		if v.Email == "" {
			writeError(w, http.StatusUnauthorized, "token has no email claim")
			return
		}

		u, err := s.store.UserByEmail(r.Context(), v.Email)
		if errors.Is(err, store.ErrNotFound) {
			// First sign-in for a Firebase identity we haven't seen before:
			// auto-create the student row in the (single) studio. Matches the
			// spec's Splash "onboarding" flow.
			u, err = s.store.ProvisionStudentFromFirebase(
				r.Context(), v.UID, v.Email, v.FullName, v.PhotoURL,
			)
			if errors.Is(err, store.ErrMultipleStudios) {
				writeError(w, http.StatusUnauthorized,
					"cannot auto-provision: multiple studios — please use your studio's invite link")
				return
			}
			if err != nil {
				log.Printf("provision: %v", err)
				writeError(w, http.StatusInternalServerError, "auth error")
				return
			}
		} else if err != nil {
			log.Printf("user lookup: %v", err)
			writeError(w, http.StatusInternalServerError, "auth error")
			return
		} else {
			// Existing row: best-effort backfill of firebase_uid for users
			// that were pre-seeded without one (or whose UID rotated, e.g.
			// emulator restarts in dev). Failure isn't fatal — the next
			// request just retries.
			if err := s.store.LinkFirebaseUID(r.Context(), u.ID, v.UID); err != nil {
				log.Printf("link firebase_uid: %v", err)
			}
		}
		// A deactivated staff member (manager turned them off) can't sign in.
		if u.Deactivated {
			writeError(w, http.StatusForbidden, "account deactivated — contact your studio")
			return
		}
		ctx := context.WithValue(r.Context(), ctxUser, u)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func userFrom(r *http.Request) *store.User {
	u, _ := r.Context().Value(ctxUser).(*store.User)
	return u
}

// requireManager gates manager-only routes — callers must have role manager
// or owner. Layered after s.auth so the caller is already resolved.
// Used for: money mutators, configuration, taxonomy mutations, reports,
// dashboard (until revenue is redacted), audit log, staff CRUD, promotions.
func (s *Server) requireManager(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r)
		if u == nil || (u.Role != "manager" && u.Role != "owner") {
			writeError(w, http.StatusForbidden, "manager access required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// requireStaff gates routes that any non-student staff member needs to do
// their job — instructors included. Read-only schedule/roster views,
// attendance marking, check-in scan, and a few lookups. Same audit log
// applies; only the gate is looser.
func (s *Server) requireStaff(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r)
		if u == nil || u.Role == "student" {
			writeError(w, http.StatusForbidden, "staff access required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- handlers ------------------------------------------------------------

// meResponse extends the stored user with a derived `tier` so the client
// doesn't need to map roles → access tiers itself. Single source of truth
// for "what can this caller reach" lives in the same place as the route
// gates (s.requireStaff / s.requireManager).
type meResponse struct {
	*store.User
	Tier string `json:"tier"`
}

// tierForRole mirrors the gate policy in requireStaff / requireManager.
// Update this together with those middlewares.
func tierForRole(role string) string {
	switch role {
	case "manager", "owner":
		return "manager"
	case "instructor":
		return "staff"
	default:
		return "student"
	}
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	writeJSON(w, http.StatusOK, meResponse{User: u, Tier: tierForRole(u.Role)})
}

func (s *Server) handleStudioConfig(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	cfg, err := s.store.StudioConfig(r.Context(), u.StudioID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "studio not found")
		return
	}
	if err != nil {
		log.Printf("studio config: %v", err)
		writeError(w, http.StatusInternalServerError, "studio config error")
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

// GET /classes — accepts ?date=YYYY-MM-DD (single day) or ?from=&to= (range,
// to is exclusive). Returns scheduled classes with per-caller booking state.
func (s *Server) handleListClasses(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	q := r.URL.Query()
	dateStr := q.Get("date")
	fromStr := q.Get("from")
	toStr := q.Get("to")

	// All date params arrive as YYYY-MM-DD without a timezone. Parse them
	// in the studio's TZ so "from=2026-06-15" means Sydney's June 15
	// boundary for a Sydney studio, not UTC's.
	loc := s.store.StudioLocation(r.Context(), u.StudioID)
	var (
		rows []store.ClassRow
		err  error
	)
	switch {
	case dateStr != "":
		day, perr := time.ParseInLocation("2006-01-02", dateStr, loc)
		if perr != nil {
			writeError(w, http.StatusBadRequest, "date must be YYYY-MM-DD")
			return
		}
		rows, err = s.store.ClassesForDay(r.Context(), u.StudioID, u.ID, day)
	case fromStr != "" && toStr != "":
		from, errA := time.ParseInLocation("2006-01-02", fromStr, loc)
		to, errB := time.ParseInLocation("2006-01-02", toStr, loc)
		if errA != nil || errB != nil {
			writeError(w, http.StatusBadRequest, "from + to must be YYYY-MM-DD")
			return
		}
		rows, err = s.store.ClassesInRange(r.Context(), u.StudioID, u.ID, from, to)
	default:
		writeError(w, http.StatusBadRequest, "date or from+to query params required")
		return
	}

	if err != nil {
		log.Printf("list classes: %v", err)
		writeError(w, http.StatusInternalServerError, "list classes error")
		return
	}
	if rows == nil {
		rows = []store.ClassRow{}
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleListEnrollments(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListEnrollments(r.Context(), u.StudioID, u.ID, false)
	if err != nil {
		log.Printf("list enrollments: %v", err)
		writeError(w, http.StatusInternalServerError, "enrollments error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleEnrollmentDetail(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	det, err := s.store.GetEnrollmentDetail(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "enrollment not found")
		return
	}
	if err != nil {
		log.Printf("enrollment detail: %v", err)
		writeError(w, http.StatusInternalServerError, "enrollment error")
		return
	}
	writeJSON(w, http.StatusOK, det)
}

type joinEnrollmentReq struct {
	PaymentMethod string `json:"payment_method"`
	DiscountCode  string `json:"discount_code,omitempty"`
}

func (s *Server) handleJoinEnrollment(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var req joinEnrollmentReq
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.PaymentMethod == "" {
		req.PaymentMethod = "dev_stub"
	}
	if !paymentMethodAllowed(req.PaymentMethod) {
		writeError(w, http.StatusForbidden, "card payment required")
		return
	}
	bookingID, err := s.store.JoinEnrollment(r.Context(), u.StudioID, u.ID, id, req.PaymentMethod, req.DiscountCode)
	if err != nil {
		respondErr(w, err, "joinEnrollment")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{
		"enrollment_booking_id": bookingID,
	})
}

// GET /classes/{id}/eligible-entitlements
func (s *Server) handleEligibleEntitlements(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	rows, err := s.store.EligibleEntitlements(r.Context(), u.StudioID, u.ID, classID)
	if err != nil {
		log.Printf("eligible entitlements: %v", err)
		writeError(w, http.StatusInternalServerError, "eligibility error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// GET /bookings?scope=upcoming|past
func (s *Server) handleListBookings(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "upcoming"
	}
	var (
		rows []store.UpcomingBooking
		err  error
	)
	switch scope {
	case "upcoming":
		rows, err = s.store.UpcomingBookings(r.Context(), u.ID)
	case "past":
		rows, err = s.store.PastBookings(r.Context(), u.ID)
	default:
		writeError(w, http.StatusBadRequest, "scope must be upcoming or past")
		return
	}
	if err != nil {
		log.Printf("list bookings: %v", err)
		writeError(w, http.StatusInternalServerError, "list bookings error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type createBookingReq struct {
	ClassID       string `json:"class_id"`
	EntitlementID string `json:"entitlement_id"`
	PlusOne       bool   `json:"plus_one"`
	PlusOneName   string `json:"plus_one_name"`
}

func (s *Server) handleCreateBooking(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req createBookingReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ClassID == "" || req.EntitlementID == "" {
		writeError(w, http.StatusBadRequest, "class_id and entitlement_id are required")
		return
	}
	id, err := s.store.CreateBooking(r.Context(), u.StudioID, u.ID, req.ClassID, req.EntitlementID, req.PlusOne, req.PlusOneName)
	if err != nil {
		respondErr(w, err, "createBooking")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

type addPlusOneReq struct {
	EntitlementID string `json:"entitlement_id"`
	PlusOneName   string `json:"plus_one_name"`
}

func (s *Server) handleAddPlusOne(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	var req addPlusOneReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.AddPlusOneToBooking(
		r.Context(), u.StudioID, u.ID, classID, req.EntitlementID, req.PlusOneName,
	)
	if err != nil {
		respondErr(w, err, "addPlusOne")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleCancelBooking(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.CancelBooking(r.Context(), u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "booking not found or already cancelled")
		return
	}
	if errors.Is(err, store.ErrClassStarted) {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": "Class has already started",
			"code":  "class_already_started",
		})
		return
	}
	if err != nil {
		log.Printf("cancel booking: %v", err)
		writeError(w, http.StatusInternalServerError, "cancel error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCancelPreview(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.CancelPreview(r.Context(), u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "booking not found or already cancelled")
		return
	}
	if err != nil {
		log.Printf("cancel preview: %v", err)
		writeError(w, http.StatusInternalServerError, "cancel preview error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleBookingPreview(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := strings.TrimSpace(r.URL.Query().Get("class_id"))
	entitlementID := strings.TrimSpace(r.URL.Query().Get("entitlement_id"))
	if classID == "" || entitlementID == "" {
		writeError(w, http.StatusBadRequest, "class_id and entitlement_id are required")
		return
	}
	out, err := s.store.BookingPreview(r.Context(), u.StudioID, u.ID, classID, entitlementID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		log.Printf("booking preview: %v", err)
		writeError(w, http.StatusInternalServerError, "booking preview error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleClassDetail(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.GetClass(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		log.Printf("class detail: %v", err)
		writeError(w, http.StatusInternalServerError, "class detail error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleProductDetail(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.GetProduct(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		log.Printf("product detail: %v", err)
		writeError(w, http.StatusInternalServerError, "product detail error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

type checkoutSessionReq struct {
	ProductID    string `json:"product_id"`
	EnrollmentID string `json:"enrollment_id"` // set to pay for a series
	DiscountCode string `json:"discount_code"`
	SuccessURL   string `json:"success_url"`
	CancelURL    string `json:"cancel_url"`
}

// handleCreateCheckoutSession creates a hosted Stripe Checkout Session for the
// web flow and returns its URL + the pending purchase id. The client supplies
// its own success/cancel return URLs (the app knows where to land the user).
func (s *Server) handleCreateCheckoutSession(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req checkoutSessionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.SuccessURL == "" || req.CancelURL == "" {
		writeError(w, http.StatusBadRequest, "success_url and cancel_url are required")
		return
	}
	// A series purchase sends enrollment_id; resolve it to the series' product
	// (and validate capacity / not-already-enrolled) before charging.
	productID := req.ProductID
	if req.EnrollmentID != "" {
		pid, err := s.store.EnrollmentProductForCheckout(r.Context(), u.StudioID, u.ID, req.EnrollmentID)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "series not found")
			return
		}
		if errors.Is(err, store.ErrAlreadyEnrolled) || errors.Is(err, store.ErrSeriesFull) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		if err != nil {
			respondErr(w, err, "enrollmentCheckout")
			return
		}
		productID = pid
	}
	if productID == "" {
		writeError(w, http.StatusBadRequest, "product_id or enrollment_id is required")
		return
	}
	out, err := s.store.CreateCheckoutPurchase(
		r.Context(), u.StudioID, u.ID, productID, req.DiscountCode,
		req.SuccessURL, req.CancelURL, req.EnrollmentID,
	)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "createCheckoutSession")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

type subscriptionCheckoutReq struct {
	ProductID  string `json:"product_id"`
	SuccessURL string `json:"success_url"`
	CancelURL  string `json:"cancel_url"`
}

// handleCreateCheckoutSubscription starts a membership: it creates a hosted
// Stripe Checkout Session in subscription mode and returns its URL + our
// subscription id. The webhook (invoice.paid) grants the rolling pass.
func (s *Server) handleCreateCheckoutSubscription(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req subscriptionCheckoutReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ProductID == "" {
		writeError(w, http.StatusBadRequest, "product_id is required")
		return
	}
	if req.SuccessURL == "" || req.CancelURL == "" {
		writeError(w, http.StatusBadRequest, "success_url and cancel_url are required")
		return
	}
	out, err := s.store.CreateCheckoutSubscription(
		r.Context(), u.StudioID, u.ID, req.ProductID, req.SuccessURL, req.CancelURL)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "createCheckoutSubscription")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleMySubscriptions(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListMySubscriptions(r.Context(), u.StudioID, u.ID)
	if err != nil {
		log.Printf("my subscriptions: %v", err)
		writeError(w, http.StatusInternalServerError, "subscriptions error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleCancelMySubscription(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.CancelMySubscription(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "subscription not found")
		return
	}
	if err != nil {
		respondErr(w, err, "cancelSubscription")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleResumeMySubscription(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ResumeMySubscription(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "subscription not found")
		return
	}
	if err != nil {
		respondErr(w, err, "resumeSubscription")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type billingPortalReq struct {
	ReturnURL string `json:"return_url"`
}

func (s *Server) handleBillingPortal(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req billingPortalReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ReturnURL == "" {
		writeError(w, http.StatusBadRequest, "return_url is required")
		return
	}
	url, err := s.store.BillingPortalURL(r.Context(), u.StudioID, u.ID, req.ReturnURL)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "no billing account yet")
		return
	}
	if err != nil {
		respondErr(w, err, "billingPortal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"url": url})
}

type confirmCheckoutSessionReq struct {
	SessionID string `json:"session_id"`
}

// handleConfirmCheckoutSession is the web success page's optimistic confirm. It
// returns one of three states so the client knows what to do:
//   - {status:"completed", entitlement:…} — pass minted (book it / show it).
//   - {status:"pending"}                  — paid not settled yet; keep polling.
//   - {status:"unknown"}                  — no matching pending purchase (the
//     webhook likely already handled it); the client falls back to its poll.
func (s *Server) handleConfirmCheckoutSession(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req confirmCheckoutSessionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.SessionID == "" {
		writeError(w, http.StatusBadRequest, "session_id is required")
		return
	}
	entitlementID, completed, err := s.store.ConfirmCheckoutSessionForUser(
		r.Context(), u.StudioID, u.ID, req.SessionID)
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "unknown"})
		return
	}
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "confirmCheckoutSession")
		return
	}
	if !completed {
		writeJSON(w, http.StatusOK, map[string]any{"status": "pending"})
		return
	}
	ent, err := s.store.GetEntitlement(r.Context(), entitlementID)
	if err != nil {
		log.Printf("get entitlement after checkout confirm: %v", err)
		writeError(w, http.StatusInternalServerError, "confirm succeeded but entitlement load failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "completed", "entitlement": ent})
}

// handlePaymentConfig returns the studio's non-secret Stripe config so the
// client can initialise the PaymentSheet. Authed (any signed-in user) but
// carries nothing sensitive — the secret key + webhook secret never leave the
// server (that's what the admin-only credentials endpoint guards).
func (s *Server) handlePaymentConfig(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	cfg, err := s.store.PaymentConfigFor(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("payment config: %v", err)
		writeError(w, http.StatusInternalServerError, "payment config error")
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

func (s *Server) handleListProducts(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	// Optional class-type filter so the "buy a pass for this class" picker
	// shows only passes that cover it. Empty = list everything.
	coversClassType := r.URL.Query().Get("covers_class_type")
	rows, err := s.store.ListProducts(r.Context(), u.StudioID, coversClassType)
	if err != nil {
		log.Printf("list products: %v", err)
		writeError(w, http.StatusInternalServerError, "list products error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type createPurchaseReq struct {
	ProductID     string `json:"product_id"`
	EnrollmentID  string `json:"enrollment_id"` // set to pay for a series (card path)
	PaymentMethod string `json:"payment_method"` // 'card' | 'cash' | 'dev_stub'
	// Optional. When set, server validates + applies the discount in the
	// same tx as the purchase insert and stores discount_minor + discount_id
	// on the resulting row.
	DiscountCode string `json:"discount_code,omitempty"`
}

func (s *Server) handleListPurchases(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "mine"
	}
	if scope != "mine" {
		writeError(w, http.StatusBadRequest, "only scope=mine supported yet")
		return
	}
	rows, err := s.store.MyPurchases(r.Context(), u.ID)
	if err != nil {
		log.Printf("my purchases: %v", err)
		writeError(w, http.StatusInternalServerError, "purchases error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleMyEntitlements(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.MyEntitlements(r.Context(), u.ID)
	if err != nil {
		log.Printf("my entitlements: %v", err)
		writeError(w, http.StatusInternalServerError, "entitlements error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleMyAttendance(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.MyAttendance(r.Context(), u.ID)
	if err != nil {
		log.Printf("my attendance: %v", err)
		writeError(w, http.StatusInternalServerError, "attendance error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleCheckInCode(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.CheckInCode(r.Context(), u.ID)
	if err != nil {
		log.Printf("checkin code: %v", err)
		writeError(w, http.StatusInternalServerError, "checkin code error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleGetNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.MyNotificationPrefs(r.Context(), u.ID)
	if err != nil {
		log.Printf("notification prefs: %v", err)
		writeError(w, http.StatusInternalServerError, "prefs error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleUpdateNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var p store.NotificationPrefsPatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.UpdateNotificationPrefs(r.Context(), u.ID, p)
	if err != nil {
		log.Printf("update notification prefs: %v", err)
		writeError(w, http.StatusInternalServerError, "prefs error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleMyAchievements(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.MyAchievements(r.Context(), u.ID)
	if err != nil {
		log.Printf("achievements: %v", err)
		writeError(w, http.StatusInternalServerError, "achievements error")
		return
	}
	// Always return an array (never null) so the Flutter side can render
	// the strip without a nil-guard.
	if out == nil {
		out = []store.Achievement{}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.RegisterDeviceInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if err := s.store.RegisterDevice(r.Context(), u.ID, in); err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleNotificationsFeed(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.NotificationsFeed(r.Context(), u.ID)
	if err != nil {
		log.Printf("notifications: %v", err)
		writeError(w, http.StatusInternalServerError, "notifications error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleMarkNotificationRead(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.MarkNotificationRead(r.Context(), u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "notification not found")
		return
	}
	if err != nil {
		log.Printf("mark read: %v", err)
		writeError(w, http.StatusInternalServerError, "mark read error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMarkAllNotificationsRead(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	n, err := s.store.MarkAllNotificationsRead(r.Context(), u.ID)
	if err != nil {
		log.Printf("mark all read: %v", err)
		writeError(w, http.StatusInternalServerError, "mark all read error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"marked": n})
}

func (s *Server) handleDeleteNotification(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.DeleteNotification(r.Context(), u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "notification not found")
		return
	}
	if err != nil {
		log.Printf("delete notification: %v", err)
		writeError(w, http.StatusInternalServerError, "delete notification error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleClearReadNotifications(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	n, err := s.store.ClearReadNotifications(r.Context(), u.ID)
	if err != nil {
		log.Printf("clear read notifications: %v", err)
		writeError(w, http.StatusInternalServerError, "clear read error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"cleared": n})
}

func (s *Server) handleAdminDashboard(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.AdminDashboardFor(r.Context(), u.StudioID, u.ID)
	if err != nil {
		log.Printf("admin dashboard: %v", err)
		writeError(w, http.StatusInternalServerError, "dashboard error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminClasses(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	fromStr := r.URL.Query().Get("from")
	toStr := r.URL.Query().Get("to")
	if fromStr == "" || toStr == "" {
		writeError(w, http.StatusBadRequest, "from + to query params required (YYYY-MM-DD)")
		return
	}
	loc := s.store.StudioLocation(r.Context(), u.StudioID)
	from, errA := time.ParseInLocation("2006-01-02", fromStr, loc)
	to, errB := time.ParseInLocation("2006-01-02", toStr, loc)
	if errA != nil || errB != nil {
		writeError(w, http.StatusBadRequest, "dates must be YYYY-MM-DD")
		return
	}
	rows, err := s.store.AdminClassesFor(r.Context(), u.StudioID, from, to)
	if err != nil {
		log.Printf("admin classes: %v", err)
		writeError(w, http.StatusInternalServerError, "admin classes error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminRoster(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	out, err := s.store.RosterFor(r.Context(), u.StudioID, classID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		log.Printf("roster: %v", err)
		writeError(w, http.StatusInternalServerError, "roster error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

type markAttendanceReq struct {
	Status string `json:"status"` // present | no_show | booked (undo)
	Via    string `json:"via"`    // manual | scan
}

func (s *Server) handleMarkAttendance(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	bookingID := chi.URLParam(r, "id")
	var req markAttendanceReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	// Translate "present" → "attended" for the DB.
	status := req.Status
	if status == "present" {
		status = "attended"
	}
	via := req.Via
	if via == "" {
		via = "manual"
	}
	err := s.store.MarkAttendance(r.Context(), u.ID, bookingID, status, via)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "booking not found")
		return
	}
	if err != nil {
		log.Printf("mark attendance: %v", err)
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePromoteWaitlist(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	out, err := s.store.PromoteWaitlist(r.Context(), u.StudioID, u.ID, classID)
	if err != nil {
		respondErr(w, err, "promoteWaitlist")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// adminBookingReq is the POST /admin/classes/{id}/bookings body.
// entitlement_id is required — manager picks from the student's
// eligible passes via GET …/eligible-entitlements?user_id=… first.
type adminBookingReq struct {
	UserID        string `json:"user_id"`
	EntitlementID string `json:"entitlement_id"`
	PlusOne       bool   `json:"plus_one,omitempty"`
	PlusOneName   string `json:"plus_one_name,omitempty"`
}

func (s *Server) handleAdminCreateBooking(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	var req adminBookingReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.UserID == "" || req.EntitlementID == "" {
		writeError(w, http.StatusBadRequest, "user_id and entitlement_id are required")
		return
	}
	out, err := s.store.CreateAdminBooking(r.Context(), u.StudioID, u.ID, classID,
		req.UserID, req.EntitlementID, req.PlusOne, req.PlusOneName)
	if err != nil {
		respondErr(w, err, "createAdminBooking")
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

// handleAdminEligibleEntitlements lists a target student's active passes
// that cover the class. Mirrors the student-self endpoint at
// GET /classes/{id}/eligible-entitlements but takes user_id as a query
// param so the manager picker can show the right list per student.
func (s *Server) handleAdminEligibleEntitlements(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	userID := r.URL.Query().Get("user_id")
	if userID == "" {
		writeError(w, http.StatusBadRequest, "user_id query param is required")
		return
	}
	rows, err := s.store.EligibleEntitlements(r.Context(), u.StudioID, userID, classID)
	if err != nil {
		log.Printf("admin eligible entitlements: %v", err)
		writeError(w, http.StatusInternalServerError, "eligibility error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// adminCancelBookingReq is the POST /admin/bookings/{id}/cancel body.
// refund_credit defaults to true — the explicit field is so the manager
// can flip to false (e.g. courtesy cancel for a no-show) without
// changing the route.
type adminCancelBookingReq struct {
	RefundCredit *bool  `json:"refund_credit,omitempty"`
	Reason       string `json:"reason,omitempty"`
}

func (s *Server) handleAdminCancelBooking(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	bookingID := chi.URLParam(r, "id")
	var req adminCancelBookingReq
	// Empty body is allowed — defaults to refund=true.
	if r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid json body")
			return
		}
	}
	refund := true
	if req.RefundCredit != nil {
		refund = *req.RefundCredit
	}
	out, err := s.store.CancelAdminBooking(r.Context(), u.StudioID, u.ID,
		bookingID, refund, req.Reason)
	if err != nil {
		respondErr(w, err, "cancelAdminBooking")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleListThemes(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListThemes(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("list themes: %v", err)
		writeError(w, http.StatusInternalServerError, "list themes error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleListMedia(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListMedia(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("list media: %v", err)
		writeError(w, http.StatusInternalServerError, "list media error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleUploadMedia(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	// Bound the in-memory parse to the store's ceiling plus a little slack for
	// multipart framing. Anything larger is rejected before we buffer it.
	if err := r.ParseMultipartForm(store.MaxMediaBytes + 1<<20); err != nil {
		writeError(w, http.StatusBadRequest, "invalid multipart form")
		return
	}
	file, hdr, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing 'file' field")
		return
	}
	defer file.Close()
	// LimitReader one past the cap so an oversized file reads as cap+1 and the
	// store's size check rejects it cleanly.
	data, err := io.ReadAll(io.LimitReader(file, store.MaxMediaBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read upload")
		return
	}
	mime := hdr.Header.Get("Content-Type")
	if mime == "" || mime == "application/octet-stream" {
		mime = http.DetectContentType(data)
	}

	row, err := s.store.UploadMedia(r.Context(), u.StudioID, u.ID, hdr.Filename, mime, data)
	if errors.Is(err, store.ErrMediaStorageUnavailable) {
		writeError(w, http.StatusServiceUnavailable, "image storage isn't set up for this studio")
		return
	}
	var rejected store.MediaRejected
	if errors.As(err, &rejected) {
		writeError(w, http.StatusBadRequest, rejected.Msg)
		return
	}
	if err != nil {
		log.Printf("upload media: %v", err)
		writeError(w, http.StatusInternalServerError, "upload failed")
		return
	}
	writeJSON(w, http.StatusCreated, row)
}

func (s *Server) handleDeleteMedia(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.DeleteMedia(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		log.Printf("delete media: %v", err)
		writeError(w, http.StatusInternalServerError, "delete media error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// writeContrastError shapes a ContrastError into the structured 400 the
// Flutter theme editor needs to highlight the failing colour pair inline.
func writeContrastError(w http.ResponseWriter, err error) bool {
	var ce *store.ContrastError
	if !errors.As(err, &ce) {
		return false
	}
	writeJSON(w, http.StatusBadRequest, map[string]any{
		"code":          "contrast_too_low",
		"error":         ce.Error(),
		"pair":          ce.Pair,
		"ratio":         ce.Ratio,
		"minimum_ratio": ce.Wanted,
	})
	return true
}

func (s *Server) handleCreateTheme(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.ThemeInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	id, err := s.store.CreateTheme(r.Context(), u.StudioID, u.ID, in)
	if writeContrastError(w, err) {
		return
	}
	if err != nil {
		log.Printf("create theme: %v", err)
		writeError(w, http.StatusInternalServerError, "create theme error")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleUpdateTheme(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	themeID := chi.URLParam(r, "id")
	var p store.ThemePatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateTheme(r.Context(), u.StudioID, u.ID, themeID, p)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "theme not found")
		return
	}
	if writeContrastError(w, err) {
		return
	}
	if err != nil {
		log.Printf("update theme: %v", err)
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleActivateTheme(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	themeID := chi.URLParam(r, "id")
	// Slot comes from a query param so the existing route shape is
	// preserved. Empty / unrecognised → "light" for back-compat with the
	// pre-dark-slot client.
	slot := r.URL.Query().Get("slot")
	if slot == "" {
		slot = "light"
	}
	err := s.store.ActivateThemeAs(r.Context(), u.StudioID, u.ID, themeID, slot)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "theme not found")
		return
	}
	if errors.Is(err, store.ErrThemeModeMismatch) {
		writeErrorCode(w, http.StatusBadRequest, "theme_mode_mismatch",
			"This theme's mode doesn't match the slot — light themes go in the light slot and dark in the dark slot.")
		return
	}
	if err != nil {
		log.Printf("activate theme: %v", err)
		writeError(w, http.StatusInternalServerError, "activate error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleUpdateMyPrefs is the catch-all PATCH for non-notification user
// prefs. Right now: theme_mode_pref. Add fields as they appear instead of
// minting a separate route per pref.
func (s *Server) handleUpdateMyPrefs(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var body struct {
		ThemeModePref *string `json:"theme_mode_pref"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if body.ThemeModePref != nil {
		if err := s.store.UpdateUserThemeMode(r.Context(), u.ID, *body.ThemeModePref); err != nil {
			respondValidation(w, err)
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleUpdateStudioConfig(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var p store.StudioConfigPatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateStudioConfig(r.Context(), u.StudioID, u.ID, p)
	if err != nil {
		log.Printf("update studio config: %v", err)
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetStripeCredentials(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.StripeCredentialsFor(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("get stripe creds: %v", err)
		writeError(w, http.StatusInternalServerError, "stripe credentials error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleUpdateStripeCredentials(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var p store.StripeCredentialsPatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.UpdateStripeCredentials(r.Context(), u.StudioID, u.ID, p)
	if err != nil {
		// Mostly user-facing validation errors ("mode must be test|live",
		// "encryption not configured"). Surface verbatim.
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListProducts(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminProducts(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin products: %v", err)
		writeError(w, http.StatusInternalServerError, "products error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateProduct(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.AdminProductInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateAdminProduct(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateProduct(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.AdminProductInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateAdminProduct(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminArchiveProduct(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ArchiveProduct(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		log.Printf("archive product: %v", err)
		writeError(w, http.StatusInternalServerError, "archive error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type studentsListResponse struct {
	Students []store.StudentSummary `json:"students"`
	Counts   struct {
		Total      int `json:"total"`
		ActivePass int `json:"active_pass"`
	} `json:"counts"`
}

func (s *Server) handleAdminListClassTemplates(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListClassTemplates(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("class templates: %v", err)
		writeError(w, http.StatusInternalServerError, "templates error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateClassTemplate(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.ClassTemplateInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.CreateClassTemplateWithAudit(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleAdminUndoClassTemplate(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.UndoClassTemplateWithAudit(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "template not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListInstructors(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminInstructors(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin instructors: %v", err)
		writeError(w, http.StatusInternalServerError, "instructors error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminListRooms(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminRooms(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin rooms: %v", err)
		writeError(w, http.StatusInternalServerError, "rooms error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateRoom(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var body struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateRoom(r.Context(), u.StudioID, u.ID, body.Name, body.Color)
	if err != nil {
		// Validation + uniqueness errors are user-fixable; surface them.
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateRoom(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	roomID := chi.URLParam(r, "id")
	// Pointer fields so omitted keys mean "leave that column alone".
	// `color: ""` (present but empty) is the explicit "clear it" signal,
	// distinct from omitting the key — store.RoomPatch handles both.
	var body store.RoomPatch
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateRoom(r.Context(), u.StudioID, u.ID, roomID, body)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "room not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminDeleteRoom(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	roomID := chi.URLParam(r, "id")
	err := s.store.DeleteRoom(r.Context(), u.StudioID, u.ID, roomID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "room not found")
		return
	}
	if errors.Is(err, store.ErrRoomInUse) {
		writeErrorCode(w, http.StatusConflict, "room_in_use",
			"This room is still used by one or more classes — move or cancel them first.")
		return
	}
	if err != nil {
		log.Printf("delete room: %v", err)
		writeError(w, http.StatusInternalServerError, "delete error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// createClassBody is the POST /admin/classes body. The recurrence block is
// optional — when present the server materializes N classes from a rule
// instead of inserting the single one described by the surrounding fields.
type createClassBody struct {
	store.AdminClassInput
	Recurrence *store.RecurrenceInput `json:"recurrence,omitempty"`
}

func (s *Server) handleAdminCreateClass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in createClassBody
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}

	// Recurring branch: build the rule + materialize.
	if in.Recurrence != nil {
		missing := []string{}
		if in.ClassTypeID == nil || *in.ClassTypeID == "" {
			missing = append(missing, "class_type_id")
		}
		if in.InstructorID == nil || *in.InstructorID == "" {
			missing = append(missing, "instructor_id")
		}
		if in.RoomID == nil || *in.RoomID == "" {
			missing = append(missing, "room_id")
		}
		if in.DurationMins == nil || *in.DurationMins <= 0 {
			missing = append(missing, "duration_minutes")
		}
		if in.Capacity == nil || *in.Capacity <= 0 {
			missing = append(missing, "capacity")
		}
		if in.StartsAt == nil || *in.StartsAt == "" {
			missing = append(missing, "starts_at")
		}
		if in.Title == nil || strings.TrimSpace(*in.Title) == "" {
			missing = append(missing, "title")
		}
		if len(missing) > 0 {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("missing fields: %v", missing))
			return
		}
		anchor, err := time.Parse(time.RFC3339, *in.StartsAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "starts_at must be RFC3339")
			return
		}
		title := strings.TrimSpace(*in.Title)
		res, err := s.store.CreateRecurringClasses(r.Context(), u.StudioID, u.ID,
			store.RecurrenceClassInput{
				Title:        title,
				ClassTypeID:  *in.ClassTypeID,
				InstructorID: *in.InstructorID,
				RoomID:       *in.RoomID,
				StartHour:    anchor.Hour(),
				StartMinute:  anchor.Minute(),
				DurationMins: *in.DurationMins,
				Capacity:     *in.Capacity,
				Recurrence:   *in.Recurrence,
			})
		if err != nil {
			respondValidation(w, err)
			return
		}
		_ = s.store.WriteAudit(r.Context(), u.StudioID, u.ID, "rule_create",
			"recurrence_rule", res.RuleID, map[string]any{
				"title":     title,
				"sessions":  len(res.GeneratedClassIDs),
				"frequency": in.Recurrence.Frequency,
			})
		writeJSON(w, http.StatusCreated, res)
		return
	}

	id, err := s.store.CreateAdminClassWithAudit(r.Context(), u.StudioID, u.ID, in.AdminClassInput)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateClass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	scope := r.URL.Query().Get("scope") // "" | this | future | all

	// If a scope is given (or the row is rule-backed), route through the
	// scoped path so future / all edits cascade. Decoded as the scoped
	// patch shape, which is a superset of the single-class one minus the
	// starts_at-on-bulk restriction (the store enforces that).
	if scope != "" {
		var in store.ScopedPatchInput
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			writeError(w, http.StatusBadRequest, "invalid json body")
			return
		}
		out, err := s.store.PatchClassScoped(r.Context(), u.StudioID, id, scope, in)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "class not found")
			return
		}
		if err != nil {
			respondValidation(w, err)
			return
		}
		// Bulk patches don't have a single "what was the before-value"
		// answer per field (it varies across N classes), but recording
		// WHICH fields the manager intended to set is useful — the
		// activity log can render "edited capacity, room" even when
		// the per-class diffs aren't enumerable. AnchorTitle comes
		// back from PatchClassScoped so we don't double-query.
		changed := []string{}
		if in.Title != nil {
			changed = append(changed, "title")
		}
		if in.ClassTypeID != nil {
			changed = append(changed, "class_type")
		}
		if in.InstructorID != nil {
			changed = append(changed, "instructor")
		}
		if in.RoomID != nil {
			changed = append(changed, "room")
		}
		if in.StartsAt != nil {
			changed = append(changed, "starts_at")
		}
		if in.DurationMins != nil {
			changed = append(changed, "duration_minutes")
		}
		if in.Capacity != nil {
			changed = append(changed, "capacity")
		}
		_ = s.store.WriteAudit(r.Context(), u.StudioID, u.ID, "class_update",
			"class", id, map[string]any{
				"class_title":     out.AnchorTitle,
				"scope":           scope,
				"classes_updated": out.ClassesUpdated,
				"rule_updated":    out.RuleUpdated,
				"fields_changed":  changed,
			})
		writeJSON(w, http.StatusOK, out)
		return
	}

	var in store.AdminClassInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateAdminClass(r.Context(), u.StudioID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	// Same action ("class_update") as the scoped branch above so the audit
	// log filter surfaces both single-class and bulk edits together. Record
	// the patched fields so the Activity log can show what changed instead
	// of just "something on this class was edited".
	detail := map[string]any{"scope": "this"}
	if in.Title != nil {
		detail["title"] = *in.Title
	}
	if in.StartsAt != nil {
		detail["starts_at"] = *in.StartsAt
	}
	if in.DurationMins != nil {
		detail["duration_minutes"] = *in.DurationMins
	}
	if in.Capacity != nil {
		detail["capacity"] = *in.Capacity
	}
	if in.ClassTypeID != nil {
		detail["class_type_id"] = *in.ClassTypeID
	}
	if in.InstructorID != nil {
		detail["instructor_id"] = *in.InstructorID
	}
	if in.RoomID != nil {
		detail["room_id"] = *in.RoomID
	}
	_ = s.store.WriteAudit(r.Context(), u.StudioID, u.ID, "class_update",
		"class", id, detail)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminCancelClass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	scope := r.URL.Query().Get("scope")
	if scope != "" && scope != "this" {
		results, err := s.store.CancelClassScoped(r.Context(), u.StudioID, id, scope)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "class not found")
			return
		}
		if err != nil {
			respondValidation(w, err)
			return
		}
		summary := store.CancelClassResult{}
		for _, r := range results {
			summary.BookingsCancelled += r.BookingsCancelled
			summary.CreditsReturned += r.CreditsReturned
			summary.NotificationsSent += r.NotificationsSent
			summary.WaitlistCleared += r.WaitlistCleared
		}
		// Use the anchor class's title as the row label — for
		// scope=future/all the series share the same title shape, so it
		// reads sensibly as "CANCELLED · Vinyasa Flow (future)".
		anchorTitle := ""
		if len(results) > 0 {
			anchorTitle = results[0].Title
		}
		_ = s.store.WriteAudit(r.Context(), u.StudioID, u.ID, "class_cancel",
			"class", id, map[string]any{
				"class_title":      anchorTitle,
				"scope":            scope,
				"classes":          len(results),
				"bookings":         summary.BookingsCancelled,
				"credits_back":     summary.CreditsReturned,
				"notifications":    summary.NotificationsSent,
				"waitlist_cleared": summary.WaitlistCleared,
			})
		writeJSON(w, http.StatusOK, map[string]any{
			"scope":   scope,
			"classes": len(results),
			"summary": summary,
		})
		return
	}

	out, err := s.store.CancelAdminClassWithAudit(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminCreateSeries(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.NewSeriesInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.CreateSeries(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleAdminListEnrollments(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminEnrollments(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin enrollments: %v", err)
		writeError(w, http.StatusInternalServerError, "enrollments error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminUpdateEnrollment(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.AdminEnrollmentInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateAdminEnrollment(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "enrollment not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminArchiveEnrollment(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ArchiveEnrollment(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "enrollment not found")
		return
	}
	if err != nil {
		log.Printf("archive enrollment: %v", err)
		writeError(w, http.StatusInternalServerError, "archive error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type adminEnrollStudentReq struct {
	UserID        string `json:"user_id"`
	PaymentMethod string `json:"payment_method"`
	DiscountCode  string `json:"discount_code,omitempty"`
}

// handleAdminEnrollStudent signs a student into a series from the desk (comp /
// cash / card / transfer). Capacity + already-enrolled are enforced in the
// store and map to 409s.
func (s *Server) handleAdminEnrollStudent(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var req adminEnrollStudentReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.UserID == "" {
		writeError(w, http.StatusBadRequest, "user_id is required")
		return
	}
	switch req.PaymentMethod {
	case "cash", "card", "card_present", "transfer", "comp":
	case "":
		req.PaymentMethod = "comp"
	default:
		writeError(w, http.StatusBadRequest,
			"payment_method must be cash|card|card_present|transfer|comp")
		return
	}
	bookingID, err := s.store.ManagerEnrollStudent(
		r.Context(), u.StudioID, u.ID, id, req.UserID, req.PaymentMethod, req.DiscountCode)
	if err != nil {
		respondErr(w, err, "adminEnrollStudent")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{
		"enrollment_booking_id": bookingID,
	})
}

func (s *Server) handleAdminSeriesRoster(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.SeriesRosterFor(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "series not found")
		return
	}
	if err != nil {
		log.Printf("series roster: %v", err)
		writeError(w, http.StatusInternalServerError, "series roster error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminAudit(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	qp := r.URL.Query()
	limit, _ := strconv.Atoi(qp.Get("limit"))
	page, err := s.store.ListAudit(r.Context(), u.StudioID, store.AuditQuery{
		Action: qp.Get("action"),
		Search: qp.Get("q"),
		Cursor: qp.Get("cursor"),
		Limit:  limit,
	})
	if err != nil {
		log.Printf("audit: %v", err)
		writeError(w, http.StatusInternalServerError, "audit error")
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (s *Server) handleAdminReports(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.AdminReportsFor(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin reports: %v", err)
		writeError(w, http.StatusInternalServerError, "reports error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// reportRange parses optional ?from=&to= (YYYY-MM-DD, studio TZ, `to`
// exclusive) shared by the focused report endpoints. ok=false means no range
// was supplied and the handler should fall back to its default window; a
// malformed range writes a 400 and returns bad=true so the handler stops.
func (s *Server) reportRange(w http.ResponseWriter, r *http.Request, studioID string) (from, to time.Time, ok, bad bool) {
	q := r.URL.Query()
	fromStr := q.Get("from")
	toStr := q.Get("to")
	if fromStr == "" && toStr == "" {
		return time.Time{}, time.Time{}, false, false
	}
	loc := s.store.StudioLocation(r.Context(), studioID)
	f, errA := time.ParseInLocation("2006-01-02", fromStr, loc)
	t, errB := time.ParseInLocation("2006-01-02", toStr, loc)
	if errA != nil || errB != nil {
		writeError(w, http.StatusBadRequest, "from + to must be YYYY-MM-DD")
		return time.Time{}, time.Time{}, false, true
	}
	if !t.After(f) {
		writeError(w, http.StatusBadRequest, "to must be after from")
		return time.Time{}, time.Time{}, false, true
	}
	return f, t, true, false
}

func (s *Server) handleAdminReportRevenue(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	from, to, ok, bad := s.reportRange(w, r, u.StudioID)
	if bad {
		return
	}
	var (
		out *store.RevenueReport
		err error
	)
	if ok {
		out, err = s.store.RevenueReportRange(r.Context(), u.StudioID, from, to, r.URL.Query().Get("granularity"))
	} else {
		out, err = s.store.RevenueReportFor(r.Context(), u.StudioID)
	}
	if err != nil {
		log.Printf("revenue report: %v", err)
		writeError(w, http.StatusInternalServerError, "revenue report error")
		return
	}
	if wantsCSV(r) {
		rows := make([][]string, 0, len(out.ByWeek))
		for _, b := range out.ByWeek {
			total := b.CardMinor + b.CashMinor
			rows = append(rows, []string{
				b.WeekStart, out.Month.Currency,
				minorToDecimal(b.CardMinor), minorToDecimal(b.CashMinor),
				minorToDecimal(total), minorToDecimal(b.GrossMinor),
				minorToDecimal(b.DiscountMinor),
			})
		}
		writeCSV(w, "revenue.csv",
			[]string{"period_start", "currency", "card", "cash", "total", "gross", "discount"},
			rows)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminReportAttendance(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	from, to, ok, bad := s.reportRange(w, r, u.StudioID)
	if bad {
		return
	}
	var (
		out any
		err error
	)
	if ok {
		out, err = s.store.AttendanceReportRange(r.Context(), u.StudioID, from, to)
	} else {
		out, err = s.store.AttendanceReportFor(r.Context(), u.StudioID)
	}
	if err != nil {
		log.Printf("attendance report: %v", err)
		writeError(w, http.StatusInternalServerError, "attendance report error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminReportInstructorPay(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	from, to, ok, bad := s.reportRange(w, r, u.StudioID)
	if bad {
		return
	}
	var (
		out *store.InstructorPayReport
		err error
	)
	if ok {
		out, err = s.store.InstructorPayReportRange(r.Context(), u.StudioID, from, to)
	} else {
		out, err = s.store.InstructorPayReportFor(r.Context(), u.StudioID)
	}
	if err != nil {
		log.Printf("instructor pay report: %v", err)
		writeError(w, http.StatusInternalServerError, "instructor pay report error")
		return
	}
	if wantsCSV(r) {
		rows := make([][]string, 0, len(out.Rows))
		for _, p := range out.Rows {
			rows = append(rows, []string{
				p.FullName, strconv.Itoa(p.ClassesTaught),
				minorToDecimal(p.RateMinor), minorToDecimal(p.PayMinor),
			})
		}
		writeCSV(w, "instructor-pay.csv",
			[]string{"instructor", "classes_taught", "rate", "pay"}, rows)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminReportCustomers(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	from, to, ok, bad := s.reportRange(w, r, u.StudioID)
	if bad {
		return
	}
	if !ok {
		// No window supplied → effectively lifetime.
		from = time.Time{}
		to = time.Now().AddDate(100, 0, 0)
	}
	sort := r.URL.Query().Get("sort")
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	rep, err := s.store.CustomerReportFor(r.Context(), u.StudioID, from, to, sort, q)
	if err != nil {
		log.Printf("customer report: %v", err)
		writeError(w, http.StatusInternalServerError, "customer report error")
		return
	}
	if wantsCSV(r) {
		rows := make([][]string, 0, len(rep.Rows))
		for _, c := range rep.Rows {
			lastSeen := ""
			if c.LastSeenAt != nil {
				lastSeen = *c.LastSeenAt
			}
			rows = append(rows, []string{
				c.FullName, c.Email, c.JoinedAt,
				strconv.Itoa(c.Visits), strconv.Itoa(c.NoShows),
				minorToDecimal(c.SpendMinor), lastSeen, c.ActivePassLabel,
			})
		}
		writeCSV(w, "customers.csv",
			[]string{"name", "email", "joined_at", "visits", "no_shows", "spend", "last_seen", "active_pass"},
			rows)
		return
	}
	writeJSON(w, http.StatusOK, rep)
}

func (s *Server) handleAdminBuilderSchema(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"datasets": s.store.BuilderSchema()})
}

func (s *Server) handleAdminBuilderRun(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var spec store.BuilderSpec
	if err := json.NewDecoder(r.Body).Decode(&spec); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	res, err := s.store.RunBuilder(r.Context(), u.StudioID, spec)
	var be *store.BuilderError
	if errors.As(err, &be) {
		writeError(w, http.StatusBadRequest, be.Error())
		return
	}
	if err != nil {
		log.Printf("report builder: %v", err)
		writeError(w, http.StatusInternalServerError, "report builder error")
		return
	}
	if wantsCSV(r) {
		header := make([]string, len(res.Columns))
		for i, c := range res.Columns {
			header[i] = c.Key
		}
		writeCSV(w, "report.csv", header, res.Rows)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleAdminListStudents(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	q := r.URL.Query().Get("q")
	rows, counts, err := s.store.ListAdminStudents(r.Context(), u.StudioID, q)
	if err != nil {
		log.Printf("students: %v", err)
		writeError(w, http.StatusInternalServerError, "students error")
		return
	}
	out := studentsListResponse{Students: rows}
	if len(counts) >= 2 {
		out.Counts.Total = counts[0]
		out.Counts.ActivePass = counts[1]
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminGetStudent(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.GetAdminStudent(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "student not found")
		return
	}
	if err != nil {
		log.Printf("student detail: %v", err)
		writeError(w, http.StatusInternalServerError, "student error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleAdminExportStudent serves the UK GDPR Art. 15 / 20 subject-access
// bundle as JSON. Reading someone's entire record is itself sensitive, so the
// access is logged to audit_log (user_data_exported) even though it's a read.
func (s *Server) handleAdminExportStudent(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.ExportUserData(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "student not found")
		return
	}
	if err != nil {
		log.Printf("export student: %v", err)
		writeError(w, http.StatusInternalServerError, "export error")
		return
	}
	if err := s.store.WriteAudit(r.Context(), u.StudioID, u.ID,
		"user_data_exported", "user", id, map[string]any{}); err != nil {
		log.Printf("export student audit: %v", err)
		writeError(w, http.StatusInternalServerError, "export error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleAdminEraseStudent fulfils a UK GDPR Art. 17 erasure request. The DB
// work (tombstone + scrub) commits first; the Firebase Auth account is then
// deleted best-effort — it holds the email separately and an orphaned auth
// account left behind would let the person sign back in. The Firebase delete
// can't be rolled into the DB transaction, so a failure there is logged but
// doesn't fail the request: the row is already pseudonymised and login is
// blocked (firebase_uid cleared) regardless.
func (s *Server) handleAdminEraseStudent(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	res, err := s.store.EraseUser(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "student not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	if res.FirebaseUID != "" && s.fbClient != nil {
		if err := s.fbClient.DeleteUser(r.Context(), res.FirebaseUID); err != nil {
			// Already-deleted is fine (idempotent erasure); anything else is
			// worth surfacing in logs for follow-up but the DB is already
			// erased, so we still return success.
			log.Printf("erase student: firebase delete uid=%s: %v", res.FirebaseUID, err)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminGrantPass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	studentID := chi.URLParam(r, "id")
	var in store.GrantPassInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.GrantPass(r.Context(), u.StudioID, u.ID, studentID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleAdminAdjustCredits(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	eid := chi.URLParam(r, "eid")
	var in store.AdjustCreditsInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.AdjustCredits(r.Context(), u.StudioID, u.ID, eid, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "entitlement not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminVoidEntitlement(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.VoidInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.VoidEntitlement(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "entitlement not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListClassTypes(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListClassTypes(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("class types: %v", err)
		writeError(w, http.StatusInternalServerError, "class types error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateClassType(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.ClassTypeInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateClassType(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateClassType(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.ClassTypeInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateClassType(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class type not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleJoinWaitlist(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	pos, err := s.store.JoinWaitlist(r.Context(), u.ID, classID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if errors.Is(err, store.ErrAlreadyBooked) {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": err.Error(),
			"code":  "already_booked",
		})
		return
	}
	if errors.Is(err, store.ErrAlreadyOnWaitlist) {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": err.Error(),
			"code":  "already_on_waitlist",
		})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]int{"position": pos})
}

func (s *Server) handleLeaveWaitlist(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	if err := s.store.LeaveWaitlist(r.Context(), u.ID, classID); err != nil {
		log.Printf("leave waitlist: %v", err)
		writeError(w, http.StatusInternalServerError, "leave waitlist error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// requiresStripeConfirm returns true for payment methods that need a
// PaymentIntent (i.e. real card collection through Stripe Elements). The
// other methods — cash, comp, card_present (manual swipe), dev_stub — are
// settled synchronously on the server with no client-side step.
func requiresStripeConfirm(method string) bool {
	return method == "card"
}

// paymentMethodAllowed is the prod-safety gate for self-serve (student-
// initiated) purchases. Only real `card` payments may settle here in
// production; dev_stub / cash / comp / card_present / transfer are accepted
// only in dev, signalled by the auth emulator being active (the same gate the
// /dev/* routes use). Without this a prod client could POST
// payment_method=dev_stub (or omit it, which defaults to dev_stub) and mint a
// free pass. Legitimate cash/comp sales go through the manager grant flow, not
// this endpoint.
func paymentMethodAllowed(method string) bool {
	return method == "card" || os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != ""
}

func (s *Server) handleCreatePurchase(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req createPurchaseReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	// A series purchase sends enrollment_id; resolve it to the series' product
	// (and validate) before charging. The pending purchase is tagged with the
	// enrollment so fulfilment enrolls the student.
	productID := req.ProductID
	if req.EnrollmentID != "" {
		pid, err := s.store.EnrollmentProductForCheckout(r.Context(), u.StudioID, u.ID, req.EnrollmentID)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "series not found")
			return
		}
		if errors.Is(err, store.ErrAlreadyEnrolled) || errors.Is(err, store.ErrSeriesFull) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		if err != nil {
			respondErr(w, err, "enrollmentCheckout")
			return
		}
		productID = pid
	}
	if productID == "" {
		writeError(w, http.StatusBadRequest, "product_id or enrollment_id is required")
		return
	}
	if req.PaymentMethod == "" {
		req.PaymentMethod = "dev_stub"
	}
	if !paymentMethodAllowed(req.PaymentMethod) {
		writeError(w, http.StatusForbidden, "card payment required")
		return
	}

	// Intent flow: real card payment. Server records a 'pending' purchase
	// and hands the client back a PaymentIntent client_secret so it can
	// finish on Stripe.js. The entitlement gets minted on POST /confirm.
	if requiresStripeConfirm(req.PaymentMethod) {
		out, err := s.store.CreatePendingPurchase(
			r.Context(), u.StudioID, u.ID, productID, req.PaymentMethod, req.DiscountCode, req.EnrollmentID,
		)
		if errors.Is(err, store.ErrStripeNotConfigured) {
			writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
			return
		}
		if err != nil {
			respondErr(w, err, "createPendingPurchase")
			return
		}
		writeJSON(w, http.StatusAccepted, out)
		return
	}

	// Synchronous one-shot for the non-Stripe methods.
	purchaseID, entitlementID, err := s.store.CreatePurchase(
		r.Context(), u.StudioID, u.ID, productID, req.PaymentMethod, req.DiscountCode,
	)
	if err != nil {
		respondErr(w, err, "createPurchase")
		return
	}
	ent, err := s.store.GetEntitlement(r.Context(), entitlementID)
	if err != nil {
		log.Printf("get entitlement: %v", err)
		writeError(w, http.StatusInternalServerError, "purchase succeeded but entitlement load failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"purchase_id": purchaseID,
		"entitlement": ent,
	})
}

// handleConfirmPurchase finalises a pending Stripe purchase once the client
// has run the PaymentIntent through Elements/PaymentSheet. The actual Stripe
// verification (PaymentIntent.status == 'succeeded') is the natural slot
// for the SDK call once STRIPE_SECRET_KEY is configured — the store layer
// trusts the caller in dev.
func (s *Server) handleConfirmPurchase(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	purchaseID := chi.URLParam(r, "id")
	entitlementID, err := s.store.ConfirmPurchase(r.Context(), u.StudioID, u.ID, purchaseID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "purchase not found")
		return
	}
	if err != nil {
		log.Printf("confirm purchase: %v", err)
		respondValidation(w, err)
		return
	}
	ent, err := s.store.GetEntitlement(r.Context(), entitlementID)
	if err != nil {
		log.Printf("get entitlement after confirm: %v", err)
		writeError(w, http.StatusInternalServerError, "confirm succeeded but entitlement load failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"purchase_id": purchaseID,
		"entitlement": ent,
	})
}

// handleStripeEphemeralKey mints an ephemeral key for the caller's Stripe
// Customer so the mobile PaymentSheet can show their saved cards. The client
// sends its mobile-SDK API version (stripe_version) — the key must be created
// with that version or the SDK rejects it.
func (s *Server) handleStripeEphemeralKey(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req struct {
		StripeVersion string `json:"stripe_version"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.StripeVersion == "" {
		writeError(w, http.StatusBadRequest, "stripe_version is required")
		return
	}
	secret, err := s.store.StripeEphemeralKey(r.Context(), u.StudioID, u.ID, u.Email, req.StripeVersion)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "stripeEphemeralKey")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"secret": secret})
}

// ---- Saved card management (the wallet's Payment methods) ----

func (s *Server) handleListPaymentMethods(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListMyPaymentMethods(r.Context(), u.StudioID, u.ID)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "listPaymentMethods")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleDetachPaymentMethod(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	pmID := chi.URLParam(r, "id")
	err := s.store.DetachMyPaymentMethod(r.Context(), u.StudioID, u.ID, pmID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "payment method not found")
		return
	}
	if err != nil {
		respondErr(w, err, "detachPaymentMethod")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCreateSetupIntent(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	secret, customerID, err := s.store.SetupIntentForCard(r.Context(), u.StudioID, u.ID, u.Email)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "createSetupIntent")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"client_secret": secret,
		"customer_id":   customerID,
	})
}

func (s *Server) handleCreateSetupCheckout(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req struct {
		SuccessURL string `json:"success_url"`
		CancelURL  string `json:"cancel_url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.SuccessURL == "" || req.CancelURL == "" {
		writeError(w, http.StatusBadRequest, "success_url and cancel_url are required")
		return
	}
	url, err := s.store.SetupCheckoutForCard(r.Context(), u.StudioID, u.ID, u.Email, req.SuccessURL, req.CancelURL)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "createSetupCheckout")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"url": url})
}

// ---- Stripe Terminal (in-person, manager-gated) ----

func (s *Server) handleAdminListTerminalReaders(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListTerminalReaders(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("list terminal readers: %v", err)
		writeError(w, http.StatusInternalServerError, "terminal readers error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminRegisterTerminalReader(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req struct {
		RegistrationCode string `json:"registration_code"`
		Label            string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	reader, err := s.store.RegisterTerminalReader(r.Context(), u.StudioID, u.ID, req.RegistrationCode, req.Label)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if err != nil {
		respondErr(w, err, "registerTerminalReader")
		return
	}
	writeJSON(w, http.StatusCreated, reader)
}

func (s *Server) handleAdminRemoveTerminalReader(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	readerID := chi.URLParam(r, "id")
	err := s.store.RemoveTerminalReader(r.Context(), u.StudioID, u.ID, readerID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "reader not found")
		return
	}
	if err != nil {
		respondErr(w, err, "removeTerminalReader")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminTerminalCharge(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req struct {
		UserID       string `json:"user_id"`
		ProductID    string `json:"product_id"`
		ReaderID     string `json:"reader_id"`
		DiscountCode string `json:"discount_code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.UserID == "" || req.ProductID == "" || req.ReaderID == "" {
		writeError(w, http.StatusBadRequest, "user_id, product_id and reader_id are required")
		return
	}
	out, err := s.store.ChargeInPerson(r.Context(), u.StudioID, u.ID, req.UserID, req.ProductID, req.DiscountCode, req.ReaderID)
	if errors.Is(err, store.ErrStripeNotConfigured) {
		writeErrorCode(w, http.StatusConflict, "stripe_not_configured", err.Error())
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "reader or product not found")
		return
	}
	if err != nil {
		respondErr(w, err, "terminalCharge")
		return
	}
	writeJSON(w, http.StatusAccepted, out)
}

func (s *Server) handleAdminTerminalCancel(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req struct {
		ReaderID string `json:"reader_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ReaderID == "" {
		writeError(w, http.StatusBadRequest, "reader_id is required")
		return
	}
	err := s.store.CancelTerminalCharge(r.Context(), u.StudioID, req.ReaderID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "reader not found")
		return
	}
	if err != nil {
		respondErr(w, err, "terminalCancel")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleStripeWebhook receives Stripe's server-to-server event POSTs. It reads
// the raw body (signature verification needs the exact bytes), hands off to the
// store which verifies the signature against the studio's webhook secret and
// applies the event, and maps the result to a status Stripe understands: 400
// for a bad signature (don't retry), 500 for a transient failure (please
// retry), 200 once handled or deduped.
func (s *Server) handleStripeWebhook(w http.ResponseWriter, r *http.Request) {
	studioID := chi.URLParam(r, "studioID")
	// Cap the body — webhook payloads are small; this stops a hostile POST to
	// the public path from forcing a huge read.
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read body")
		return
	}
	sig := r.Header.Get("Stripe-Signature")
	if err := s.store.HandleStripeEvent(r.Context(), studioID, payload, sig); err != nil {
		if errors.Is(err, store.ErrWebhookSignature) {
			writeError(w, http.StatusBadRequest, "invalid signature")
			return
		}
		log.Printf("stripe webhook (studio=%s): %v", studioID, err)
		writeError(w, http.StatusInternalServerError, "webhook handling failed")
		return
	}
	w.WriteHeader(http.StatusOK)
}

// Per-booking single-use scan: the token alone identifies the booking. The
// class_id field is no longer required on the request — kept off the
// struct so callers don't accidentally send irrelevant data.
type checkinScanReq struct {
	Token string `json:"token"`
}

func (s *Server) handleAdminCheckinScan(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req checkinScanReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.CheckinScan(r.Context(), u.StudioID, u.ID, req.Token)
	var se *store.ScanError
	if errors.As(err, &se) {
		status := http.StatusConflict
		if se.Code == "invalid_token" {
			status = http.StatusNotFound
		}
		writeJSON(w, status, map[string]string{"error": se.Message, "code": se.Code})
		return
	}
	if err != nil {
		log.Printf("checkin scan: %v", err)
		writeError(w, http.StatusInternalServerError, "scan error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListStaff(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminStaff(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin staff: %v", err)
		writeError(w, http.StatusInternalServerError, "staff error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateStaff(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.StaffInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateStaff(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateStaff(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.StaffInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateStaff(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "staff member not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminDeactivateStaff(w http.ResponseWriter, r *http.Request) {
	s.setStaffActive(w, r, false)
}

func (s *Server) handleAdminReactivateStaff(w http.ResponseWriter, r *http.Request) {
	s.setStaffActive(w, r, true)
}

func (s *Server) setStaffActive(w http.ResponseWriter, r *http.Request, active bool) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.SetStaffActive(r.Context(), u.StudioID, u.ID, id, active)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "staff member not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleListPromotions(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListActivePromotions(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("promotions: %v", err)
		writeError(w, http.StatusInternalServerError, "promotions error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminListPromotions(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminPromotions(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin promotions: %v", err)
		writeError(w, http.StatusInternalServerError, "promotions error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreatePromotion(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.PromotionInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreatePromotion(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdatePromotion(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.PromotionInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdatePromotion(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "promotion not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminArchivePromotion(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ArchivePromotion(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "promotion not found")
		return
	}
	if err != nil {
		log.Printf("archive promotion: %v", err)
		writeError(w, http.StatusInternalServerError, "archive error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- discounts ----------------------------------------------------------

func (s *Server) handleAdminListDiscounts(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	includeArchived := r.URL.Query().Get("include_archived") == "1"
	rows, err := s.store.ListDiscounts(r.Context(), u.StudioID, includeArchived)
	if err != nil {
		log.Printf("admin discounts: %v", err)
		writeError(w, http.StatusInternalServerError, "discounts error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type createDiscountReq struct {
	Code               *string `json:"code,omitempty"`
	Kind               string  `json:"kind"`
	Value              int     `json:"value"`
	AppliesToProductID *string `json:"applies_to_product_id,omitempty"`
	ValidFrom          *string `json:"valid_from,omitempty"`
	ValidTo            *string `json:"valid_to,omitempty"`
	MaxUses            *int    `json:"max_uses,omitempty"`
	MaxUsesPerUser     *int    `json:"max_uses_per_user,omitempty"`
	Notes              string  `json:"notes,omitempty"`
}

func (s *Server) handleAdminCreateDiscount(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req createDiscountReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	in, err := discountInputFromReq(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	d, err := s.store.CreateDiscount(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, d)
}

// discountInputFromReq maps the JSON request onto the store input, parsing the
// RFC3339 window bounds. Shared by create + update.
func discountInputFromReq(req createDiscountReq) (store.DiscountCreate, error) {
	in := store.DiscountCreate{
		Code:               req.Code,
		Kind:               req.Kind,
		Value:              req.Value,
		AppliesToProductID: req.AppliesToProductID,
		MaxUses:            req.MaxUses,
		MaxUsesPerUser:     req.MaxUsesPerUser,
		Notes:              req.Notes,
	}
	if req.ValidFrom != nil && *req.ValidFrom != "" {
		t, err := time.Parse(time.RFC3339, *req.ValidFrom)
		if err != nil {
			return in, fmt.Errorf("valid_from: invalid RFC3339 time")
		}
		in.ValidFrom = &t
	}
	if req.ValidTo != nil && *req.ValidTo != "" {
		t, err := time.Parse(time.RFC3339, *req.ValidTo)
		if err != nil {
			return in, fmt.Errorf("valid_to: invalid RFC3339 time")
		}
		in.ValidTo = &t
	}
	return in, nil
}

func (s *Server) handleAdminUpdateDiscount(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var req createDiscountReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	in, err := discountInputFromReq(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	d, err := s.store.UpdateDiscount(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "discount not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) handleAdminArchiveDiscount(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ArchiveDiscount(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "discount not found")
		return
	}
	if err != nil {
		log.Printf("archive discount: %v", err)
		writeError(w, http.StatusInternalServerError, "archive error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type refundPurchaseReq struct {
	RefundAmountMinor int    `json:"refund_amount_minor"`
	Note              string `json:"note,omitempty"`
}

func (s *Server) handleAdminRefundPurchase(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var req refundPurchaseReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.RefundPurchase(r.Context(), u.StudioID, u.ID, id, req.RefundAmountMinor, req.Note)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "purchase not found")
		return
	}
	if err != nil {
		respondValidation(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminListSubscriptions(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.AdminListSubscriptions(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin subscriptions: %v", err)
		writeError(w, http.StatusInternalServerError, "subscriptions error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type adminCancelSubscriptionReq struct {
	Immediate bool `json:"immediate"`
}

func (s *Server) handleAdminCancelSubscription(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	// Body is optional — default (no body) cancels at period end.
	var req adminCancelSubscriptionReq
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&req)
	}
	err := s.store.AdminCancelSubscription(r.Context(), u.StudioID, u.ID, id, req.Immediate)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "subscription not found")
		return
	}
	if err != nil {
		respondErr(w, err, "adminCancelSubscription")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleAdminRefundSubscription refunds the latest membership payment and
// cancels the subscription now (revoking access + releasing future seats).
func (s *Server) handleAdminRefundSubscription(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.AdminRefundMembership(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "subscription not found")
		return
	}
	if errors.Is(err, store.ErrNoRefundablePayment) {
		writeError(w, http.StatusConflict,
			"No recorded payment to refund yet — refund this one via the Stripe dashboard.")
		return
	}
	if err != nil {
		respondErr(w, err, "adminRefundSubscription")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminResumeSubscription(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.AdminResumeSubscription(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "subscription not found")
		return
	}
	if err != nil {
		respondErr(w, err, "adminResumeSubscription")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminPaymentsAttention(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.AdminListPaymentsAttention(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("payments attention: %v", err)
		writeError(w, http.StatusInternalServerError, "payments attention error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// handleDevResetTestState wipes non-seed bookings/purchases/etc. so
// integration tests can re-run from a clean baseline. Only available
// when the Firebase Auth emulator is in play — refuses with 404
// otherwise to keep prod surface-area zero.
func (s *Server) handleDevResetTestState(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	if err := s.store.ResetTestState(r.Context()); err != nil {
		respondErr(w, err, "internal")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleDevConfigureStripe points a studio at Stripe test keys for the
// checkout integration test. Body: {"studio_id":"s52","secret_key":"sk_test_…",
// "publishable_key":"pk_test_…","webhook_secret":"whsec_…"}. studio_id defaults
// to s52. Dev-only gate via the auth emulator.
func (s *Server) handleDevConfigureStripe(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	var body struct {
		StudioID       string `json:"studio_id"`
		SecretKey      string `json:"secret_key"`
		PublishableKey string `json:"publishable_key"`
		WebhookSecret  string `json:"webhook_secret"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if body.StudioID == "" {
		body.StudioID = "s52"
	}
	if err := s.store.ConfigureTestStripeKeys(r.Context(), body.StudioID,
		body.SecretKey, body.PublishableKey, body.WebhookSecret); err != nil {
		respondErr(w, err, "configureStripe")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleDevSeedMembership creates a real Stripe test-mode subscription for a
// seeded student so dev exercises real Stripe (not placeholder rows). Same
// emulator-only gate as the other /dev routes. The webhook fulfils it.
func (s *Server) handleDevSeedMembership(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	var body struct {
		StudioID  string `json:"studio_id"`
		Email     string `json:"email"`
		ProductID string `json:"product_id"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.StudioID == "" {
		body.StudioID = "s52"
	}
	if body.Email == "" {
		body.Email = "maya@studio52.dev"
	}
	if body.ProductID == "" {
		body.ProductID = store.ProductUnlimitedMonthly
	}
	if err := s.store.DevSeedRealMembership(r.Context(), body.StudioID, body.Email, body.ProductID); err != nil {
		respondErr(w, err, "devSeedMembership")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleDevFillClass fills the requested class to capacity by booking
// eligible community-seed students. Body: {"studio_id":"s52","class_id":"…"}.
// Same dev-only gate as the reset endpoint.
func (s *Server) handleDevFillClass(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	var body struct {
		StudioID string `json:"studio_id"`
		ClassID  string `json:"class_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	n, err := s.store.FillClassToCapacity(r.Context(), body.StudioID, body.ClassID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		respondErr(w, err, "internal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"booked": n})
}

// ---- chat ----------------------------------------------------------------

// createConversationBody is the POST /conversations payload. `kind` selects
// the branch: a "group" reads title + member_ids; a "dm" reads user_id (the
// other participant). Empty kind defaults to group for ergonomics.
type createConversationBody struct {
	Kind      string   `json:"kind"`       // "group" | "dm"
	Title     string   `json:"title"`      // group only
	MemberIDs []string `json:"member_ids"` // group: initial members besides the creator
	UserID    string   `json:"user_id"`    // dm: the target user
}

func (s *Server) handleCreateConversation(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var body createConversationBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	var (
		conv *store.Conversation
		err  error
	)
	switch body.Kind {
	case "dm":
		conv, err = s.store.OpenDM(r.Context(), u.StudioID, u.ID, strings.TrimSpace(body.UserID))
	case "group", "":
		conv, err = s.store.CreateConversation(r.Context(), u.StudioID, u.ID, body.Title, body.MemberIDs)
	default:
		writeError(w, http.StatusBadRequest, "kind must be 'group' or 'dm'")
		return
	}
	if err != nil {
		respondErr(w, err, "create conversation")
		return
	}
	writeJSON(w, http.StatusCreated, conv)
}

func (s *Server) handleAddConversationMembers(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	convID := chi.URLParam(r, "id")
	var body struct {
		MemberIDs []string `json:"member_ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if err := s.store.AddMembers(r.Context(), u.StudioID, u.ID, convID, body.MemberIDs); err != nil {
		respondErr(w, err, "add conversation members")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleOpenClassChat resolves (and lazy-creates) the class chat for the
// classID in the URL. For a recurring class the chat is anchored to the
// series so all instances share one room; for a one-off it's anchored to
// the single class. Eligibility (booked / waitlisted / instructor of any
// matching class / staff in the studio) is enforced by the store, which
// returns ErrNotMember for ineligible callers and ErrNotFound for a class
// outside the caller's studio.
func (s *Server) handleOpenClassChat(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	conv, err := s.store.OpenOrCreateClassConversation(r.Context(), u.StudioID, u.ID, classID)
	if err != nil {
		respondErr(w, err, "open class chat")
		return
	}
	writeJSON(w, http.StatusOK, conv)
}

func (s *Server) handleListConversations(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.ListConversations(r.Context(), u.StudioID, u.ID, u.Role != "student")
	if err != nil {
		respondErr(w, err, "list conversations")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleListMessages(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	convID := chi.URLParam(r, "id")
	before := queryInt(r, "before")
	after := queryInt(r, "after")
	limit := queryInt(r, "limit")
	out, err := s.store.ListMessages(r.Context(), u.ID, convID, before, after, limit)
	if err != nil {
		respondErr(w, err, "list messages")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleSendMessage(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	convID := chi.URLParam(r, "id")
	var body struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	msg, err := s.store.SendMessage(r.Context(), u.StudioID, u.ID, convID, body.Body)
	if err != nil {
		respondErr(w, err, "send message")
		return
	}
	writeJSON(w, http.StatusCreated, msg)
}

func (s *Server) handleEditMessage(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	convID := chi.URLParam(r, "id")
	msgID := chi.URLParam(r, "mid")
	var body struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	msg, err := s.store.EditMessage(r.Context(), u.StudioID, u.ID, convID, msgID, body.Body)
	if err != nil {
		respondErr(w, err, "edit message")
		return
	}
	writeJSON(w, http.StatusOK, msg)
}

func (s *Server) handleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	convID := chi.URLParam(r, "id")
	msgID := chi.URLParam(r, "mid")
	if err := s.store.DeleteMessage(r.Context(), u.StudioID, u.ID, convID, msgID); err != nil {
		respondErr(w, err, "delete message")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMarkConversationRead(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	convID := chi.URLParam(r, "id")
	var body struct {
		UpToSeq int `json:"up_to_seq"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if err := s.store.MarkConversationRead(r.Context(), u.ID, convID, body.UpToSeq); err != nil {
		respondErr(w, err, "mark conversation read")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// queryInt parses a non-negative integer query param, returning 0 when
// absent or unparseable — every chat caller treats 0 as "unset".
func queryInt(r *http.Request, key string) int {
	n, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// ---- student notes -------------------------------------------------------

// handleAdminListStudentNotes returns the staff-visible notes for a
// student newest-first. Available to any staff member (instructors
// + managers); the store scopes by studio_id so cross-tenant reads
// are impossible even with a leaked path.
func (s *Server) handleAdminListStudentNotes(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	studentID := chi.URLParam(r, "id")
	notes, err := s.store.ListStudentNotes(r.Context(), u.StudioID, studentID)
	if err != nil {
		respondErr(w, err, "listStudentNotes")
		return
	}
	writeJSON(w, http.StatusOK, notes)
}

func (s *Server) handleAdminCreateStudentNote(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	studentID := chi.URLParam(r, "id")
	var body struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateStudentNote(r.Context(), u.StudioID, u.ID, studentID, body.Body)
	if err != nil {
		respondErr(w, err, "createStudentNote")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateStudentNote(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	noteID := chi.URLParam(r, "id")
	var body struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if err := s.store.UpdateStudentNote(r.Context(), u.StudioID, u.ID, noteID, body.Body); err != nil {
		respondErr(w, err, "updateStudentNote")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminDeleteStudentNote(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	noteID := chi.URLParam(r, "id")
	if err := s.store.DeleteStudentNote(r.Context(), u.StudioID, u.ID, noteID); err != nil {
		respondErr(w, err, "deleteStudentNote")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- helpers -------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// writeErrorCode mirrors writeError but also surfaces a stable machine
// code so the client can branch on the failure type without parsing the
// human-readable message.
func writeErrorCode(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}

// writeCSV streams a CSV download. header is the column row; rows are the data
// rows (each already stringified). Sets the attachment filename so a browser
// fetch can name the saved file.
func writeCSV(w http.ResponseWriter, filename string, header []string, rows [][]string) {
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", "attachment; filename=\""+filename+"\"")
	w.WriteHeader(http.StatusOK)
	cw := csv.NewWriter(w)
	_ = cw.Write(header)
	_ = cw.WriteAll(rows)
	cw.Flush()
}

// wantsCSV reports whether the caller asked for a CSV download via ?format=csv
// or an Accept: text/csv header.
func wantsCSV(r *http.Request) bool {
	if r.URL.Query().Get("format") == "csv" {
		return true
	}
	return strings.Contains(r.Header.Get("Accept"), "text/csv")
}

// minorToDecimal renders integer minor units as a plain decimal string
// ("2500" → "25.00") for spreadsheet-friendly CSV cells.
func minorToDecimal(minor int) string {
	neg := minor < 0
	if neg {
		minor = -minor
	}
	s := fmt.Sprintf("%d.%02d", minor/100, minor%100)
	if neg {
		return "-" + s
	}
	return s
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// handleHealthz answers the load balancer's "are you alive?" probe.
// Returns 200 when the DB is reachable, 503 otherwise. A failing
// healthz tells the platform to stop sending traffic and (depending on
// config) restart the process — which is the right reaction to a stuck
// or disconnected DB, and the wrong reaction to e.g. a Firebase outage,
// so we deliberately only probe the DB here.
//
// Short context timeout — the prober itself runs on a tight schedule,
// and an answer that takes 30s is worse than no answer (it ties up
// goroutines + makes the prober think we're slow rather than down).
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.DB().PingContext(ctx); err != nil {
		// Plain text body — the prober just reads the status code, but
		// curling /healthz in incident triage gives the operator a hint
		// of WHY it's down.
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("db ping failed: " + err.Error() + "\n"))
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}
