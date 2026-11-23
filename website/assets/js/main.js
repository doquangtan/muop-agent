/* Tiện ích dùng chung: menu mobile, phóng to ảnh, sao chép code. */
(function () {
  "use strict";

  // Menu mobile
  var toggle = document.getElementById("navToggle");
  var links = document.getElementById("navLinks");
  if (toggle && links) {
    toggle.addEventListener("click", function () {
      links.classList.toggle("open");
    });
    links.addEventListener("click", function (e) {
      if (e.target.tagName === "A") links.classList.remove("open");
    });
  }

  // Lightbox
  var box = document.getElementById("lightbox");
  var boxImg = document.getElementById("lightboxImg");
  var closeBtn = document.getElementById("lightboxClose");
  function openBox(src, alt) {
    if (!box || !boxImg) return;
    boxImg.src = src;
    boxImg.alt = alt || "";
    box.classList.add("open");
  }
  function closeBox() {
    if (box) box.classList.remove("open");
  }
  document.querySelectorAll("[data-zoom]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var img = btn.querySelector("img");
      openBox(btn.getAttribute("data-zoom"), img ? img.alt : "");
    });
  });
  if (box) {
    box.addEventListener("click", function (e) {
      if (e.target === box || e.target === closeBtn) closeBox();
    });
  }
  if (closeBtn) closeBtn.addEventListener("click", closeBox);
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeBox();
  });

  // Nút sao chép trong khối code
  document.querySelectorAll(".codeblock .copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var pre = btn.parentElement.querySelector("pre");
      if (!pre || !navigator.clipboard) return;
      navigator.clipboard.writeText(pre.innerText).then(function () {
        var old = btn.textContent;
        btn.textContent = "Đã chép";
        setTimeout(function () { btn.textContent = old; }, 1400);
      });
    });
  });
})();
