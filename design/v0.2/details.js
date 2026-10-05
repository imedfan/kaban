// v0.2 details panels (glass panel over the board)
const pHead = (id, crumb, title, pill, chips, cur) => {
  const st = ['Backlog','Dev','Test','AI Review','Human Review','Merge','Done'];
  const i = st.indexOf(cur);
  return `<div class="p-head">
  <div class="p-row">${mascotFace('🦊','wave',22)}<span class="p-id">${id}</span><span class="p-crumb">${crumb}</span><span class="sp"></span>
   <span class="btn">${ic('external',11)}Открыть в Cursor</span><span class="iconbtn">${ic('more',14)}</span><span class="iconbtn">${ic('x',13)}</span></div>
  <div class="p-title">${title}</div>
  <div class="p-meta"><span class="statpill am">${ic('hand',11)}${pill}</span>${chips}</div>
  <div class="path">${st.map((s,k)=>`<span class="${k<i?'done':k===i?'cura':''}">${s}</span>`).join(ic('chevright',10))}</div>
 </div>`;
};
const composer = `<div class="composer"><b class="cl">${ic('message',12)}Замечание агенту</b><span class="ph">текст уйдёт агенту, стадия продолжится</span><span class="btn sm primary">Отправить и продолжить</span></div>`;
const evr = (cls, icon, h, s, t) => `<div class="ev ${cls}"><span class="g">${ic(icon,12)}</span><div><div class="h">${h}</div><div class="s">${s}</div></div><span class="t">${t}</span></div>`;

const panelSubst = `<div class="panel">
 ${pHead('SHOP-35','shop-api · AI Review','Кэш каталога в Redis','waiting_human · model_substituted',
   `<span class="chipm">${ic('play',10)}запуск 7</span><span class="chipm">${ic('bot',10)}opus-4.5 ${pooltag('om')}</span><span class="chipm mono">${ic('branch',10)}kaban/shop-35-redis-cache</span>`,'AI Review')}
 <div class="attn">
  <div class="attn-h">${ic('alert',14)}<b>Cursor ответил не той моделью</b><span class="t">15:12:04 · запуск 7</span></div>
  <div class="attn-b">
   <div class="cmp">
    <div class="mbox"><div class="lb">${ic('bot',10)}Запрошена</div><div class="nm">Opus 4.5 ${pooltag('om')}</div>
     <dl><dt>id</dt><dd class="mono">opus-4.5</dd><dt>откуда</dt><dd>стадия AI Review</dd><dt>время</dt><dd>15:12:03, старт</dd></dl></div>
    <div class="arrow">${ic('arrowright',16)}</div>
    <div class="mbox got"><div class="lb">${ic('alert',10)}Ответила</div><div class="nm">Sonnet 4 ${pooltag('om')}</div>
     <dl><dt>id</dt><dd class="mono">sonnet-4</dd><dt>имя в init</dt><dd>«Claude Sonnet 4»</dd><dt>fallbackModel</dt><dd class="mono">sonnet-4</dd></dl></div>
   </div>
   <div class="facts"><span class="fact">${ic('check',10)}остановлено до первого вызова инструмента</span><span class="fact">${ic('check',10)}клон чистый</span><span class="fact">${ic('check',10)}попытка не списана</span><span class="fact">${ic('check',10)}в лимит запусков не считается</span><span class="fact">${ic('ban',10)}результат не принят</span></div>
   <div class="hint2" style="white-space:nowrap">${ic('file',11)}<a style="color:var(--accent)">Лог запуска 7</a><span class="faint">·</span>${ic('info',11)}<span>флаг «подменена» на Opus 4.5 · ещё 1 задача ждёт</span><span class="sp"></span><span class="btn sm">Снять флаг</span></div>
   <div class="acts2"><span class="btn primary">${ic('refresh',11)}Повторить</span><span class="btn">${ic('bot',11)}Другая модель${ic('chevdown',9)}</span><span class="btn">${ic('inbox',11)}В Backlog</span><span class="sp"></span><span class="hint2">Повтор на Opus 4.5 подождёт квоту Om (до 17.10)</span></div>
  </div>
 </div>
 <div class="tabs"><span class="on">Лента</span><span>Живой лог</span><span>Сводка</span><span>Запуски <span class="n">7</span></span></div>
 <div class="feed">
  ${evr('am','alert','Остановлено: подмена модели <span class="evcode">model_substituted</span>','запрошена <span class="mono">opus-4.5</span>, в <span class="mono">system/init</span> «Claude Sonnet 4» · процесс убит до первого вызова · флаг модели <span class="mono">substituted</span>','15:12')}
  ${evr('','play','Запуск AI Review · запуск 7','<span class="mono">cursor-agent --model opus-4.5</span> · MCP: только сервер доски','15:12')}
  ${evr('','check','Dev завершена · гейты зелёные','<span class="mono">complete_stage</span> · swift build ✓ · swift test ✓ (212) · +96 −14','15:09')}
  ${evr('grey','info','Модель не подтверждена <span class="evcode">model_unconfirmed</span>','Dev, запуск 6: имени «composer-1 (preview)» нет в справочнике · запуск продолжен','14:31')}
  ${evr('','play','Запуск Dev · запуск 6','<span class="mono">cursor-agent --model composer-1</span>','14:31')}
 </div>
 ${composer}
</div>`;

const seg12 = n => `<span class="segs">${Array.from({length:12},(_,k)=>`<i class="${k<n?'on':''}"></i>`).join('')}</span>`;
const panelRunLimit = `<div class="panel">
 ${pHead('SHOP-47','shop-api · Dev','Импорт прайса из 1С','waiting_human · run_limit',
   `<span class="chipm">${ic('history',10)}запуски 12/12</span><span class="chipm">${ic('bot',10)}composer-1 ${pooltag('cm')}</span><span class="chipm mono">${ic('branch',10)}kaban/shop-47-price-import</span>`,'Dev')}
 <div class="attn">
  <div class="attn-h">${ic('hand',14)}<b>Лимит автоматических запусков: 12 из 12</b><span class="t">14:58 · max_runs_per_task</span></div>
  <div class="attn-b">
   <div style="display:flex;align-items:center;gap:10px;font-size:11.5px;color:var(--text-2)">${seg12(12)}<span>Dev ×7 · Test ×3 · AI Review ×2</span><span class="sp"></span><span class="faint">не в счёт: rate_limit, перезапуск демона</span></div>
   <table class="runs">
    <tr><td>12</td><td>Dev</td><td>попытка 2/3</td><td><span class="rk">краш процесса</span></td><td>WIP сохранён · клон откатан</td><td>14:57</td></tr>
    <tr><td>11</td><td>Dev</td><td>попытка 1/3</td><td><span class="rk">stall 10 мин</span></td><td>WIP сохранён · клон откатан</td><td>14:41</td></tr>
    <tr><td>10</td><td>Test</td><td>попытка 1/3</td><td>возврат в Dev</td><td>↩ 3/3 · «падает на пустом артикуле»</td><td>14:22</td></tr>
    <tr><td>9</td><td>Dev</td><td>попытка 1/3</td><td>готово</td><td>гейты зелёные</td><td>14:05</td></tr>
   </table>
   <div class="snap">
    <div class="sn-h">${ic('history',12)}<b>Сохранённое состояние клона</b><span class="mono">refs/kaban/wip/r-0412</span><span class="sp"></span><span class="faint">запуск 12 · перед откатом · 14:57</span></div>
    <div class="sn-f"><span class="mono">Sources/Import/PriceParser.swift</span><span class="ad">+121 −9</span></div>
    <div class="sn-f"><span class="mono">Sources/Import/OneCClient.swift</span><span class="ad">+48 −13</span></div>
    <div class="sn-f"><span class="mono">Tests/ImportTests/PriceParserTests.swift</span><span class="ad">+15</span><span class="faint">· и ещё 4 файла · всего +184 −22</span></div>
    <div class="acts2" style="margin-top:4px"><span class="btn">${ic('undo',11)}Восстановить в клон</span><span class="btn">${ic('code',11)}Показать дифф</span><span class="hint2">восстанавливает поверх последнего коммита стадии</span></div>
   </div>
   <div class="acts2"><span class="btn primary">${ic('refresh',11)}Перезапустить стадию</span><span class="btn">${ic('bot',11)}Другая модель${ic('chevdown',9)}</span><span class="btn">${ic('inbox',11)}В Backlog</span><span class="btn">${ic('x',11)}Отменить…</span></div>
   <div class="hint2">${ic('info',11)}Любое ваше действие (и замечание агенту) обнуляет счётчик запусков: 12 → 0</div>
  </div>
 </div>
 <div class="tabs"><span class="on">Лента</span><span>Живой лог</span><span>Сводка</span><span>Запуски <span class="n">14</span></span></div>
 <div class="feed">
  ${evr('am','hand','Лимит запусков: 12 из 12 <span class="evcode">run_limit</span>','задача ждёт вас · счётчик обнулится после любого действия','14:58')}
  ${evr('','history','Состояние клона сохранено перед откатом','<span class="mono">refs/kaban/wip/r-0412</span> · 7 файлов, +184 −22 · после краша','14:57')}
  ${evr('','alert','Краш процесса · Dev, попытка 2/3','exit 137 · <a style="color:var(--accent)">лог запуска 12</a>','14:57')}
 </div>
 ${composer}
</div>`;
