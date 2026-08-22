# SwiftUI/AppKit bridging

Scope: rules for hosting SwiftUI content inside AppKit view controllers, and
for the async-closure/task pitfalls that show up most often at this
boundary. For actor/concurrency invariants that aren't specific to this
boundary, see `concurrency-invariants.md`.

---

## Key invariants

9. Full-pane `NSHostingView` instances whose frame is controlled by an external Auto Layout constraint (full-pane, sidebar fill, split-view pane) must set `sizingOptions = []`. `NSHostingView` instances in intrinsic-size contexts (preferences windows, popups, sheets) must not set it.

18. Do not invoke an `async` closure as a bare trailing argument (`someInit(x: { ... await ... }())`). The closure literal becomes implicitly `async` the moment its body contains `await`, and the call site needs `await` too, but nothing forces this to be visually obvious — the `await` keyword is buried inside the closure body, not next to the call. Resolve async values into a `let` on the line(s) before the call and pass the `let`.
