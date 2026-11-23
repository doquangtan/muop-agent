/* Dựng trang tài liệu API từ window.MUOP_API (xem api-data.js). */
(function () {
  "use strict";

  var D = window.MUOP_API;
  if (!D) return;

  var BASE_KEY = "muop-api-base";
  var baseInput = document.getElementById("baseUrl");

  // ---------- Tiện ích ----------
  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
  // Chuyển `code` thành <code>, các phần còn lại là văn bản thường (đã escape).
  function md(s) {
    return esc(s).replace(/`([^`]+)`/g, "<code>$1</code>");
  }
  function slug(s) {
    return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  }
  function epId(e) {
    return "ep-" + e.m.toLowerCase() + "-" + slug(e.p);
  }
  function currentBase() {
    var v = (baseInput && baseInput.value.trim()) || "http://localhost:8787";
    return v.replace(/\/+$/, "");
  }
  function defaultBase() {
    var h = window.location.hostname;
    if (window.location.protocol.indexOf("http") === 0 && h) {
      return window.location.protocol + "//" + h + ":8787";
    }
    return "http://localhost:8787";
  }

  // Khối lệnh có {BASE} lưu mẫu trong data-tpl; refreshBase() thay địa chỉ khi người dùng đổi
  function codeBlock(text, asTemplate) {
    var tpl = text;
    var shown = asTemplate ? tpl.replace(/\{BASE\}/g, currentBase()) : tpl;
    var attr = asTemplate ? ' data-tpl="' + esc(tpl) + '"' : "";
    return (
      '<div class="codeblock"><pre><code' + attr + ">" + esc(shown) + "</code></pre>" +
      '<button class="copy" type="button">Sao chép</button></div>'
    );
  }

  function compactJson(body) {
    try {
      return JSON.stringify(JSON.parse(body));
    } catch (err) {
      return body.replace(/\s+/g, " ").trim();
    }
  }

  function curlFor(e) {
    if (e.curl) return e.curl;
    var url = "{BASE}" + e.p;
    var req = (e.q || []).filter(function (x) { return x[2]; }).map(function (x) {
      return x[0] + "=<" + x[0] + ">";
    });
    if (req.length) url += "?" + req.join("&");
    var lines = [];
    var first = "curl";
    if (e.m !== "GET") first += " -X " + e.m;
    lines.push(first + ' "' + url + '"' + (e.body ? " \\" : ""));
    if (e.body) {
      lines.push("  -H 'Content-Type: application/json' \\");
      lines.push("  -d '" + compactJson(e.body) + "'");
    }
    return lines.join("\n");
  }

  function table(headers, rows) {
    var h = headers.map(function (x) { return "<th>" + esc(x) + "</th>"; }).join("");
    var body = rows.map(function (r) {
      return "<tr>" + r.map(function (c, i) {
        return "<td>" + (i === 0 ? "<code>" + esc(c) + "</code>" : md(c)) + "</td>";
      }).join("") + "</tr>";
    }).join("");
    return '<div class="table-wrap"><table><thead><tr>' + h + "</tr></thead><tbody>" + body + "</tbody></table></div>";
  }

  function paramTable(list, headers) {
    if (!list || !list.length) return "";
    var rows = list.map(function (x) {
      var req = x[2] ? '<span class="req">bắt buộc</span>' : '<span class="opt">tùy chọn</span>';
      return '<tr><td><code>' + esc(x[0]) + '</code>' + req + '</td><td><span class="type">' +
        esc(x[1]) + '</span></td><td>' + md(x[3]) + '</td></tr>';
    }).join("");
    return '<div class="table-wrap"><table><thead><tr><th>' + headers[0] + "</th><th>" + headers[1] +
      "</th><th>" + headers[2] + "</th></tr></thead><tbody>" + rows + "</tbody></table></div>";
  }

  // ---------- Endpoint ----------
  function renderEndpoint(e, groupTitle) {
    var parts = [];
    var search = (e.m + " " + e.p + " " + (e.alias || "") + " " + e.s + " " + groupTitle).toLowerCase();
    parts.push('<article class="endpoint" id="' + epId(e) + '" data-search="' + esc(search) + '">');
    parts.push('<div class="ep-head"><span class="method m-' + e.m + '">' + e.m + '</span>' +
      '<code class="ep-path">' + esc(e.p) + "</code></div>");
    parts.push('<p class="ep-summary">' + md(e.s) + "</p>");
    if (e.alias) parts.push('<div class="alias">Alias: <code>' + esc(e.alias) + "</code></div>");
    if (e.d) parts.push("<p>" + md(e.d) + "</p>");

    if (e.q && e.q.length) {
      parts.push("<h4>Tham số query</h4>");
      parts.push(paramTable(e.q, ["Tên", "Kiểu", "Mô tả"]));
    }
    if (e.b && e.b.length) {
      parts.push("<h4>Body (JSON)</h4>");
      parts.push(paramTable(e.b, ["Trường", "Kiểu", "Mô tả"]));
    }

    parts.push("<h4>Ví dụ yêu cầu</h4>");
    parts.push(codeBlock(curlFor(e), true));

    if (e.res) {
      parts.push("<h4>Phản hồi</h4>");
      parts.push(codeBlock(e.res, false));
    }
    if (e.note) parts.push('<p class="note">' + md(e.note) + "</p>");
    if (e.err) parts.push('<p class="note" style="border-color:var(--warn);background:rgba(245,193,92,.08)">' + md(e.err) + "</p>");
    parts.push("</article>");
    return parts.join("");
  }

  // ---------- Nhóm và mục lục ----------
  var groupsEl = document.getElementById("groups");
  var sideEl = document.getElementById("sideLinks");
  var sideHtml = [];
  var groupsHtml = [];
  var totalEndpoints = 0;

  D.groups.forEach(function (g) {
    totalEndpoints += g.endpoints.length;
    var gid = "grp-" + g.id;
    var section = [];
    section.push('<section class="api-group" id="' + gid + '" data-group>');
    section.push("<h2>" + esc(g.title) + "</h2>");
    section.push('<p class="gdesc">' + md(g.desc) + "</p>");
    if (g.note) section.push('<p class="note" style="margin-bottom:18px">' + md(g.note) + "</p>");
    g.endpoints.forEach(function (e) { section.push(renderEndpoint(e, g.title)); });
    if (g.errors) section.push('<p class="note">' + md(g.errors) + "</p>");
    section.push("</section>");
    groupsHtml.push(section.join(""));

    var links = g.endpoints.map(function (e) {
      return '<a href="#' + epId(e) + '" data-search="' + esc((e.m + " " + e.p + " " + e.s + " " + g.title).toLowerCase()) +
        '"><span style="font-family:var(--mono);font-size:.72rem;color:var(--text-faint);margin-right:6px">' +
        e.m + "</span>" + esc(e.p) + "</a>";
    }).join("");
    sideHtml.push('<h5><a href="#' + gid + '" style="padding:0;display:inline;color:inherit">' + esc(g.title) + "</a></h5>" +
      '<div data-group-id="' + gid + '">' + links + "</div>");
  });
  groupsEl.innerHTML = groupsHtml.join("");

  // Socket.IO
  var S = D.socket;
  var clientCount = S.client.length;
  var serverCount = S.server.length;
  document.getElementById("socketIntro").innerHTML = md(S.intro);
  document.getElementById("socketClient").innerHTML = table(["Sự kiện", "Payload", "Ack / phản hồi"], S.client.map(function (x) {
    return [x.e, x.p, x.a];
  }));
  document.getElementById("socketServer").innerHTML = table(["Sự kiện", "Khi nào", "Payload"], S.server.map(function (x) {
    return [x.e, x.w, x.p];
  }));
  document.getElementById("bridgeEvents").innerHTML = S.bridge.map(function (x) {
    return '<span class="tag" style="font-size:.8rem;padding:4px 9px">' + esc(x) + "</span>";
  }).join("");
  document.getElementById("socketNotes").innerHTML = S.notes.map(function (x) {
    return "<li style='margin-bottom:8px'>" + md(x) + "</li>";
  }).join("");

  // Socket trong mục lục
  sideHtml.push('<h5><a href="#socket" style="padding:0;display:inline;color:inherit">Socket.IO</a></h5>');
  sideHtml.push('<a href="#socket">Sự kiện client → server</a><a href="#socket">Sự kiện server → client</a>');
  sideHtml.push('<h5><a href="#rtsp" style="padding:0;display:inline;color:inherit">Màn hình (RTSP)</a></h5>');
  sideHtml.push('<h5><a href="#quy-uoc" style="padding:0;display:inline;color:inherit">Quy ước chung</a></h5>');
  sideEl.innerHTML = sideHtml.join("");

  // RTSP và quy ước
  var R = D.screen;
  document.getElementById("screenDesc").innerHTML = md(R.desc);
  document.getElementById("screenUrl").textContent = R.url;
  document.getElementById("screenStatus").textContent = R.status;
  document.getElementById("conventions").innerHTML = table(["Mục", "Nội dung"], D.conventions);

  document.getElementById("epCount").textContent =
    totalEndpoints + " endpoint REST, " + (clientCount + serverCount) + " sự kiện Socket.IO";

  // ---------- Địa chỉ server ----------
  var saved = null;
  try { saved = window.localStorage.getItem(BASE_KEY); } catch (err) { saved = null; }
  baseInput.value = saved || defaultBase();

  function refreshBase() {
    var base = currentBase();
    document.querySelectorAll("code[data-tpl]").forEach(function (el) {
      el.textContent = el.getAttribute("data-tpl").replace(/\{BASE\}/g, base);
    });
  }
  baseInput.addEventListener("input", function () {
    try { window.localStorage.setItem(BASE_KEY, baseInput.value.trim()); } catch (err) { /* bỏ qua */ }
    refreshBase();
  });
  refreshBase();

  // ---------- Tìm kiếm ----------
  var search = document.getElementById("search");
  var emptyEl = document.getElementById("emptyState");
  function applyFilter() {
    var q = search.value.trim().toLowerCase();
    var anyVisible = false;
    var groupVisible = {};
    document.querySelectorAll("article.endpoint").forEach(function (el) {
      var match = !q || el.getAttribute("data-search").indexOf(q) !== -1;
      el.classList.toggle("hide", !match);
      el.style.display = match ? "" : "none";
      if (match) {
        anyVisible = true;
        var g = el.closest("[data-group]");
        if (g) groupVisible[g.id] = true;
      }
    });
    document.querySelectorAll("[data-group]").forEach(function (g) {
      var show = !q || !!groupVisible[g.id];
      g.style.display = show ? "" : "none";
    });
    document.querySelectorAll("#sideLinks a[data-search]").forEach(function (a) {
      var match = !q || a.getAttribute("data-search").indexOf(q) !== -1;
      a.style.display = match ? "" : "none";
    });
    document.querySelectorAll("#sideLinks [data-group-id]").forEach(function (box) {
      var shown = !q || Array.prototype.some.call(box.querySelectorAll("a"), function (a) {
        return a.style.display !== "none";
      });
      var heading = box.previousElementSibling;
      if (heading) heading.style.display = shown ? "" : "none";
      box.style.display = shown ? "" : "none";
    });
    emptyEl.style.display = anyVisible || !q ? "none" : "block";
  }
  search.addEventListener("input", applyFilter);

  // ---------- Mục đang xem (scroll-spy đơn giản) ----------
  var links = Array.prototype.slice.call(document.querySelectorAll("#sideLinks a"));
  function markActive() {
    var hash = window.location.hash;
    links.forEach(function (a) {
      a.classList.toggle("active", !!hash && a.getAttribute("href") === hash);
    });
  }
  window.addEventListener("hashchange", markActive);
  markActive();

  // Mở đúng phần khi đến từ liên kết có neo
  if (window.location.hash) {
    var target = document.querySelector(window.location.hash);
    if (target) target.scrollIntoView();
  }
})();
