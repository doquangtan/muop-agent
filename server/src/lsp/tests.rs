use super::*;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_round_trip_handles_spaces_and_unicode() {
        let p = Path::new("/home/john/Documents/my project/mã nguồn/main.go");
        let uri = file_uri(p);
        assert!(uri.starts_with("file:///home/john/Documents/my%20project/"));
        assert_eq!(uri_to_path(&uri), p.to_string_lossy());
    }

    #[test]
    fn finds_nearest_project_root() {
        let root = std::env::temp_dir().join(format!("lsp-root-test-{}", std::process::id()));
        let nested = root.join("pkg/sub");
        fs::create_dir_all(&nested).unwrap();
        fs::write(root.join("pubspec.yaml"), "name: x").unwrap();
        let file = nested.join("a.dart");
        fs::write(&file, "").unwrap();
        assert_eq!(find_root(Lang::Dart, &file), root);
        // Không có go.mod: quay về thư mục chứa tệp
        assert_eq!(find_root(Lang::Go, &file), nested);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn flattens_hierarchical_and_flat_symbols() {
        let items = vec![json!({
            "name": "Outer", "kind": 5,
            "range": {"start": {"line": 1}, "end": {"line": 9}},
            "children": [{"name": "inner", "kind": 6,
                "range": {"start": {"line": 2}, "end": {"line": 4}}}]
        })];
        let mut out = Vec::new();
        flatten_symbols(&items, 0, &mut out);
        assert_eq!(out.len(), 2);
        assert_eq!(
            (
                out[1].name.as_str(),
                out[1].depth,
                out[1].kind_label.as_str()
            ),
            ("inner", 1, "method")
        );
    }
}
