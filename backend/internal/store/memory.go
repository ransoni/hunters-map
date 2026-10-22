package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"sort"
	"sync"
)

// Memory is an in-memory Store for tests and local development. Like Firestore it
// rejects reads after writes and applies a transaction's writes only if fn succeeds.
type Memory struct {
	mu        sync.Mutex
	users     map[string]User
	groups    map[string]Group
	members   map[string]map[string]Member   // groupID -> userID -> member
	locations map[string]map[string]Location // groupID -> userID -> location
	tracks    map[string]map[string]Track    // groupID -> userID -> track
	invites   map[string]Invite
}

func NewMemory() *Memory {
	return &Memory{
		users:     map[string]User{},
		groups:    map[string]Group{},
		members:   map[string]map[string]Member{},
		locations: map[string]map[string]Location{},
		tracks:    map[string]map[string]Track{},
		invites:   map[string]Invite{},
	}
}

func (m *Memory) NewID() string {
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (m *Memory) RunTx(ctx context.Context, fn func(Tx) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	tx := &memTx{m: m}
	if err := fn(tx); err != nil {
		return err
	}
	for _, w := range tx.writes {
		w()
	}
	return nil
}

type memTx struct {
	m      *Memory
	writes []func()
}

func (t *memTx) read() error {
	if len(t.writes) > 0 {
		return ErrReadAfterWrite
	}
	return nil
}

func (t *memTx) GetUser(id string) (*User, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	u, ok := t.m.users[id]
	if !ok {
		return nil, ErrNotFound
	}
	u.ID = id
	u.GroupIDs = append([]string(nil), u.GroupIDs...)
	return &u, nil
}

func (t *memTx) GetGroup(id string) (*Group, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	g, ok := t.m.groups[id]
	if !ok {
		return nil, ErrNotFound
	}
	g.ID = id
	return &g, nil
}

func (t *memTx) GetMember(groupID, userID string) (*Member, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	mem, ok := t.m.members[groupID][userID]
	if !ok {
		return nil, ErrNotFound
	}
	mem.UserID = userID
	return &mem, nil
}

func (t *memTx) ListMembers(groupID string) ([]*Member, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	var out []*Member
	for id, mem := range t.m.members[groupID] {
		mem.UserID = id
		out = append(out, &mem)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UserID < out[j].UserID })
	return out, nil
}

func (t *memTx) ListLocations(groupID string) ([]*Location, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	var out []*Location
	for id, loc := range t.m.locations[groupID] {
		loc.UserID = id
		out = append(out, &loc)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UserID < out[j].UserID })
	return out, nil
}

func (t *memTx) GetTrack(groupID, userID string) (*Track, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	tr, ok := t.m.tracks[groupID][userID]
	if !ok {
		return nil, ErrNotFound
	}
	tr.UserID = userID
	tr.Points = append([]TrackPoint(nil), tr.Points...)
	return &tr, nil
}

func (t *memTx) ListTracks(groupID string) ([]*Track, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	var out []*Track
	for id, tr := range t.m.tracks[groupID] {
		tr.UserID = id
		tr.Points = append([]TrackPoint(nil), tr.Points...)
		out = append(out, &tr)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UserID < out[j].UserID })
	return out, nil
}

func (t *memTx) GetInvite(code string) (*Invite, error) {
	if err := t.read(); err != nil {
		return nil, err
	}
	inv, ok := t.m.invites[code]
	if !ok {
		return nil, ErrNotFound
	}
	inv.Code = code
	return &inv, nil
}

func (t *memTx) SetUser(u *User) error {
	v := *u
	v.GroupIDs = append([]string(nil), u.GroupIDs...)
	t.writes = append(t.writes, func() { t.m.users[v.ID] = v })
	return nil
}

func (t *memTx) DeleteUser(id string) error {
	t.writes = append(t.writes, func() { delete(t.m.users, id) })
	return nil
}

func (t *memTx) SetGroup(g *Group) error {
	v := *g
	t.writes = append(t.writes, func() { t.m.groups[v.ID] = v })
	return nil
}

func (t *memTx) DeleteGroup(id string) error {
	t.writes = append(t.writes, func() { delete(t.m.groups, id) })
	return nil
}

func (t *memTx) SetMember(groupID string, mem *Member) error {
	v := *mem
	t.writes = append(t.writes, func() {
		if t.m.members[groupID] == nil {
			t.m.members[groupID] = map[string]Member{}
		}
		t.m.members[groupID][v.UserID] = v
	})
	return nil
}

func (t *memTx) DeleteMember(groupID, userID string) error {
	t.writes = append(t.writes, func() { delete(t.m.members[groupID], userID) })
	return nil
}

func (t *memTx) SetInvite(inv *Invite) error {
	v := *inv
	t.writes = append(t.writes, func() { t.m.invites[v.Code] = v })
	return nil
}

func (t *memTx) SetLocation(groupID string, loc *Location) error {
	v := *loc
	t.writes = append(t.writes, func() {
		if t.m.locations[groupID] == nil {
			t.m.locations[groupID] = map[string]Location{}
		}
		t.m.locations[groupID][v.UserID] = v
	})
	return nil
}

func (t *memTx) DeleteLocation(groupID, userID string) error {
	t.writes = append(t.writes, func() { delete(t.m.locations[groupID], userID) })
	return nil
}

func (t *memTx) SetTrack(groupID string, tr *Track) error {
	v := *tr
	v.Points = append([]TrackPoint(nil), tr.Points...)
	t.writes = append(t.writes, func() {
		if t.m.tracks[groupID] == nil {
			t.m.tracks[groupID] = map[string]Track{}
		}
		t.m.tracks[groupID][v.UserID] = v
	})
	return nil
}

func (t *memTx) DeleteTrack(groupID, userID string) error {
	t.writes = append(t.writes, func() { delete(t.m.tracks[groupID], userID) })
	return nil
}
