use super::*;

/// Quét các Artifact / Kế hoạch (Plan) đang yêu cầu phê duyệt trong thư mục brain của phiên hội thoại
pub fn scan_pending_plans(session_id: &str) -> Vec<PlanArtifactInfo> {
    let mut plans = Vec::new();
    let brain_dir = Path::new(BRAIN_DIR_PATH).join(session_id);
    if !brain_dir.exists() || !brain_dir.is_dir() {
        return plans;
    }

    if let Ok(entries) = fs::read_dir(&brain_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.ends_with(".metadata.json") {
                    let artifact_name = name.trim_end_matches(".metadata.json").to_string();
                    let artifact_path = brain_dir.join(&artifact_name);
                    if artifact_path.exists() && artifact_path.is_file() {
                        let mut summary = String::new();
                        let mut updated_at = String::new();
                        let mut req_feedback = false;

                        if let Ok(meta_content) = fs::read_to_string(&path) {
                            if let Ok(val) =
                                serde_json::from_str::<serde_json::Value>(&meta_content)
                            {
                                summary = val
                                    .get("summary")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                updated_at = val
                                    .get("updatedAt")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                req_feedback = val
                                    .get("requestFeedback")
                                    .and_then(|v| v.as_bool())
                                    .unwrap_or(false);
                            }
                        }

                        let content = fs::read_to_string(&artifact_path).unwrap_or_default();
                        let title = content
                            .lines()
                            .find(|l| l.starts_with("# "))
                            .map(|l| l.trim_start_matches("# ").trim().to_string())
                            .unwrap_or_else(|| artifact_name.clone());

                        plans.push(PlanArtifactInfo {
                            file_name: artifact_name,
                            file_path: artifact_path.to_string_lossy().to_string(),
                            title,
                            summary,
                            updated_at,
                            request_feedback: req_feedback,
                            content,
                        });
                    }
                }
            }
        }
    }
    plans.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    plans
}
