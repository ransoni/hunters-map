// Package service holds the hunters-map business rules: profiles, hunting groups,
// invites and location sharing. Every operation is one store transaction that does all
// its reads before any writes (a Firestore requirement).
package service

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/ransoni/hunters-map/backend/internal/store"
)

var (
	ErrNotFound  = errors.New("not found")
	ErrForbidden = errors.New("forbidden")
	ErrInvalid   = errors.New("invalid")
	ErrLimit     = errors.New("limit reached")
)

const (
	MaxGroupsPerUser = 20
	MaxMembers       = 50
	MaxNameLength    = 40
	// MaxSharing caps one sharing session, so nobody shares for days by accident.
	MaxSharing = 24 * time.Hour
	InviteTTL  = 7 * 24 * time.Hour
	// LocationTTL keeps the last position visible ("last seen") a while after sharing ends;
	// Firestore TTL deletes it afterwards.
	LocationTTL = time.Hour

	inviteAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no 0/O, 1/I
	inviteLength   = 8
)

// Identity is the signed-in user, from the verified ID token.
type Identity struct {
	UID   string
	Name  string
	Email string
}

type Service struct {
	store store.Store
	now   func() time.Time
}

func New(s store.Store, now func() time.Time) *Service {
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &Service{store: s, now: now}
}

// GroupSummary is one of the caller's groups.
type GroupSummary struct {
	Group        *store.Group
	Role         string
	SharingUntil *time.Time
}

// GroupDetail is a group with its members, for members only.
type GroupDetail struct {
	Group   *store.Group
	Members []*store.Member
}

// ---------------------------------------------------------------------------- profile

// Profile returns the caller's profile, creating it on first use.
func (s *Service) Profile(ctx context.Context, id Identity) (*store.User, error) {
	var out *store.User
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		u, created, err := s.loadOrNewUser(tx, id)
		if err != nil {
			return err
		}
		if created {
			if err := tx.SetUser(u); err != nil {
				return err
			}
		}
		out = u
		return nil
	})
	return out, err
}

// UpdateProfile sets the display name, also on the caller's memberships.
func (s *Service) UpdateProfile(ctx context.Context, id Identity, displayName string) (*store.User, error) {
	name, err := cleanName(displayName)
	if err != nil {
		return nil, err
	}
	var out *store.User
	err = s.store.RunTx(ctx, func(tx store.Tx) error {
		u, _, err := s.loadOrNewUser(tx, id)
		if err != nil {
			return err
		}
		members := map[string]*store.Member{} // groupID -> caller's membership
		for _, gid := range u.GroupIDs {
			m, err := tx.GetMember(gid, u.ID)
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			if err != nil {
				return err
			}
			members[gid] = m
		}
		u.DisplayName = name
		u.UpdatedAt = s.now()
		if err := tx.SetUser(u); err != nil {
			return err
		}
		for gid, m := range members {
			m.DisplayName = name
			if err := tx.SetMember(gid, m); err != nil {
				return err
			}
		}
		out = u
		return nil
	})
	return out, err
}

// DeleteAccount removes the caller from all groups (handing over or deleting groups
// they own) and deletes their profile. The sign-in account itself is deleted by the caller.
func (s *Service) DeleteAccount(ctx context.Context, uid string) error {
	var groupIDs []string
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		u, err := tx.GetUser(uid)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		groupIDs = u.GroupIDs
		return nil
	})
	if err != nil {
		return err
	}
	for _, gid := range groupIDs {
		if err := s.RemoveMember(ctx, uid, gid, uid); err != nil && !errors.Is(err, ErrNotFound) {
			return fmt.Errorf("leave group %s: %w", gid, err)
		}
	}
	return s.store.RunTx(ctx, func(tx store.Tx) error {
		return tx.DeleteUser(uid)
	})
}

// ---------------------------------------------------------------------------- groups

func (s *Service) ListGroups(ctx context.Context, uid string) ([]GroupSummary, error) {
	var out []GroupSummary
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		out = nil
		u, err := tx.GetUser(uid)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		for _, gid := range u.GroupIDs {
			g, err := tx.GetGroup(gid)
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			if err != nil {
				return err
			}
			m, err := tx.GetMember(gid, uid)
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			if err != nil {
				return err
			}
			sum := GroupSummary{Group: g, Role: m.Role}
			if m.Sharing(s.now()) {
				sum.SharingUntil = m.SharingUntil
			}
			out = append(out, sum)
		}
		return nil
	})
	return out, err
}

func (s *Service) CreateGroup(ctx context.Context, id Identity, name string) (*store.Group, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, err
	}
	gid := s.store.NewID()
	var out *store.Group
	err = s.store.RunTx(ctx, func(tx store.Tx) error {
		u, _, err := s.loadOrNewUser(tx, id)
		if err != nil {
			return err
		}
		if len(u.GroupIDs) >= MaxGroupsPerUser {
			return fmt.Errorf("%w: at most %d groups", ErrLimit, MaxGroupsPerUser)
		}
		now := s.now()
		g := &store.Group{ID: gid, Name: name, OwnerID: u.ID, CreatedAt: now}
		u.GroupIDs = append(u.GroupIDs, gid)
		u.UpdatedAt = now
		if err := tx.SetGroup(g); err != nil {
			return err
		}
		owner := &store.Member{UserID: u.ID, DisplayName: u.DisplayName, Role: store.RoleOwner, JoinedAt: now}
		if err := tx.SetMember(gid, owner); err != nil {
			return err
		}
		if err := tx.SetUser(u); err != nil {
			return err
		}
		out = g
		return nil
	})
	return out, err
}

func (s *Service) GetGroup(ctx context.Context, uid, gid string) (*GroupDetail, error) {
	var out *GroupDetail
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		g, err := getGroup(tx, gid)
		if err != nil {
			return err
		}
		if _, err := requireMember(tx, gid, uid); err != nil {
			return err
		}
		members, err := tx.ListMembers(gid)
		if err != nil {
			return err
		}
		slices.SortFunc(members, func(a, b *store.Member) int { return a.JoinedAt.Compare(b.JoinedAt) })
		out = &GroupDetail{Group: g, Members: members}
		return nil
	})
	return out, err
}

// DeleteGroup deletes a group with its members and positions. Owner only.
func (s *Service) DeleteGroup(ctx context.Context, uid, gid string) error {
	return s.store.RunTx(ctx, func(tx store.Tx) error {
		g, err := getGroup(tx, gid)
		if err != nil {
			return err
		}
		if g.OwnerID != uid {
			if _, err := requireMember(tx, gid, uid); err != nil {
				return err
			}
			return fmt.Errorf("%w: only the owner can delete the group", ErrForbidden)
		}
		return deleteGroupTx(tx, g)
	})
}

// RemoveMember removes target from the group: actor leaving (actor == target) or the
// owner removing someone. An owner who leaves hands the group to the longest-standing
// member; the last member leaving deletes the group.
func (s *Service) RemoveMember(ctx context.Context, actor, gid, target string) error {
	return s.store.RunTx(ctx, func(tx store.Tx) error {
		g, err := getGroup(tx, gid)
		if err != nil {
			return err
		}
		if _, err := requireMember(tx, gid, actor); err != nil {
			return err
		}
		if actor != target && g.OwnerID != actor {
			return fmt.Errorf("%w: only the owner can remove members", ErrForbidden)
		}
		if _, err := tx.GetMember(gid, target); errors.Is(err, store.ErrNotFound) {
			return ErrNotFound
		} else if err != nil {
			return err
		}
		members, err := tx.ListMembers(gid)
		if err != nil {
			return err
		}
		var rest []*store.Member
		for _, m := range members {
			if m.UserID != target {
				rest = append(rest, m)
			}
		}
		if len(rest) == 0 {
			return deleteGroupTx(tx, g)
		}
		targetUser, err := tx.GetUser(target)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return err
		}

		// Writes.
		if err := tx.DeleteMember(gid, target); err != nil {
			return err
		}
		if err := tx.DeleteLocation(gid, target); err != nil {
			return err
		}
		if targetUser != nil {
			targetUser.GroupIDs = slices.DeleteFunc(targetUser.GroupIDs, func(id string) bool { return id == gid })
			targetUser.UpdatedAt = s.now()
			if err := tx.SetUser(targetUser); err != nil {
				return err
			}
		}
		if g.OwnerID == target {
			slices.SortFunc(rest, func(a, b *store.Member) int { return a.JoinedAt.Compare(b.JoinedAt) })
			heir := rest[0]
			heir.Role = store.RoleOwner
			g.OwnerID = heir.UserID
			if err := tx.SetMember(gid, heir); err != nil {
				return err
			}
			if err := tx.SetGroup(g); err != nil {
				return err
			}
		}
		return nil
	})
}

// ---------------------------------------------------------------------------- invites

// CreateInvite makes a join code for the group. Any member can invite.
func (s *Service) CreateInvite(ctx context.Context, uid, gid string) (*store.Invite, error) {
	codes := make([]string, 5)
	for i := range codes {
		c, err := newInviteCode()
		if err != nil {
			return nil, err
		}
		codes[i] = c
	}
	var out *store.Invite
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		if _, err := getGroup(tx, gid); err != nil {
			return err
		}
		if _, err := requireMember(tx, gid, uid); err != nil {
			return err
		}
		code := ""
		for _, c := range codes {
			_, err := tx.GetInvite(c)
			if errors.Is(err, store.ErrNotFound) {
				code = c
				break
			}
			if err != nil {
				return err
			}
		}
		if code == "" {
			return errors.New("could not generate a unique invite code")
		}
		now := s.now()
		inv := &store.Invite{Code: code, GroupID: gid, CreatedBy: uid, CreatedAt: now, ExpiresAt: now.Add(InviteTTL)}
		if err := tx.SetInvite(inv); err != nil {
			return err
		}
		out = inv
		return nil
	})
	return out, err
}

// JoinByInvite adds the caller to the invite's group. Joining twice is harmless.
func (s *Service) JoinByInvite(ctx context.Context, id Identity, code string) (*store.Group, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) != inviteLength {
		return nil, fmt.Errorf("%w: invite code", ErrInvalid)
	}
	var out *store.Group
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		inv, err := tx.GetInvite(code)
		if errors.Is(err, store.ErrNotFound) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if !inv.ExpiresAt.After(s.now()) {
			return ErrNotFound // TTL deletion may lag; treat expired codes as gone
		}
		g, err := getGroup(tx, inv.GroupID)
		if err != nil {
			return err
		}
		if _, err := tx.GetMember(g.ID, id.UID); err == nil {
			out = g
			return nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		members, err := tx.ListMembers(g.ID)
		if err != nil {
			return err
		}
		if len(members) >= MaxMembers {
			return fmt.Errorf("%w: group is full (%d members)", ErrLimit, MaxMembers)
		}
		u, _, err := s.loadOrNewUser(tx, id)
		if err != nil {
			return err
		}
		if len(u.GroupIDs) >= MaxGroupsPerUser {
			return fmt.Errorf("%w: at most %d groups", ErrLimit, MaxGroupsPerUser)
		}
		now := s.now()
		m := &store.Member{UserID: u.ID, DisplayName: u.DisplayName, Role: store.RoleMember, JoinedAt: now}
		u.GroupIDs = append(u.GroupIDs, g.ID)
		u.UpdatedAt = now
		if err := tx.SetMember(g.ID, m); err != nil {
			return err
		}
		if err := tx.SetUser(u); err != nil {
			return err
		}
		out = g
		return nil
	})
	return out, err
}

// ---------------------------------------------------------------------------- sharing

// SetSharing starts sharing in a group until the given time (capped to MaxSharing), or
// stops it when until is nil or not in the future. Stopping removes the shared position.
// Returns the effective end time, nil when stopped.
func (s *Service) SetSharing(ctx context.Context, uid, gid string, until *time.Time) (*time.Time, error) {
	now := s.now()
	var effective *time.Time
	if until != nil && until.After(now) {
		t := *until
		if limit := now.Add(MaxSharing); t.After(limit) {
			t = limit
		}
		t = t.UTC()
		effective = &t
	}
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		if _, err := getGroup(tx, gid); err != nil {
			return err
		}
		m, err := requireMember(tx, gid, uid)
		if err != nil {
			return err
		}
		m.SharingUntil = effective
		if err := tx.SetMember(gid, m); err != nil {
			return err
		}
		if effective == nil {
			return tx.DeleteLocation(gid, uid)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return effective, nil
}

// LocationUpdate is one position report from the phone.
type LocationUpdate struct {
	Lat, Lon   float64
	Accuracy   float64
	Heading    *float64
	Speed      *float64
	RecordedAt time.Time
}

func (l LocationUpdate) validate(now time.Time) error {
	switch {
	case l.Lat < -90 || l.Lat > 90 || l.Lon < -180 || l.Lon > 180:
		return fmt.Errorf("%w: coordinates out of range", ErrInvalid)
	case l.Accuracy < 0 || l.Accuracy > 1000:
		return fmt.Errorf("%w: accuracy must be 0-1000 m", ErrInvalid)
	case l.Heading != nil && (*l.Heading < 0 || *l.Heading >= 360):
		return fmt.Errorf("%w: heading must be 0-360", ErrInvalid)
	case l.Speed != nil && (*l.Speed < 0 || *l.Speed > 100):
		return fmt.Errorf("%w: speed must be 0-100 m/s", ErrInvalid)
	case l.RecordedAt.Before(now.Add(-10 * time.Minute)):
		return fmt.Errorf("%w: position is older than 10 minutes", ErrInvalid)
	case l.RecordedAt.After(now.Add(time.Minute)):
		return fmt.Errorf("%w: position is in the future", ErrInvalid)
	}
	return nil
}

// UpdateLocation stores the caller's position in every group where they are sharing
// and returns those group ids.
func (s *Service) UpdateLocation(ctx context.Context, uid string, upd LocationUpdate) ([]string, error) {
	now := s.now()
	if upd.RecordedAt.IsZero() {
		upd.RecordedAt = now
	}
	if err := upd.validate(now); err != nil {
		return nil, err
	}
	var shared []string
	err := s.store.RunTx(ctx, func(tx store.Tx) error {
		shared = nil
		u, err := tx.GetUser(uid)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		var sharing []*store.Member
		var gids []string
		for _, gid := range u.GroupIDs {
			m, err := tx.GetMember(gid, uid)
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			if err != nil {
				return err
			}
			if m.Sharing(now) {
				sharing = append(sharing, m)
				gids = append(gids, gid)
			}
		}
		for i, m := range sharing {
			loc := &store.Location{
				UserID:       uid,
				DisplayName:  m.DisplayName,
				Lat:          upd.Lat,
				Lon:          upd.Lon,
				Accuracy:     upd.Accuracy,
				Heading:      upd.Heading,
				Speed:        upd.Speed,
				RecordedAt:   upd.RecordedAt.UTC(),
				UpdatedAt:    now,
				SharingUntil: *m.SharingUntil,
				ExpireAt:     m.SharingUntil.Add(LocationTTL),
			}
			if err := tx.SetLocation(gids[i], loc); err != nil {
				return err
			}
		}
		shared = gids
		return nil
	})
	return shared, err
}

// ---------------------------------------------------------------------------- helpers

// loadOrNewUser reads the caller's profile or builds a new one (not yet written).
func (s *Service) loadOrNewUser(tx store.Tx, id Identity) (*store.User, bool, error) {
	u, err := tx.GetUser(id.UID)
	if err == nil {
		return u, false, nil
	}
	if !errors.Is(err, store.ErrNotFound) {
		return nil, false, err
	}
	now := s.now()
	name := defaultName(id)
	return &store.User{ID: id.UID, DisplayName: name, Email: id.Email, GroupIDs: []string{}, CreatedAt: now, UpdatedAt: now}, true, nil
}

func getGroup(tx store.Tx, gid string) (*store.Group, error) {
	g, err := tx.GetGroup(gid)
	if errors.Is(err, store.ErrNotFound) {
		return nil, ErrNotFound
	}
	return g, err
}

// requireMember returns ErrNotFound for non-members, so group ids can't be probed.
func requireMember(tx store.Tx, gid, uid string) (*store.Member, error) {
	m, err := tx.GetMember(gid, uid)
	if errors.Is(err, store.ErrNotFound) {
		return nil, ErrNotFound
	}
	return m, err
}

func deleteGroupTx(tx store.Tx, g *store.Group) error {
	members, err := tx.ListMembers(g.ID)
	if err != nil {
		return err
	}
	locations, err := tx.ListLocations(g.ID)
	if err != nil {
		return err
	}
	var users []*store.User
	for _, m := range members {
		u, err := tx.GetUser(m.UserID)
		if errors.Is(err, store.ErrNotFound) {
			continue
		}
		if err != nil {
			return err
		}
		users = append(users, u)
	}
	for _, u := range users {
		u.GroupIDs = slices.DeleteFunc(u.GroupIDs, func(id string) bool { return id == g.ID })
		if err := tx.SetUser(u); err != nil {
			return err
		}
	}
	for _, m := range members {
		if err := tx.DeleteMember(g.ID, m.UserID); err != nil {
			return err
		}
	}
	for _, l := range locations {
		if err := tx.DeleteLocation(g.ID, l.UserID); err != nil {
			return err
		}
	}
	return tx.DeleteGroup(g.ID)
}

func cleanName(s string) (string, error) {
	s = strings.Join(strings.Fields(s), " ")
	if s == "" || utf8.RuneCountInString(s) > MaxNameLength {
		return "", fmt.Errorf("%w: name must be 1-%d characters", ErrInvalid, MaxNameLength)
	}
	return s, nil
}

func defaultName(id Identity) string {
	if n, err := cleanName(id.Name); err == nil {
		return n
	}
	if local, _, ok := strings.Cut(id.Email, "@"); ok && local != "" {
		if n, err := cleanName(local); err == nil {
			return n
		}
	}
	return "Metsästäjä"
}

func newInviteCode() (string, error) {
	b := make([]byte, inviteLength)
	max := big.NewInt(int64(len(inviteAlphabet)))
	for i := range b {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		b[i] = inviteAlphabet[n.Int64()]
	}
	return string(b), nil
}
