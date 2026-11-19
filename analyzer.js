/* SW Oto Klip - analiz motoru (gizli WebView icinde calisir) */
(function () {
  'use strict';
  if (window.__swLoaded) return;
  window.__swLoaded = true;

  var TW_CLIENT = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
  var TW_HASH = 'b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a';

  var cancelled = false;
  window.swCancel = function () { cancelled = true; };

  function post(o) { try { SW.postMessage(JSON.stringify(o)); } catch (e) {} }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  var lastProg = 0;
  function prog(pct, text, force) {
    var n = Date.now();
    if (!force && n - lastProg < 400) return;
    lastProg = n;
    post({ type: 'progress', pct: Math.max(0, Math.min(1, pct)), text: text });
  }

  async function waitFor(fn, ms) {
    var t0 = Date.now();
    while (Date.now() - t0 < ms && !cancelled) {
      var v = null;
      try { v = fn(); } catch (e) {}
      if (v) return v;
      await sleep(300);
    }
    return null;
  }

  async function fj(url, opt, tries) {
    tries = tries || 3;
    for (var i = 0; i < tries && !cancelled; i++) {
      try {
        var r = await fetch(url, opt);
        var t = await r.text();
        if (r.ok) {
          try { return JSON.parse(t); } catch (e) {}
        }
        if (r.status === 429) await sleep(2500 * (i + 1));
        else await sleep(800 * (i + 1));
      } catch (e) {
        await sleep(800 * (i + 1));
      }
    }
    return null;
  }

  function normTime(s) {
    s = String(s == null ? '' : s).trim();
    if (/^\d{4}-\d\d-\d\d \d/.test(s)) s = s.replace(' ', 'T');
    if (!/(Z|[+-]\d\d:?\d\d)$/.test(s)) s += 'Z';
    return s;
  }

  async function runSegments(n, label, countFn, walk) {
    var done = new Array(n).fill(0);
    function upd(i, f) {
      done[i] = Math.max(0, Math.min(1, f));
      var s = 0;
      for (var k = 0; k < done.length; k++) s += done[k];
      var p = s / n;
      prog(0.06 + 0.88 * p, label + ' %' + Math.round(p * 100) + ' \u2022 ' + countFn() + ' mesaj');
    }
    var jobs = [];
    for (var i = 0; i < n; i++) {
      (function (idx) { jobs.push(walk(idx, function (f) { upd(idx, f); })); })(i);
    }
    await Promise.all(jobs);
  }

  /* ---------------- YOUTUBE ---------------- */
  function ytText(msg) {
    if (!msg || !msg.runs) return '';
    var out = '';
    for (var i = 0; i < msg.runs.length; i++) {
      var r = msg.runs[i];
      if (r.text !== undefined) out += r.text;
      else if (r.emoji) {
        if (r.emoji.isCustomEmoji) out += (r.emoji.shortcuts && r.emoji.shortcuts[0]) || '';
        else out += r.emoji.emojiId || '';
        out += ' ';
      }
    }
    return out;
  }

  function findHeat(o, out, depth) {
    if (!o || typeof o !== 'object' || depth > 45) return;
    if (Array.isArray(o)) {
      for (var i = 0; i < o.length; i++) findHeat(o[i], out, depth + 1);
      return;
    }
    if (o.heatMarkerRenderer) {
      var h = o.heatMarkerRenderer;
      var s0 = Number(h.timeRangeStartMillis) / 1000;
      var d0 = Number(h.markerDurationMillis) / 1000;
      var v0 = Number(h.heatMarkerIntensityScoreNormalized);
      if (isFinite(s0) && isFinite(d0) && isFinite(v0)) out.push({ s: s0, e: s0 + d0, v: v0 });
    } else if (o.intensityScoreNormalized !== undefined && o.startMillis !== undefined) {
      var s1 = Number(o.startMillis) / 1000;
      var d1 = Number(o.durationMillis) / 1000;
      var v1 = Number(o.intensityScoreNormalized);
      if (isFinite(s1) && isFinite(d1) && isFinite(v1)) out.push({ s: s1, e: s1 + d1, v: v1 });
    }
    for (var k in o) {
      if (Object.prototype.hasOwnProperty.call(o, k)) findHeat(o[k], out, depth + 1);
    }
  }

  async function ytFetch(P) {
    prog(0.02, 'YouTube sayfası okunuyor\u2026', true);
    var data = await waitFor(function () { return window.ytInitialData; }, 25000);
    var pr = await waitFor(function () { return window.ytInitialPlayerResponse; }, 6000);
    if (!data) throw new Error('YouTube sayfası okunamadı. Çerez/onay ekranı çıkmış olabilir, tekrar dene.');
    var vd = (pr && pr.videoDetails) || {};
    if (vd.isLive) throw new Error('Bu yayın hâlâ canlı. Yayın bitince kayıt linkiyle tekrar dene.');
    var title = vd.title || 'YouTube videosu';
    var duration = parseInt(vd.lengthSeconds, 10) || 0;
    var meta = { platform: 'youtube', id: P.id, title: title, duration: duration, source: '' };
    post({ type: 'meta', meta: meta });

    var heat = [];
    try { findHeat(data, heat, 0); } catch (e) {}
    var seenH = {};
    heat = heat.filter(function (h) { var k = h.s.toFixed(2); if (seenH[k]) return false; seenH[k] = 1; return true; });

    var cont = null;
    try {
      var lcr = data.contents.twoColumnWatchNextResults.conversationBar.liveChatRenderer;
      var items = (lcr.header && lcr.header.liveChatHeaderRenderer && lcr.header.liveChatHeaderRenderer.viewSelector &&
        lcr.header.liveChatHeaderRenderer.viewSelector.sortFilterSubMenuRenderer &&
        lcr.header.liveChatHeaderRenderer.viewSelector.sortFilterSubMenuRenderer.subMenuItems) || [];
      if (items.length) {
        var last = items[items.length - 1];
        cont = last && last.continuation && last.continuation.reloadContinuationData && last.continuation.reloadContinuationData.continuation;
      }
      if (!cont && lcr.continuations && lcr.continuations[0] && lcr.continuations[0].reloadContinuationData) {
        cont = lcr.continuations[0].reloadContinuationData.continuation;
      }
    } catch (e) { cont = null; }

    var cfg = window.ytcfg;
    var ctx = cfg && cfg.get ? cfg.get('INNERTUBE_CONTEXT') : null;
    var key = cfg && cfg.get ? cfg.get('INNERTUBE_API_KEY') : null;

    var msgs = [];
    if (cont && ctx && key && duration > 0) {
      var seen = new Set();
      var url = '/youtubei/v1/live_chat/get_live_chat_replay?key=' + encodeURIComponent(key) + '&prettyPrint=false';
      var nseg = Math.min(6, Math.max(1, Math.ceil(duration / 1200)));
      var segLen = duration / nseg;
      await runSegments(nseg, 'Sohbet taranıyor', function () { return msgs.length; }, async function (i, report) {
        var a = i * segLen, b = (i + 1) * segLen;
        var c = cont, pos = a * 1000, stall = 0, it = 0;
        while (!cancelled && it++ < 8000) {
          var body = { context: ctx, continuation: c, currentPlayerState: { playerOffsetMs: String(Math.max(0, Math.floor(pos))) } };
          var r = await fj(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }, 3);
          var lc = r && r.continuationContents && r.continuationContents.liveChatContinuation;
          if (!lc) break;
          var maxOff = -1;
          var acts = lc.actions || [];
          for (var x = 0; x < acts.length; x++) {
            var ra = acts[x].replayChatItemAction;
            if (!ra) continue;
            var o = parseInt(ra.videoOffsetTimeMsec, 10);
            if (!isFinite(o)) continue;
            if (o > maxOff) maxOff = o;
            var inner = ra.actions || [];
            for (var y = 0; y < inner.length; y++) {
              var item = inner[y].addChatItemAction && inner[y].addChatItemAction.item;
              if (!item) continue;
              var rd = item.liveChatTextMessageRenderer || item.liveChatPaidMessageRenderer;
              if (!rd) continue;
              if (rd.id) { if (seen.has(rd.id)) continue; seen.add(rd.id); }
              msgs.push({ t: Math.max(0, o / 1000), u: rd.authorExternalChannelId || null, x: ytText(rd.message), p: !!item.liveChatPaidMessageRenderer });
            }
          }
          var next = null;
          var conts = lc.continuations || [];
          for (var z = 0; z < conts.length; z++) {
            var cc = conts[z];
            var dd = cc.liveChatReplayContinuationData || cc.playerSeekContinuationData || cc.timedContinuationData;
            if (dd && dd.continuation) { next = dd.continuation; break; }
          }
          var np = maxOff >= 0 ? maxOff : pos + 20000;
          if (np > pos) stall = 0; else stall++;
          pos = np;
          report((pos / 1000 - a) / (b - a));
          if (pos / 1000 >= b || !next || stall > 10) break;
          c = next;
        }
        report(1);
      });
    }
    return { meta: meta, msgs: msgs, duration: duration, heat: heat };
  }

  /* ---------------- KICK ---------------- */
  function cleanKick(s) {
    return String(s == null ? '' : s).replace(/\[emote:\d+:([^\]]+)\]/g, '$1 ');
  }

  async function kickFetch(P) {
    prog(0.02, 'Kick kaydı sorgulanıyor\u2026', true);
    var info = null;
    for (var i = 0; i < 15 && !cancelled; i++) {
      info = await fj('/api/v1/video/' + P.id, { headers: { Accept: 'application/json' } }, 1);
      if (info && (info.livestream || info.source)) break;
      info = null;
      prog(0.02, 'Kick erişim doğrulaması bekleniyor\u2026 (' + (i + 1) + ')', true);
      await sleep(3000);
    }
    if (!info) throw new Error('Kick verisine erişilemedi (Cloudflare engeli olabilir). Biraz sonra tekrar dene.');
    var ls = info.livestream || {};
    var title = ls.session_title || info.title || 'Kick VOD';
    var source = info.source || ls.source || '';
    var ch = ls.channel_id || (ls.channel && ls.channel.id) || null;
    if (!ch) {
      var slug = (ls.channel && ls.channel.slug) || ls.slug || null;
      if (slug) {
        var chi = await fj('/api/v2/channels/' + slug, { headers: { Accept: 'application/json' } }, 2);
        if (chi && chi.id) ch = chi.id;
      }
    }
    var startMs = Date.parse(normTime(ls.start_time || ls.created_at || info.created_at));
    var dur = Number(ls.duration || info.duration || 0);
    if (dur > 172800) dur = dur / 1000;
    if (!ch) throw new Error('Kick kanal bilgisi okunamadı.');
    if (!isFinite(startMs)) throw new Error('Kick yayın başlangıç zamanı okunamadı.');
    if (!dur) throw new Error('Kick yayın süresi okunamadı.');
    var meta = { platform: 'kick', id: P.id, title: title, duration: dur, source: source };
    post({ type: 'meta', meta: meta });

    var msgs = [];
    var seen = new Set();
    var nseg = Math.min(6, Math.max(1, Math.ceil(dur / 1200)));
    var segLen = dur / nseg;
    await runSegments(nseg, 'Sohbet taranıyor', function () { return msgs.length; }, async function (i, report) {
      var a = startMs + i * segLen * 1000;
      var b = startMs + (i + 1) * segLen * 1000;
      var cur = a, stall = 0, it = 0;
      while (!cancelled && cur < b && it++ < 9000) {
        var r = await fj('/api/v2/channels/' + ch + '/messages?start_time=' + encodeURIComponent(new Date(cur).toISOString()), { headers: { Accept: 'application/json' } }, 3);
        var list = (r && r.data && r.data.messages) || [];
        var maxT = -1;
        for (var k = 0; k < list.length; k++) {
          var m = list[k];
          var tm = Date.parse(normTime(m.created_at));
          if (!isFinite(tm)) continue;
          if (tm > maxT) maxT = tm;
          if (m.id != null) { if (seen.has(m.id)) continue; seen.add(m.id); }
          var t = (tm - startMs) / 1000;
          if (t < 0 || t > dur + 120) continue;
          msgs.push({ t: t, u: (m.sender && m.sender.id) || m.user_id || null, x: cleanKick(m.content), p: false });
        }
        if (maxT > cur) { cur = maxT; stall = 0; } else { cur += 5000; stall++; }
        report((cur - a) / (b - a));
        if (r === null && stall > 40) break;
      }
      report(1);
    });
    return { meta: meta, msgs: msgs, duration: dur, heat: [] };
  }

  /* ---------------- TWITCH ---------------- */
  async function gql(body) {
    for (var i = 0; i < 3 && !cancelled; i++) {
      try {
        var r = await fetch('https://gql.twitch.tv/gql', {
          method: 'POST',
          headers: { 'Client-Id': TW_CLIENT, 'Content-Type': 'text/plain;charset=UTF-8' },
          body: JSON.stringify(body)
        });
        if (r.ok) return await r.json();
        await sleep(800 * (i + 1));
      } catch (e) {
        await sleep(800 * (i + 1));
      }
    }
    return null;
  }

  async function twitchFetch(P) {
    prog(0.02, 'Twitch kaydı sorgulanıyor\u2026', true);
    var info = await gql({ query: 'query{video(id:"' + P.id + '"){title lengthSeconds}}' });
    var v = info && info.data && info.data.video;
    if (!v) throw new Error('Twitch kaydı bulunamadı (silinmiş ya da gizli olabilir).');
    var dur = Number(v.lengthSeconds) || 0;
    if (!dur) throw new Error('Twitch kayıt süresi okunamadı.');
    var meta = { platform: 'twitch', id: P.id, title: v.title || 'Twitch VOD', duration: dur, source: '' };
    post({ type: 'meta', meta: meta });

    var msgs = [];
    var seen = new Set();
    var nseg = Math.min(6, Math.max(1, Math.ceil(dur / 1200)));
    var segLen = dur / nseg;
    await runSegments(nseg, 'Sohbet taranıyor', function () { return msgs.length; }, async function (i, report) {
      var a = i * segLen, b = (i + 1) * segLen;
      var cursor = null, it = 0, finished = false;
      while (!cancelled && !finished && it++ < 9000) {
        var vars = cursor ? { videoID: P.id, cursor: cursor } : { videoID: P.id, contentOffsetSeconds: Math.floor(a) };
        var r = await gql({ operationName: 'VideoCommentsByOffsetOrCursor', variables: vars, extensions: { persistedQuery: { version: 1, sha256Hash: TW_HASH } } });
        var c = r && r.data && r.data.video && r.data.video.comments;
        if (!c) break;
        var edges = c.edges || [];
        for (var k = 0; k < edges.length; k++) {
          var n = edges[k].node;
          if (!n) continue;
          var t = Number(n.contentOffsetSeconds);
          if (!isFinite(t)) continue;
          if (t > b) { finished = true; break; }
          if (n.id) { if (seen.has(n.id)) continue; seen.add(n.id); }
          var frs = (n.message && n.message.fragments) || [];
          var txt = '';
          for (var q = 0; q < frs.length; q++) txt += (frs[q].text || '');
          msgs.push({ t: t, u: (n.commenter && n.commenter.id) || null, x: txt, p: false });
          report((t - a) / (b - a));
        }
        cursor = edges.length ? edges[edges.length - 1].cursor : null;
        if (!cursor || !(c.pageInfo && c.pageInfo.hasNextPage)) break;
      }
      report(1);
    });
    return { meta: meta, msgs: msgs, duration: dur, heat: [] };
  }

  /* ---------------- ANALIZ ---------------- */
  var RE_LAUGH = /kekw|\bkek\b|lul|lmao|lmfao|\bxd+\b|(?:ha){3,}|(?:ah){3,}|(?:he){3,}|\u{1F602}|\u{1F923}|\u{1F606}|\u00f6ld\u00fcm|g\u00fclmekten|jaja/iu;
  var RE_HYPE = /pog|\bgg\b|\bgol+\b|efsane|inanilmaz|inan\u0131lmaz|vay be|\byu+h+\b|yo{3,}|hype|let'?s ?go|letsgo|\u{1F525}|\u{1F44F}|\u{1F64C}|m\u00fcthi\u015f|muthis|harika|clutch|insane|crazy|\bgoat\b|(?:^|\s)w+(?:\s|$)/iu;
  var RE_SHOCK = /wtf|omg|omfg|\bwow+\b|no way|no+o{2,}|\?\?+|\u{1F631}|\u{1F92F}|\u{1F480}|yok art\u0131k|yok artik|olamaz|ne ya\b|what the|nas\u0131l ya/iu;
  var RE_CLIP = /\bkl[i\u0131]p\b|\bclip\b|klip al|clip it|clip that/iu;
  var STOP = new Set(('bu ve bir de da mi m\u0131 mu m\u00fc ne ya ama ben sen o biz siz onlar \u00e7ok i\u00e7in gibi bak var yok ki ile daha en her \u015fey the and you is it to a of in that this what are was for on be i me my so at lol').split(' '));

  function prepare(D) {
    var msgs = D.msgs.filter(function (m) { return isFinite(m.t) && m.t >= 0; });
    msgs.sort(function (a, b) { return a.t - b.t; });
    var n = msgs.length;
    var maxT = n ? msgs[n - 1].t : 0;
    var dur = Math.max(60, Math.ceil(D.duration > 0 ? D.duration : maxT + 30));
    var T = new Float32Array(n), W = new Float32Array(n), F = new Uint8Array(n);
    var pw = new Float64Array(dur + 2);
    for (var i = 0; i < n; i++) {
      var m = msgs[i];
      var x = (m.x || '').slice(0, 200);
      m.x = x;
      var f = 0, w = 1;
      if (RE_LAUGH.test(x)) { f |= 1; w += 0.8; }
      if (RE_HYPE.test(x)) { f |= 2; w += 1; }
      if (RE_SHOCK.test(x)) { f |= 4; w += 1; }
      if (RE_CLIP.test(x)) { f |= 8; w += 2.5; }
      if (m.p) { f |= 16; w += 2; }
      if (w > 4) w = 4;
      T[i] = m.t; W[i] = w; F[i] = f;
      var sec = Math.min(dur, Math.floor(m.t));
      pw[sec + 1] += w;
    }
    for (var k = 1; k < pw.length; k++) pw[k] += pw[k - 1];
    return { meta: D.meta, dur: dur, msgs: msgs, T: T, W: W, F: F, pw: pw, heat: D.heat || [], n: n };
  }

  function lowerBound(arr, v) {
    var lo = 0, hi = arr.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (arr[mid] < v) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

  function rank(S, P) {
    var B = 20;
    var dur = S.dur;
    var hasChat = S.n >= 30;
    var hasHeat = S.heat.length > 0;
    if (!hasChat && !hasHeat) throw new Error('Bu videoda yeterli sohbet verisi bulunamadı (sohbet tekrarı kapalı olabilir).');
    var clipLen = Math.max(15, Number(P.clipLen) || 45);
    var maxClips = Math.max(1, Number(P.maxClips) || 12);
    var pw = S.pw;

    var hArr = new Float32Array(dur + 1);
    for (var hi0 = 0; hi0 < S.heat.length; hi0++) {
      var h = S.heat[hi0];
      var a0 = Math.max(0, Math.floor(h.s)), b0 = Math.min(dur, Math.ceil(h.e));
      for (var q = a0; q < b0; q++) if (h.v > hArr[q]) hArr[q] = h.v;
    }

    var sArr = new Float32Array(dur), lArr = new Float32Array(dur), raw = new Float32Array(dur);
    var sMax = 1;
    if (hasChat) {
      for (var t = 0; t < dur; t++) {
        var hiB = Math.min(dur, t + B);
        var s = pw[hiB] - pw[t];
        var lo2 = Math.max(0, t - 300), hi2 = Math.min(dur, t + 300);
        var mean = (pw[hi2] - pw[lo2]) / Math.max(1, hi2 - lo2);
        sArr[t] = s;
        lArr[t] = s / (mean * B + 3);
        if (s > sMax) sMax = s;
      }
    }
    for (var t2 = 0; t2 < dur; t2++) {
      var hv = hArr[Math.min(dur, t2 + 10)];
      var r;
      if (hasChat) {
        r = 0.55 * clamp01(lArr[t2] / 6) + 0.45 * (sArr[t2] / sMax);
        if (hasHeat) r = 0.8 * r + 0.2 * hv;
        if (sArr[t2] < 6) r *= 0.2;
      } else {
        r = hv;
      }
      raw[t2] = r;
    }

    var order = new Array(dur);
    for (var oi = 0; oi < dur; oi++) order[oi] = oi;
    order.sort(function (x, y) { return raw[y] - raw[x]; });

    var sep = Math.max(clipLen, 30);
    var minRaw = hasChat ? 0.2 : 0.15;
    var picks = [];
    for (var pi = 0; pi < order.length && picks.length < maxClips; pi++) {
      var t0 = order[pi];
      if (raw[t0] < minRaw) break;
      var ok = true;
      for (var j = 0; j < picks.length; j++) { if (Math.abs(picks[j] - t0) < sep) { ok = false; break; } }
      if (ok) picks.push(t0);
    }

    var lead = hasChat ? Math.round(clipLen * 0.35) : 0;
    var totalMsgs = S.n;
    var avgPerMin = totalMsgs / dur * 60;
    var clips = [];
    for (var ci = 0; ci < picks.length; ci++) {
      var p0 = picks[ci];
      var start = Math.max(0, p0 - lead);
      var end = Math.min(dur, start + clipLen);
      if (end - start < clipLen) start = Math.max(0, end - clipLen);

      var lo = lowerBound(S.T, start), hi = lowerBound(S.T, end);
      var count = hi - lo;
      var users = new Set();
      for (var u = lo; u < hi; u++) { var uid = S.msgs[u].u; if (uid != null) users.add(uid); }

      var bl = lowerBound(S.T, Math.max(0, p0 - 5)), bh = lowerBound(S.T, p0 + B + 5);
      var bn = bh - bl;
      var fc = [0, 0, 0, 0, 0];
      var words = {};
      var flagged = [], plain = [], seenTxt = {};
      for (var bi = bl; bi < bh; bi++) {
        var f = S.F[bi];
        if (f & 1) fc[0]++;
        if (f & 2) fc[1]++;
        if (f & 4) fc[2]++;
        if (f & 8) fc[3]++;
        if (f & 16) fc[4]++;
        var tx = S.msgs[bi].x || '';
        var toks = tx.toLowerCase().split(/[\s,.!?;:()"]+/);
        for (var ti = 0; ti < toks.length; ti++) {
          var w = toks[ti];
          if (w.length < 2 || STOP.has(w) || /^\d+$/.test(w)) continue;
          words[w] = (words[w] || 0) + 1;
        }
        var key = tx.toLowerCase();
        if (tx.length >= 3 && !seenTxt[key]) {
          seenTxt[key] = 1;
          if (f) flagged.push(tx.slice(0, 60)); else if (tx.length >= 8) plain.push(tx.slice(0, 60));
        }
      }
      var wl = Object.keys(words).filter(function (k) { return words[k] >= 3; })
        .sort(function (x, y) { return words[y] - words[x]; }).slice(0, 4)
        .map(function (k) { return k + ' \u00d7' + words[k]; });
      var samples = flagged.concat(plain).slice(0, 3);

      var heatV = hArr[Math.min(dur, p0 + 10)];
      var tags = [];
      if (bn > 0) {
        if (fc[0] / bn >= 0.2) tags.push('\u{1F602} Komik / g\u00fclme');
        if (fc[1] / bn >= 0.2) tags.push('\u{1F525} Hype');
        if (fc[2] / bn >= 0.15) tags.push('\u{1F631} \u015eok / tepki');
        if (fc[3] >= 3) tags.push('\u{1F3AC} Chat klip istedi');
        if (fc[4] > 0) tags.push('\u{1F4B8} S\u00fcper sohbet');
      }
      if (heatV >= 0.65) tags.push('\u{1F4C8} En \u00e7ok izlenen');
      if (!tags.length) tags.push('\u{1F4AC} Chat yo\u011funlu\u011fu');

      var score = Math.round(100 * raw[p0]);
      clips.push({
        rank: ci + 1,
        start: start, end: end, peak: p0 + B / 2,
        score: Math.max(1, Math.min(100, score)),
        count: count,
        perMin: count * 60 / Math.max(1, end - start),
        lift: hasChat ? lArr[p0] : 0,
        users: users.size,
        heat: heatV,
        tags: tags, words: wl, samples: samples
      });
    }
    return {
      meta: S.meta, hasChat: hasChat, hasHeat: hasHeat,
      totalMessages: totalMsgs, avgPerMin: avgPerMin, durationSec: dur, clips: clips
    };
  }

  window.__swInternals = { prepare: prepare, rank: rank };

  window.swStart = async function (P) {
    if (window.__swRunning) return;
    window.__swRunning = true;
    cancelled = false;
    try {
      prog(0.01, 'Ba\u015fl\u0131yor\u2026', true);
      var D;
      if (P.platform === 'youtube') D = await ytFetch(P);
      else if (P.platform === 'kick') D = await kickFetch(P);
      else if (P.platform === 'twitch') D = await twitchFetch(P);
      else throw new Error('Desteklenmeyen platform');
      if (cancelled) throw new Error('\u0130ptal edildi');
      prog(0.97, 'Analiz ediliyor\u2026', true);
      window.__swD = prepare(D);
      var res = rank(window.__swD, P);
      res.type = 'result';
      post(res);
    } catch (e) {
      post({ type: 'error', text: String((e && e.message) || e) });
    }
    window.__swRunning = false;
  };

  window.swRerank = function (P) {
    try {
      if (!window.__swD) return;
      var res = rank(window.__swD, P);
      res.type = 'result';
      res.rerank = true;
      post(res);
    } catch (e) {
      post({ type: 'error', text: String((e && e.message) || e) });
    }
  };
})();
