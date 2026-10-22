package store

import (
	"context"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Firestore is the production Store.
type Firestore struct {
	client *firestore.Client
}

func NewFirestore(client *firestore.Client) *Firestore {
	return &Firestore{client: client}
}

func (f *Firestore) NewID() string {
	return f.client.Collection("groups").NewDoc().ID
}

func (f *Firestore) RunTx(ctx context.Context, fn func(Tx) error) error {
	return f.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		return fn(&fsTx{c: f.client, tx: tx})
	})
}

type fsTx struct {
	c  *firestore.Client
	tx *firestore.Transaction
}

func (t *fsTx) users() *firestore.CollectionRef   { return t.c.Collection("users") }
func (t *fsTx) groups() *firestore.CollectionRef  { return t.c.Collection("groups") }
func (t *fsTx) invites() *firestore.CollectionRef { return t.c.Collection("invites") }
func (t *fsTx) members(gid string) *firestore.CollectionRef {
	return t.groups().Doc(gid).Collection("members")
}
func (t *fsTx) locations(gid string) *firestore.CollectionRef {
	return t.groups().Doc(gid).Collection("locations")
}

// get reads one document into dst and maps a missing document to ErrNotFound.
func (t *fsTx) get(ref *firestore.DocumentRef, dst any) error {
	snap, err := t.tx.Get(ref)
	if status.Code(err) == codes.NotFound {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	return snap.DataTo(dst)
}

func (t *fsTx) GetUser(id string) (*User, error) {
	var u User
	if err := t.get(t.users().Doc(id), &u); err != nil {
		return nil, err
	}
	u.ID = id
	return &u, nil
}

func (t *fsTx) GetGroup(id string) (*Group, error) {
	var g Group
	if err := t.get(t.groups().Doc(id), &g); err != nil {
		return nil, err
	}
	g.ID = id
	return &g, nil
}

func (t *fsTx) GetMember(groupID, userID string) (*Member, error) {
	var m Member
	if err := t.get(t.members(groupID).Doc(userID), &m); err != nil {
		return nil, err
	}
	m.UserID = userID
	return &m, nil
}

func (t *fsTx) ListMembers(groupID string) ([]*Member, error) {
	snaps, err := t.tx.Documents(t.members(groupID)).GetAll()
	if err != nil {
		return nil, err
	}
	out := make([]*Member, 0, len(snaps))
	for _, s := range snaps {
		var m Member
		if err := s.DataTo(&m); err != nil {
			return nil, err
		}
		m.UserID = s.Ref.ID
		out = append(out, &m)
	}
	return out, nil
}

func (t *fsTx) ListLocations(groupID string) ([]*Location, error) {
	snaps, err := t.tx.Documents(t.locations(groupID)).GetAll()
	if err != nil {
		return nil, err
	}
	out := make([]*Location, 0, len(snaps))
	for _, s := range snaps {
		var l Location
		if err := s.DataTo(&l); err != nil {
			return nil, err
		}
		l.UserID = s.Ref.ID
		out = append(out, &l)
	}
	return out, nil
}

func (t *fsTx) GetInvite(code string) (*Invite, error) {
	var inv Invite
	if err := t.get(t.invites().Doc(code), &inv); err != nil {
		return nil, err
	}
	inv.Code = code
	return &inv, nil
}

func (t *fsTx) SetUser(u *User) error   { return t.tx.Set(t.users().Doc(u.ID), u) }
func (t *fsTx) DeleteUser(id string) error { return t.tx.Delete(t.users().Doc(id)) }
func (t *fsTx) SetGroup(g *Group) error { return t.tx.Set(t.groups().Doc(g.ID), g) }
func (t *fsTx) DeleteGroup(id string) error {
	return t.tx.Delete(t.groups().Doc(id))
}
func (t *fsTx) SetMember(groupID string, m *Member) error {
	return t.tx.Set(t.members(groupID).Doc(m.UserID), m)
}
func (t *fsTx) DeleteMember(groupID, userID string) error {
	return t.tx.Delete(t.members(groupID).Doc(userID))
}
func (t *fsTx) SetInvite(inv *Invite) error {
	return t.tx.Set(t.invites().Doc(inv.Code), inv)
}
func (t *fsTx) SetLocation(groupID string, loc *Location) error {
	return t.tx.Set(t.locations(groupID).Doc(loc.UserID), loc)
}
func (t *fsTx) DeleteLocation(groupID, userID string) error {
	return t.tx.Delete(t.locations(groupID).Doc(userID))
}
