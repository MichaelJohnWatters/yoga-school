package api

import (
	"errors"
	"log"
	"net/http"
	"os"

	"github.com/studio52/yoga-school/server/internal/store"
)

// devVerboseErrors is the flag that controls whether response bodies
// include the raw error detail (`_debug` field). True when:
//   - DEV_VERBOSE_ERRORS=1 explicitly, OR
//   - FIREBASE_AUTH_EMULATOR_HOST is set — that env var already gates
//     /dev routes and means "this is a developer / staging environment,
//     not production." Reusing it spares us a second flag to remember.
//
// Computed once at package init so flipping it requires a server restart
// (intentional — runtime toggles invite mistakes).
var devVerboseErrors = os.Getenv("DEV_VERBOSE_ERRORS") == "1" ||
	os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != ""

// SafeError is the contract a store / domain error must satisfy to have
// its message returned verbatim to the client. Anything that doesn't
// implement it is treated as internal and gets a generic message.
//
// We keep this distinct from Go's standard `error` so message authors
// have to think "is this user-facing copy?" when they create the type
// instead of accidentally leaking an internal stringified error.
type SafeError interface {
	error
	// HTTPStatus is the response code to use (e.g. http.StatusConflict).
	HTTPStatus() int
	// Code is the stable machine-readable identifier — UIs branch on this,
	// never on the message text. Lower_snake.
	Code() string
	// Message is the user-facing text. May be shown verbatim in snackbars.
	Message() string
}

// errorBody is the response shape for every error written through
// respondErr. _debug is omitted in production (devVerboseErrors=false).
type errorBody struct {
	Error string     `json:"error"`
	Code  string     `json:"code"`
	Debug *debugBody `json:"_debug,omitempty"`
}

type debugBody struct {
	// Raw is the underlying error's full Error() text, including any
	// stringified DB constraint info. NEVER returned in production.
	Raw string `json:"raw"`
	// Where is a free-form caller hint passed by the handler — usually
	// the store method that returned the error. Helps a dev jump straight
	// to the right file when a 500 lands.
	Where string `json:"where,omitempty"`
}

// respondErr is the single funnel for non-success responses. Handlers
// hand it any error and a `where` hint (typically the store method
// name), and it works out:
//
//   - Typed SafeError → returns its status/code/message verbatim.
//   - Known store sentinel → mapped via mapStoreError to a SafeError.
//   - Anything else → logs the full error + returns a generic 500.
//
// In dev mode, the response also carries a `_debug` block with the raw
// error text so the engineer's snackbar still shows what actually went
// wrong without us having to grep server logs.
func respondErr(w http.ResponseWriter, err error, where string) {
	if err == nil {
		// Defensive: callers should only invoke respondErr on a real
		// failure. If we somehow get nil, treat it as internal so the
		// bug surfaces in logs rather than silently 200-ing.
		log.Printf("respondErr: nil error at %s", where)
		err = errors.New("nil error")
	}

	// 1. Already a SafeError? Use it directly.
	var safe SafeError
	if errors.As(err, &safe) {
		writeErr(w, safe.HTTPStatus(), safe.Code(), safe.Message(), err, where)
		return
	}

	// 2. Map known store sentinels.
	if mapped := mapStoreError(err); mapped != nil {
		writeErr(w, mapped.HTTPStatus(), mapped.Code(), mapped.Message(), err, where)
		return
	}

	// 3. Genuinely unknown → log + generic 500.
	log.Printf("internal error at %s: %v", where, err)
	writeErr(w, http.StatusInternalServerError, "internal",
		"Something went wrong. Please try again — if it keeps happening, contact support.",
		err, where)
}

// writeErr is the low-level emitter shared by respondErr branches.
// Centralising it means the debug-attachment rule lives in one place.
func writeErr(w http.ResponseWriter, status int, code, msg string, raw error, where string) {
	body := errorBody{Error: msg, Code: code}
	if devVerboseErrors && raw != nil {
		body.Debug = &debugBody{Raw: raw.Error(), Where: where}
	}
	writeJSON(w, status, body)
}

// mapStoreError translates the small set of well-known store sentinels
// into SafeErrors. New sentinels added to the store should land here too
// — that's how the API stays in sync without hand-rolling a switch in
// every handler.
//
// Returning nil from this function (the default) means "I don't
// recognise this; treat it as internal" — which is the safe default.
func mapStoreError(err error) SafeError {
	// BookingError is special: it's a struct with Code/Message fields
	// (not methods, so it can't implement SafeError directly without
	// renaming the fields and breaking every store construction site).
	// Recognise it here and lift the fields into a simpleSafe envelope.
	var be *store.BookingError
	if errors.As(err, &be) {
		return simpleSafe{
			status: http.StatusConflict,
			code:   be.Code,
			msg:    be.Message,
		}
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return simpleSafe{
			status: http.StatusNotFound,
			code:   "not_found",
			msg:    "Not found.",
		}
	case errors.Is(err, store.ErrRoomInUse):
		return simpleSafe{
			status: http.StatusConflict,
			code:   "room_in_use",
			msg:    "This room is still used by one or more classes — move or cancel them first.",
		}
	case errors.Is(err, store.ErrThemeModeMismatch):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "theme_mode_mismatch",
			msg:    "This theme's mode doesn't match the slot — light themes go in the light slot and dark in the dark slot.",
		}
	case errors.Is(err, store.ErrClassStarted):
		return simpleSafe{
			status: http.StatusConflict,
			code:   "class_already_started",
			msg:    "Class has already started.",
		}
	case errors.Is(err, store.ErrAlreadyBooked):
		return simpleSafe{
			status: http.StatusConflict,
			code:   "already_booked",
			msg:    "You already have a booking for this class.",
		}
	case errors.Is(err, store.ErrAlreadyOnWaitlist):
		return simpleSafe{
			status: http.StatusConflict,
			code:   "already_on_waitlist",
			msg:    "You're already on the waitlist for this class.",
		}
	case errors.Is(err, store.ErrNotMember):
		return simpleSafe{
			status: http.StatusForbidden,
			code:   "not_a_member",
			msg:    "You don't have access to this conversation.",
		}
	case errors.Is(err, store.ErrNotSender):
		return simpleSafe{
			status: http.StatusForbidden,
			code:   "not_message_sender",
			msg:    "You can only edit or delete your own messages.",
		}
	case errors.Is(err, store.ErrEmptyMessage):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "empty_message",
			msg:    "Message can't be empty.",
		}
	case errors.Is(err, store.ErrNotGroup):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "not_a_group",
			msg:    "Members can only be added to group conversations.",
		}
	case errors.Is(err, store.ErrInvalidMember):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "invalid_member",
			msg:    "One or more selected people aren't part of this studio.",
		}
	case errors.Is(err, store.ErrEmptyTitle):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "empty_title",
			msg:    "Give the group a name.",
		}
	case errors.Is(err, store.ErrSelfDM):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "self_dm",
			msg:    "You can't start a direct message with yourself.",
		}
	case errors.Is(err, store.ErrMessageTooLong):
		return simpleSafe{
			status: http.StatusBadRequest,
			code:   "message_too_long",
			msg:    "That message is too long.",
		}
	}
	return nil
}

// simpleSafe is the workhorse SafeError implementation — most sentinels
// map to a triple of (status, code, message) and need nothing more.
// Handler-specific errors that need richer fields can roll their own
// type that also implements SafeError.
type simpleSafe struct {
	status int
	code   string
	msg    string
}

func (e simpleSafe) Error() string   { return e.msg }
func (e simpleSafe) HTTPStatus() int { return e.status }
func (e simpleSafe) Code() string    { return e.code }
func (e simpleSafe) Message() string { return e.msg }

// respondValidation is the 400-path shorthand. Wraps the error's text in
// the standard validation envelope and routes through respondErr so the
// _debug block still attaches in dev mode. Use this for store-returned
// argument errors ("name is required", "buy_layout must be grid|list|
// grouped", etc.) that are already authored as user-facing text. For
// anything that might wrap a raw DB error, return a typed sentinel from
// the store instead and let mapStoreError handle it.
func respondValidation(w http.ResponseWriter, err error) {
	respondErr(w, validationError{wrapped: err}, "validation")
}

// validationError is a SafeError wrapper for plain error values that
// have been judged "this message text is safe to show the user." Status
// is fixed at 400 and the code is the generic "validation" — handlers
// that want a more specific code should mint their own SafeError type.
type validationError struct {
	wrapped error
}

func (v validationError) Error() string   { return v.wrapped.Error() }
func (v validationError) HTTPStatus() int { return http.StatusBadRequest }
func (v validationError) Code() string    { return "validation" }
func (v validationError) Message() string { return v.wrapped.Error() }
func (v validationError) Unwrap() error   { return v.wrapped }
