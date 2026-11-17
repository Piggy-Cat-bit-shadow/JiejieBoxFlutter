package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// profileStore owns profile bytes for the host. The running core reads the file,
// not this process's memory, so a service can outlive the UI.
type profileStore struct {
	dir string
}

type profileMeta struct {
	ID              string `json:"id"`
	Label           string `json:"label"`
	Kind            string `json:"kind"`
	Revision        string `json:"revision"`
	UpdatedAtMillis int64  `json:"updatedAtMillis"`
}

func newProfileStore(dir string) (*profileStore, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &profileStore{dir: dir}, nil
}

func (s *profileStore) metaPath(id string) string { return filepath.Join(s.dir, id+".meta.json") }
func (s *profileStore) bodyPath(id string) string { return filepath.Join(s.dir, id+".json") }
func (s *profileStore) backupMetaPath(id string) string {
	return filepath.Join(s.dir, id+".meta.json.bak")
}
func (s *profileStore) backupBodyPath(id string) string {
	return filepath.Join(s.dir, id+".json.bak")
}

func (s *profileStore) List() ([]profileMeta, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	out := make([]profileMeta, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		if len(entry.Name()) < len(".meta.json") || entry.Name()[len(entry.Name())-len(".meta.json"):] != ".meta.json" {
			continue
		}
		meta, err := s.readMeta(filepath.Join(s.dir, entry.Name()))
		if err != nil {
			continue
		}
		out = append(out, meta)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (s *profileStore) Read(id string) (profileMeta, []byte, error) {
	meta, err := s.readMeta(s.metaPath(id))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return profileMeta{}, nil, err
		}
		return profileMeta{}, nil, errStorageCorrupt(id)
	}
	body, err := os.ReadFile(s.bodyPath(id))
	if err != nil {
		return profileMeta{}, nil, err
	}
	return meta, body, nil
}

// Write is temp-file + fsync + rename, then the meta record. A crash leaves the
// previous revision intact, never a half-written profile.
func (s *profileStore) Write(id, label, kind string, content []byte, expectedRevision *string, validate bool) (profileMeta, error) {
	if id == "" {
		id = "p" + time.Now().UTC().Format("20060102150405.000000000")
	}
	if expectedRevision != nil {
		existing, err := s.readMeta(s.metaPath(id))
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				return profileMeta{}, err
			}
			return profileMeta{}, errRevisionMismatch
		}
		if existing.Revision != *expectedRevision {
			return profileMeta{}, errRevisionMismatch
		}
	}
	if previous, previousErr := os.ReadFile(s.bodyPath(id)); previousErr == nil {
		if metaErr := os.WriteFile(s.backupBodyPath(id), previous, 0o644); metaErr != nil {
			return profileMeta{}, errStorageWriteFailed("write restore point")
		}
		if meta, metaErr := os.ReadFile(s.metaPath(id)); metaErr == nil {
			if writeErr := os.WriteFile(s.backupMetaPath(id), meta, 0o644); writeErr != nil {
				return profileMeta{}, errStorageWriteFailed("write restore point meta")
			}
		}
	}
	temp := s.bodyPath(id) + ".tmp"
	file, err := os.OpenFile(temp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return profileMeta{}, errStorageWriteFailed("open temp body")
	}
	if _, err = file.Write(content); err != nil {
		file.Close()
		return profileMeta{}, errStorageWriteFailed("write temp body")
	}
	if err = file.Sync(); err != nil {
		file.Close()
		return profileMeta{}, errStorageWriteFailed("fsync temp body")
	}
	if err = file.Close(); err != nil {
		return profileMeta{}, errStorageWriteFailed("close temp body")
	}
	if err = os.Rename(temp, s.bodyPath(id)); err != nil {
		return profileMeta{}, errStorageWriteFailed("rename body")
	}
	sum := sha256.Sum256(content)
	meta := profileMeta{
		ID:              id,
		Label:           label,
		Kind:            kind,
		Revision:        hex.EncodeToString(sum[:]),
		UpdatedAtMillis: time.Now().UnixMilli(),
	}
	encoded, err := json.Marshal(meta)
	if err != nil {
		return profileMeta{}, errStorageWriteFailed("encode meta")
	}
	tempMeta := s.metaPath(id) + ".tmp"
	if err = os.WriteFile(tempMeta, encoded, 0o644); err != nil {
		return profileMeta{}, errStorageWriteFailed("write meta")
	}
	if err = os.Rename(tempMeta, s.metaPath(id)); err != nil {
		return profileMeta{}, errStorageWriteFailed("rename meta")
	}
	return meta, nil
}

func (s *profileStore) Delete(id string, expectedRevision *string) error {
	meta, err := s.readMeta(s.metaPath(id))
	if err != nil {
		return errInvalidArgument("no such profile " + id)
	}
	if expectedRevision != nil && meta.Revision != *expectedRevision {
		return errRevisionMismatch
	}
	if err = os.Remove(s.bodyPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errStorageWriteFailed("remove body")
	}
	if err = os.Remove(s.metaPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errStorageWriteFailed("remove meta")
	}
	return nil
}

// Restore swaps the retained previous revision back in. The current revision
// becomes the new restore point, so restore is reversible by construction.
func (s *profileStore) Restore(id, revision string) (profileMeta, error) {
	current, err := s.readMeta(s.metaPath(id))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return profileMeta{}, errInvalidArgument("no such profile " + id)
		}
		return profileMeta{}, errStorageCorrupt(id)
	}
	backup, err := s.readMeta(s.backupMetaPath(id))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return profileMeta{}, errRevisionMismatch
		}
		return profileMeta{}, errStorageCorrupt(id)
	}
	if revision != "" && backup.Revision != revision {
		return profileMeta{}, errRevisionMismatch
	}
	body, err := os.ReadFile(s.backupBodyPath(id))
	if err != nil {
		return profileMeta{}, errStorageWriteFailed("read restore point")
	}
	if renamed := os.Rename(s.bodyPath(id), s.backupBodyPath(id)); renamed != nil {
		return profileMeta{}, errStorageWriteFailed("rotate restore point")
	}
	if renamed := os.Rename(s.metaPath(id), s.backupMetaPath(id)); renamed != nil {
		return profileMeta{}, errStorageWriteFailed("rotate restore point meta")
	}
	temp := s.bodyPath(id) + ".tmp"
	if err = os.WriteFile(temp, body, 0o644); err != nil {
		return profileMeta{}, errStorageWriteFailed("write restored body")
	}
	if err = os.Rename(temp, s.bodyPath(id)); err != nil {
		return profileMeta{}, errStorageWriteFailed("rename restored body")
	}
	meta := profileMeta{
		ID:              id,
		Label:           backup.Label,
		Kind:            backup.Kind,
		Revision:        backup.Revision,
		UpdatedAtMillis: time.Now().UnixMilli(),
	}
	encoded, err := json.Marshal(meta)
	if err != nil {
		return profileMeta{}, errStorageWriteFailed("encode restored meta")
	}
	if err = os.WriteFile(s.metaPath(id), encoded, 0o644); err != nil {
		return profileMeta{}, errStorageWriteFailed("write restored meta")
	}
	_ = current
	return meta, nil
}

func (s *profileStore) readMeta(path string) (profileMeta, error) {
	var meta profileMeta
	raw, err := os.ReadFile(path)
	if err != nil {
		return meta, err
	}
	if err = json.Unmarshal(raw, &meta); err != nil {
		return meta, err
	}
	return meta, nil
}
