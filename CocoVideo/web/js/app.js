/* ========== COCO APP 核心库 ========== */
// 站点地址：APP内（file://）用绝对地址；网页版（http/https 同源）用相对地址
var SITE = (location.protocol === 'http:' || location.protocol === 'https:') ? '' : 'https://191314.best';
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
  // 原生图片代理回传：uri 为 data:image/...;base64,xxx
  _nativeImg: function (cbId, uri) {
    var cb = Coco._nbcbs[cbId];
    if (!cb) return;
    delete Coco._nbcbs[cbId];
    cb(uri ? null : new Error('img'), uri || '');
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
    // iOS 的页面源是 cocoapp://local/，用 fetch 打 https 属于跨源不透明请求，
    // WebKit 会直接拦掉且不报错 → 回调永远不来，所以这种协议下必须先走原生通道。
    // 安卓是 file://（开了通用访问），fetch 本来就能通，保持原逻辑不动。
    var iosScheme = location.protocol === 'cocoapp:';
    if ((iosScheme || !window.fetch) && window.AndroidBridge && AndroidBridge.request) {
      var cbId0 = 'nb_' + (++Coco._seq);
      var done0 = false;
      var timer0 = setTimeout(function () {
        if (done0) return; done0 = true;
        delete Coco._nbcbs[cbId0]; cb && cb(new Error('timeout'));
      }, 10000);
      Coco._nbcbs[cbId0] = function (err, d) {
        done0 = true; clearTimeout(timer0);
        if (err) { cb && cb(err); return; }
        var text = d && d.__raw !== undefined ? d.__raw : (typeof d === 'string' ? d : JSON.stringify(d || ''));
        cb && cb(null, text || '');
      };
      try { AndroidBridge.request(url, cbId0); }
      catch (e) { clearTimeout(timer0); delete Coco._nbcbs[cbId0]; cb && cb(e); }
      return;
    }
    if (window.fetch) {
      var aborted = false;
      var ctrl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
      var t0 = setTimeout(function () { aborted = true; if (ctrl) { try { ctrl.abort(); } catch (e) {} } }, 10000);
      fetch(url, ctrl ? { credentials: 'include', signal: ctrl.signal } : { credentials: 'include' })
        .then(function (r) { return r.text(); })
        .then(function (t) { clearTimeout(t0); cb && cb(null, t); })
        .catch(function (e) { clearTimeout(t0); cb && cb(e); });
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
    var CACHE_KEY = 'coco_classes_v7';
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
      // 内置层级表一个都没命中 → 说明换站了（或后台把分类重排成别的 ID 段）。
      // 这时不能报"分类加载失败"，直接按 API 返回的扁平列表渲染，保证永远有分类可选。
      if (!tops.length) {
        all.forEach(function (c) {
          tops.push({ type_id: c.type_id, type_name: c.type_name, subs: [] });
        });
        Coco.classes = tops;
        try { localStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), tops: tops })); } catch (e6) {}
        cb && cb(tops);
        return;
      }
      // 补充：内置表未覆盖的分类一律作为独立顶级。
      // 这一站的 HTML 频道页直接 500，探测子分类拿不到任何东西，
      // 所以不做探测——宁可平铺也不能让分类整块消失。
      var topIds = {}, subIds = {};
      tops.forEach(function (t) {
        topIds[String(t.type_id)] = true;
        (t.subs || []).forEach(function (s) { subIds[String(s.type_id)] = true; });
      });
      all.forEach(function (c) {
        var id = String(c.type_id);
        if (topIds[id] || subIds[id]) return;
        tops.push({ type_id: c.type_id, type_name: c.type_name, subs: [] });
        topIds[id] = true;
      });
      Coco.classes = tops;
      try { localStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), tops: tops })); } catch (e2) {}
      cb && cb(tops);
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
        // 先出列表（缺图的先显示占位块），封面在后台补齐后回填，
        // 别让一批 ac=detail 请求把整个列表卡住。
        outCb && outCb(null, d);
        Coco.fillPosters(d, function (e2, d2) {
          var dd = (e2 || !d2) ? d : d2;
          try { localStorage.setItem(key, JSON.stringify({ t: Date.now(), d: dd })); } catch (e) {}
          Coco._onPicsFilled(dd);
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
    while (arr.length) batches.push(arr.splice(0, 20).map(function (v) { return v.vod_id; }).join(','));
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
        cb && cb(null, d);   // 先出搜索结果，封面后台补
        Coco.fillPosters(d, function (e2, d2) {
          var dd = (e2 || !d2) ? d : d2;
          try { localStorage.setItem(key, JSON.stringify({ t: Date.now(), d: dd })); } catch (e) {}
          Coco._onPicsFilled(dd);
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
    if (!p) return Coco.placeholder(120, 160);
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
    var ph = Coco.placeholder(160, 220);
    return '<a class="poster" href="detail.html?id=' + v.vod_id + '">' +
      '<div class="p-img"><img data-src="' + Coco.pic(v.vod_pic) + '" src="' + ph + '" loading="lazy"' +
      ' onerror="Coco.imgFallback(this)">' +
      (v.vod_score && parseFloat(v.vod_score) > 0 ? '<span class="p-score">' + v.vod_score + '分</span>' : '') +
      (v.vod_remarks ? '<span class="p-remark">' + v.vod_remarks + '</span>' : '') +
      '</div><div class="p-name">' + (v.vod_name || '') + '</div></a>';
  },
  /* ---------- 占位图：必须 encodeURIComponent，Safari 不认裸的 <svg> ---------- */
  placeholder: function (w, h) {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + w + '" height="' + h + '">'
      + '<rect width="100%" height="100%" fill="#1c1e26"/>'
      + '<text x="50%" y="50%" fill="#4a4f5e" font-size="12" text-anchor="middle">暂无图</text></svg>';
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  },
  /* ---------- 原图加载失败 → 走原生代理取字节（绕开证书链/防盗链/UA 问题） ---------- */
  /* ---------- 封面补齐后回填到已渲染的列表（按 detail.html?id= 对位） ---------- */
  _onPicsFilled: function (d) {
    if (!d || !d.list || !d.list.length) return;
    var map = {};
    d.list.forEach(function (v) {
      if (v && v.vod_id && v.vod_pic) map[String(v.vod_id)] = v.vod_pic;
    });
    if (!Object.keys(map).length) return;
    var imgs = document.querySelectorAll('a.poster img[data-src]');
    imgs.forEach(function (img) {
      if (img.getAttribute('data-nbf') === '1') return;
      var link = img.closest('a.poster');
      if (!link) return;
      var m = /[?&]id=(\d+)/.exec(link.getAttribute('href') || '');
      if (!m || !map[m[1]]) return;
      var next = Coco.pic(map[m[1]]);
      if (img.getAttribute('data-src') !== next) {
        img.setAttribute('data-src', next);
        img.removeAttribute('data-nbf');   // 地址换了，允许重新走一次加载
      }
    });
    Coco.imgLazy(document);
  },
  imgFallback: function (img) {
    if (!img || img.getAttribute('data-nbf') === '1') return;
    var url = img.getAttribute('data-src') || img.getAttribute('src') || '';
    if (!url || url.indexOf('data:') === 0) return;
    img.setAttribute('data-nbf', '1');
    if (!(window.AndroidBridge && AndroidBridge.img)) return;
    var cbId = 'im_' + (++Coco._seq);
    Coco._nbcbs[cbId] = function (err, uri) {
      if (!err && uri) { img.src = uri; }
    };
    try { AndroidBridge.img(url, cbId); }
    catch (e) { delete Coco._nbcbs[cbId]; }
  },
  /* ---------- 图片懒加载（IO + 轮询兜底，保证任何环境都出图） ---------- */
  _lazyObs: null,
  _lazyTimer: null,
  /* ---------- 图片加载 ----------
     iOS 上 WebKit 直接拉图经常失败（图片站证书链不全 / 防盗链 / UA 判定），
     所以 cocoapp 协议下把 <img src> 指到 cocoimg:// 协议，
     由原生取字节（放行证书链、压到 480px）后直接回给 WebKit，
     不走 base64 回传，也不会因为大字符串卡住。
     安卓是 file://，直接拉图本来就没问题，保持原样。 */
  _useNativeImg: function () {
    return location.protocol === 'cocoapp:';
  },
  loadImg: function (img) {
    if (!img) return;
    var ds = img.getAttribute('data-src');
    if (!ds) return;
    if (img.getAttribute('data-nbf') === '1') return;
    if (ds.indexOf('data:') === 0) return;      // 占位图，等真地址回填
    img.setAttribute('data-nbf', '1');

    if (!Coco._useNativeImg()) { img.src = ds; return; }

    // 三层兜底：cocoapp 图片代理 → 桥接 base64 → 直连
    var step = 0;
    function next() {
      step++;
      if (step === 1) {
        img.src = 'cocoapp://local/__img/?u=' + encodeURIComponent(ds);
        return;
      }
      if (step === 2 && window.AndroidBridge && AndroidBridge.img) {
        var cbId = 'im_' + (++Coco._seq);
        Coco._nbcbs[cbId] = function (err, uri) {
          if (!err && uri) { img.src = uri; return; }
          next();
        };
        try { AndroidBridge.img(ds, cbId); } catch (e) { delete Coco._nbcbs[cbId]; next(); }
        return;
      }
      if (step === 3) { img.src = ds; return; }
      // 三层全挂：退回占位块，别留一个问号在那儿
      img.onerror = null;
      img.src = Coco.placeholder(160, 220);
    }
    img.onerror = next;
    next();
  },
  imgLazy: function (root) {
    var imgs = (root || document).querySelectorAll('img[data-src]');
    if (!imgs.length) return;
    if (!('IntersectionObserver' in window)) {
      imgs.forEach(function (img) { Coco.loadImg(img); });
      return;
    }
    if (!Coco._lazyObs) {
      Coco._lazyObs = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) {
            Coco.loadImg(en.target);
            Coco._lazyObs.unobserve(en.target);
          }
        });
      }, { rootMargin: '600px 0px' });
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
          if (!ds) return;
          if (img.getAttribute('data-nbf') === '1' || img.getAttribute('src') === ds) return;
          var r = img.getBoundingClientRect();
          if (r.top < vh + 400 && r.bottom > -120) { Coco.loadImg(img); }
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
