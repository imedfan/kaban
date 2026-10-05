// Board screen renderer (used by board.html, board-dark.html, task-details.html)
const KIND_IC = {queue:'inbox', agent:'hammer', test:'flask', review:'eye', human:'usercheck', merge:'merge', terminal:'circlecheck', gate:'gates'};
function colHead(kind, name, wip, extra='') {
  let w = '';
  if (wip) { const [a,b] = wip.split('/').map(Number); const cls = a>b?'over':a===b?'full':''; w = `<span class="wip ${cls}">${wip}</span>`; }
  else if (extra) w = `<span class="wip plain">${extra}</span>`;
  const kc = {queue:'queue',agent:'agent',test:'agent',review:'agent',human:'human',merge:'merge',terminal:'terminal'}[kind];
  return `<div class="col-h"><span class="kic" style="color:var(--kind-${kc})">${ic(KIND_IC[kind],12)}</span><b>${name}</b>${w}</div>`;
}
function col(kind, name, wip, cards, extra) {
  return `<div class="col">${colHead(kind,name,wip,extra)}<div class="col-cards">${cards.map(card).join('') || '<div class="empty">Пусто</div>'}</div></div>`;
}
function gateStrip(name, n) {
  return `<div class="gate-strip"><span class="kic" style="color:var(--kind-gate)">${ic('gates',12)}</span><span class="gs-name">${name}</span>${n?`<span class="gs-tok st-gating"><span class="stdot"></span>${n}</span>`:''}</div>`;
}
function laneHead(p, state, stateText, chips, open=true) {
  const P = PROJ[p];
  return `<div class="lane-h">${ic(open?'chevdown':'chevright',12,'chev')}${mascotFace(P.m,state,24)}<b class="ln">${P.name}</b><span class="br mono">${ic('branch',10)}main</span><span class="lstate">${stateText}</span><span class="sp"></span>${chips}<span class="lh-ic">${ic('sliders',13)}</span></div>`;
}
function renderBoard(el, opts={}) {
  const sel = opts.selected;
  const M = opts.mac || 'none', FREE = M!=='none', ALL = !!opts.showAll;
  const shop = `<div class="lane">${laneHead('shop','work',FREE?'работает · 1 агент':'работает · 2 агента',
      `<span class="lflag fl-merge">${ic('merge',11)}<b>Слияние остановлено:</b> правки в рабочей копии main пересекаются с SHOP-30</span><span class="btn sm">${ic('refresh',9)}Проверить снова</span><span class="lchip">вес 2</span><span class="lchip">${ic('cpu',11)} ${FREE?'1 процесс':'2 процесса'}</span>`)}
    <div class="cols">
      ${col('queue','Backlog',null,[
        {p:'shop',id:58,t:'Экспорт заказов в CSV',s:'queued',meta:'#1',badges:[['','фича']]},
        {p:'shop',id:61,t:'Rate limit на /auth/login',s:'queued',label:'Не запустится',badges:[['warn','без критериев приёмки','alert']]},
      ],'2')}
      ${col('agent','Dev','2/3',[
        (M==='rate'?{p:'shop',id:42,t:'Пагинация в /orders',s:'retry',label:'Ждёт лимит',meta:'16:40',badges:[['ret','возврат 1/3','undo'],['','rate_limit','zap']]}:M==='runner'?{p:'shop',id:42,t:'Пагинация в /orders',s:'retry',label:'Ждёт Cursor',badges:[['ret','возврат 1/3','undo'],['','runner_auth','key']]}:{p:'shop',id:42,t:'Пагинация в /orders',s:'running',meta:'12 мин',progress:55,badges:[['ret','возврат 1/3','undo'],['','opus']]}),
        {p:'shop',id:44,t:'Цены в копейках',s:'gating',label:'Гейты',meta:'swift test · 2/3',progress:66,badges:[['warn','пересечение файлов','layers']]},
        {p:'shop',id:36,t:'Скидки по промокодам',s:'queued',meta:'первая',prio:'↑',badges:[['ret','возврат: конфликт 1/2','merge']]},
      ])}
      ${col('test','Test','1/2',[
        {p:'shop',id:39,t:'Повтор вебхуков оплаты',s:'running',meta:'4 мин',progress:30,badges:[['','sonnet']]},
        {p:'shop',id:40,t:'Валидация адреса доставки',s:'waiting',label:'Попытки исчерпаны',meta:'3/3',badges:[['bad','stall 10 мин','timer']]},
      ])}
      ${col('review','AI Review','1/2',[
        {p:'shop',id:35,t:'Кэш каталога в Redis',s:'waiting',label:'Вопрос агента',meta:'18 м',badges:[['','request_human','message']]},
        {p:'shop',id:34,t:'Логи запросов без PII',s:'retry',label:'Повтор',meta:'1:40 · 2/3',badges:[['','краш процесса']]},
      ])}
      ${col('human','Human Review','1/5',[
        {p:'shop',id:31,t:'Слияние гостевой корзины',s:'review',label:'На ревью',meta:'+128 −40',badges:[['ret','после конфликта','merge'],['ok','гейты ✓']]},
      ])}
      ${col('merge','Merge','',[
        {p:'shop',id:29,t:'Индексы для поиска по SKU',s:'gating',label:'Rebase + гейты',meta:'#1',progress:40},
        {p:'shop',id:30,t:'Убрать устаревший /v1/cart',s:'blocked',label:'Заблокирована',badges:[['warn','main грязная','alert']]},
      ],'2')}
      ${col('terminal','Done',null,[
        {p:'shop',id:27,t:'Health-check для балансировщика',s:'done',meta:'14:05 → main'},
        {p:'shop',id:25,t:'GraphQL-шлюз (отклонено)',s:'cancelled',meta:'вчера'},
      ],'24')}
    </div></div>`;
  const kaban = `<div class="lane lane-alarm">${laneHead('kaban','alarm','<span class="alarm-txt">'+ic('siren',11)+' инцидент в KBN-17</span>',
      `<span class="lchip">вес 1</span><span class="lchip">${ic('cpu',11)} 1 процесс</span>`)}
    <div class="cols">
      ${col('queue','Backlog',null,[
        {p:'kaban',id:19,t:'Сводка ревью: список коммитов ветки',s:'queued',meta:'#1'},
      ],'5')}
      ${col('agent','Dev','1/2',[
        {p:'kaban',id:17,t:'Обёртка git: белый список флагов',s:'incident',label:'Инцидент',meta:'main откатан',sel:sel==='KBN-17'},
        {p:'kaban',id:15,t:'Дорожки: закреплённые заголовки',s:'running',meta:'21 мин',progress:70,badges:[['grant','git ×1 разрешено','key'],['','gpt-5']]},
      ])}
      ${gateStrip('Lint', 1)}
      ${col('review','AI Review','0/1',[
        {p:'kaban',id:18,t:'Ротация логов run',s:'waiting',label:'Политика git',meta:'5/5 отказов',badges:[['bad','5 отказов','ban']]},
        {p:'kaban',id:13,t:'Счётчик в менюбаре',s:'queued',label:'Ждёт места',badges:[['','Human Review 2/2','hourglass']]},
      ])}
      ${col('human','Human Review','2/2',[
        {p:'kaban',id:10,t:'XPC: досылка по seq',s:'review',label:'На ревью',meta:'+311 −52',badges:[['ok','гейты ✓']]},
        {p:'kaban',id:11,t:'Маскот: «Уменьшить движение»',s:'review',label:'На ревью',meta:'+96 −8'},
      ])}
      ${col('merge','Merge','',[],'0')}
      ${col('terminal','Done',null,[
        {p:'kaban',id:8,t:'Снимок refs до и после run',s:'done',meta:'12:40 → main'},
      ],'9')}
    </div></div>`;
  const mob = `<div class="lane collapsed">${laneHead('mob','wave','машет · ждут человека',
      `<span class="lflag fl-intake">${ic('hand',11)}<b>3/3 ждут человека</b> — новые задачи из Backlog не берутся</span><span class="lchip">в работе 1</span><span class="lchip">${ic('cpu',11)} 1 процесс</span>`, false)}</div>`;
  const docs = `<div class="lane collapsed">${laneHead('docs','sleep','спит · очередь пуста',
      `<span class="lflag fl-pause">${ic('pause',10)}<b>Проект на паузе</b> — новые запуски не стартуют</span><span class="btn sm">${ic('play',9)}Возобновить</span><span class="lchip">готово 31</span>`, false)}</div>`;
  const infra = `<div class="lane collapsed">${laneHead('infra','sleep','недоступен',
      `<span class="lflag fl-unav">${ic('folder',11)}<b>Проект недоступен:</b> папка ~/dev/infra не найдена, задачи стоят в queued</span><span class="btn sm">Указать путь…</span><span class="btn sm">${ic('refresh',9)}Проверить снова</span>`, false)}</div>`;
  const runner = M==='runner' ? `<div class="flagbar ru">${ic('alert',14)}<b>Cursor недоступен: не выполнен вход</b><span class="rcode">runner_auth</span><span>· новые запуски не стартуют во всех проектах, текущие доигрывают. Выполните <span class="mono">cursor-agent login</span></span><span class="sp"></span><span class="btn sm">${ic('refresh',9)}Проверить снова</span></div>` : '';
  const rl = M==='rate' ? `<div class="flagbar rl">${ic('zap',14)}<b>Лимит Cursor</b><span>новые запуски не стартуют во всех проектах до 16:40 (cooldown 30 мин), текущие доигрывают</span><span class="sp"></span><span class="btn sm">Снять cooldown сейчас</span></div>` : '';

  const projRow = (p, st, sub, right, on=true) => `<div class="proj ${on?'':'off'}"><span class="check ${on?'':'off'}">${on?ic('check',10):''}</span>${mascotFace(PROJ[p].m,st,22)}<div><div class="pn">${PROJ[p].name}</div><div class="ps">${sub}</div></div><div class="pr">${right}</div></div>`;
  el.innerHTML = `<div class="win">
  <div class="backdrop"><i style="left:-120px;top:-80px;width:520px;height:420px;background:#ffb08a"></i><i style="left:-60px;top:420px;width:420px;height:520px;background:#9ec5ff"></i><i style="left:620px;top:-200px;width:700px;height:360px;background:#c7d7ff"></i><i style="left:1100px;top:560px;width:500px;height:400px;background:#ffd9ec"></i></div>
  <aside class="sidebar glass">
    <div class="sb-top"><div class="lights"><i></i><i></i><i></i></div><span class="sp"></span>${ic('sidebar',15)}</div>
    <div class="sb-item on">${ic('rows',14)}Доска</div>
    <div class="sb-item">${ic('hand',14)}Ждут человека<span class="cnt"><span class="badge-n o">6</span></span></div>
    <div class="sb-item">${ic('siren',14)}Инциденты<span class="cnt"><span class="badge-n r">1</span></span></div>
    <div class="sb-sec">Проекты<span class="sp"></span>${ic('plus',12)}</div>
    ${projRow('shop','work','работает','<span class="kbd">⌘1</span>')}
    ${projRow('kaban','alarm','<span style="color:var(--st-incident-fg);font-weight:600">тревожится</span>','<span class="badge-n r">1</span>')}
    ${projRow('mob','wave','машет · 3 ждут','<span class="badge-n o">3</span>')}
    ${projRow('docs','sleep','спит','<span class="kbd">⌘4</span>')}
    ${ALL?`<div class="proj"><span class="check">${ic('check',10)}</span>${mascotFace('🐢','sleep',22)}<div><div class="pn">infra</div><div class="ps" style="color:var(--st-blocked-fg)">недоступен</div></div><div class="pr">${ic('folder',12)}</div></div>`:`<div class="proj off"><span class="check off"></span>${mascotFace('🐢','wave',22)}<div><div class="pn">infra</div><div class="ps">скрыт · 1 ждёт</div></div><div class="pr"><span class="badge-n o">1</span></div></div>`}
    <div class="sp"></div>
    <div class="mac-card">
      <div class="mc-h">${ic('cpu',12)}<b>Этот Мак</b><span class="sp"></span><span class="faint">потолок 4</span></div>
      <div class="slots big"><span class="slot">🦊</span>${FREE?'<span class="slot free"></span>':'<span class="slot">🦊</span>'}<span class="slot">🐗</span><span class="slot">🐙</span></div>
      <div class="mc-row"><span>Процессы агентов</span><b>${FREE?'3':'4'} / 4</b></div>
      <div class="mc-row"><span>Веса</span><span class="faint">🦊 2 · 🐗 1 · 🐙 1 · 🦉 1</span></div>
      <div class="mc-row"><span>${ic('zap',11)} Cursor</span>${M==='rate'?'<span style="color:var(--st-retry-fg);font-weight:600">cooldown до 16:40</span>':M==='runner'?'<span style="color:var(--st-incident-fg);font-weight:600">нет входа</span>':'<span style="color:var(--st-done-fg);font-weight:600">в норме</span>'}</div>
    </div>
  </aside>
  <header class="toolbar">
    <div class="tb-title"><b>Доска</b><span>${ALL?'все 5 проектов':'4 из 5 проектов'}</span></div>
    <div class="capsule glass">
      <div class="seg" style="background:transparent"><span>Один</span><span class="${ALL?'':'on'}">Несколько</span><span class="${ALL?'on':''}">Все</span></div>
      <div class="vsep"></div>
      <div class="tbtn"><span class="emos">🦊🐗🐙🦉${ALL?'🐢':''}</span>${ic('chevdown',10)}${ALL?'':'<span class="badge-n o" title="скрытые ждут">+1</span>'}</div>
    </div>
    <div class="capsule glass">
      <div class="tbtn on">${ic('rows',13)}Дорожки</div><div class="tbtn">${ic('grid',13)}По типу стадии</div>
    </div>
    <span class="sp"></span>
    <div class="capsule glass ceiling">
      <div class="tbtn">${ic('cpu',13)}<span>Агенты</span><span class="slots mini"><i class="slot"></i><i class="slot"></i><i class="slot"></i><i class="slot${FREE?' free':''}"></i></span><b class="mono">${FREE?'3':'4'}/4</b></div>
    </div>
    <div class="capsule glass">
      <div class="tbtn">${ic('search',14)}</div>
      <div class="tbtn">${ic('bell',14)}<span class="badge-n r corner">1</span></div>
      <div class="tbtn">${ic('pause',13)}</div>
    </div>
    <div class="capsule glass" style="padding:0 4px"><div class="tbtn primary">${ic('plus',13)}Задача</div></div>
  </header>
  <main class="board">${runner}${rl}${shop}${kaban}${mob}${docs}${ALL?infra:''}</main>
  ${opts.overlay||''}
  </div>`;
}
