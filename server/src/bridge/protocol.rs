//! Giao thức Socket.IO v4 ở mức tối thiểu cho bridge (chỉ WebSocket, namespace `/`).
//!
//! Gói engine.io/socket.io là chuỗi văn bản:
//! - `2` ping (server gửi), phải trả `3`
//! - `41` server ngắt kết nối
//! - `42[name, data]` sự kiện
//! - `42<id>[name, data]` client yêu cầu ack (client gửi)
//! - `43<id>[data...]` ack trả về cho yêu cầu có id

use serde_json::Value;

#[derive(Debug, PartialEq)]
pub enum Packet {
    /// Ping từ server: phải trả lời `3`
    Ping,
    /// Sự kiện `42[name, data]`
    Event { name: String, data: Value },
    /// Ack `43<id>[data]`: đối số đầu tiên là giá trị trả về
    Ack { id: u64, data: Value },
    /// Server ngắt kết nối (`41`)
    Disconnect,
    /// Gói không dùng tới (open, connect ack, pong, sự kiện có yêu cầu ack từ server...)
    Other,
}

pub fn parse(text: &str) -> Result<Packet, String> {
    if text == "2" {
        return Ok(Packet::Ping);
    }
    if text == "41" {
        return Ok(Packet::Disconnect);
    }
    if let Some(rest) = text.strip_prefix("42") {
        // "42<id>[...]" là sự kiện kèm yêu cầu ack từ server: chưa dùng tới
        if !rest.starts_with('[') {
            return Ok(Packet::Other);
        }
        let args = parse_args(rest)?;
        let name = args
            .first()
            .and_then(Value::as_str)
            .ok_or_else(|| "sự kiện thiếu tên".to_string())?
            .to_string();
        let data = args.get(1).cloned().unwrap_or(Value::Null);
        return Ok(Packet::Event { name, data });
    }
    if let Some(rest) = text.strip_prefix("43") {
        let digits_len = rest.bytes().take_while(u8::is_ascii_digit).count();
        let id: u64 = rest[..digits_len]
            .parse()
            .map_err(|_| "ack thiếu id".to_string())?;
        let args = parse_args(&rest[digits_len..])?;
        let data = args.into_iter().next().unwrap_or(Value::Null);
        return Ok(Packet::Ack { id, data });
    }
    Ok(Packet::Other)
}

fn parse_args(json: &str) -> Result<Vec<Value>, String> {
    serde_json::from_str::<Vec<Value>>(json).map_err(|e| format!("JSON gói tin không hợp lệ: {e}"))
}

/// Mã hoá một sự kiện gửi đi. `ack_id` có giá trị thì server sẽ trả `43<id>[...]`.
pub fn encode_event(name: &str, payload: &Value, ack_id: Option<u64>) -> String {
    let body = serde_json::json!([name, payload]).to_string();
    match ack_id {
        Some(id) => format!("42{id}{body}"),
        None => format!("42{body}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_ping_and_disconnect() {
        assert_eq!(parse("2").unwrap(), Packet::Ping);
        assert_eq!(parse("41").unwrap(), Packet::Disconnect);
    }

    #[test]
    fn parses_event_with_payload() {
        let p = parse(r#"42["meta:update",{"port":8787}]"#).unwrap();
        assert_eq!(
            p,
            Packet::Event {
                name: "meta:update".into(),
                data: json!({"port": 8787}),
            }
        );
    }

    #[test]
    fn event_without_payload_gets_null() {
        let p = parse(r#"42["retry:update"]"#).unwrap();
        assert_eq!(
            p,
            Packet::Event {
                name: "retry:update".into(),
                data: Value::Null,
            }
        );
    }

    #[test]
    fn parses_ack_and_takes_first_argument() {
        let p = parse(r#"4312[{"ok":true,"conversationId":"c1"}]"#).unwrap();
        assert_eq!(
            p,
            Packet::Ack {
                id: 12,
                data: json!({"ok": true, "conversationId": "c1"}),
            }
        );
    }

    #[test]
    fn open_and_connect_packets_are_ignored() {
        assert_eq!(parse(r#"0{"sid":"abc"}"#).unwrap(), Packet::Other);
        assert_eq!(parse(r#"40{"sid":"abc"}"#).unwrap(), Packet::Other);
        assert_eq!(parse(r#"42/ns,["x",1]"#).unwrap(), Packet::Other);
    }

    #[test]
    fn broken_json_is_an_error() {
        assert!(parse(r#"42["chat:stream",{"#).is_err());
    }

    #[test]
    fn encodes_event_with_and_without_ack() {
        assert_eq!(
            encode_event("chat:send", &json!({"a": 1}), Some(3)),
            r#"423["chat:send",{"a":1}]"#
        );
        assert_eq!(
            encode_event("request-meta", &Value::Null, None),
            r#"42["request-meta",null]"#
        );
    }
}
