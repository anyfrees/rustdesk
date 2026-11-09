use std::sync::atomic::{AtomicI32, Ordering};

pub const QUERY: &str = "nnu-dock-active-input";
static LAST_OPERATOR: AtomicI32 = AtomicI32::new(0);

pub fn record(id: i32, authorized: bool, simulated: bool) {
    if id > 0 && authorized && simulated {
        LAST_OPERATOR.store(id, Ordering::Relaxed);
    }
}

pub fn snapshot() -> String {
    LAST_OPERATOR.load(Ordering::Relaxed).to_string()
}

#[cfg(feature = "flutter")]
pub fn publish(value: &str) {
    if let Ok(id) = value.parse::<i32>() {
        if id > 0 {
            let _ = crate::flutter::push_global_event(
                crate::flutter::APP_TYPE_CM,
                serde_json::json!({"name": "nnu_input_activity", "id": id.to_string()}).to_string(),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn only_authorized_executed_input_promotes_the_operator() {
        super::record(11, true, true);
        assert_eq!(super::snapshot(), "11");
        super::record(12, false, true);
        super::record(13, true, false);
        super::record(0, true, true);
        assert_eq!(super::snapshot(), "11");
        super::record(14, true, true);
        assert_eq!(super::snapshot(), "14");
    }
}
