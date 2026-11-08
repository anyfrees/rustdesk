pub(crate) fn outgoing() -> bool {
    #[cfg(all(windows, feature = "flutter"))]
    { std::env::args().nth(1).as_deref() == Some("--nnu-voice-call") }
    #[cfg(not(all(windows, feature = "flutter")))]
    { false }
}
