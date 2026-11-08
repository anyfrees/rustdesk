#[derive(Default)]
pub struct LinkHealth {
    baseline_ms: Option<u32>,
    last_sample_ms: Option<u64>,
    recent_bad: u16,
    blocked: bool,
}

impl LinkHealth {
    pub fn block_for_session(&mut self) {
        self.blocked = true;
        self.recent_bad = 0;
    }

    pub fn observe(&mut self, delay_ms: u32, elapsed_ms: u64, busy: bool) -> bool {
        let baseline = self.baseline_ms.get_or_insert(delay_ms);
        *baseline = (*baseline).min(delay_ms);
        let stale = self.last_sample_ms.map_or(false, |last| {
            elapsed_ms.saturating_sub(last) > (u64::from(delay_ms) + 2_000).max(5_000)
        });
        self.last_sample_ms = Some(elapsed_ms);
        if self.blocked || busy || elapsed_ms < 8_000 {
            self.recent_bad = 0;
            return false;
        }
        if stale {
            self.recent_bad = 0;
        }
        let bad = delay_ms >= 1_000 || delay_ms >= baseline.saturating_mul(4).max(250);
        self.recent_bad = ((self.recent_bad << 1) | u16::from(bad)) & 0x0fff;
        if self.recent_bad.count_ones() < 3 {
            return false;
        }
        self.blocked = true;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::LinkHealth;

    #[test]
    fn isolated_spikes_do_not_switch_but_repeated_stalls_switch_once() {
        let mut health = LinkHealth::default();
        for second in 0..40 {
            let delay = if second == 9 || second == 25 { 1_700 } else { 9 };
            assert!(!health.observe(delay, second * 1_000, false));
        }
        assert!(!health.observe(1_700, 40_000, false));
        assert!(!health.observe(9, 42_000, false));
        assert!(!health.observe(1_800, 43_000, false));
        assert!(!health.observe(9, 45_000, false));
        assert!(health.observe(1_600, 46_000, false));
        assert!(!health.observe(1_900, 48_000, false));

        let mut very_slow = LinkHealth::default();
        assert!(!very_slow.observe(9, 0, false));
        assert!(!very_slow.observe(6_000, 8_000, false));
        assert!(!very_slow.observe(6_000, 15_000, false));
        assert!(very_slow.observe(6_000, 22_000, false));
    }

    #[test]
    fn stable_long_distance_delay_and_busy_or_stale_samples_do_not_force_a_switch() {
        let mut stable = LinkHealth::default();
        for second in 0..20 {
            assert!(!stable.observe(300, second * 1_000, false));
        }
        let mut health = LinkHealth::default();
        assert!(!health.observe(9, 0, false));
        assert!(!health.observe(1_500, 8_000, false));
        assert!(!health.observe(1_500, 9_000, false));
        assert!(!health.observe(1_500, 15_000, false));
        assert!(!health.observe(1_500, 16_000, true));
        assert!(!health.observe(1_500, 17_000, false));
        assert!(!health.observe(1_500, 18_000, false));
        health.block_for_session();
        for second in 19..25 {
            assert!(!health.observe(1_500, second * 1_000, false));
        }
    }
}
