/* ========== COCO APP 核心库 ========== */
// 站点地址：APP内（file://）用绝对地址；网页版（http/https 同源）用相对地址
var SITE = (location.protocol === 'http:' || location.protocol === 'https:') ? '' : 'https://dutv.eu.org';
var API = SITE + '/api.php/provide/vod/';

var Coco = {
  // 分类缓存
  classes: [],
  _seq: 0,
  _nbcbs: {},
  // 原生通道回调（Android OkHttp请求后回传）
  _nativeResp: function (cbId, text, err) {
    var cb = Coco._nbcbs[cbId];
    if (!cb) return;
    delete Coco._nbcbs[cbId];
    if (err) { cb(new Error(err)); return; }
    try { cb(null, JSON.parse(text)); } catch (e) { cb(null, { __raw: text }); }
  },
  /* ---------- 底层请求：APP内走原生OkHttp，浏览器走JSONP ---------- */
  jsonp: function (params, cb) {
    params.ac = params.ac || 'list';
    params.at = 'json';
    var qs = Object.keys(params).map(function (k) {
      return k + '=' + encodeURIComponent(params[k]);
    }).join('&');
    var url = API + '?' + qs;

    // 1) 原生通道（最稳，不受跨域/混合内容限制）
    if (window.AndroidBridge && AndroidBridge.request) {
      var cbId = 'nb_' + (++Coco._seq);
      var done = false;
      var timer = setTimeout(function () {
        if (done) return; done = true;
        delete Coco._nbcbs[cbId]; cb(new Error('timeout'));
      }, 15000);
      Coco._nbcbs[cbId] = function () {
        done = true; clearTimeout(timer); cb.apply(null, arguments);
      };
      try { AndroidBridge.request(url, cbId); }
      catch (e) { clearTimeout(timer); delete Coco._nbcbs[cbId]; cb(e); }
      return;
    }

    // 2) 浏览器兜底：同源 XHR（网页版部署在同一站点，无跨域问题）
    var xhr = new XMLHttpRequest();
    xhr.open('GET', url);
    xhr.timeout = 15000;
    xhr.onload = function () {
      try { cb && cb(null, JSON.parse(xhr.responseText)); }
      catch (e) { cb && cb(new Error('parse')); }
    };
    xhr.onerror = function () { cb && cb(new Error('network')); };
    xhr.ontimeout = function () { cb && cb(new Error('timeout')); };
    xhr.send();
    return;
  },
  /* ---------- POST表单请求（登录/注册/找回） ---------- */
  post: function (path, data, cb) {
    var url = SITE + path;
    var qs = Object.keys(data).map(function (k) {
      return k + '=' + encodeURIComponent(data[k]);
    }).join('&');
    if (window.AndroidBridge && AndroidBridge.post) {
      var cbId = 'nb_' + (++Coco._seq);
      var done = false;
      var timer = setTimeout(function () {
        if (done) return; done = true;
        delete Coco._nbcbs[cbId]; cb && cb(new Error('timeout'));
      }, 15000);
      Coco._nbcbs[cbId] = function () {
        done = true; clearTimeout(timer);
        if (cb) cb.apply(null, arguments);
      };
      try { AndroidBridge.post(url, qs, cbId); }
      catch (e) { clearTimeout(timer); delete Coco._nbcbs[cbId]; cb && cb(e); }
      return;
    }
    // 浏览器兜底：隐藏表单提交（同步跳转）不适用，用fetch
    if (window.fetch) {
      fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' }, body: qs })
        .then(function (r) { return r.json(); })
        .then(function (d) { cb && cb(null, d); })
        .catch(function (e) { cb && cb(e); });
    } else {
      cb && cb(new Error('no support'));
    }
  },
  /* ---------- 用户态 ---------- */
  _userKey: 'coco_user',
  getUser: function () { try { return JSON.parse(localStorage.getItem(Coco._userKey) || 'null'); } catch (e) { return null; } },
  setUser: function (u) { if (u) localStorage.setItem(Coco._userKey, JSON.stringify(u)); else localStorage.removeItem(Coco._userKey); },
  isLogin: function () { return !!Coco.getUser(); },
  login: function (name, pwd, cb) {
    Coco.post('/index.php/user/login', { user_name: name, user_pwd: pwd }, function (err, d) {
      if (!err && d && d.code == 1) Coco.setUser({ name: name });
      cb && cb(err, d);
    });
  },
  reg: function (name, pwd, pwd2, cb) {
    Coco.post('/index.php/user/reg', { user_name: name, user_pwd: pwd, user_pwd2: pwd2 }, function (err, d) {
      if (!err && d && d.code == 1) Coco.setUser({ name: name });
      cb && cb(err, d);
    });
  },
  logout: function (cb) {
    Coco.post('/index.php/user/logout', {}, function (err, d) {
      Coco.setUser(null);
      // 退出登录清除本地详情缓存，避免会员可见的播放地址残留在游客状态
      try { Object.keys(localStorage).forEach(function(k){ if(k.indexOf('coco_d_v')===0) localStorage.removeItem(k); }); } catch(e){}
      cb && cb(err, d);
    });
  },
  /* ---------- 评论列表（解析 comment/ajax） ---------- */
  comments: function (rid, page, cb) {
    Coco.getRaw('/index.php/comment/ajax?mid=1&rid=' + rid + '&p=' + (page || 1), function (err, raw) {
      if (err) { cb && cb(err); return; }
      var html = (raw && raw.__raw) || raw || '';
      if (!html) { cb && cb(new Error('empty')); return; }
      var list = [], re = /cmt_item[\s\S]*?<span class="fr">([^<]+)<[\s\S]*?<a class="name"[^>]*>([^<]+)<[\s\S]*?<p class="con">([\s\S]*?)<\/p>/g, m;
      while ((m = re.exec(html))) {
        list.push({
          name: m[2].trim(),
          time: (m[1] || '').trim(),
          content: m[3].replace(/<[^>]+>/g, '').trim()
        });
        if (list.length >= 20) break;
      }
      // 总条数
      var total = 0, tm = /item_count[^>]*>(\d+)</.exec(html);
      if (tm) total = +tm[1];
      cb(null, { list: list, total: total });
    });
  },
  /* ---------- 发表评论 ---------- */
  addComment: function (rid, content, cb) {
    Coco.post('/index.php/comment/saveData', { comment_mid: 1, comment_rid: rid, comment_content: content }, cb);
  },
  /* ---------- 原始文本请求（会员页数据源，HTML解析用） ---------- */
  getRaw: function (path, cb) {
    var url = path.indexOf('http') === 0 ? path : SITE + path;
    // WebView内优先走浏览器fetch（等同正常浏览器访问，服务器放行；原生OkHttp通道常被服务器500拒绝）
    if (window.fetch) {
      fetch(url, { credentials: 'include' })
        .then(function (r) { return r.text(); })
        .then(function (t) { cb && cb(null, t); })
        .catch(function (e) { cb && cb(e); });
      return;
    }
    if (window.AndroidBridge && AndroidBridge.request) {
      var cbId = 'nb_' + (++Coco._seq);
      var done = false;
      var timer = setTimeout(function () {
        if (done) return; done = true;
        delete Coco._nbcbs[cbId]; cb && cb(new Error('timeout'));
      }, 15000);
      Coco._nbcbs[cbId] = function () {
        done = true; clearTimeout(timer);
        cb && cb.apply(null, arguments);
      };
      try { AndroidBridge.request(url, cbId); }
      catch (e) { clearTimeout(timer); delete Coco._nbcbs[cbId]; cb && cb(e); }
      return;
    }
    cb && cb(new Error('no support'));
  },
  /* ---------- 会员信息（解析 /index.php/user/ajax_info 页面） ---------- */
  memberInfo: function (cb) {
    Coco.getRaw('/index.php/user/ajax_info', function (err, raw) {
      if (err) { cb && cb(err); return; }
      var html = (raw && raw.__raw) || raw || '';
      if (!html) { cb && cb(new Error('empty')); return; }
      function pick(p) {
        var m = new RegExp(p + '：([^<\\n]+)').exec(html);
        return m ? m[1].trim() : '';
      }
      cb(null, {
        name: pick('会员名'),
        group: pick('会员等级'),
        points: pick('剩余积分'),
        lastLogin: pick('上次登录时间'),
        loginNum: pick('登录次数')
      });
    });
  },
  /* ---------- 会员等级+到期时间（解析 /index.php/user/upgrade 页面） ---------- */
  upgradeData: function (cb) {
    Coco.getRaw('/index.php/user/upgrade', function (err, raw) {
      if (err) { cb && cb(err); return; }
      var html = (raw && raw.__raw) || raw || '';
      if (!html) { cb && cb(new Error('empty')); return; }
      var groups = [], map = {};
      var re = /data-id="(\d+)" data-name="([^"]+)" data-points="(\d+)" data-long="(\w+)"/g, m;
      while ((m = re.exec(html))) {
        if (!map[m[1]]) { map[m[1]] = { id: m[1], name: m[2], points: {} }; groups.push(map[m[1]]); }
        map[m[1]].points[m[4]] = m[3];
      }
      var etm = /(\d{4}-\d{2}-\d{2}[^\s<]*|无限期|永久)/.exec(html);
      cb(null, { groups: groups, endTime: etm ? etm[1].trim() : '' });
    });
  },
  /* ---------- 积分兑换会员（POST升级） ---------- */
  exchange: function (groupId, long, cb) {
    Coco.post('/index.php/user/upgrade', { group_id: groupId, long: long }, cb);
  },
  /* ---------- 充值记录（解析 /index.php/user/orders 页面） ---------- */
  orders: function (cb) {
    Coco.getRaw('/index.php/user/orders', function (err, raw) {
      if (err) { cb && cb(err); return; }
      var html = (raw && raw.__raw) || raw || '';
      if (!html) { cb && cb(new Error('empty')); return; }
      var list = [], re = /<tr>([\s\S]*?)<\/tr>/g, tr;
      while ((tr = re.exec(html))) {
        var tds = [], tdRe = /<td[^>]*>([\s\S]*?)<\/td>/g, td;
        while ((td = tdRe.exec(tr[1]))) tds.push(td[1].replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim());
        if (tds.length >= 7 && tds[2]) {
          list.push({
            id: tds[0].replace(/\D/g, ''),
            code: tds[2],
            status: tds[3],
            price: tds[4],
            points: tds[5],
            time: tds[6]
          });
        }
      }
      cb(null, list);
    });
  },
  /* ---------- 打开网页（找回密码等） ---------- */
  openWeb: function (path, title) {
    var url = path.indexOf('http') === 0 ? path : SITE + path;
    if (window.AndroidBridge && AndroidBridge.openWeb) { AndroidBridge.openWeb(url); return; }
    window.open(url, '_blank');
  },
  /* ---------- 获取顶级分类（探测频道页子导航，服务器API无type_pid层级） ---------- */
  loadClasses: function (cb) {
    var CACHE_KEY = 'coco_classes_v5';
    if (Coco.classes.length) { cb && cb(Coco.classes); return; }
    try {
      var c = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
      if (c && c.tops && Date.now() - c.t < 2 * 3600 * 1000) {
        Coco.classes = c.tops; cb && cb(Coco.classes); return;
      }
    } catch (e) {}
    Coco.jsonp({ ac: 'list', pg: 1 }, function (err, d) {
      if (err || !d || !d.class || !d.class.length) { cb && cb([]); return; }
      var all = d.class;
      var byId = {};
      all.forEach(function (c) { byId[String(c.type_id)] = c; });
      // 内置完整分类层级（依据本后台实际结构：7个顶级 + 全部二级，覆盖1-50全部分类）。
      // 说明：后台 type_pid 只配了电影/连续剧的部分子类，频道页探测不可靠，
      // 因此以 API 扫描验证过的静态层级为准，探测仅作"未来新增顶级"的补充。
      var TOP_MAP = {
        '1':  [6, 7, 8, 9, 10, 11, 12, 25, 26, 27, 30],   // 电影
        '2':  [13, 14, 15, 16, 20, 21, 22, 23, 24],       // 连续剧
        '3':  [38, 39, 40, 41],                            // 综艺
        '4':  [35, 36, 37],                                // 动漫
        '5':  [17, 18],                                    // 资讯(公告/头条)
        '28': [31, 32, 33, 34],                            // 体育赛事
        '29': [42, 43, 44, 45, 46, 47, 48, 49, 50]         // 短剧
      };
      var tops = [];
      Object.keys(TOP_MAP).forEach(function (tid) {
        var t = byId[tid];
        if (!t) return;
        var subs = (TOP_MAP[tid] || []).map(function (sid) {
          var s = byId[String(sid)];
          return s ? { type_id: sid, type_name: s.type_name } : null;
        }).filter(Boolean);
        tops.push({ type_id: t.type_id, type_name: t.type_name, subs: subs });
      });
      // 补充：内置表未覆盖的分类（后台未来新增）——探测其频道页，有子导航视为新顶级
      var topIds = {}, subIds = {};
      tops.forEach(function (t) {
        topIds[String(t.type_id)] = true;
        (t.subs || []).forEach(function (s) { subIds[String(s.type_id)] = true; });
      });
      var extra = all.filter(function (c) {
        var id = String(c.type_id);
        return !topIds[id] && !subIds[id];
      });
      if (extra.length) {
        var doneCnt = 0;
        extra.forEach(function (c) {
          Coco.loadSubs(c.type_id, function (subs) {
            doneCnt++;
            if (subs && subs.length) {
              tops.push({ type_id: c.type_id, type_name: c.type_name, subs: subs });
            }
            if (doneCnt >= extra.length) {
              Coco.classes = tops;
              try { localStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), tops: tops })); } catch (e2) {}
              cb && cb(tops);
            }
          });
        });
      } else {
        Coco.classes = tops;
        try { localStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), tops: tops })); } catch (e2) {}
        cb && cb(tops);
      }
    });
  },
  /* ---------- 二级分类（解析频道页，API不返回层级） ---------- */
  subsCache: {},
  loadSubs: function (topId, cb) {
    if (Coco.subsCache[topId]) { cb && cb(Coco.subsCache[topId]); return; }
    Coco.getRaw('/index.php/vod/type/id/' + topId + '.html', function (err, raw) {
      var html = (raw && raw.__raw) || raw || '';
      var subs = [];
      if (html) {
        var re = /\/index\.php\/vod\/(?:show|type)\/id\/(\d+)\.html"[^>]*>([^<]{2,12})</g, m;
        while ((m = re.exec(html))) {
          var id = m[1], nm = m[2].replace(/^\s+|\s+$/g, '');
          if (nm && nm != '全部' && nm != '首页' && nm != '更多' && id != topId && subs.indexOf(nm) < 0) {
            subs.push({ type_id: id, type_name: nm });
          }
          if (subs.length >= 30) break;
        }
      }
      if (subs.length) Coco.subsCache[topId] = subs;
      cb && cb(subs);
    });
  },
  /* ---------- 视频列表（支持数字/字符串t或对象{t,c,pg}，自动补封面） ---------- */
  list: function (t, pg, cb) {
    var opt = {}, outCb = cb;
    if (typeof pg === 'function') { outCb = pg; pg = undefined; }
    if (typeof t === 'object' && t !== null) { opt = t; }
    else { if (t) opt.t = t; opt.pg = pg || 1; }
    // 本地缓存（30分钟有效）：命中直接秒开，跳过补封面
    var key = 'coco_l_v2_' + (opt.t || '') + '_' + (opt.pg || 1) + '_' + (opt.wd || '') + '_' + (opt.ac || '') + '_' + (opt.class || '');
    var hit = null;
    try { hit = JSON.parse(localStorage.getItem(key) || 'null'); } catch (e) {}
    if (hit && hit.d && hit.d.list && hit.d.list.length && (Date.now() - hit.t < 1800000)) {
      outCb && outCb(null, hit.d);
      return;
    }
    Coco.jsonp(opt, function (err, d) {
      if (!err && d && d.list && d.list.length) {
        // 先补封面再存缓存，保证缓存里也有缩略图
        Coco.fillPosters(d, function (e2, d2) {
          var dd = (e2 || !d2) ? d : d2;
          try { localStorage.setItem(key, JSON.stringify({ t: Date.now(), d: dd })); } catch (e) {}
          outCb && outCb(e2, dd);
        });
      } else if (hit && hit.d && hit.d.list && hit.d.list.length) {
        outCb && outCb(null, hit.d);   // 网络失败回退缓存
      } else {
        outCb && outCb(err, d);
      }
    });
  },
  /* ---------- 批量补封面（列表接口不带vod_pic，用详情接口补） ---------- */
  fillPosters: function (d, cb) {
    if (!d || !d.list || !d.list.length) { cb && cb(null, d); return; }
    var need = d.list.some(function (v) { return !v.vod_pic; });
    if (!need) { cb && cb(null, d); return; }
    var arr = d.list.slice(), map = {}, batches = [];
    while (arr.length) batches.push(arr.splice(0, 10).map(function (v) { return v.vod_id; }).join(','));
    if (!batches.length) { cb && cb(null, d); return; }
    var left = batches.length;
    batches.forEach(function (ids) {
      Coco.jsonp({ ac: 'detail', ids: ids }, function (e2, d2) {
        if (!e2 && d2 && d2.list) d2.list.forEach(function (x) { map[x.vod_id] = x; });
        left--;
        if (left === 0) {
          d.list = d.list.map(function (v) { return map[v.vod_id] || v; });
          cb && cb(null, d);
        }
      });
    });
  },
  /* ---------- 搜索 ---------- */
  search: function (wd, pg, cb) {
    // 搜索缓存（30分钟有效）
    var key = 'coco_s_v2_' + wd + '_' + (pg || 1), hit = null;
    try { hit = JSON.parse(localStorage.getItem(key) || 'null'); } catch (e) {}
    if (hit && hit.d && hit.d.list && hit.d.list.length && (Date.now() - hit.t < 1800000)) { cb && cb(null, hit.d); return; }
    Coco.jsonp({ wd: wd, pg: pg || 1 }, function (err, d) {
      if (!err && d && d.list && d.list.length) {
        Coco.fillPosters(d, function (e2, d2) {
          var dd = (e2 || !d2) ? d : d2;
          try { localStorage.setItem(key, JSON.stringify({ t: Date.now(), d: dd })); } catch (e) {}
          cb && cb(e2, dd);
        });
      } else if (hit && hit.d && hit.d.list && hit.d.list.length) { cb && cb(null, hit.d); }
      else { cb && cb(err, d); }
    });
  },
  /* ---------- 搜索联想（只取名称，轻量不补封面，内存缓存5分钟） ---------- */
  _sugCache: {},
  suggest: function (wd, cb) {
    wd = (wd || '').trim();
    if (!wd) { cb && cb([]); return; }
    var ck = Coco._sugCache[wd];
    if (ck && Date.now() - ck.t < 300000) { cb && cb(ck.list); return; }
    Coco.jsonp({ wd: wd, pg: 1 }, function (err, d) {
      var names = [];
      if (!err && d && d.list && d.list.length) {
        var seen = {};
        d.list.forEach(function (v) {
          var nm = (v.vod_name || '').trim();
          if (nm && !seen[nm]) { seen[nm] = 1; names.push({ id: v.vod_id, name: nm, remark: v.vod_remarks || '' }); }
        });
        names = names.slice(0, 10);
        Coco._sugCache[wd] = { t: Date.now(), list: names };
      }
      cb && cb(names);
    });
  },
  /* ---------- 详情（含播放地址与会员权限，完全不缓存，放开/收回权限都立即生效） ---------- */
  detail: function (ids, cb) {
    Coco.jsonp({ ac: 'detail', ids: ids }, function (err, d) { cb && cb(err, d); });
  },
  /* ---------- 解析播放线路 ---------- */
  parsePlay: function (vod) {
    var lines = [];
    // 播放源编码 → 中文名映射（与后台播放器配置名称对应，APP离线兜底显示）
    var PN = {
      'hnm3u8':'红牛在线','mtm3u8':'茅台资源','snm3u8':'索尼资源','yym3u8':'鸭鸭资源',
      'wjvwsym3u8':'无尽③','wjwsym3u8':'无尽③','mgtv':'芒果视频','qiyi':'爱奇艺','youku':'优酷','qq':'腾讯',
      'bilibili':'哔哩哔哩','m3u8':'m3u8','ckm3u8':'超酷资源','ffm3u8':'非凡资源',
      'xlm3u8':'线路库','wolong':'卧龙资源','sdm3u8':'闪电资源','zym3u8':'资源猫',
      'hanm3u8':'红牛在线','1080zyk':'1080资源库','bfzym3u8':'暴风资源','58kan':'58看看',
      'sohu':'搜狐','pptv':'PPTV','letv':'乐视','cctv':'CCTV','boke':'播客','weibo':'微博',
      'music':'音乐','dplayer':'DPlayer','videojs':'VideoJS','iva':'IVA','iframe':'外链','link':'外链'
    };
    // 优先使用站点API返回的完整线路列表（含播放器中文名 player_info.show）
    // 注意：苹果CMS返回的 vod_play_list/urls 可能是对象 {"1":{...}}，需统一转数组
    var plist = vod.vod_play_list;
    var plistArr = [];
    if (plist) {
      if (Array.isArray(plist)) { plistArr = plist; }
      else { plistArr = Object.keys(plist).map(function (k) { return plist[k]; }); }
    }
    if (plistArr.length) {
      plistArr.forEach(function (pl) {
        var eps = [];
        var ul = pl.urls;
        if (ul) {
          var uarr = Array.isArray(ul) ? ul : Object.keys(ul).map(function (k) { return ul[k]; });
          uarr.forEach(function (u) {
            if (!u || !u.url) return;
            eps.push({ name: u.name || '播放', url: u.url });
          });
        }
        // 名称优先级：服务器返回的播放器名称(可后台改) > 内置映射表(兜底) > 来源编码
        var pname = (pl.player_info && pl.player_info.show) || PN[pl.from] || pl.from || '线路';
        lines.push({ from: pname, eps: eps });
      });
      return lines;
    }
    // 回退：按 vod_play_from/vod_play_url 拆分
    var froms = (vod.vod_play_from || '').split('$$$');
    var urls = (vod.vod_play_url || '').split('$$$');
    var lines = [];
    for (var i = 0; i < froms.length; i++) {
      var eps = [];
      if (urls[i]) {
        urls[i].split('#').forEach(function (seg) {
          if (!seg) return;
          var idx = seg.lastIndexOf('$');
          var name = idx > -1 ? seg.substring(0, idx) : '播放';
          var url = idx > -1 ? seg.substring(idx + 1) : seg;
          eps.push({ name: name, url: url });
        });
      }
      lines.push({ from: PN[froms[i]] || froms[i] || ('线路' + (i + 1)), eps: eps });
    }
    return lines;
  },
  /* ---------- 本地收藏 ---------- */
  getFavs: function () { try { return JSON.parse(localStorage.getItem('coco_favs') || '[]'); } catch (e) { return []; } },
  isFav: function (id) { return Coco.getFavs().some(function (v) { return v.id == id; }); },
  toggleFav: function (item) {
    var favs = Coco.getFavs(), i = favs.findIndex(function (v) { return v.id == item.vod_id; });
    if (i > -1) { favs.splice(i, 1); } else {
      favs.unshift({ id: item.vod_id, name: item.vod_name, pic: item.vod_pic, remark: item.vod_remarks, score: item.vod_score, t: Date.now() });
    }
    localStorage.setItem('coco_favs', JSON.stringify(favs));
    return i === -1;
  },
  /* ---------- 播放历史 ---------- */
  getHistory: function () { try { return JSON.parse(localStorage.getItem('coco_history') || '[]'); } catch (e) { return []; } },
  addHistory: function (item) {
    var h = Coco.getHistory().filter(function (v) { return v.id != item.vod_id; });
    h.unshift({ id: item.vod_id, name: item.vod_name, pic: item.vod_pic, remark: item.vod_remarks, ep: item.ep || '', t: Date.now() });
    localStorage.setItem('coco_history', JSON.stringify(h.slice(0, 100)));
  },
  /* ---------- 工具 ---------- */
  pic: function (p) {
    if (!p) return 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="120" height="160"><rect width="100%" height="100%" fill="%23222"/><text x="50%" y="50%" fill="%23555" font-size="12" text-anchor="middle">暂无图</text></svg>';
    if (p.indexOf('//') === 0) p = 'http:' + p;
    else if (p.indexOf('http') !== 0 && p.indexOf('data:') !== 0) p = SITE + (p.charAt(0) === '/' ? '' : '/') + p;
    return p;
  },
  toast: function (msg) {
    var t = document.querySelector('.toast');
    if (!t) { t = document.createElement('div'); t.className = 'toast'; document.body.appendChild(t); }
    t.textContent = msg; t.style.display = 'block';
    clearTimeout(Coco._tt);
    Coco._tt = setTimeout(function () { t.style.display = 'none'; }, 1800);
  },
  qs: function (k) {
    var m = new RegExp('[?&]' + k + '=([^&]*)').exec(location.search);
    return m ? decodeURIComponent(m[1]) : '';
  },
  poster: function (v) {
    var ph = 'data:image/svg+xml;utf8,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="160" height="220"><rect width="100%" height="100%" fill="#1c1e26"/></svg>');
    return '<a class="poster" href="detail.html?id=' + v.vod_id + '">' +
      '<div class="p-img"><img data-src="' + Coco.pic(v.vod_pic) + '" src="' + ph + '" loading="lazy">' +
      (v.vod_score && parseFloat(v.vod_score) > 0 ? '<span class="p-score">' + v.vod_score + '分</span>' : '') +
      (v.vod_remarks ? '<span class="p-remark">' + v.vod_remarks + '</span>' : '') +
      '</div><div class="p-name">' + (v.vod_name || '') + '</div></a>';
  },
  /* ---------- 图片懒加载（IO + 轮询兜底，保证任何环境都出图） ---------- */
  _lazyObs: null,
  _lazyTimer: null,
  imgLazy: function (root) {
    var imgs = (root || document).querySelectorAll('img[data-src]');
    if (!imgs.length) return;
    if (!('IntersectionObserver' in window)) {
      imgs.forEach(function (img) { img.src = img.getAttribute('data-src'); });
      return;
    }
    if (!Coco._lazyObs) {
      Coco._lazyObs = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) {
            var img = en.target;
            var ds = img.getAttribute('data-src');
            if (ds && img.getAttribute('src') !== ds) img.src = ds;
            Coco._lazyObs.unobserve(img);
          }
        });
      }, { rootMargin: '300px 0px' });
    }
    imgs.forEach(function (img) { Coco._lazyObs.observe(img); });
    // 轮询兜底：IO 不触发的环境（部分WebView/headless）也能加载视口内图片
    if (!Coco._lazyTimer) {
      Coco._lazyTimer = setInterval(function () {
        var vh = window.innerHeight;
        var list = document.querySelectorAll('img[data-src]');
        var all = true;
        list.forEach(function (img) {
          var ds = img.getAttribute('data-src');
          if (img.getAttribute('src') === ds) return;
          var r = img.getBoundingClientRect();
          if (r.top < vh + 400 && r.bottom > -120) { img.src = ds; }
          else { all = false; }
        });
        if (!list.length || all) { clearInterval(Coco._lazyTimer); Coco._lazyTimer = null; }
      }, 700);
    }
  },
  /* ---------- 滚动加载（节流） ---------- */
  scrollLoad: function (fn) {
    var t = 0;
    window.addEventListener('scroll', function () {
      var now = Date.now();
      if (now - t < 120) return;
      t = now;
      if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 300) fn();
    }, { passive: true });
  }
};

// 安卓原生桥（投屏等）
var Native = {
  cast: function (url, title) {
    if (window.AndroidBridge && AndroidBridge.cast) { AndroidBridge.cast(url, title || ''); }
    else { Coco.toast('未检测到投屏服务'); }
  },
  share: function (title) {
    if (window.AndroidBridge && AndroidBridge.share) { AndroidBridge.share(title || '', location.href); }
    else { Coco.toast('请在浏览器中分享'); }
  }
};
