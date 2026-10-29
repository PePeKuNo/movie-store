/* ==========================================================================
   Movie Store — single page application
   All data comes from /api/*; nothing about a movie lives in this file.
   ========================================================================== */
(function () {
  "use strict";

  var boot = JSON.parse(document.getElementById("bootstrap").textContent);

  var state = {
    region: boot.defaultRegion,
    seed: String(boot.defaultSeed),
    likes: 0,
    reviews: 0,
    view: "table",
    page: 1,
    pageSize: 20,
    items: [],
    ui: {},
    meta: {},
    galleryPage: 0,
    galleryLoading: false,
    openRow: null,
    playing: 0
  };

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  function esc(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function t(key, fallback) {
    var value = state.ui[key];
    return value == null || value === "" ? (fallback || key) : value;
  }

  function baseParams(extra) {
    var params = {
      region: state.region,
      seed: state.seed,
      likes: Number(state.likes).toFixed(1),
      reviews: Number(state.reviews).toFixed(1)
    };
    if (extra) { Object.keys(extra).forEach(function (key) { params[key] = extra[key]; }); }
    return params;
  }

  function url(path, extra) {
    var params = baseParams(extra);
    var query = Object.keys(params)
      .map(function (key) { return encodeURIComponent(key) + "=" + encodeURIComponent(params[key]); })
      .join("&");
    return path + "?" + query;
  }

  // `getJSON` takes a complete URL (already carrying its query string).
  async function getJSON(requestUrl) {
    var response = await fetch(requestUrl, { headers: { Accept: "application/json" } });
    if (response.status === 202) return { __pending: true };
    if (!response.ok) throw new Error("HTTP " + response.status);
    return response.json();
  }

  /* ------------------------------------------------------------- i18n -- */

  function applyLanguage() {
    $$("[data-ui]").forEach(function (node) {
      node.textContent = t(node.getAttribute("data-ui"), node.textContent);
    });
    $$("[data-ui-title]").forEach(function (node) {
      var label = t(node.getAttribute("data-ui-title"), "");
      if (label) { node.setAttribute("title", label); node.setAttribute("aria-label", label); }
    });
    document.documentElement.lang = state.region;
  }

  /* ------------------------------------------------------------- toast -- */

  var toastTimer = null;
  function toast(message) {
    var node = $("#toast");
    node.textContent = message;
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { node.hidden = true; }, 3200);
  }

  /* ------------------------------------------------------------ loading -- */

  function setLoading(on) {
    document.body.style.cursor = on ? "progress" : "";
  }

  /* ----------------------------------------------------------- fetching -- */

  async function loadMeta() {
    state.meta = await getJSON(url("/api/meta"));
    state.ui = state.meta.ui || {};
    state.pageSize = state.meta.pageSize || 20;
    applyLanguage();
    var stats = state.meta.media || {};
    $("#media-stats").textContent =
      (stats.clips || 0) + " clips · " + (stats.music || 0) + " tracks · " +
      (stats.fonts || 0) + " fonts · " + (stats.sfx || 0) + " sfx";
  }

  async function loadPage(page) {
    var data = await getJSON(url("/api/movies", { page: page }));
    return data.items || [];
  }

  /* ------------------------------------------------------------- detail -- */

  // `movie.index` runs across pages; the trailer endpoints address a record
  // by its position inside the current page (0..pageSize-1).
  function recordIndex(movie) {
    return (movie.index - 1) % state.pageSize;
  }

  function posterUrl(movie, width) {
    var extra = { index: recordIndex(movie) };
    if (width) extra.w = width;
    return url("/api/trailers/" + encodeURIComponent(movie.trailer.key) + "/poster", extra);
  }

  // Poster <img> tag. `width` picks a server side variant: 160 px for the
  // table thumbnail, 640 px for cards and the detail panel (the full frame
  // is 1280 px and ~100 KB - four times what a 62 px thumb needs).
  // The poster endpoint answers 503 + Retry-After while the frame is still
  // being rendered in the background, which fires an `error` on the image;
  // the listener bound in bind() retries it with a backoff instead of
  // leaving a broken image behind.
  function posterImg(movie, attrs, width) {
    var src = posterUrl(movie, width);
    return '<img src="' + esc(src) + '" data-poster="' + esc(src) + '" ' + (attrs || "") + ">";
  }

  function videoUrl(movie) {
    return url("/api/trailers/" + encodeURIComponent(movie.trailer.key) + "/video",
              { index: recordIndex(movie), quality: "hd" });
  }

  function statusUrl(movie) {
    return url("/api/trailers/" + encodeURIComponent(movie.trailer.key) + "/status",
               { index: recordIndex(movie), quality: "hd" });
  }

  // Likes and reviews are integer counts, coloured relative to the average
  // currently set in the toolbar: green = clearly above it, red = clearly
  // below it, gold = around it.
  function scoreClass(value, average) {
    var avg = Number(average) || 0;
    var v = Number(value) || 0;
    if (avg <= 0) return v > 0 ? "score--high" : "score--mid";
    if (v >= avg * 1.3) return "score--high";
    if (v <= avg * 0.7) return "score--low";
    return "score--mid";
  }

  // Counts are whole people - never show "7.0" for them.
  function countLabel(value) {
    return String(Math.round(Number(value) || 0));
  }

  // A review carries its own 1..5 star rating.
  function stars(value) {
    var full = Math.min(5, Math.max(0, Math.round(Number(value) || 0)));
    return "★★★★★".slice(0, full) + "☆☆☆☆☆".slice(0, 5 - full);
  }

  function detailHTML(movie) {
    var genres = (movie.genres || []).map(function (genre) {
      return '<span class="chip">' + esc(genre) + "</span>";
    }).join("");

    var cast = (movie.cast || []).map(esc).join(", ");

    var reviews = (movie.reviews || []).slice(0, movie.reviewCount || 0).map(function (review) {
      return '' +
        '<div class="review">' +
          '<div class="review__stars">' + stars(review.stars) + "</div>" +
          '<p class="review__text">“' + esc(review.text) + '”</p>' +
          '<div class="review__by">' + esc(review.author) + " · " + esc(review.source) + "</div>" +
        "</div>";
    }).join("");

    var series = "";
    if (movie.series && movie.series.seasons && movie.series.seasons.length) {
      series = '<section class="detail__section">' +
        '<h4 class="detail__h">' + esc(t("col_series", "Series")) + "</h4>" +
        movie.series.seasons.map(function (season) {
          var titles = (season.sample || []).map(function (episode) {
            return esc(episode.number) + ". " + esc(episode.title);
          }).join(" · ");
          return '<div class="season">' +
            '<span class="season__n">' + esc(t("seasons", "Season")) + " " + esc(season.number) + "</span>" +
            '<span class="season__eps">' + esc(season.episodes) + " " + esc(t("episode", "episodes")) + "</span>" +
            '<span class="season__titles">' + titles + "</span>" +
          "</div>";
        }).join("") + "</section>";
    }

    var runtime = esc(movie.duration) + " " + esc(t("min", "min"));

    return '' +
      '<div class="detail__inner">' +
        '<div class="detail__rail">' +
          '<div class="detail__poster">' +
            posterImg(movie, 'alt=""', 640) +
          "</div>" +
          '<div class="detail__meta">' +
            "<span><b>" + esc(movie.year) + "</b></span>" +
            "<span><b>" + runtime + "</b></span>" +
            '<span class="rating-pill">' + esc(movie.rating) + "</span>" +
            '<span>' + esc(t("director", "Director")) + ": <b>" + esc(movie.director) + "</b></span>" +
          "</div>" +
          '<div class="detail__section" style="margin-top:14px">' +
            '<h4 class="detail__h">' + esc(t("col_genres", "Genres")) + "</h4>" +
            '<div class="chips">' + genres + "</div>" +
          "</div>" +
        "</div>" +

        "<div>" +
          '<section class="detail__section">' +
            '<h2 class="detail__title">' + esc(movie.title) + "</h2>" +
            '<p class="detail__synopsis">' + esc(movie.synopsis) + "</p>" +
          "</section>" +
          '<section class="detail__section">' +
            '<h4 class="detail__h">' + esc(t("col_cast", "Cast")) + "</h4>" +
            '<p class="detail__synopsis" style="font-size:14.5px">' + cast + "</p>" +
          "</section>" +
          series +
        "</div>" +

        '<div>' +
          '<section class="detail__section">' +
            '<h4 class="detail__h">' + esc(t("trailer", "Trailer")) + "</h4>" +
            '<div class="trailer" data-trailer="' + esc(movie.trailer.key) + '">' +
              '<div class="trailer__stage">' +
                posterImg(movie, 'class="trailer__poster" alt=""', 640) +
                '<div class="trailer__state" data-state>' +
                  '<span class="spinner"></span>' +
                  "<span>" + esc(t("trailer_rendering", "Rendering trailer…")) + "</span>" +
                "</div>" +
                '<video controls playsinline preload="none" hidden data-video></video>' +
                '<button class="trailer__play" type="button" hidden data-play aria-label="Play">&#9654;</button>' +
              "</div>" +
              '<div class="trailer__bar">' +
                '<span data-label>' + esc(t("trailer_rendering", "Rendering trailer…")) + "</span>" +
                '<span class="trailer__live" data-live hidden></span>' +
              "</div>" +
            "</div>" +
          "</section>" +

          '<section class="detail__section">' +
            '<h4 class="detail__h">' + esc(t("written_by", "Reviews")) + " · " +
              '<span class="score ' + scoreClass(movie.likes, state.likes) + '">' + countLabel(movie.likes) + "</span> " +
              esc(t("col_likes", "Likes")) + " · " +
              '<span class="score ' + scoreClass(movie.reviewCount, state.reviews) + '">' + countLabel(movie.reviewCount) + "</span> " +
              esc(t("col_reviews", "Reviews")) +
            "</h4>" +
            (reviews || '<p class="review__by">' + esc(t("empty", "No reviews.")) + "</p>") +
          "</section>" +
        "</div>" +
      "</div>";
  }

  /* ----------------------------------------------------- trailer playing -- */

  var pollTimers = new WeakMap();

  function setTrailerState(root, text, spinning) {
    var stateNode = $("[data-state]", root);
    if (stateNode) {
      stateNode.hidden = !spinning && !text;
      var label = $("span:last-child", stateNode);
      if (label && text) label.textContent = text;
      var spinner = $(".spinner", stateNode);
      if (spinner) spinner.hidden = !spinning;
    }
    var barLabel = $("[data-label]", root);
    if (barLabel) barLabel.textContent = text || "";
  }

  function startTrailer(root, movie) {
    var video = $("[data-video]", root);
    var playBtn = $("[data-play]", root);
    var poster = $(".trailer__poster", root);
    var live = $("[data-live]", root);

    function beginPlayback() {
      video.dataset.retried = "";
      video.hidden = false;
      poster.hidden = true;
      playBtn.hidden = false;
      setTrailerState(root, "", false);
      // the element must be visible *before* the source is attached - a
      // media element that is display:none when the source is set can abort
      // its first byte-range request in Chromium
      video.src = videoUrl(movie);
      video.load();
      var attempt = video.play();
      if (attempt && attempt.catch) {
        attempt.catch(function () {
          // autoplay blocked - the big button stays visible for a manual start
          playBtn.hidden = false;
        });
      }
    }

    function fallbackToBlob() {
      // last resort: download the trailer once and hand the bytes to the
      // element directly (bypasses range requests entirely)
      return fetch(videoUrl(movie))
        .then(function (response) { return response.ok ? response.blob() : Promise.reject(); })
        .then(function (blob) {
          if (!root.isConnected) return;
          video.src = URL.createObjectURL(blob);
          video.hidden = false;
          video.load();
          var attempt = video.play();
          if (attempt && attempt.catch) attempt.catch(function () { playBtn.hidden = false; });
        })
        .catch(function () {
          setTrailerState(root, t("trailer_missing", "Trailer unavailable"), false);
        });
    }

    video.addEventListener("playing", function () {
      playBtn.hidden = true;
      live.hidden = false;
      live.textContent = "30 fps · 720p";
      state.playing += 1;
      document.body.setAttribute("data-playing", String(state.playing));
    });

    video.addEventListener("pause", function () { live.hidden = true; });
    video.addEventListener("error", function () {
      // one transparent retry: the first byte-range response occasionally
      // trips the demuxer while the render thread is still closing the file
      if (!video.dataset.retried) {
        video.dataset.retried = "1";
        video.load();
        return;
      }
      if (!video.dataset.blobTried) {
        video.dataset.blobTried = "1";
        fallbackToBlob();
        return;
      }
      setTrailerState(root, t("trailer_missing", "Trailer unavailable"), false);
    });

    playBtn.addEventListener("click", function () {
      var attempt = video.play();
      if (attempt && attempt.catch) attempt.catch(function () {});
    });

    (async function ensureVideo() {
      try {
        var status = await getJSON(statusUrl(movie));
        if (status.state !== "ready") {
          // kicks off the background render; answers 202 while it runs
          await fetch(videoUrl(movie), { headers: { Accept: "application/json" } }).catch(function () {});
          setTrailerState(root, t("trailer_rendering", "Rendering trailer…"), true);

          var ticks = 0;
          await new Promise(function (resolve, reject) {
            var timer = setInterval(async function () {
              ticks += 1;
              if (ticks > 240) { clearInterval(timer); reject(new Error("timeout")); return; }
              try {
                var probe = await getJSON(statusUrl(movie));
                if (probe.state === "ready") { clearInterval(timer); resolve(); }
                else if (probe.state === "missing") { clearInterval(timer); reject(new Error("missing")); }
              } catch (error) { /* keep polling */ }
            }, 900);
            pollTimers.set(root, timer);
          });
        }
        if (!root.isConnected) return; // row was closed while rendering
        beginPlayback();
      } catch (error) {
        setTrailerState(root, t("trailer_missing", "Trailer unavailable"), false);
      }
    })();
  }

  function stopTrailer(root) {
    var timer = pollTimers.get(root);
    if (timer) clearInterval(timer);
    var video = $("[data-video]", root);
    if (video) {
      video.pause();
      video.removeAttribute("src");
      video.load();
      video.hidden = true;
    }
    var poster = $(".trailer__poster", root);
    if (poster) poster.hidden = false;
    var playBtn = $("[data-play]", root);
    if (playBtn) playBtn.hidden = true;
  }

  /* -------------------------------------------------------------- table -- */

  function rowHTML(movie, position) {
    var seriesBadge = movie.series && movie.series.seasons && movie.series.seasons.length
      ? ' <span class="badge badge--series">' + esc(t("col_series", "Series")) + "</span>" : "";

    return '' +
      '<tr class="row" data-index="' + movie.index + '">' +
        '<td class="cell-num">' + esc(position) + "</td>" +
        "<td>" +
          '<div class="cell-title">' +
            posterImg(movie, 'class="cell-title__thumb" alt=""', 160) +
            '<div class="cell-title__text">' +
              '<div class="cell-title__name">' + esc(movie.title) + seriesBadge + "</div>" +
              '<div class="cell-title__sub">' + esc(movie.director) + "</div>" +
            "</div>" +
          "</div>" +
        "</td>" +
        '<td class="cell-num">' + esc(movie.year) + "</td>" +
        "<td><div class=\"chips\">" + (movie.genres || []).slice(0, 2).map(function (genre) {
          return '<span class="chip">' + esc(genre) + "</span>";
        }).join("") + "</div></td>" +
        '<td><div class="cast-line">' + esc((movie.cast || []).slice(0, 3).join(", ")) + "</div></td>" +
        '<td class="cell-num">' + esc(movie.duration) + "</td>" +
        '<td class="cell-num score ' + scoreClass(movie.likes, state.likes) + '">' + countLabel(movie.likes) + "</td>" +
        '<td class="cell-num score ' + scoreClass(movie.reviewCount, state.reviews) + '">' + countLabel(movie.reviewCount) + "</td>" +
        '<td class="cell-num"><button class="chev" type="button" aria-label="' +
          esc(t("expand", "Expand")) + '">&#8964;</button></td>' +
      "</tr>";
  }

  function renderTable(items) {
    var rows = $("#rows");
    rows.innerHTML = items.map(function (movie, i) {
      return rowHTML(movie, (state.page - 1) * state.pageSize + i + 1);
    }).join("");

    var from = (state.page - 1) * state.pageSize + 1;
    var to = from + items.length - 1;
    $("#range-label").textContent = t("showing", "Showing") + " " + from + "–" + to + " " +
      t("movies", "movies");
    $("#page-number").textContent = String(state.page);
    renderPages();
    $("#table-empty").hidden = items.length > 0;
  }

  function renderPages() {
    var pages = [];
    for (var candidate = 1; candidate <= state.page + 2; candidate++) pages.push(candidate);
    var html = pages.map(function (page, i) {
      var gap = i > 0 && page - pages[i - 1] > 1 ? '<span class="pager__gap">…</span>' : "";
      return gap + '<button class="pager__page' + (page === state.page ? " is-active" : "") +
        '" type="button" data-goto="' + page + '">' + page + "</button>";
    }).join("");
    $("#pages").innerHTML = html;
    var prev = $('.pager__btn[data-page="prev"]');
    if (prev) prev.disabled = state.page <= 1;
  }

  async function showPage(page, preloaded) {
    state.page = page;
    state.openRow = null;
    setLoading(true);
    try {
      var items = preloaded || await loadPage(page);
      state.items = items;
      renderTable(items);
      window.scrollTo({ top: 0, behavior: "smooth" });
    } catch (error) {
      toast(error.message);
    } finally {
      setLoading(false);
    }
  }

  function closeOpenRow() {
    if (!state.openRow) return;
    var detail = state.openRow;
    var row = document.querySelector('tr.row[data-index="' + detail.dataset.for + '"]');
    if (row) {
      row.classList.remove("is-open");
      var chev = $(".chev", row);
      if (chev) chev.innerHTML = "&#8964;";
    }
    stopTrailer(detail);
    detail.remove();
    state.openRow = null;
  }

  function toggleRow(row) {
    var index = row.dataset.index;
    var existing = row.nextElementSibling;
    if (existing && existing.classList.contains("detail")) {
      closeOpenRow();
      return;
    }
    closeOpenRow();

    var movie = state.items.find(function (item) { return String(item.index) === index; });
    if (!movie) return;

    var detail = document.createElement("tr");
    detail.className = "detail";
    detail.dataset.for = index;
    detail.innerHTML = '<td colspan="9">' + detailHTML(movie) + "</td>";
    row.parentNode.insertBefore(detail, row.nextSibling);
    row.classList.add("is-open");
    var chev = $(".chev", row);
    if (chev) chev.innerHTML = "&#8963;";
    state.openRow = detail;

    var trailer = $("[data-trailer]", detail);
    if (trailer) startTrailer(trailer, movie);
  }

  /* ------------------------------------------------------------ gallery -- */

  function cardHTML(movie) {
    return '' +
      '<article class="card" data-index="' + movie.index + '" role="button" tabindex="0" ' +
        'aria-label="' + esc(movie.title) + '">' +
        '<div class="card__media">' +
          posterImg(movie, 'alt=""', 640) +
          '<div class="card__shade"></div>' +
          '<span class="card__year">' + esc(movie.year) + " · " + esc(movie.duration) + " " + esc(t("min", "min")) + "</span>" +
          '<span class="card__play">&#9654;</span>' +
        "</div>" +
        '<div class="card__body">' +
          '<h3 class="card__title">' + esc(movie.title) + "</h3>" +
          '<div class="card__meta">' +
            "<span>" + esc((movie.genres || []).slice(0, 2).join(" · ")) + "</span>" +
            '<span class="card__stats">' +
              '<span class="' + scoreClass(movie.likes, state.likes) + '">♥ ' + countLabel(movie.likes) + "</span>" +
              '<span class="' + scoreClass(movie.reviewCount, state.reviews) + '">✎ ' + countLabel(movie.reviewCount) + "</span>" +
            "</span>" +
          "</div>" +
        "</div>" +
      "</article>";
  }

  // A gallery card may or may not still be in state.items (batches are not
  // cached), so fall back to a page lookup before opening the lightbox.
  function openCard(card) {
    var movie = state.items.find(function (item) { return String(item.index) === card.dataset.index; });
    if (movie) { openLightbox(movie); return; }
    fetchMovie(card.dataset.index).then(function (found) {
      if (found) openLightbox(found);
    });
  }

  // The infinite scrolling itself is delegated to the third-party
  // "Infinite Scroll" library (metafizzy, vendored in
  // app/assets/javascripts/infinite-scroll.pkgd.js). It watches the scroll
  // position, asks our API for the next batch and emits events; this file
  // only turns the JSON payload into cards.
  var infScroll = null;

  function renderBatch(items) {
    state.galleryPage += 1;
    if (!items.length) {
      $("#gallery-end").hidden = false;
      $("#gallery-empty").hidden = false;
      return;
    }
    $("#gallery").insertAdjacentHTML("beforeend", items.map(cardHTML).join(""));
    $("#gallery-count").textContent =
      state.galleryPage * state.pageSize + " " + t("movies", "movies");
  }

  function mountInfiniteScroll() {
    if (infScroll || !window.InfiniteScroll) return;

    infScroll = new window.InfiniteScroll("#gallery", {
      // absolute path => evaluated on every request, so it always asks for
      // the next page of the current parameters
      path: function () { return url("/api/movies", { page: state.galleryPage + 1 }); },
      responseBody: "json",
      history: false,
      loadOnScroll: true,
      scrollThreshold: 600
    });

    infScroll.on("request", function () { $("#gallery-loader").hidden = false; });

    infScroll.on("load", function (body) {
      $("#gallery-loader").hidden = true;
      renderBatch((body && body.items) || []);
    });

    infScroll.on("error", function () {
      // a single failed batch must not kill the scroller for good
      $("#gallery-loader").hidden = true;
      infScroll.canLoad = true;
      toast(t("empty", "Nothing more to load."));
    });
  }

  function unmountInfiniteScroll() {
    if (!infScroll) return;
    infScroll.destroy();
    infScroll = null;
  }

  function resetGallery() {
    unmountInfiniteScroll();
    state.galleryPage = 0;
    state.galleryLoading = false;
    $("#gallery").innerHTML = "";
    $("#gallery-end").hidden = true;
    $("#gallery-empty").hidden = true;
    $("#gallery-count").textContent = "";
  }

  // First batch is loaded eagerly (the scroller takes over afterwards).
  async function appendGalleryBatch() {
    if (state.galleryLoading) return;
    state.galleryLoading = true;
    $("#gallery-loader").hidden = false;
    try {
      var items = await loadPage(state.galleryPage + 1);
      renderBatch(items);
    } catch (error) {
      toast(error.message);
    } finally {
      state.galleryLoading = false;
      $("#gallery-loader").hidden = true;
    }
  }

  /* ------------------------------------------------------------ lightbox -- */

  function openLightbox(movie) {
    var box = $("#lightbox");
    $("#lightbox-body").innerHTML = detailHTML(movie);
    box.hidden = false;
    document.body.style.overflow = "hidden";
    var trailer = $("[data-trailer]", box);
    if (trailer) startTrailer(trailer, movie);
    box.dataset.index = movie.index;
  }

  function closeLightbox() {
    var box = $("#lightbox");
    if (box.hidden) return;
    var trailer = $("[data-trailer]", box);
    if (trailer) stopTrailer(trailer);
    $("#lightbox-body").innerHTML = "";
    box.hidden = true;
    document.body.style.overflow = "";
  }

  /* ---------------------------------------------------------- parameters -- */

  var reloadTimer = null;
  // Short enough that moving a slider feels immediate (the new counts of
  // every movie appear while the thumb is still being dragged), long enough
  // to coalesce a burst of `input` events into one request.
  function scheduleReload() {
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(reload, 140);
  }

  async function reload() {
    state.page = 1;
    closeOpenRow();
    closeLightbox();
    resetGallery();
    $("#table-empty").hidden = true;

    if (state.view === "gallery") {
      resetGallery();
      appendGalleryBatch().then(mountInfiniteScroll);
    } else {
      await showPage(1);
    }
  }

  function updateSlider(input, output) {
    var value = Number(input.value);
    var min = Number(input.min), max = Number(input.max);
    var percent = ((value - min) / (max - min)) * 100;
    input.style.setProperty("--fill", percent + "%");
    output.textContent = value.toFixed(1);
  }

  function randomSeed() {
    var high = Math.floor(Math.random() * 0x100000000) | 0x10000000; // keep bit 32+ set
    var low = Math.floor(Math.random() * 0x100000000) >>> 0;
    var value = (BigInt(high >>> 0) << 32n) | BigInt(low);
    return value.toString(10);
  }

  /* --------------------------------------------------------------- wire -- */

  function setView(view) {
    state.view = view;
    $("#table-view").hidden = view !== "table";
    $("#gallery-view").hidden = view !== "gallery";
    $("#view-table").classList.toggle("is-active", view === "table");
    $("#view-gallery").classList.toggle("is-active", view === "gallery");
    if (view === "gallery") {
      resetGallery();
      appendGalleryBatch().then(mountInfiniteScroll);
      window.scrollTo({ top: 0, behavior: "smooth" });
    } else {
      showPage(state.page);
    }
  }

  function bind() {
    // A poster that is still rendering comes back as 503 and shows up as an
    // `error` on the <img> (the event does not bubble, hence capture). Retry
    // with a growing backoff - by the third or fourth attempt the frame, and
    // often the whole page, is on disk.
    document.addEventListener("error", function (event) {
      var img = event.target;
      if (!img || !img.tagName || img.tagName !== "IMG" || !img.dataset || !img.dataset.poster) return;

      var attempt = Number(img.dataset.posterRetry || "0");
      if (attempt >= 6) return;

      img.dataset.posterRetry = String(attempt + 1);
      var delay = Math.min(2400, 500 * Math.pow(1.5, attempt));
      window.setTimeout(function () {
        var base = img.dataset.poster;
        img.src = base + (base.indexOf("?") >= 0 ? "&" : "?") + "retry=" + attempt;
      }, delay);
    }, true);

    $("#region").addEventListener("change", async function (event) {
      state.region = event.target.value;
      await loadMeta();
      scheduleReload();
    });

    var seedInput = $("#seed");
    seedInput.addEventListener("input", function (event) {
      state.seed = event.target.value;
      scheduleReload();
    });
    seedInput.addEventListener("change", function (event) {
      state.seed = event.target.value.trim() || "0";
      seedInput.value = state.seed;
      scheduleReload();
    });

    $("#random-seed").addEventListener("click", function () {
      state.seed = randomSeed();
      seedInput.value = state.seed;
      scheduleReload();
    });

    [["likes", "#likes-out"], ["reviews", "#reviews-out"]].forEach(function (pair) {
      var input = $("#" + pair[0]);
      var output = $(pair[1]);
      updateSlider(input, output);
      input.addEventListener("input", function () {
        state[pair[0]] = Number(input.value);
        updateSlider(input, output);
        scheduleReload();
      });
    });

    $("#view-table").addEventListener("click", function () { setView("table"); });
    $("#view-gallery").addEventListener("click", function () { setView("gallery"); });

    /* ----------------------------------------------------------- export -- */

    // A page of trailers takes a few minutes to render, so the button works
    // as a progress meter: it starts the download right away (through a
    // hidden anchor, so the page itself never navigates) and polls how many
    // trailers are ready meanwhile.
    var exportTimer = null;
    var exportLabel = $('#export [data-ui="export"]');

    function paintExport(text, busy) {
      if (exportLabel) exportLabel.textContent = text;
      $("#export").classList.toggle("is-busy", !!busy);
      $("#export").disabled = !!busy;
    }

    function stopExport() {
      clearInterval(exportTimer);
      exportTimer = null;
      $("#export").classList.remove("is-busy");
      $("#export").disabled = false;
      applyLanguage(); // puts the localized label back after the progress text
    }

    $("#export").addEventListener("click", function () {
      if (exportTimer) return;

      var page = state.view === "gallery" ? 1 : state.page;
      var archiveUrl = url("/api/export", { page: page });
      var progressUrl = url("/api/export/progress", { page: page });
      var finished = false;
      var resetTimer = null;

      exportTimer = setInterval(pollExport, 1000);
      paintExport(t("exporting", "Rendering") + " …", true);

      var anchor = document.createElement("a");
      anchor.href = archiveUrl;
      // Same-origin + `download` makes Chrome save the file instead of
      // navigating away, even if a proxy strips the attachment header.
      anchor.download = "trailers.zip";
      anchor.rel = "noopener";
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();

      function pollExport() {
        getJSON(progressUrl).then(function (data) {
          if (!data || !data.total) return;
          if (data.ready >= data.total) {
            if (finished) return;
            finished = true;
            paintExport(t("export_ready", "Downloading archive"), true);
            resetTimer = window.setTimeout(stopExport, 30000);
            return;
          }
          paintExport(t("exporting", "Rendering") + " " + data.ready + "/" + data.total, true);
        }).catch(function (error) {
          window.clearTimeout(resetTimer);
          stopExport();
          toast("Export failed: " + error.message);
        });
      }
    });

    $("#pager").addEventListener("click", function (event) {
      var button = event.target.closest("button");
      if (!button) return;
      if (button.dataset.goto) {
        showPage(Number(button.dataset.goto));
        return;
      }
      if (button.dataset.page === "prev" && state.page > 1) showPage(state.page - 1);
      if (button.dataset.page === "next") showPage(state.page + 1);
      if (button.dataset.page === "first") showPage(1);
    });

    $("#rows").addEventListener("click", function (event) {
      var row = event.target.closest("tr.row");
      if (row) toggleRow(row);
    });

    $("#gallery").addEventListener("click", function (event) {
      var card = event.target.closest(".card");
      if (card) openCard(card);
    });

    $("#gallery").addEventListener("keydown", function (event) {
      if (event.key !== "Enter" && event.key !== " ") return;
      var card = event.target.closest(".card");
      if (!card) return;
      event.preventDefault();
      openCard(card);
    });

    $("#lightbox").addEventListener("click", function (event) {
      if (event.target.hasAttribute("data-close")) closeLightbox();
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeLightbox();
    });

    // Fallback for environments where the vendored infinite-scroll library
    // could not load: plain IntersectionObserver on the sentinel.
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting && state.view === "gallery" && !window.InfiniteScroll) {
          appendGalleryBatch();
        }
      });
    }, { rootMargin: "600px 0px" });
    observer.observe($("#sentinel"));
  }

  // gallery batches are not kept in state.items - look the movie up again
  async function fetchMovie(index) {
    var page = Math.ceil(Number(index) / state.pageSize);
    try {
      var items = await loadPage(page);
      return items.find(function (item) { return String(item.index) === String(index); }) || null;
    } catch (error) {
      return null;
    }
  }

  async function init() {
    try {
      // The toolbar strings and the first page are independent requests: they
      // go out together and the table is painted as soon as both land, which
      // halves the time until the first row appears.
      var metaPromise = loadMeta();
      var pagePromise = loadPage(1).then(
        function (items) { return items; },
        function (error) { return { __failed: error }; }
      );

      await metaPromise;
      $("#seed").value = state.seed;
      state.likes = 0;
      state.reviews = 0;
      updateSlider($("#likes"), $("#likes-out"));
      updateSlider($("#reviews"), $("#reviews-out"));
      bind();

      var firstPage = await pagePromise;
      if (firstPage && firstPage.__failed) throw firstPage.__failed;
      await showPage(1, firstPage);
    } catch (error) {
      toast("Boot failed: " + error.message);
      console.error(error);
    }
  }

  init();
})();
