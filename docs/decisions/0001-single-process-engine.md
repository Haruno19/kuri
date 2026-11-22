# 0001. One app, with the engine in-process behind an event stream

Status: accepted

## Context
Kuri should feel like a native Mac app: one thing to install, running in the background, no services to manage. It also needs, eventually, to serve an iOS client.

## Decision
Kuri is a single app. Everything that isn't UI is the `KuriKit` package, and its facade is the `Engine` actor. The app calls `Engine` methods and observes `Engine.events()`, an `AsyncStream` that any number of subscribers can listen to. There's no local server between the UI and the engine.

## Consequences
- Nothing to deploy or keep running separately; quitting Kuri stops everything.
- The UI is a client of the event stream like any other. A future network server (for the iOS client) subscribes to the same events and forwards them, without the local UI going through HTTP.
- The package must never import SwiftUI, and the engine must publish an event for anything a UI would need to know.
