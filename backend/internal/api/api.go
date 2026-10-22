// Package api is the HTTP layer of the hunters-map backend. All /v1 routes require a
// Firebase ID token ("Authorization: Bearer <token>").
//
//	GET    /healthz
//	GET    /v1/me                              profile (created on first call)
//	PUT    /v1/me                              {displayName}
//	DELETE /v1/me                              delete account and all its data
//	GET    /v1/groups                          caller's groups
//	POST   /v1/groups                          {name}
//	GET    /v1/groups/{gid}                    group with members
//	DELETE /v1/groups/{gid}                    owner only
//	POST   /v1/groups/{gid}/invites            -> {code, expiresAt}
//	POST   /v1/invites/{code}/join             join a group
//	DELETE /v1/groups/{gid}/members/{uid}      leave, or owner removes a member
//	PUT    /v1/groups/{gid}/sharing            {until} start (capped to 24 h); null stops
//	POST   /v1/locations                       {lat, lon, accuracy, heading?, speed?, recordedAt?}
//
// Phones read live positions straight from Firestore (groups/{gid}/locations), allowed
// for members by firestore.rules; all writes go through this API.
package api

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/ransoni/hunters-map/backend/internal/auth"
	"github.com/ransoni/hunters-map/backend/internal/service"
	"github.com/ransoni/hunters-map/backend/internal/store"
)

const maxBody = 16 << 10

type Server struct {
	svc      *service.Service
	verifier auth.Verifier
	accounts auth.AccountDeleter
	log      *slog.Logger
}

func New(svc *service.Service, v auth.Verifier, accounts auth.AccountDeleter, log *slog.Logger) *Server {
	return &Server{svc: svc, verifier: v, accounts: accounts, log: log}
}

func (s *Server) Handler() http.Handler {
	v1 := http.NewServeMux()
	v1.HandleFunc("GET /v1/me", s.getMe)
	v1.HandleFunc("PUT /v1/me", s.putMe)
	v1.HandleFunc("DELETE /v1/me", s.deleteMe)
	v1.HandleFunc("GET /v1/groups", s.listGroups)
	v1.HandleFunc("POST /v1/groups", s.createGroup)
	v1.HandleFunc("GET /v1/groups/{gid}", s.getGroup)
	v1.HandleFunc("DELETE /v1/groups/{gid}", s.deleteGroup)
	v1.HandleFunc("POST /v1/groups/{gid}/invites", s.createInvite)
	v1.HandleFunc("POST /v1/invites/{code}/join", s.join)
	v1.HandleFunc("DELETE /v1/groups/{gid}/members/{uid}", s.removeMember)
	v1.HandleFunc("PUT /v1/groups/{gid}/sharing", s.putSharing)
	v1.HandleFunc("POST /v1/locations", s.postLocation)

	root := http.NewServeMux()
	root.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	root.Handle("/v1/", auth.Middleware(s.verifier, writeError)(v1))
	return s.logRequests(root)
}

// ---------------------------------------------------------------------------- JSON shapes

type userJSON struct {
	ID          string    `json:"id"`
	DisplayName string    `json:"displayName"`
	Email       string    `json:"email"`
	CreatedAt   time.Time `json:"createdAt"`
}

type groupJSON struct {
	ID           string       `json:"id"`
	Name         string       `json:"name"`
	OwnerID      string       `json:"ownerId"`
	CreatedAt    time.Time    `json:"createdAt"`
	Role         string       `json:"role,omitempty"`
	SharingUntil *time.Time   `json:"sharingUntil,omitempty"`
	Members      []memberJSON `json:"members,omitempty"`
}

type memberJSON struct {
	UserID       string     `json:"userId"`
	DisplayName  string     `json:"displayName"`
	Role         string     `json:"role"`
	JoinedAt     time.Time  `json:"joinedAt"`
	SharingUntil *time.Time `json:"sharingUntil,omitempty"`
}

func toUser(u *store.User) userJSON {
	return userJSON{ID: u.ID, DisplayName: u.DisplayName, Email: u.Email, CreatedAt: u.CreatedAt}
}

func toGroup(g *store.Group) groupJSON {
	return groupJSON{ID: g.ID, Name: g.Name, OwnerID: g.OwnerID, CreatedAt: g.CreatedAt}
}

// ---------------------------------------------------------------------------- handlers

func (s *Server) getMe(w http.ResponseWriter, r *http.Request) {
	u, err := s.svc.Profile(r.Context(), auth.FromContext(r.Context()))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toUser(u))
}

func (s *Server) putMe(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DisplayName string `json:"displayName"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	u, err := s.svc.UpdateProfile(r.Context(), auth.FromContext(r.Context()), body.DisplayName)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toUser(u))
}

func (s *Server) deleteMe(w http.ResponseWriter, r *http.Request) {
	uid := auth.FromContext(r.Context()).UID
	if err := s.svc.DeleteAccount(r.Context(), uid); err != nil {
		s.fail(w, r, err)
		return
	}
	if err := s.accounts.DeleteAccount(r.Context(), uid); err != nil {
		s.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) listGroups(w http.ResponseWriter, r *http.Request) {
	groups, err := s.svc.ListGroups(r.Context(), auth.FromContext(r.Context()).UID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]groupJSON, 0, len(groups))
	for _, g := range groups {
		j := toGroup(g.Group)
		j.Role = g.Role
		j.SharingUntil = g.SharingUntil
		out = append(out, j)
	}
	writeJSON(w, http.StatusOK, map[string]any{"groups": out})
}

func (s *Server) createGroup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name string `json:"name"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	g, err := s.svc.CreateGroup(r.Context(), auth.FromContext(r.Context()), body.Name)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	j := toGroup(g)
	j.Role = store.RoleOwner
	writeJSON(w, http.StatusCreated, j)
}

func (s *Server) getGroup(w http.ResponseWriter, r *http.Request) {
	uid := auth.FromContext(r.Context()).UID
	d, err := s.svc.GetGroup(r.Context(), uid, r.PathValue("gid"))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	j := toGroup(d.Group)
	now := time.Now()
	for _, m := range d.Members {
		mj := memberJSON{UserID: m.UserID, DisplayName: m.DisplayName, Role: m.Role, JoinedAt: m.JoinedAt}
		if m.Sharing(now) {
			mj.SharingUntil = m.SharingUntil
		}
		if m.UserID == uid {
			j.Role = m.Role
			j.SharingUntil = mj.SharingUntil
		}
		j.Members = append(j.Members, mj)
	}
	writeJSON(w, http.StatusOK, j)
}

func (s *Server) deleteGroup(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.DeleteGroup(r.Context(), auth.FromContext(r.Context()).UID, r.PathValue("gid")); err != nil {
		s.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) createInvite(w http.ResponseWriter, r *http.Request) {
	inv, err := s.svc.CreateInvite(r.Context(), auth.FromContext(r.Context()).UID, r.PathValue("gid"))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"code": inv.Code, "groupId": inv.GroupID, "expiresAt": inv.ExpiresAt,
	})
}

func (s *Server) join(w http.ResponseWriter, r *http.Request) {
	g, err := s.svc.JoinByInvite(r.Context(), auth.FromContext(r.Context()), r.PathValue("code"))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toGroup(g))
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request) {
	actor := auth.FromContext(r.Context()).UID
	if err := s.svc.RemoveMember(r.Context(), actor, r.PathValue("gid"), r.PathValue("uid")); err != nil {
		s.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) putSharing(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Until *time.Time `json:"until"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	until, err := s.svc.SetSharing(r.Context(), auth.FromContext(r.Context()).UID, r.PathValue("gid"), body.Until)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sharing": until != nil, "until": until})
}

func (s *Server) postLocation(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Lat        *float64  `json:"lat"`
		Lon        *float64  `json:"lon"`
		Accuracy   float64   `json:"accuracy"`
		Heading    *float64  `json:"heading"`
		Speed      *float64  `json:"speed"`
		RecordedAt time.Time `json:"recordedAt"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if body.Lat == nil || body.Lon == nil {
		writeError(w, http.StatusBadRequest, "invalid", "lat and lon are required")
		return
	}
	groups, err := s.svc.UpdateLocation(r.Context(), auth.FromContext(r.Context()).UID, service.LocationUpdate{
		Lat: *body.Lat, Lon: *body.Lon, Accuracy: body.Accuracy,
		Heading: body.Heading, Speed: body.Speed, RecordedAt: body.RecordedAt,
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if groups == nil {
		groups = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"groups": groups})
}

// ---------------------------------------------------------------------------- helpers

func readJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "invalid", "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}

// fail maps service errors to HTTP statuses; anything unexpected is logged and hidden.
func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, service.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", err.Error())
	case errors.Is(err, service.ErrInvalid):
		writeError(w, http.StatusBadRequest, "invalid", err.Error())
	case errors.Is(err, service.ErrLimit):
		writeError(w, http.StatusConflict, "limit", err.Error())
	default:
		s.log.ErrorContext(r.Context(), "request failed", "path", r.URL.Path, "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		if r.URL.Path == "/healthz" {
			return
		}
		s.log.InfoContext(r.Context(), "request",
			"method", r.Method, "path", r.URL.Path, "status", sw.status,
			"ms", time.Since(start).Milliseconds())
	})
}
