//! Panel SSH: danh sách máy đã lưu (thêm, sửa, xóa) và chạy một lệnh một lần trên máy đã chọn.
//! Terminal tương tác (xterm) chưa làm: cần một thành phần terminal riêng trong WebView.

use dioxus::prelude::*;

use crate::data::api;
use crate::data::models::{SshExecRequest, SshExecResponse, SshHost, SshHostSave};
use crate::store::{put, Store};

/// Kiểu xác thực bằng mật khẩu (giá trị gửi lên server)
pub const AUTH_PASSWORD: &str = "password";
/// Kiểu xác thực bằng SSH key
pub const AUTH_KEY: &str = "key";
/// Cổng mặc định khi người dùng để trống
pub const DEFAULT_PORT: u16 = 22;
/// Thời gian chờ của một lệnh (server mặc định 30 giây)
pub const EXEC_TIMEOUT_SECS: u64 = 30;

/// Nhãn kiểu xác thực hiển thị cho người dùng.
pub fn auth_label(auth_type: &str) -> &'static str {
    if auth_type == AUTH_KEY {
        "SSH key"
    } else {
        "Mật khẩu"
    }
}

/// Chuỗi địa chỉ hiển thị dưới tên máy. "Máy này" không có host để hiện, chỉ có tên user.
pub fn host_address(host: &SshHost) -> String {
    if host.builtin {
        return format!("Máy này · {}", host.username);
    }
    if host.port == DEFAULT_PORT {
        format!("{}@{}", host.username, host.host)
    } else {
        format!("{}@{}:{}", host.username, host.host, host.port)
    }
}

/// Mô tả bí mật đã lưu: để người dùng biết máy đã có mật khẩu hay key chưa.
pub fn secret_status(host: &SshHost) -> &'static str {
    let has = if host.auth_type == AUTH_KEY {
        host.has_key
    } else {
        host.has_password
    };
    if has {
        "đã lưu"
    } else {
        "chưa lưu"
    }
}

/// Máy đang chọn nếu còn trong danh sách, không thì máy đầu tiên (máy mặc định đứng đầu).
pub fn pick_host(hosts: &[SshHost], selected: Option<u64>) -> Option<u64> {
    selected
        .filter(|id| hosts.iter().any(|h| h.id == *id))
        .or_else(|| hosts.first().map(|h| h.id))
}

/// Dữ liệu form thêm/sửa máy, đã ở dạng chữ người dùng nhập.
#[derive(Debug, Clone, PartialEq)]
pub struct HostForm {
    pub id: u64,
    pub name: String,
    pub host: String,
    pub port: String,
    pub username: String,
    pub auth_type: String,
    pub password: String,
    pub private_key: String,
}

/// Kiểm tra form và tạo body lưu. Chỉ gửi bí mật của kiểu xác thực đang chọn,
/// để đổi kiểu không để lại bí mật cũ. Lỗi là câu hiển thị ngay dưới form.
pub fn build_save(form: &HostForm) -> Result<SshHostSave, String> {
    let host = form.host.trim();
    if host.is_empty() {
        return Err("Nhập địa chỉ máy (IP hoặc tên miền)".into());
    }
    let username = form.username.trim();
    if username.is_empty() {
        return Err("Nhập tên đăng nhập".into());
    }
    let port = match form.port.trim() {
        "" => DEFAULT_PORT,
        text => match text.parse::<u16>() {
            Ok(p) if p > 0 => p,
            _ => return Err("Cổng phải là số từ 1 đến 65535".into()),
        },
    };
    let name = match form.name.trim() {
        "" => format!("{username}@{host}"),
        other => other.to_string(),
    };
    let is_key = form.auth_type == AUTH_KEY;
    Ok(SshHostSave {
        id: form.id,
        name,
        host: host.to_string(),
        port,
        username: username.to_string(),
        auth_type: if is_key { AUTH_KEY } else { AUTH_PASSWORD }.to_string(),
        password: if is_key {
            String::new()
        } else {
            form.password.clone()
        },
        private_key: if is_key {
            form.private_key.clone()
        } else {
            String::new()
        },
    })
}

/// Dòng tóm tắt kết quả chạy lệnh.
pub fn exec_summary(resp: &SshExecResponse) -> String {
    match resp.exit_code {
        Some(0) => "Hoàn tất (mã thoát 0)".to_string(),
        Some(code) => format!("Lỗi (mã thoát {code})"),
        None if resp.ok => "Hoàn tất".to_string(),
        None => "Không chạy được".to_string(),
    }
}

/// Nhãn loại mật khẩu server đang hỏi (`sudo` hoặc `ssh`).
pub fn password_prompt_label(kind: &str) -> &'static str {
    if kind == "sudo" {
        "Nhập mật khẩu sudo"
    } else {
        "Nhập mật khẩu SSH"
    }
}

/// Các signal của form thêm/sửa máy. `open` = form đang hiện.
#[derive(Clone, Copy)]
struct FormSignals {
    open: Signal<bool>,
    id: Signal<u64>,
    name: Signal<String>,
    host: Signal<String>,
    port: Signal<String>,
    username: Signal<String>,
    auth_type: Signal<String>,
    password: Signal<String>,
    private_key: Signal<String>,
    error: Signal<String>,
}

fn use_form_signals() -> FormSignals {
    FormSignals {
        open: use_signal(|| false),
        id: use_signal(|| 0),
        name: use_signal(String::new),
        host: use_signal(String::new),
        port: use_signal(String::new),
        username: use_signal(String::new),
        auth_type: use_signal(|| AUTH_PASSWORD.to_string()),
        password: use_signal(String::new),
        private_key: use_signal(String::new),
        error: use_signal(String::new),
    }
}

/// Mở form: máy mới nếu `host` là None, ngược lại điền sẵn để sửa (mật khẩu/key để trống = giữ nguyên).
fn open_form(f: FormSignals, host: Option<&SshHost>) {
    put(f.error, String::new());
    put(f.password, String::new());
    put(f.private_key, String::new());
    match host {
        Some(h) => {
            put(f.id, h.id);
            put(f.name, h.name.clone());
            put(f.host, h.host.clone());
            put(f.port, h.port.to_string());
            put(f.username, h.username.clone());
            put(f.auth_type, h.auth_type.clone());
        }
        None => {
            put(f.id, 0);
            put(f.name, String::new());
            put(f.host, String::new());
            put(f.port, DEFAULT_PORT.to_string());
            put(f.username, String::new());
            put(f.auth_type, AUTH_PASSWORD.to_string());
        }
    }
    put(f.open, true);
}

fn form_from_signals(f: FormSignals) -> HostForm {
    HostForm {
        id: *f.id.peek(),
        name: f.name.peek().clone(),
        host: f.host.peek().clone(),
        port: f.port.peek().clone(),
        username: f.username.peek().clone(),
        auth_type: f.auth_type.peek().clone(),
        password: f.password.peek().clone(),
        private_key: f.private_key.peek().clone(),
    }
}

#[component]
pub fn SshPanel() -> Element {
    let store = use_context::<Store>();
    let form = use_form_signals();

    let hosts = store.ssh_hosts.read().clone();
    let selected = use_signal(|| None::<u64>);
    let command = use_signal(String::new);
    let running = use_signal(|| false);
    let output = use_signal(|| None::<SshExecResponse>);
    let password = use_signal(String::new);
    let save_password = use_signal(|| false);
    let confirm_delete = use_signal(|| None::<u64>);

    let current_id = pick_host(&hosts, *selected.read());
    let current = current_id.and_then(|id| hosts.iter().find(|h| h.id == id).cloned());

    // Chạy lệnh trên máy đang chọn. `password` rỗng = dùng mật khẩu đã lưu.
    let run = move |pw: String, save: bool| {
        let Some(host_id) = current_id else {
            return;
        };
        let cmd = command.peek().trim().to_string();
        if cmd.is_empty() || *running.peek() {
            return;
        }
        let base = store.base();
        put(running, true);
        put(output, None);
        dioxus::prelude::spawn(async move {
            let req = SshExecRequest {
                host_id,
                command: cmd,
                timeout_secs: EXEC_TIMEOUT_SECS,
                password: pw,
                save_password: save,
            };
            let result = api::on_io(async move { api::ssh_exec(&base, &req).await }).await;
            put(running, false);
            match result {
                Ok(resp) => {
                    // Lưu mật khẩu thành công thì cờ "đã lưu" trên danh sách đổi
                    if resp.ok && save {
                        store.reload_ssh_hosts();
                    }
                    put(output, Some(resp));
                }
                Err(e) => put(
                    output,
                    Some(SshExecResponse {
                        error: e.to_string(),
                        ..Default::default()
                    }),
                ),
            }
        });
    };

    // Lưu form thêm/sửa. Thành công thì chọn máy vừa lưu và đóng form.
    let save_form = move || {
        let snapshot = form_from_signals(form);
        let body = match build_save(&snapshot) {
            Ok(body) => body,
            Err(message) => {
                put(form.error, message);
                return;
            }
        };
        let base = store.base();
        dioxus::prelude::spawn(async move {
            let result = api::on_io(async move { api::ssh_save(&base, &body).await }).await;
            match result {
                Ok(resp) if resp.ok => {
                    put(form.open, false);
                    put(form.error, String::new());
                    if resp.id > 0 {
                        put(selected, Some(resp.id));
                    }
                    store.reload_ssh_hosts();
                }
                Ok(resp) => put(form.error, resp.error),
                Err(e) => put(form.error, e.to_string()),
            }
        });
    };

    // Xóa máy đã lưu (hai bước: bấm "Xóa", rồi "Xác nhận xóa")
    let delete_host = move |id: u64| {
        let base = store.base();
        dioxus::prelude::spawn(async move {
            let result = api::on_io(async move { api::ssh_delete(&base, id).await }).await;
            match result {
                Ok(resp) if resp.ok => {
                    put(confirm_delete, None);
                    put(selected, None);
                    put(output, None);
                    store.reload_ssh_hosts();
                }
                Ok(resp) => put(store.notice, Some(resp.error)),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    };

    let form_open = *form.open.read();
    let form_error = form.error.read().clone();
    let running_now = *running.read();
    let cmd_text = command.read().clone();
    let result = output.read().clone();
    let pw_text = password.read().clone();
    let pw_save_now = *save_password.read();
    let confirm_id = *confirm_delete.read();

    rsx! {
        header { class: "conv-header",
            div { class: "conv-title",
                h2 { "SSH" }
                p { class: "muted",
                    if let Some(h) = current.as_ref() {
                        "{h.name}"
                    } else {
                        "Chưa có máy"
                    }
                }
            }
            div { class: "conv-stats",
                button {
                    class: "toggle",
                    onclick: move |_| {
                        put(confirm_delete, None);
                        open_form(form, None);
                    },
                    "+ Thêm máy"
                }
                button { class: "toggle", onclick: move |_| store.toggle_ssh_panel(), "Đóng" }
            }
        }
        section { class: "ssh-body",
            div { class: "host-chips",
                for host in hosts.iter() {
                    button {
                        key: "{host.id}",
                        class: if Some(host.id) == current_id { "chip active" } else { "chip" },
                        onclick: {
                            let id = host.id;
                            move |_| {
                                put(selected, Some(id));
                                put(output, None);
                                put(password, String::new());
                                put(confirm_delete, None);
                                put(form.open, false);
                            }
                        },
                        "{host.name}"
                    }
                }
            }

            if form_open {
                div { class: "ssh-form",
                    label { "Tên hiển thị"
                        input {
                            value: "{form.name}",
                            placeholder: "Để trống sẽ dùng user@host",
                            oninput: move |e| put(form.name, e.value()),
                        }
                    }
                    label { "Địa chỉ (IP hoặc tên miền)"
                        input {
                            value: "{form.host}",
                            placeholder: "192.168.1.10",
                            oninput: move |e| put(form.host, e.value()),
                        }
                    }
                    label { "Cổng"
                        input {
                            value: "{form.port}",
                            oninput: move |e| put(form.port, e.value()),
                        }
                    }
                    label { "Tên đăng nhập"
                        input {
                            value: "{form.username}",
                            oninput: move |e| put(form.username, e.value()),
                        }
                    }
                    label { class: "wide", "Xác thực"
                        select {
                            value: "{form.auth_type}",
                            onchange: move |e| put(form.auth_type, e.value()),
                            option { value: AUTH_PASSWORD, "Mật khẩu" }
                            option { value: AUTH_KEY, "SSH key" }
                        }
                    }
                    if form.auth_type.read().as_str() == AUTH_KEY {
                        label { class: "wide", "Private key (để trống = giữ key đã lưu khi sửa)"
                            textarea {
                                value: "{form.private_key}",
                                oninput: move |e| put(form.private_key, e.value()),
                            }
                        }
                    } else {
                        label { class: "wide", "Mật khẩu (để trống = giữ mật khẩu đã lưu khi sửa)"
                            input {
                                r#type: "password",
                                value: "{form.password}",
                                oninput: move |e| put(form.password, e.value()),
                            }
                        }
                    }
                    if !form_error.is_empty() {
                        p { class: "banner error wide", "{form_error}" }
                    }
                    div { class: "ssh-form-actions",
                        button { class: "toggle", onclick: move |_| put(form.open, false), "Hủy" }
                        button { class: "send", onclick: move |_| save_form(), "Lưu máy" }
                    }
                }
            }

            if let Some(h) = current.clone() {
                div { class: "ssh-host-head",
                    div {
                        h3 { "{h.name}" }
                        p { class: "muted mono", "{host_address(&h)}" }
                        p { class: "muted", "{auth_label(&h.auth_type)} · {secret_status(&h)}" }
                    }
                    if !h.builtin {
                        div { class: "container-actions",
                            button {
                                class: "toggle",
                                onclick: {
                                    let host = h.clone();
                                    move |_| {
                                        put(confirm_delete, None);
                                        open_form(form, Some(&host));
                                    }
                                },
                                "Sửa"
                            }
                            if confirm_id == Some(h.id) {
                                button {
                                    class: "stop",
                                    onclick: {
                                        let id = h.id;
                                        move |_| delete_host(id)
                                    },
                                    "Xác nhận xóa"
                                }
                                button { class: "toggle", onclick: move |_| put(confirm_delete, None), "Hủy" }
                            } else {
                                button {
                                    class: "stop",
                                    onclick: {
                                        let id = h.id;
                                        move |_| put(confirm_delete, Some(id))
                                    },
                                    "Xóa"
                                }
                            }
                        }
                    }
                }

                div { class: "ssh-exec",
                    textarea {
                        class: "ssh-command",
                        rows: "3",
                        placeholder: "Lệnh chạy một lần, ví dụ: uname -a",
                        value: "{cmd_text}",
                        oninput: move |e| put(command, e.value()),
                    }
                    div { class: "ssh-exec-actions",
                        button {
                            class: "send",
                            disabled: running_now || cmd_text.trim().is_empty(),
                            onclick: move |_| run(String::new(), false),
                            if running_now { "Đang chạy…" } else { "Chạy" }
                        }
                    }
                }

                if let Some(resp) = result {
                    if resp.needs_password {
                        div { class: "ssh-password",
                            span { "{password_prompt_label(&resp.password_kind)}" }
                            input {
                                r#type: "password",
                                value: "{pw_text}",
                                oninput: move |e| put(password, e.value()),
                            }
                            label { class: "muted",
                                input {
                                    r#type: "checkbox",
                                    checked: pw_save_now,
                                    onchange: move |e| put(save_password, e.checked()),
                                }
                                " Lưu mật khẩu cho máy này"
                            }
                            button {
                                class: "send",
                                disabled: pw_text.is_empty() || running_now,
                                onclick: move |_| run(password.peek().clone(), *save_password.peek()),
                                "Chạy lại"
                            }
                        }
                    }
                    div { class: if resp.ok { "ssh-output ok" } else { "ssh-output err" },
                        p { class: "muted", "{exec_summary(&resp)}" }
                        if !resp.stdout.is_empty() {
                            pre { "{resp.stdout}" }
                        }
                        if !resp.stderr.is_empty() {
                            pre { class: "stderr", "{resp.stderr}" }
                        }
                        if !resp.error.is_empty() && !resp.needs_password {
                            p { class: "banner error", "{resp.error}" }
                        }
                    }
                }
            } else if !form_open {
                p { class: "muted center", "Chưa có máy nào. Bấm + Thêm máy." }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(id: u64, name: &str, builtin: bool) -> SshHost {
        SshHost {
            id,
            name: name.into(),
            host: "10.0.0.5".into(),
            port: DEFAULT_PORT,
            username: "john".into(),
            auth_type: AUTH_PASSWORD.into(),
            has_password: true,
            has_key: false,
            builtin,
        }
    }

    fn form() -> HostForm {
        HostForm {
            id: 0,
            name: String::new(),
            host: " 10.0.0.5 ".into(),
            port: String::new(),
            username: " john ".into(),
            auth_type: AUTH_PASSWORD.into(),
            password: "secret".into(),
            private_key: "KEY".into(),
        }
    }

    #[test]
    fn build_save_trims_defaults_port_and_name() {
        let body = build_save(&form()).expect("hợp lệ");
        assert_eq!(body.host, "10.0.0.5");
        assert_eq!(body.username, "john");
        assert_eq!(body.port, 22);
        assert_eq!(body.name, "john@10.0.0.5");
        assert_eq!(body.password, "secret");
        // Kiểu mật khẩu không gửi private key
        assert_eq!(body.private_key, "");
    }

    #[test]
    fn build_save_sends_only_key_secret_for_key_auth() {
        let mut f = form();
        f.auth_type = AUTH_KEY.into();
        let body = build_save(&f).expect("hợp lệ");
        assert_eq!(body.auth_type, AUTH_KEY);
        assert_eq!(body.password, "");
        assert_eq!(body.private_key, "KEY");
    }

    #[test]
    fn build_save_rejects_bad_input() {
        let mut f = form();
        f.host = "  ".into();
        assert!(build_save(&f).is_err());
        let mut f = form();
        f.username = String::new();
        assert!(build_save(&f).is_err());
        let mut f = form();
        f.port = "0".into();
        assert!(build_save(&f).is_err());
        f.port = "abc".into();
        assert!(build_save(&f).is_err());
        f.port = "2222".into();
        assert_eq!(build_save(&f).expect("cổng hợp lệ").port, 2222);
    }

    #[test]
    fn host_address_and_secret_status() {
        let remote = host(3, "Lab", false);
        assert_eq!(host_address(&remote), "john@10.0.0.5");
        let mut custom = host(3, "Lab", false);
        custom.port = 2222;
        assert_eq!(host_address(&custom), "john@10.0.0.5:2222");
        assert_eq!(host_address(&host(1, "Máy này", true)), "Máy này · john");
        assert_eq!(secret_status(&remote), "đã lưu");
        let mut key_host = host(4, "K", false);
        key_host.auth_type = AUTH_KEY.into();
        assert_eq!(secret_status(&key_host), "chưa lưu");
    }

    #[test]
    fn pick_host_keeps_selection_or_falls_back_to_first() {
        let hosts = vec![host(1, "Máy này", true), host(2, "Lab", false)];
        assert_eq!(pick_host(&hosts, Some(2)), Some(2));
        assert_eq!(pick_host(&hosts, Some(9)), Some(1));
        assert_eq!(pick_host(&hosts, None), Some(1));
        assert_eq!(pick_host(&[], None), None);
    }

    #[test]
    fn exec_summary_reports_exit_code() {
        let ok = SshExecResponse {
            ok: true,
            exit_code: Some(0),
            ..Default::default()
        };
        assert_eq!(exec_summary(&ok), "Hoàn tất (mã thoát 0)");
        let failed = SshExecResponse {
            ok: true,
            exit_code: Some(2),
            ..Default::default()
        };
        assert_eq!(exec_summary(&failed), "Lỗi (mã thoát 2)");
        let none = SshExecResponse::default();
        assert_eq!(exec_summary(&none), "Không chạy được");
    }

    #[test]
    fn password_prompt_label_follows_kind() {
        assert_eq!(password_prompt_label("sudo"), "Nhập mật khẩu sudo");
        assert_eq!(password_prompt_label("ssh"), "Nhập mật khẩu SSH");
        assert_eq!(password_prompt_label(""), "Nhập mật khẩu SSH");
    }
}
