// Package store persists hunters-map data. Firestore layout (database "hunters-map"):
//
//	users/{uid}                     profile and the ids of the groups the user belongs to
//	groups/{gid}                    hunting party (seurue)
//	groups/{gid}/members/{uid}      membership, role and sharing state
//	groups/{gid}/locations/{uid}    latest shared position; phones listen to this collection
//	groups/{gid}/tracks/{uid}       the last hour of shared positions, for trails
//	invites/{code}                  invite codes; expire via TTL on expiresAt
//
// All business rules live in package service; a Store only offers transactions with
// Firestore semantics: every read must happen before the first write.
package store

import (
	"context"
	"errors"
	"time"
)

var (
	ErrNotFound = errors.New("not found")
	// ErrReadAfterWrite mirrors Firestore, which rejects reads after a write in a transaction.
	ErrReadAfterWrite = errors.New("read after write in transaction")
)

const (
	RoleOwner  = "owner"
	RoleMember = "member"
)

type User struct {
	ID          string    `firestore:"-"`
	DisplayName string    `firestore:"displayName"`
	Email       string    `firestore:"email"`
	GroupIDs    []string  `firestore:"groupIds"`
	CreatedAt   time.Time `firestore:"createdAt"`
	UpdatedAt   time.Time `firestore:"updatedAt"`
}

type Group struct {
	ID        string    `firestore:"-"`
	Name      string    `firestore:"name"`
	OwnerID   string    `firestore:"ownerId"`
	CreatedAt time.Time `firestore:"createdAt"`
}

type Member struct {
	UserID       string     `firestore:"-"`
	DisplayName  string     `firestore:"displayName"`
	Role         string     `firestore:"role"`
	JoinedAt     time.Time  `firestore:"joinedAt"`
	SharingUntil *time.Time `firestore:"sharingUntil"` // nil = not sharing
}

// Sharing reports whether the member shares their location at time now.
func (m *Member) Sharing(now time.Time) bool {
	return m.SharingUntil != nil && m.SharingUntil.After(now)
}

type Invite struct {
	Code      string    `firestore:"-"`
	GroupID   string    `firestore:"groupId"`
	CreatedBy string    `firestore:"createdBy"`
	CreatedAt time.Time `firestore:"createdAt"`
	ExpiresAt time.Time `firestore:"expiresAt"` // TTL field
}

type Location struct {
	UserID       string    `firestore:"-"`
	DisplayName  string    `firestore:"displayName"`
	Lat          float64   `firestore:"lat"`
	Lon          float64   `firestore:"lon"`
	Accuracy     float64   `firestore:"accuracy"`
	Heading      *float64  `firestore:"heading"`
	Speed        *float64  `firestore:"speed"`
	RecordedAt   time.Time `firestore:"recordedAt"`
	UpdatedAt    time.Time `firestore:"updatedAt"`
	SharingUntil time.Time `firestore:"sharingUntil"` // clients hide the position after this
	ExpireAt     time.Time `firestore:"expireAt"`     // TTL field
}

// TrackPoint is one point of a shared track.
type TrackPoint struct {
	Lat float64   `firestore:"lat"`
	Lon float64   `firestore:"lon"`
	T   time.Time `firestore:"t"`
}

// Track holds a member's recent shared positions in a group, oldest first.
type Track struct {
	UserID    string       `firestore:"-"`
	Points    []TrackPoint `firestore:"points"`
	UpdatedAt time.Time    `firestore:"updatedAt"`
	ExpireAt  time.Time    `firestore:"expireAt"` // TTL field
}

// Store runs transactions. fn may be retried, so it must not have side effects
// outside the transaction.
type Store interface {
	RunTx(ctx context.Context, fn func(Tx) error) error
	NewID() string
}

// Tx is one transaction. Getters return ErrNotFound for missing documents.
type Tx interface {
	GetUser(id string) (*User, error)
	GetGroup(id string) (*Group, error)
	GetMember(groupID, userID string) (*Member, error)
	ListMembers(groupID string) ([]*Member, error)
	ListLocations(groupID string) ([]*Location, error)
	GetTrack(groupID, userID string) (*Track, error)
	ListTracks(groupID string) ([]*Track, error)
	GetInvite(code string) (*Invite, error)

	SetUser(u *User) error
	DeleteUser(id string) error
	SetGroup(g *Group) error
	DeleteGroup(id string) error
	SetMember(groupID string, m *Member) error
	DeleteMember(groupID, userID string) error
	SetInvite(inv *Invite) error
	SetLocation(groupID string, loc *Location) error
	DeleteLocation(groupID, userID string) error
	SetTrack(groupID string, t *Track) error
	DeleteTrack(groupID, userID string) error
}
