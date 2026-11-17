package main

// The Windows mirror of the contract's latest-intent reconciler. It is the third
// implementation (Dart, Kotlin, Go) and must satisfy the same invariants:
// running needs runtime evidence, older revisions never move the machine, and
// close is terminal.

import "strconv"

const (
	stateIdle               = "idle"
	stateAwaitingPermission = "awaitingPermission"
	stateStarting           = "starting"
	stateRunning            = "running"
	stateStopping           = "stopping"
	stateFailed             = "failed"
	stateClosed             = "closed"
)

type intentKind string

const (
	intentStart   intentKind = "start"
	intentStop    intentKind = "stop"
	intentRestart intentKind = "restart"
	intentClose   intentKind = "close"
)

type pendingIntent struct {
	kind            intentKind
	revision        int64
	needsPermission bool
}

type stateMachine struct {
	state      string
	revision   int64
	pending    *pendingIntent
	running    bool
	permission bool // granted
	closed     bool
	results    []string
	errors     []string
}

func newStateMachine(permissionGranted bool) *stateMachine {
	return &stateMachine{state: stateIdle, permission: permissionGranted}
}

func (m *stateMachine) start(revision int64, needsPermission bool) string {
	if m.closed {
		m.errors = append(m.errors, "closed")
		return "rejected:closed"
	}
	if revision <= m.revision {
		m.errors = append(m.errors, "stale_revision")
		return "rejected:stale_revision"
	}
	m.revision = revision
	hadPending := m.pending != nil
	m.supersedePending(intentStart)
	if m.running && !hadPending {
		m.results = append(m.results, "start@"+strconv.FormatInt(revision, 10)+":applied")
		m.permission = true
		return "applied"
	}
	m.pending = &pendingIntent{kind: intentStart, revision: revision, needsPermission: needsPermission && !m.permission}
	m.state = m.derive()
	return "pending"
}

func (m *stateMachine) stop(revision int64) string {
	if m.closed {
		m.errors = append(m.errors, "closed")
		return "rejected:closed"
	}
	if revision <= m.revision {
		m.errors = append(m.errors, "stale_revision")
		return "rejected:stale_revision"
	}
	m.revision = revision
	m.supersedePending(intentStop)
	m.pending = &pendingIntent{kind: intentStop, revision: revision}
	m.state = m.derive()
	return "pending"
}

func (m *stateMachine) restart(revision int64, needsPermission bool) string {
	if m.closed {
		m.errors = append(m.errors, "closed")
		return "rejected:closed"
	}
	if revision <= m.revision {
		m.errors = append(m.errors, "stale_revision")
		return "rejected:stale_revision"
	}
	m.revision = revision
	m.supersedePending(intentRestart)
	m.pending = &pendingIntent{kind: intentRestart, revision: revision, needsPermission: needsPermission && !m.permission}
	m.state = m.derive()
	return "pending"
}

func (m *stateMachine) close(revision int64) string {
	if m.closed {
		m.errors = append(m.errors, "closed")
		return "rejected:closed"
	}
	if revision <= m.revision {
		m.errors = append(m.errors, "stale_revision")
		return "rejected:stale_revision"
	}
	m.revision = revision
	m.supersedePending(intentClose)
	m.pending = &pendingIntent{kind: intentClose, revision: revision}
	m.state = m.derive()
	return "pending"
}

// supersedePending records the outcome of an intent this one replaces. A repeat
// of the same kind is coalesced, anything else is superseded.
func (m *stateMachine) supersedePending(kind intentKind) {
	if m.pending == nil {
		return
	}
	outcome := "superseded"
	if m.pending.kind == kind && (kind == intentStart || kind == intentStop) {
		outcome = "coalesced"
	}
	m.results = append(m.results, string(m.pending.kind)+"@"+strconv.FormatInt(m.pending.revision, 10)+":"+outcome)
	m.pending = nil
}

// runtimeReport applies runtime evidence. A report stamped before the newest
// intent is dropped.
func (m *stateMachine) runtimeReport(running bool, reportRevision int64) string {
	if reportRevision != 0 && reportRevision < m.revision {
		m.errors = append(m.errors, "stale_runtime_report")
		return "dropped"
	}
	m.running = running
	if m.pending == nil {
		if running {
			m.state = stateRunning
			return "observed"
		}
		if m.state == stateRunning {
			m.fail("service.lost")
			return "observed"
		}
		m.state = m.derive()
		return "observed"
	}
	switch m.pending.kind {
	case intentStart, intentRestart:
		if running {
			m.resolve("applied")
			m.state = stateRunning
			return "applied"
		}
		if m.pending.kind == intentRestart {
			m.state = stateStarting
		}
		return "waiting"
	case intentStop:
		if !running {
			m.resolve("applied")
			m.state = stateIdle
			return "applied"
		}
		return "waiting"
	case intentClose:
		if !running {
			m.resolve("applied")
			m.state = stateClosed
			m.closed = true
			return "applied"
		}
		return "waiting"
	}
	return "waiting"
}

func (m *stateMachine) permissionReport(granted bool) string {
	m.permission = granted
	if m.pending != nil && (m.pending.kind == intentStart || m.pending.kind == intentRestart) {
		if !granted {
			m.fail("permission_denied")
			return "failed"
		}
		m.pending.needsPermission = false
		m.state = m.derive()
		return "proceed"
	}
	return "ignored"
}

func (m *stateMachine) failPending(message string) string {
	if m.pending == nil {
		return "ignored"
	}
	m.fail(message)
	return "failed"
}

func (m *stateMachine) derive() string {
	if m.closed {
		return stateClosed
	}
	if m.pending != nil {
		switch m.pending.kind {
		case intentStart:
			if m.pending.needsPermission {
				return stateAwaitingPermission
			}
			return stateStarting
		case intentRestart:
			return stateStarting
		case intentStop, intentClose:
			return stateStopping
		}
	}
	if m.running {
		return stateRunning
	}
	if m.state == stateFailed {
		return stateFailed
	}
	return stateIdle
}

func (m *stateMachine) resolve(outcome string) {
	if m.pending == nil {
		return
	}
	m.results = append(m.results, string(m.pending.kind)+"@"+strconv.FormatInt(m.pending.revision, 10)+":"+outcome)
	m.pending = nil
}

func (m *stateMachine) fail(message string) {
	m.state = stateFailed
	if m.pending != nil {
		m.results = append(m.results, string(m.pending.kind)+"@"+strconv.FormatInt(m.pending.revision, 10)+":applied")
	}
	m.pending = nil
	m.errors = append(m.errors, message)
}
