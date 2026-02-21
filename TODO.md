# TODO

## High Priority

- [ ] Add first-class playback error visibility:
  - Extend playback snapshot with `last_error` (`code`, `message`, `timestamp`, `recoverable`).
  - Report failures from open/play/seek/swapchain-recreate paths into `last_error`.
  - Show error in UI with `Retry` and `Dismiss` actions.
