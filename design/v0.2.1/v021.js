// Kaban v0.2.1 — on top of ../components.js and ../v0.2/v02.js (both untouched)
// suspicious_files: amber token alias --st-suspicious (= --st-waiting), own icon «shieldalert» (lucide shield-alert, SF Symbol exclamationmark.shield)
ICONS.shieldalert = ICONS.shield + '<path d="M12 8v4"/><path d="M12 16h.01"/>';
ICONS.rotateccw = '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>';
ICONS.filediff = '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M9 10h6"/><path d="M12 7v6"/><path d="M9 17h6"/>';
ST.suspicious = {st:'waiting_human', i:'shieldalert', l:'Подозрительные файлы', lv:'attn'};
STCLS.suspicious = 'suspicious';

/* file line on a card. SuspiciousFile {path, rule: pattern|size, pattern?, sizeBytes, blob} (арх. PR #2).
   f = [basename, rule:'pattern'|'size', pattern-or-size]; card shows basename + short reason, «+N» for the rest */
const fl = (f, more) => {
  // f = [basename, 'pattern'|'size', pattern | size, showSize?]
  const tag = f[1]==='pattern' ? `<span class="fr2">по шаблону <span class="mono">${f[2]}</span></span>`
    : `${f[3]?`<span class="fsz">${f[2]}</span><span class="fsep">·</span>`:''}<span class="fr2">больше 5 МБ</span>`;
  return `<div class="fline"><span class="fp">${f[0]}</span><span class="fsep">·</span>${tag}${more?`<span class="more">+${more}</span>`:''}</div>`;
};
/* card3 = card() + any number of extra lines under the title (o.lines = html[]) */
function card3(o) {
  let h = card(o);
  if (o.lines) h = h.replace(/(<div class="card-title">[\s\S]*?<\/div>)/, `$1${o.lines.join('')}`);
  return h;
}
function col21(kind, name, wip, cards, extra, m) {
  return col2(kind, name, wip, [], extra, m).replace('<div class="empty">Пусто</div>', cards.length ? cards.map(c => c.lines ? card3(c) : card2(c)).join('') : '<div class="empty">Пусто</div>');
}
const SHOP52 = (sel) => ({p:'shop',id:52,t:'Интеграция платёжного шлюза',s:'suspicious',label:'Подозрительные файлы: 3',sel,
  lines:[fl(['.env.local','pattern','.env*']), fl(['orders-dump.sql','size','12,4 МБ'],1)]});

/* board: copy of renderBoard2 (v0.2) with SHOP-47 replaced by SHOP-52 · suspicious_files */
function renderBoard21(el, opts={}) {
  const sel = opts.selected;
  const shop = `<div class="lane">${laneHead2('shop','wave','ждут человека · 3',`<span class="lchip">вес 2</span><span class="lchip">${ic('cpu',11)} 1 процесс</span>`)}
    <div class="cols">
      ${col21('queue','Backlog',null,[
        {p:'shop',id:58,t:'Экспорт заказов в CSV',s:'queued',badges:[['','фича']]},
        {p:'shop',id:61,t:'Rate limit на /auth/login',s:'queued'},
      ],'2')}
      ${col21('agent','Dev','2/3',[
        {p:'shop',id:42,t:'Пагинация курсором в /orders',s:'running',meta:'12 мин',progress:55,badges:[['bnc','↩ 2/3','undo']]},
        {p:'shop',id:44,t:'Цены в копейках во всём API',s:'retry',label:'Попытка 2/3',meta:'повтор через 1:45',badges:[['','gate_failed','gates']]},
        Object.assign(SHOP52(sel==='SHOP-52'), opts.card52||{}),
      ],'',{id:'composer-1'})}
      ${col21('test','Test','0/2',[
        {p:'shop',id:39,t:'Повтор вебхуков оплаты',s:'queued',label:'Ждёт квоту Om',meta:'сброс через 13д'},
        {p:'shop',id:40,t:'Валидация адреса доставки',s:'queued',label:'Ждёт квоту Om',meta:'сброс через 13д',badges:[['bnc','↩ 1/3','undo']]},
      ],'',{id:'sonnet-4.5',mk:'om'})}
      ${col21('review','AI Review','0/2',[
        {p:'shop',id:35,t:'Кэш каталога в Redis',s:'subst',label:'Подмена модели',meta:'15:12',line:['am','Подмена: Opus 4.5 <span class="arr">→</span> Sonnet 4','alert']},
      ],'',{id:'opus-4.5',mk:'subst'})}
      ${col21('human','Human Review','1/5',[
        {p:'shop',id:31,t:'Слияние гостевой корзины',s:'review',label:'На ревью',meta:'+128 −40',badges:[['ok','гейты ✓']]},
      ])}
      ${col21('merge','Merge','',[
        {p:'shop',id:29,t:'Индексы для поиска по SKU',s:'suspicious',label:'Подозрительные файлы: 1',meta:'',sel:sel==='SHOP-29',
          lines:[`<div class="fline gr">${ic('merge',10)}перед слиянием</div>`, fl(['seed-sku.sql','size','6,8 МБ',1])]},
      ],'1')}
      ${col21('terminal','Done',null,[
        {p:'shop',id:27,t:'Health-check для балансировщика',s:'done'},
      ],'24')}
    </div></div>`;
  const kaban = `<div class="lane">${laneHead2('kaban','sad','новые запуски не стартуют',
      `<span class="lflag fl-amber">${ic('alert',11)}<b>Пайплайн не запустится:</b> нет модели у Test, AI Review<span class="btn sm">Указать модели</span></span><span class="lchip">${ic('cpu',11)} 1 процесс</span>`)}
    <div class="cols">
      ${col21('queue','Backlog',null,[{p:'kaban',id:21,t:'Справочник моделей: фильтр «проверь пул»',s:'queued'}],'3')}
      ${col21('agent','Dev','1/2',[{p:'kaban',id:15,t:'Дорожки: закреплённые заголовки',s:'running',label:'Доигрывает',meta:'21 мин',progress:80}],'',{id:'composer-1'})}
      ${col21('test','Test','0/2',[{p:'kaban',id:14,t:'Квота: свежесть данных перед стартом',s:'queued',label:'В очереди',meta:'ждёт пайплайн'}],'',{mk:'none'})}
      ${col21('review','AI Review','0/1',[],'',{mk:'auto'})}
      ${col21('human','Human Review','1/2',[{p:'kaban',id:10,t:'XPC: досылка по seq',s:'review',label:'На ревью',meta:'+311 −52'}])}
      ${col21('merge','Merge','',[],'0')}
      ${col21('terminal','Done',null,[],'9')}
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

/* details header with any status icon */
const pHead21 = (o) => {
  const st = ['Backlog','Dev','Test','AI Review','Human Review','Merge','Done'];
  const i = st.indexOf(o.cur);
  return `<div class="p-head">
  <div class="p-row">${mascotFace('🦊','wave',22)}<span class="p-id">${o.id}</span><span class="p-crumb">${o.crumb}</span><span class="sp"></span>
   <span class="btn">${ic('external',11)}Открыть в Cursor</span><span class="iconbtn">${ic('more',14)}</span><span class="iconbtn">${ic('x',13)}</span></div>
  <div class="p-title">${o.title}</div>
  <div class="p-meta"><span class="statpill am">${ic(o.icon||'hand',11)}${o.pill}</span>${o.chips}</div>
  <div class="path">${st.map((s,k)=>`<span class="${k<i?'done':k===i?'cura':''}">${s}</span>`).join(ic('chevright',10))}</div>
 </div>`;
};
const evr21 = (cls, icon, h, s, t) => `<div class="ev ${cls}"><span class="g">${ic(icon,12)}</span><div><div class="h">${h}</div><div class="s">${s}</div></div><span class="t">${t}</span></div>`;

/* settings sidebar for shop-api (v0.2.1 grouping: MCP is project-level, stored on this Mac — spec v0.8 §1.5) */
function side21(active, stageOn) {
  const st = [['inbox','Backlog','queue'],['hammer','Dev','agent'],['flask','Test','agent'],['eye','AI Review','agent'],['usercheck','Human Review','human'],['merge','Merge','merge'],['circlecheck','Done','terminal']];
  return `<div class="proj" style="padding:4px 8px 10px">${mascotFace('🦊','wave',26)}<div><div class="pn" style="font-size:14px;font-weight:650">shop-api</div><div class="ps mono">~/dev/shop-api · main</div></div></div>
 <div class="grp">Стадии пайплайна</div>
 ${st.map(s=>sit(s[0],s[1],s[2],s[1]===stageOn)).join('')}
 <div class="grp">Проект · .kaban/ в репозитории</div>${sit('shield','Права и git','',active==='git')}${sit('shieldalert','Подозрительные файлы')}${sit('folder','Рабочая копия задачи')}${sit('hand','Лимиты и возвраты')}
 <div class="grp">Проект · на этом Маке</div>${sit('plug','MCP для запусков')}${sit('cpu','Вес и личный максимум')}${sit('sparkles','Маскот')}
 <div style="flex:1"></div>
 <div class="hint" style="padding:0 8px">Источник правды — закоммиченный <span class="mono">main:.kaban/pipeline.yaml</span>. Сохранение коммитит только <span class="mono">.kaban/</span>.</div>`;
}
