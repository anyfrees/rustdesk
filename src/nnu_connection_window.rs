pub fn hidden(approve_mode: &str, allow_hide: bool) -> bool {
    approve_mode == "password" && allow_hide
}

#[cfg(test)]
mod tests {
    #[test]
    fn password_approval_can_hide_the_window_without_requiring_a_password_type() {
        assert!(super::hidden("password", true));
        assert!(!super::hidden("password", false));
        assert!(!super::hidden("click", true));
        assert!(!super::hidden("", true));
    }
}
