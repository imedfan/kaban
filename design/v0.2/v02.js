// Kaban v0.2 — renderers on top of ../components.js (card, ic, PROJ, ST, mascotFace)
ST.runlimit = {st:'waiting_human', i:'hand',     l:'Лимит запусков', lv:'attn'};
ST.subst    = {st:'waiting_human', i:'hand',     l:'Подмена модели', lv:'attn'};
STCLS.runlimit = 'waiting'; STCLS.subst = 'waiting';
const POOL = m => /^composer-/.test(m) ? 'cm' : 'om';
const pooltag = p => `<span class="pooltag ${p}">${p==='cm'?'Cm':'Om'}</span>`;
/* card2 = card() + optional amber/grey line under the title (o.line=[cls, html, icon]) */
function card2(o) {
  let h = card(o);
  if (o.line) {
    const ln = `<div class="cline ${o.line[0]}">${o.line[2]?ic(o.line[2],10):''}${o.line[1]}</div>`;
    h = h.replace(/(<div class="card-title">[\s\S]*?<\/div>)/, `$1${ln}`);
  }
  return h;
}
const KIND_IC2 = {queue:'inbox', agent:'hammer', test:'flask', review:'eye', human:'usercheck', merge:'merge', terminal:'circlecheck'};
/* model line under column header: m = {id, mk:'om'|'none'|'unav'|'subst'|'auto', txt} */
function modelLine(m) {
  if (!m) return '';
  if (m.mk === 'none') return `<div class="col-m mk">${ic('alert',10)}нет модели</div>`;
  if (m.mk === 'auto') return `<div class="col-m mk">${ic('alert',10)}<span class="mn">auto</span> — запрещено</div>`;
  const tag = pooltag(POOL(m.id));
  if (m.mk === 'om')    return `<div class="col-m mk">${ic('hourglass',10)}<span class="mn">${m.id}</span>${tag}<span>исчерпан</span></div>`;
  if (m.mk === 'unav')  return `<div class="col-m mg">${ic('ban',10)}<span class="mn">${m.id}</span><span>недоступна</span></div>`;
  if (m.mk === 'subst') return `<div class="col-m mk">${ic('alert',10)}<span class="mn">${m.id}</span>${tag}<span>подмена</span></div>`;
  return `<div class="col-m">${ic('bot',10)}<span class="mn">${m.id}</span>${tag}</div>`;
}
function col2(kind, name, wip, cards, extra, m) {
  let w = '';
  if (wip) { const [a,b] = wip.split('/').map(Number); w = `<span class="wip ${a>b?'over':a===b?'full':''}">${wip}</span>`; }
  else if (extra) w = `<span class="wip plain">${extra}</span>`;
  const kc = {queue:'queue',agent:'agent',test:'agent',review:'agent',human:'human',merge:'merge',terminal:'terminal'}[kind];
  const fx = {Backlog:.65,Dev:1.35,Test:1.45,'AI Review':1.3,'Human Review':1.0,Merge:.6,Done:.5}[name]||1;
  return `<div class="col" style="flex:${fx} 1 0"><div class="col-h"><span class="kic" style="color:var(--kind-${kc})">${ic(KIND_IC2[kind],12)}</span><b>${name}</b>${w}</div>${modelLine(m)}<div class="col-cards">${cards.map(card2).join('') || '<div class="empty">Пусто</div>'}</div></div>`;
}
/* quota widget: values are % used; null = «нет данных» (never 0%). q = {cm, om, cmReset, omReset, cyc, thr, upd} */
function qbar(p, used, reset, o={}) {
  const cyc = o.cyc ?? 53, thr = 100 - (o.thr ?? 10);
  if (used == null) return `<div class="qrow"><span class="pl">${p==='cm'?'Cm':'Om'}</span><div class="qbar nd"><span class="cyc" style="left:${cyc}%"></span></div><span class="val nd">нет данных</span></div>`;
  const low = used >= thr;
  return `<div class="qrow"><span class="pl">${p==='cm'?'Cm':'Om'}</span><div class="qbar ${p}${low?' low':''}"><span class="f" style="width:${used}%"></span><span class="cyc" style="left:${cyc}%"></span><span class="thr" style="left:${thr}%"></span></div><span class="val${low?' am':''}"><b>${used}%</b> · ${reset ?? '—'}</span></div>`;
}
function quotaWidget(q = {}) {
  const Q = Object.assign({cm:46, om:100, cmReset:'13д 13ч', omReset:'13д 13ч'}, q);
  return `<div class="qw">
    <div class="qw-h">${ic('gauge',11)}<span style="white-space:nowrap">Квота Cursor</span><span class="unoff">неофициально</span></div>
    ${qbar('cm', Q.cm, Q.cmReset, Q)}
    ${qbar('om', Q.om, Q.omReset, Q)}
    <div class="qnote"><span><i></i>цикл</span><span><u></u>порог 10%</span><span class="sp"></span><span>${Q.upd||'2 мин назад'}</span></div>
  </div>`;
}
const projRow2 = (p, st, sub, right, on=true) => `<div class="proj ${on?'':'off'}">${mascotFace(PROJ[p].m,st,22)}<div><div class="pn">${PROJ[p].name}</div><div class="ps">${sub}</div></div><div class="pr">${right}</div></div>`;
function sidebar2() {
  return `<aside class="sidebar glass">
    <div class="sb-top"><div class="lights"><i></i><i></i><i></i></div><span class="sp"></span>${ic('sidebar',15)}</div>
    <div class="sb-item on">${ic('rows',14)}Доска</div>
    <div class="sb-item">${ic('hand',14)}Ждут человека<span class="cnt"><span class="badge-n o">4</span></span></div>
    <div class="sb-item">${ic('siren',14)}Инциденты<span class="cnt">0</span></div>
    <div class="sb-sec">Проекты<span class="sp"></span>${ic('plus',12)}</div>
    ${projRow2('shop','wave','ждут 3','<span class="badge-n o">3</span>')}
    ${projRow2('kaban','sad','<span style="color:var(--amber-fg);font-weight:600">пайплайн некорректен</span>','')}
    ${projRow2('mob','sad','<span style="color:var(--amber-fg);font-weight:600">лишний MCP</span>','')}
    ${projRow2('docs','sleep','спит','<span class="kbd">⌘4</span>')}
    <div class="sb-hint">Перетащите проект на доску, чтобы добавить дорожку</div>
    <div class="sp"></div>
    <div class="mac-card">
      <div class="mc-h">${ic('cpu',12)}<b>Этот Мак</b><span class="sp"></span><span class="faint">потолок 4</span></div>
      <div class="slots big"><span class="slot">🦊</span><span class="slot">🐗</span><span class="slot free"></span><span class="slot free"></span></div>
      <div class="mc-row"><span>Процессы агентов</span><b>2 / 4</b></div>
      <div class="mc-row"><span>${ic('zap',11)} Cursor</span><span style="color:var(--amber-fg);font-weight:600">Om исчерпан</span></div>
      <div style="height:.5px;background:var(--sep);margin:1px 0"></div>
      ${quotaWidget()}
    </div>
  </aside>`;
}
function toolbar2(title, sub) {
  return `<header class="toolbar">
    <div class="tb-title"><b>${title}</b><span>${sub}</span></div>
    <div class="capsule glass"><div class="tbtn on">${ic('rows',13)}Дорожки</div><div class="tbtn">${ic('grid',13)}По типу стадии</div></div>
    <span class="sp"></span>
    <div class="capsule glass ceiling"><div class="tbtn">${ic('cpu',13)}<span>Агенты</span><span class="slots mini"><i class="slot"></i><i class="slot"></i><i class="slot free"></i><i class="slot free"></i></span><b class="mono">2/4</b></div></div>
    <div class="capsule glass"><div class="tbtn">${ic('search',14)}</div><div class="tbtn">${ic('bell',14)}<span class="badge-n o corner">3</span></div><div class="tbtn">${ic('pause',13)}</div></div>
    <div class="capsule glass" style="padding:0 4px"><div class="tbtn primary">${ic('plus',13)}Задача</div></div>
  </header>`;
}
const laneHead2 = (p, state, stateText, chips, open=true) => `<div class="lane-h">${ic(open?'chevdown':'chevright',12,'chev')}${mascotFace(PROJ[p].m,state,24)}<b class="ln">${PROJ[p].name}</b><span class="br mono">${ic('branch',10)}main</span><span class="lstate">${stateText}</span><span class="sp"></span>${chips}<span class="lh-ic">${ic('sliders',13)}</span><span class="lh-x" title="Убрать дорожку с доски">${ic('x',11)}</span></div>`;
const BANNERS = {
  om: `<div class="flagbar qx">${ic('hourglass',14)}<b>Om исчерпан · 2 стадии · до 17.10, 05:40</b><span class="muted2">· стоят стадии на моделях Om (знак в шапке), <span class="mono">composer-*</span> работают, текущие доигрывают</span><span class="sp"></span><span class="cnt2">сброс через 13д 13ч</span><span class="btn sm">Сменить модель стадии…</span></div>`,
  unav: `<div class="flagbar thin">${ic('ban',12)}<b>Opus 4.1 недоступен · 2 стадии</b><span>· пропал из <span class="mono">--list-models</span>, задачи этих стадий ждут в queued</span><span class="sp"></span><span class="faint">проба не чаще раза в 10 мин</span><span class="btn sm">Сменить модель</span><span class="btn sm">Снять флаг</span></div>`,
  subst: `<div class="flagbar thin">${ic('alert',12,'am')}<b>Cursor подменяет Opus 4.5 · 1 стадия</b><span>· запрошена Opus 4.5, ответила Sonnet 4; 1 задача у вас, 1 ждёт в queued</span><span class="sp"></span><span class="btn sm">Показать задачи</span><span class="btn sm">Снять флаг</span></div>`,
};
function renderBoard2(el, opts={}) {
  const sel = opts.selected;
  const shop = `<div class="lane">${laneHead2('shop','wave','ждут человека · 3',`<span class="lchip">вес 2</span><span class="lchip">${ic('cpu',11)} 1 процесс</span>`)}
    <div class="cols">
      ${col2('queue','Backlog',null,[
        {p:'shop',id:58,t:'Экспорт заказов в CSV',s:'queued',badges:[['','фича']]},
        {p:'shop',id:61,t:'Rate limit на /auth/login',s:'queued'},
      ],'2')}
      ${col2('agent','Dev','2/3',[
        {p:'shop',id:42,t:'Пагинация курсором в /orders',s:'running',meta:'12 мин',progress:55,badges:[['bnc','↩ 2/3','undo']]},
        {p:'shop',id:44,t:'Цены в копейках во всём API',s:'retry',label:'Попытка 2/3',meta:'повтор через 1:45',badges:[['','gate_failed','gates']]},
        {p:'shop',id:47,t:'Импорт прайса из 1С',s:'runlimit',label:'Лимит запусков',meta:'12/12',badges:[['wipsnap','WIP сохранён','history']],sel:sel==='SHOP-47'},
      ],'',{id:'composer-1'})}
      ${col2('test','Test','0/2',[
        {p:'shop',id:39,t:'Повтор вебхуков оплаты',s:'queued',label:'Ждёт квоту Om',meta:'сброс через 13д'},
        {p:'shop',id:40,t:'Валидация адреса доставки',s:'queued',label:'Ждёт квоту Om',meta:'сброс через 13д',badges:[['bnc','↩ 1/3','undo']]},
      ],'',{id:'sonnet-4.5',mk:'om'})}
      ${col2('review','AI Review','0/2',[
        {p:'shop',id:35,t:'Кэш каталога в Redis',s:'subst',label:'Подмена модели',meta:'15:12',line:['am','Подмена: Opus 4.5 <span class="arr">→</span> Sonnet 4','alert'],sel:sel==='SHOP-35'},
        {p:'shop',id:34,t:'Логи запросов без PII',s:'queued',label:'На модели флаг',meta:'Opus 4.5'},
      ],'',{id:'opus-4.5',mk:'subst'})}
      ${col2('human','Human Review','1/5',[
        {p:'shop',id:31,t:'Слияние гостевой корзины',s:'review',label:'На ревью',meta:'+128 −40',badges:[['ok','гейты ✓']]},
      ])}
      ${col2('merge','Merge','',[
        {p:'shop',id:29,t:'Индексы для поиска по SKU',s:'gating',label:'Rebase',progress:40},
      ],'1')}
      ${col2('terminal','Done',null,[
        {p:'shop',id:27,t:'Health-check для балансировщика',s:'done'},
      ],'24')}
    </div></div>`;
  const kaban = `<div class="lane">${laneHead2('kaban','sad','новые запуски не стартуют',
      `<span class="lflag fl-amber">${ic('alert',11)}<b>Пайплайн не запустится:</b> нет модели у Test, AI Review<span class="btn sm">Указать модели</span></span><span class="lchip">${ic('cpu',11)} 1 процесс</span>`)}
    <div class="cols">
      ${col2('queue','Backlog',null,[{p:'kaban',id:21,t:'Справочник моделей: фильтр «проверь пул»',s:'queued'}],'3')}
      ${col2('agent','Dev','1/2',[{p:'kaban',id:15,t:'Дорожки: закреплённые заголовки',s:'running',label:'Доигрывает',meta:'21 мин',progress:80}],'',{id:'composer-1'})}
      ${col2('test','Test','0/2',[{p:'kaban',id:14,t:'Квота: свежесть данных перед стартом',s:'queued',label:'В очереди',meta:'ждёт пайплайн'}],'',{mk:'none'})}
      ${col2('review','AI Review','0/1',[],'',{mk:'auto'})}
      ${col2('human','Human Review','1/2',[{p:'kaban',id:10,t:'XPC: досылка по seq',s:'review',label:'На ревью',meta:'+311 −52'}])}
      ${col2('merge','Merge','',[],'0')}
      ${col2('terminal','Done',null,[],'9')}
    </div></div>`;
  const mob = `<div class="lane collapsed">${laneHead2('mob','sad','стоит',
      `<span class="lflag fl-amber">${ic('plug',11)}<b>Запуски остановлены: лишний MCP-сервер «jira»</b> — CLI видит его вне собранного конфига<span class="btn sm">Настройки MCP</span><span class="btn sm">${ic('refresh',9)}Проверить снова</span></span><span class="lchip">в очереди 4</span>`, false)}</div>`;
  const docs = `<div class="lane collapsed">${laneHead2('docs','sleep','спит · очередь пуста',`<span class="lchip">готово 31</span>`, false)}</div>`;
  el.innerHTML = `<div class="win">
  <div class="backdrop"><i style="left:-120px;top:-80px;width:520px;height:420px;background:#ffb08a"></i><i style="left:-60px;top:420px;width:420px;height:520px;background:#9ec5ff"></i><i style="left:620px;top:-200px;width:700px;height:360px;background:#c7d7ff"></i><i style="left:1100px;top:560px;width:500px;height:400px;background:#ffd9ec"></i></div>
  ${sidebar2()}
  ${toolbar2('Доска','4 проекта на доске')}
  <main class="board"><div class="banners">${BANNERS.om}${BANNERS.unav}${BANNERS.subst}</div>${shop}${kaban}${mob}${docs}</main>
  ${opts.overlay||''}
  </div>`;
}
/* generic settings window for v0.2 screens */
function settingsWin2(el, o) {
  el.innerHTML = `<div class="win">
  <div class="backdrop"><i style="left:-120px;top:-80px;width:520px;height:420px;background:#ffc9a8"></i><i style="left:-60px;top:460px;width:420px;height:520px;background:#a9cbff"></i><i style="left:700px;top:-220px;width:700px;height:340px;background:#d3defc"></i></div>
  <aside class="sidebar glass s2-side">
    <div class="sb-top"><div class="lights"><i></i><i></i><i></i></div><span class="sp"></span>${ic('sidebar',15)}</div>
    ${o.side}
  </aside>
  <header class="toolbar"><div class="tb-title"><b>${o.title}</b><span>${o.sub}</span></div><span class="sp"></span>${o.right||''}</header>
  <main class="s-main">${o.tabs?`<div class="s-tabs">${o.tabs}</div>`:''}<div class="s-body">${o.body}</div>${o.foot?`<div class="s-foot">${o.foot}</div>`:''}</main>
  ${o.overlay||''}</div>`;
}
const sit = (icn, name, k, on, warn) => `<div class="it ${on?'on':''}">${ic(icn,13)}<span>${name}</span>${warn?`<span class="wm">${ic('alert',11)}</span>`:''}${k?`<span class="k">${k}</span>`:''}</div>`;
