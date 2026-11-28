//! Khung chính: mở luồng Socket.IO theo địa chỉ máy chủ, ghép sidebar và khung hội thoại.

use dioxus::prelude::*;

use crate::data::socket;
use crate::store::Store;
use crate::ui::conversation::Conversation;
use crate::ui::dialog::DialogHost;
use crate::ui::docker::DockerPanel;
use crate::ui::explorer::Explorer;
use crate::ui::file_view::FileView;
use crate::ui::git::GitHistoryPanel;
use crate::ui::sidebar::Sidebar;
use crate::ui::ssh::SshPanel;

#[component]
pub fn Shell() -> Element {
    let store = use_context::<Store>();

    // Đọc địa chỉ trong thân closure (đồng bộ) để future chạy lại khi đổi máy chủ.
    use_future(move || {
        let base = store.address.read().clone();
        async move {
            store.reset_for_new_server();
            let (client, mut events) = socket::connect(&base);
            let mut slot = store.socket;
            slot.set(Some(client));
            while let Some(event) = events.recv().await {
                store.handle(event);
            }
        }
    });

    let viewed_open = store.viewed_file.read().is_some();
    let ssh_open = *store.ssh_panel.read();
    let docker_open = *store.docker_panel.read();
    let git_open = *store.git_panel.read();
    rsx! {
        div { class: "app",
            Sidebar {}
            if *store.explorer_open.read() {
                Explorer {}
            }
            main { class: "main",
                if ssh_open {
                    SshPanel {}
                } else if docker_open {
                    DockerPanel {}
                } else if git_open {
                    GitHistoryPanel {}
                } else if viewed_open {
                    FileView {}
                } else {
                    Conversation {}
                }
            }
            DialogHost {}
        }
    }
}
