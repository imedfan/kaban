// v0.2.1 · «Вернуть…» sheet on gate / merge stages for waiting_human · suspicious_files
// Spec v0.8.3 UC-25.4, frontend plan v0.5.10 §3.5, arch v0.11.2 §3.1, §3.3, §8.2.
// One «Вернуть…» button in the panel; the sheet's primary button label depends on the note field:
//   empty  → «Принять файлы и вернуть» → moveTask(stage)                       — accepts the set
//   filled → «Вернуть с замечанием»    → requestChanges(taskId, comments, target) — does NOT accept
const PIPE_GATE = ['Backlog','Dev','Test','Checks','AI Review','Human Review','Merge','Done'];
const rsHead = (o) => {
  const i = o.stages.indexOf(o.cur);
  return `<div class="p-head">
  <div class="p-row">${mascotFace('🦊','wave',22)}<span class="p-id">${o.id}</span><span class="p-crumb">${o.crumb}</span><span class="sp"></span>
   <span class="btn">${ic('external',11)}Открыть в Cursor</span><span class="iconbtn">${ic('more',14)}</span><span class="iconbtn">${ic('x',13)}</span></div>
  <div class="p-title">${o.title}</div>
  <div class="p-meta"><span class="statpill am">${ic('shieldalert',11)}waiting_human · suspicious_files</span>${o.chips}</div>
  <div class="path">${o.stages.map((s,k)=>`<span class="${k<i?'done':k===i?'cura':''}">${s}</span>`).join(ic('chevright',10))}</div>
 </div>`;
};
// decision block on gate / merge: no «Попросить убрать» / answerHuman (invalid_state there), one «Вернуть…»
const rsDecide = (n, cur, next, tid) => `
   <div class="dec"><span class="btn primary">${ic('check',11)}Принять файлы (${n})</span><span class="cap2"><b>Примет ровно ${n===1?'этот файл':'эти '+n+' файла'}</b> (<span class="mono">acceptSuspiciousFiles</span>) и продолжит <b>${cur} → ${next}</b> без нового запуска.</span></div>
   <div class="dec"><span class="btn on">${ic('undo',11)}Вернуть…</span><span class="cap2">Лист: куда вернуть и замечание агенту. Без замечания — <span class="mono">moveTask</span>, с замечанием — <span class="mono">requestChanges</span>.</span></div>
   <div class="also"><div class="lb">${ic('info',11)}<span><b style="color:var(--text)">Эти действия тоже примут текущий набор:</b></span></div>
    <div class="acts2"><span class="btn sm">${ic('refresh',10)}Перезапустить</span><span class="btn sm">${ic('inbox',10)}В Backlog</span><span class="btn sm">${ic('x',10)}Отменить…</span><span class="cbk"><span class="check off"></span>Сохранить ветку → <span class="mono">kaban/archive/${tid}</span></span></div></div>`;

function rsPanel(c, filled) {
  const n = c.files.length;
  const nf = n===1 ? '1 файл' : n+' файла';
  const fileRows = c.files.map(f=>`<div class="r">${ic('file',11)}<span class="p"><span class="dir">${f[0]}</span>${f[1]}</span><span class="z">${f[2]}</span><span>${rtag(f[3],f[4])}</span>${filled
     ? `<span class="fst keep">${ic('shieldalert',10)}останется помеченным</span>`
     : `<span class="fst acc">${ic('check',10)}в принятые · <span class="mono" style="font-size:9.5px">${f[5]}</span></span>`}</div>`).join('');
  const ta = filled
    ? `<div class="ta focus">${c.note}<span class="caret"></span></div>
       <div class="row"><span class="hint">Замечание уйдёт агенту ${c.target} в промпт (<span class="mono">comments</span>), задача встанет первой в очередь.</span></div>`
    : `<div class="ta"><span class="ph">Пусто — файлы будут приняты. Напишите замечание, чтобы вернуть без принятия…</span></div>
       <div class="row"><span class="sug">${ic('plus',10)}Подставить «Убери из ветки: ${c.files.map(f=>f[0]+f[1]).join(', ')}»</span></div>`;
  const res = filled
    ? `<div class="res keep">${ic('shieldalert',13)}<div><b>Набор не принимается.</b> ${n===1?'Файл остаётся помеченным':'Файлы остаются помеченными'}: после запуска агента в ${c.target} и его гейтов проверка повторится, а файл, оставшийся в ветке, сработает снова. Возврат ручной — в лимиты не идёт.</div></div>`
    : `<div class="res acc">${ic('circlecheck',13)}<div><b>Набор принимается.</b> ${nf} уйд${n===1?'ёт':'ут'} в принятые (<span class="mono">acceptedFiles</span>): с этим содержимым больше не сработа${n===1?'ет':'ют'}. Попытка не списывается, задача вернётся в ${c.target} без замечания; ручной возврат в лимиты не идёт.</div></div>`;
  const foot = filled
    ? `<span class="cmd"><b>requestChanges</b>(taskId, comments, target: "${c.targetId}")</span><span class="sp"></span><span class="btn">Отмена</span><span class="btn primary">${ic('message',11)}Вернуть с замечанием</span>`
    : `<span class="cmd"><b>moveTask</b>(taskId, stage: "${c.targetId}")</span><span class="sp"></span><span class="btn">Отмена</span><span class="btn primary">${ic('check',11)}Принять файлы и вернуть</span>`;
  const sheet = `<div class="rsheet glass-strong">
   <div class="sh-h"><span class="sh-ic">${ic('undo',15)}</span><div style="flex:1;min-width:0"><div class="sh-t">Вернуть ${c.id} из ${c.cur}</div><div class="sh-s">${c.kind} · <span class="mono">waiting_human · suspicious_files</span> · ${nf} в наборе</div></div><span class="iconbtn">${ic('x',12)}</span></div>
   <div class="fr"><span class="l">Куда</span><div class="v">
     <div class="row"><span class="pop tg">${ic('hammer',11)}${c.target}${ic('chevdown',9)}</span><span class="alt">${c.targetNote}</span></div>
     <div class="hint">${c.routeHint}</div></div></div>
   <div class="fr"><span class="l">Возвраты</span><div class="v">
     <div class="row">${c.counters}</div>
     <div class="hint">${c.counterHint}</div></div></div>
   <div class="fr"><span class="l">Замечание агенту</span><div class="v">${ta}</div></div>
   <div class="fr"><span class="l">Файлы</span><div class="v"><div class="fl3">${fileRows}</div></div></div>
   ${res}
   <div class="sep2"></div>
   <div class="sh-f">${foot}</div>
  </div>`;
  return `<div class="rs-frame"><div class="backdrop"><i style="width:420px;height:320px;left:-80px;top:120px;background:#ffb36b"></i><i style="width:380px;height:300px;right:-60px;bottom:-40px;background:#7aa8ff"></i></div>
   <div class="panel">
    ${rsHead(c)}
    <div class="attn">
     <div class="attn-h">${ic('shieldalert',14)}<b>В ветке подозрительные файлы: ${n}</b><span class="t">${c.when}</span></div>
     <div class="attn-b">
      <div class="hint2" style="white-space:nowrap">${ic('info',11)}<span>${c.hint2}</span></div>
      ${sfTable(c.files, tblFoot)}
      ${rsDecide(n, c.cur, c.next, c.id)}
     </div>
    </div>
    ${c.feed||''}
   </div>
   <div class="scrim"></div>${sheet}</div>`;
}

function rsPage(el, c) {
  el.innerHTML = `<div>
   <h1>${c.h1}</h1>
   <div class="lead">${c.lead}</div></div>
  <div class="rs-two">
   <div class="rs-col"><div class="rs-lab"><span class="k">а</span>Поле пустое → «Принять файлы и вернуть» <span class="faint">· <span class="mono">moveTask</span> · набор принимается</span></div>
     ${rsPanel(c,false)}
     <div class="rs-cap">${c.capA}</div></div>
   <div class="rs-col"><div class="rs-lab"><span class="k">б</span>Вписано замечание → «Вернуть с замечанием» <span class="faint">· <span class="mono">requestChanges</span> · набор не принимается</span></div>
     ${rsPanel(c,true)}
     <div class="rs-cap">${c.capB}</div></div>
  </div>`;
}

const RS_GATE = {
  id:'SHOP-55', crumb:'shop-api · Checks', title:'Экспорт заказов в CSV', kind:'gate-стадия Checks',
  stages: PIPE_GATE, cur:'Checks', next:'AI Review', target:'Dev', targetId:'dev',
  chips:`<span class="chipm">${ic('gates',10)}gate · без агента</span><span class="chipm mono">${ic('branch',10)}kaban/shop-55-orders-csv</span><span class="bdg" style="height:20px;display:inline-flex;align-items:center;gap:3px;padding:0 6px;border-radius:6px;background:var(--bg-control);font-size:10.5px;color:var(--text-2)">${ic('undo',9)}Checks→Dev 1/3</span>`,
  feed:`<div class="tabs"><span class="on">Лента</span><span>Живой лог</span><span>Сводка</span><span>Попытки <span class="n">5</span></span></div>
   <div class="feed">
    ${evr21('sf','shieldalert','Найдены подозрительные файлы: 2 <span class="evcode">suspiciousFilesFound</span>','после гейтов Checks · переход Checks → AI Review остановлен · не инцидент','11:40')}
    ${evr21('','check','Checks · гейты зелёные','<span class="mono">npm run e2e</span> ✓ · <span class="mono">npm audit</span> ✓','11:39')}
    ${evr21('','undo','Возврат Checks → Dev 1/3 · on_fail','e2e упал: <span class="mono">export.spec.ts</span> — пустой CSV при 0 заказов','10:52')}
   </div>`,
  when:'11:40 · после гейтов Checks',
  hint2:'Весь diff ветки от базы <span class="mono">main@a41c9e2</span> · гейты Checks зелёные · попытка не списана',
  files:[
    ['fixtures/','orders-dump.sql','12,4 МБ','size','','c71b5e0','',true,true],
    ['','.env.local','412 Б','pattern','.env*','3f9a1c2','',true,false],
  ],
  note:'Убери <span class="mono">fixtures/orders-dump.sql</span> из ветки, генерируй фикстуру в тесте. И <span class="mono">.env.local</span> тоже не коммить — ключи бери из <span class="mono">.env.example</span>.',
  targetNote:'из <span class="mono">on_fail</span> · можно <span>Test</span> · только стадии, которые правят код',
  routeHint:'Заполнено из <span class="mono">StageSummary.onFail</span>: здесь явно <span class="mono">on_fail: { stage: dev, limit: 3 }</span>; без <span class="mono">stage</span> — ближайшая предыдущая по <span class="mono">on_success</span> agent-стадия с <span class="mono">readOnly = false</span>. Read-only стадий в списке нет. Обе кнопки шлют выбранную стадию явно.',
  counters:`<span class="bcnt"><b>Всего возвратов 4/5</b></span><span class="bcnt">${ic('undo',10)}Checks → Dev 1/3 <span class="mono">on_fail.limit</span></span>`,
  counterHint:'Всего — сумма <span class="mono">bounceByReason</span> (ещё Test → Dev 2/3, AI Review → Dev 1/2) против общего лимита возвратов (<span class="mono">bounce_limit_total</span>, 5); у пары — свой лимит возвратов. Ручной возврат счётчики не меняет.',
  h1:'Kaban v0.2.1 · «Вернуть…» на gate-стадии · подозрительные файлы',
  lead:'Задача SHOP-55 на gate-стадии Checks (<span class="mono">kind: gate</span>, без агента) в <span class="mono">waiting_human · suspicious_files</span>. На gate и merge «Попросить убрать» — это «Вернуть с замечанием»: поля «Замечание агенту» внизу панели нет (<span class="mono">answerHuman</span> → <span class="mono">invalid_state</span>), одна кнопка «Вернуть…» открывает лист. Подпись основной кнопки зависит от поля замечания (спека v0.8.3 UC-25.4, фронт-план v0.5.10 §3.5, арх. v0.11.2 §3.3, §8.2). Лист — стекло окна; акцент — янтарь, без красного.',
  capA:'<b>Пустое поле.</b> Кнопка «Принять файлы и вернуть» → <span class="mono">moveTask(stage: "dev")</span>: пары «путь + blob» пишутся в <span class="mono">task_accepted_file</span>, идёт <span class="mono">suspiciousFilesAccepted</span>. Попытка не списывается. Выбор Test в «Куда» даст <span class="mono">stage: "test"</span>. «Подставить…» вставит шаблон и переключит кнопку.',
  capB:'<b>Замечание вписано.</b> Кнопка «Вернуть с замечанием» → <span class="mono">requestChanges(taskId, comments, target: "dev")</span>. Набор не принят: после гейтов Dev проверка пройдёт заново. Возврат ручной: «Всего возвратов 4/5» и «Checks → Dev 1/3» не растут.',
};

const RS_MERGE = {
  id:'SHOP-29', crumb:'shop-api · Merge', title:'Индексы для поиска по SKU', kind:'merge-стадия',
  stages: PIPE_GATE, cur:'Merge', next:'слияние в main', target:'Dev', targetId:'dev',
  chips:`<span class="chipm">${ic('merge',10)}merge · перед слиянием</span><span class="chipm mono">${ic('branch',10)}kaban/shop-29-sku-index</span>`,
  feed:`<div class="tabs"><span class="on">Лента</span><span>Живой лог</span><span>Сводка</span><span>Попытки <span class="n">7</span></span></div>
   <div class="feed">
    ${evr21('sf','shieldalert','Перед слиянием: подозрительный файл 1 <span class="evcode">suspiciousFilesFound</span>','повторная проверка в Merge после rebase · слияние ждёт решения','16:12')}
    ${evr21('','merge','Rebase на main@b7d20f4 · без конфликтов','демон, merge-стадия','16:11')}
    ${evr21('','undo','Конфликт слияния → Dev 1/2 · on_conflict','<span class="mono">db/schema.rb</span> · rebase отменён','13:05')}
   </div>`,
  when:'16:12 · перед слиянием, после rebase',
  hint2:'Повторная проверка в Merge: весь diff ветки от <span class="mono">main@b7d20f4</span> после rebase · попытка не списана',
  files:[
    ['fixtures/','seed-sku.sql','6,8 МБ','size','','5e19ac3','',true,true],
  ],
  note:'Убери <span class="mono">fixtures/seed-sku.sql</span> из ветки: сид собирай в тесте из <span class="mono">scripts/seed-sku.ts</span>, в репозиторий только скрипт.',
  targetNote:'из <span class="mono">on_conflict</span> · можно <span>Test</span> · только стадии, которые правят код',
  routeHint:'Заполнено из <span class="mono">StageSummary.onConflict</span>: демон присылает цель уже разрешённой: без <span class="mono">stage</span> — первая agent-стадия с <span class="mono">readOnly = false</span>, Dev. Дальше задача снова идёт по стадиям, через Human Review, к Merge. Обе кнопки шлют выбранную стадию явно.',
  counters:`<span class="bcnt"><b>Всего возвратов 3/5</b></span><span class="bcnt cf">${ic('merge',10)}Merge → Dev 1/2 <span class="mono">on_conflict.limit</span></span>`,
  counterHint:'Всего — сумма <span class="mono">bounceByReason</span> (ещё Test → Dev 1/3, AI Review → Dev 1/2) против общего лимита возвратов (<span class="mono">bounce_limit_total</span>, 5); пара Merge → Dev — конфликты, фиолетовый бейдж. Ручной возврат счётчики не меняет.',
  h1:'Kaban v0.2.1 · «Вернуть…» на merge-стадии · подозрительные файлы',
  lead:'SHOP-29 в Merge: повторная проверка перед слиянием нашла крупный файл. Merge — тот же лист, что у gate: одна кнопка «Вернуть…», подпись основной кнопки зависит от замечания (спека v0.8.3 UC-25.4, фронт-план v0.5.10 §3.5, арх. v0.11.2 §3.3, §8.2). Автоматический возврат merge задаёт <span class="mono">on_conflict { stage?, limit = 2 }</span>; ручной возврат в лимиты не идёт и стадию выбирает человек.',
  capA:'<b>Пустое поле.</b> «Принять файлы и вернуть» → <span class="mono">moveTask(stage: "dev")</span>: файл принят по blob, задача уходит в Dev без замечания и снова проходит стадии до Merge. Попытка не списывается.',
  capB:'<b>Замечание вписано.</b> «Вернуть с замечанием» → <span class="mono">requestChanges(taskId, comments, target: "dev")</span>: файл остаётся помеченным; проверка после гейтов Dev и ещё раз в Merge. «Всего возвратов 3/5» и «Merge → Dev 1/2» не растут.',
};
