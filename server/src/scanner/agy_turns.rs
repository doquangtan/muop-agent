use super::*;

#[derive(Clone)]
pub(super) struct CachedTranscript {
    pub(super) modified: DateTime<Utc>,
    pub(super) len: u64,
    pub(super) parsed: std::sync::Arc<ParsedTranscript>,
}

pub(super) static TRANSCRIPT_CACHE: OnceLock<Mutex<HashMap<String, CachedTranscript>>> =
    OnceLock::new();

pub(super) fn get_transcript_cache() -> &'static Mutex<HashMap<String, CachedTranscript>> {
    TRANSCRIPT_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Ghi model đã dùng cho một lượt agy. Transcript của agy không lưu model nên server tự ghi nhận
/// vào SQLite (xem `store`).
pub fn record_agy_turn_model(conversation_id: &str, started_at: &str, model: &str) {
    crate::infra::store::record_agy_turn_model(conversation_id, started_at, model);
}

pub(super) fn load_agy_turn_models(conversation_id: &str) -> Vec<(DateTime<Utc>, String)> {
    let mut turns: Vec<(DateTime<Utc>, String)> =
        crate::infra::store::agy_turn_models(conversation_id)
            .into_iter()
            .filter_map(|(started, model)| {
                let started = DateTime::parse_from_rfc3339(&started)
                    .ok()?
                    .with_timezone(&Utc);
                Some((started, model))
            })
            .collect();
    turns.sort_by_key(|(started, _)| *started);
    turns
}

#[cfg(test)]
mod agy_model_tests {
    use super::parse_agy_models;

    #[test]
    fn parses_tab_separated_model_list_and_skips_noise() {
        let output = "Fetching available models...\n\
            gemini-4-argon-medium\tGemini 4 Argon (Medium)\n\
            claude-opus-5-5-high\tClaude Opus 5.5 (High)\n\
            \n\
            bad id with space\tX\n";
        let parsed: Vec<(String, String)> = parse_agy_models(output)
            .into_iter()
            .map(|m| (m.id, m.label))
            .collect();
        assert_eq!(
            parsed,
            vec![
                (
                    "agy:gemini-4-argon-medium".to_string(),
                    "Gemini 4 Argon (Medium)".to_string()
                ),
                (
                    "agy:claude-opus-5-5-high".to_string(),
                    "Claude Opus 5.5 (High)".to_string()
                ),
            ]
        );
    }
}

pub(super) fn agy_turn_model_at(turns: &[(DateTime<Utc>, String)], at: DateTime<Utc>) -> String {
    // Step được làm tròn theo giây nên cho phép lệch 1 giây khi so với thời điểm bắt đầu lượt
    turns
        .iter()
        .rev()
        .find(|(started, _)| *started <= at + chrono::Duration::seconds(1))
        .map(|(_, model)| model.clone())
        .unwrap_or_default()
}
