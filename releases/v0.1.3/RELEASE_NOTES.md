# Birdwatch 0.1.3

A maintenance release. Nothing changes on screen.

## Under the hood

- Updated to [swift-stats](https://github.com/awizemann/swift-stats) 0.2.0, the library behind the anonymous usage counts introduced in 0.1.2. What that means for you: under Low Data Mode nothing is sent at all (events wait until the mode lifts), network timeouts are tighter, the on-disk queue is cheaper to maintain, and a couple of rare edge cases — turning usage sharing off at the exact moment a batch was leaving — are handled cleanly.
- Usage events are now handed to the library synchronously, so nothing in the interface ever waits on the analytics queue.

What is and isn't collected is unchanged — see the [privacy policy](https://awizemann.github.io/birdwatch/privacy.html). The switch is still in Diagnostics → *Share anonymous usage*.

Source and issue tracker: https://github.com/awizemann/birdwatch
