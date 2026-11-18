fn main() {
    // Style "cosmic" đổi theo Palette.color-scheme lúc chạy, nên theme sáng/tối của app áp được cho nút và ô nhập
    let config = slint_build::CompilerConfiguration::new().with_style("cosmic".into());
    slint_build::compile_with_config("ui/app.slint", config)
        .expect("Slint: biên dịch ui/app.slint thất bại");
}
