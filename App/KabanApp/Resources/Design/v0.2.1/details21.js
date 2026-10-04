// v0.2.1 details panels: waiting_human · suspicious_files (UC-25, арх. §5, §8.2)
// SuspiciousFile {path, rule: pattern|size, pattern?, sizeBytes, isText, blob}; rows: [dir, name, size, rule, pattern, blob, mark, isText, overMax]
// «дифф» iff isText && sizeBytes < max_file_mb (isText from git diff --numstat, arch §6) — independent of rule; else «Показать в Finder»
const rtag = (rule, pat) => rule==='pattern'
  ? `<span class="rtag sec">${ic('file',9)}по шаблону <span class="pt">${pat}</span></span>`
  : `<span class="rtag sz">${ic('box',9)}больше 5 МБ</span>`;
const sfRow = (f) => `<div class="r ${f[6]?'hl':''}">${ic('file',12)}<span class="p"><span><span class="dir">${f[0]}</span>${f[1]}</span>${f[6]==='new'?'<span class="stag">новый</span>':f[6]==='chg'?'<span class="stag chg">изменён</span>':''}</span><span class="sz ${f[3]==='size'?'big':''}">${f[2]}</span><span>${rtag(f[3],f[4])}</span>${!(f[7] && !f[8])?`<span class="lk">${ic('folder',10)}Показать в Finder</span>`:`<span class="lk">${ic('code',10)}дифф</span>`}</div>`;
const sfTable = (rows, foot) => `<div class="sft"><div class="hd"><span></span><span>Файл · весь diff ветки от базы</span><span style="text-align:right">Размер</span><span>Правило</span><span></span></div>${rows.map(sfRow).join('')}<div class="ft">${foot}</div></div>`;
const decide = (n, cur, next, pending, tid='SHOP-52') => `
   <div class="dec"><span class="btn primary ${pending?'pending':''}">${pending?`<span class="spin"></span>Отправлено…`:`${ic('check',11)}Принять файлы (${n})`}</span><span class="cap2"><b>Примет ровно эти ${n} файла</b> (<span class="mono">acceptSuspiciousFiles</span>). Kaban сразу перепроверит ветку и продолжит <b>${cur} → ${next}</b> без нового запуска агента; попытка не списывается.</span></div>
   <div class="dec"><span class="btn">${ic('message',11)}Попросить убрать</span><span class="cap2"><b>Набор не принимается.</b> Замечание агенту (<span class="mono">answerHuman</span>) → новый запуск ${cur}; после его гейтов проверка заново. На gate/merge — «Вернуть с замечанием» (<span class="mono">requestChanges</span>), тоже без принятия.</span></div>
   <div class="also"><div class="lb">${ic('info',11)}<span><b style="color:var(--text)">Эти действия тоже примут текущий набор</b> — изменённый или новый файл сработает снова:</span></div>
    <div class="acts2"><span class="btn sm">${ic('refresh',10)}Перезапустить</span><span class="btn sm">${ic('inbox',10)}В Backlog</span><span class="btn sm">${ic('x',10)}Отменить…</span><span class="cbk"><span class="check off"></span>Сохранить ветку → <span class="mono">kaban/archive/${tid}</span></span></div>
    <div class="cmdl2">retryStage · moveTask · cancelTask(keepBranch) · «Отклонить» — только в Human Review</div></div>`;
const accepted = `<div class="acc"><div class="ah">${ic('history',11)}Принятые ранее<span class="n">2</span><span class="sp"></span><span class="faint" style="font-weight:500;font-size:10.5px">TaskDetail.acceptedFiles · повторно не срабатывают, пока не изменятся</span></div>
    <div class="ar">${ic('check',11)}<span class="mono">docs/payment-flow.pdf</span><span class="bl">52e1a90</span><span>вы</span><span class="w">3 окт, 18:20</span></div>
    <div class="ar">${ic('check',11)}<span class="mono">.env.test</span><span class="bl">0b77f3d</span><span>вы</span><span class="w">3 окт, 18:21</span></div></div>`;
const chips52 = `<span class="chipm">${ic('play',10)}запуск 4</span><span class="chipm">${ic('bot',10)}composer-1 ${pooltag('cm')}</span><span class="chipm mono">${ic('branch',10)}kaban/shop-52-payment-gateway</span>`;
const head52 = pHead21({id:'SHOP-52',crumb:'shop-api · Dev',title:'Интеграция платёжного шлюза',icon:'shieldalert',pill:'waiting_human · suspicious_files',chips:chips52,cur:'Dev'});
const FILES = [
  ['', '.env.local', '412 Б', 'pattern', '.env*', '3f9a1c2', '', true, false],
  ['certs/', 'stripe-test.pem', '3,2 КБ', 'pattern', '*.pem', '8d04e7b', '', true, false],
  ['fixtures/', 'orders-dump.sql', '12,4 МБ', 'size', '', 'c71b5e0', '', true, true],
];
const tblFoot = `<span>дифф — при <span class="mono">isText</span> и размере &lt; <span class="mono">max_file_mb</span>, в Cursor из <span class="mono">clonePath</span>; иначе Finder</span><span class="sp"></span><a>В исключения проекта…</a>`;
const feed52 = `
 <div class="tabs"><span class="on">Лента</span><span>Живой лог</span><span>Сводка</span><span>Попытки <span class="n">4</span></span></div>
 <div class="feed">
  ${evr21('sf','shieldalert','Найдены подозрительные файлы: 3 <span class="evcode">suspiciousFilesFound</span>','после гейтов Dev, запуск 4 · переход Dev → Test остановлен · не инцидент, попытка не списана','14:52')}
  ${evr21('','check','Dev завершена · гейты зелёные','<span class="mono">complete_stage</span> · npm test ✓ (318) · eslint ✓ · +412 −36','14:51')}
  ${evr21('','play','Запуск Dev · запуск 4','<span class="mono">cursor-agent --model composer-1</span> · ↩ из Test: «нет теста на отказ 3-D Secure»','14:22')}
 </div>`;

const panelSusp = `<div class="panel">
 ${head52}
 <div class="attn">
  <div class="attn-h">${ic('shieldalert',14)}<b>В ветке подозрительные файлы: 3</b><span class="t">14:52 · после гейтов Dev · запуск 4</span></div>
  <div class="attn-b">
   <div class="hint2" style="white-space:nowrap">${ic('info',11)}<span>Весь diff ветки от базы <span class="mono">main@a41c9e2</span> · не инцидент, refs не откатывались · попытка не списана</span></div>
   ${sfTable(FILES, tblFoot)}
   ${decide(3,'Dev','Test')}
   ${accepted}
  </div>
 </div>
 ${feed52}
 <div class="composer"><b class="cl">${ic('message',12)}Замечание агенту</b><span class="ph">«Попросить убрать» подставит: «Убери из ветки: .env.local, certs/stripe-test.pem…»</span><span class="btn sm primary">Отправить и продолжить</span></div>
</div>`;

const FILES_STALE = [
  ['certs/', 'stripe-test.pem', '3,2 КБ', 'pattern', '*.pem', '8d04e7b', '', true, false],
  ['fixtures/', 'orders-dump.sql', '9,8 МБ', 'size', '', 'e2a6d41', 'chg', true, true],
  ['scripts/seed/', '.env.seed', '268 Б', 'pattern', '.env*', '91fc0b3', 'new', true, false],
];
const panelStale = `<div class="panel">
 ${head52}
 <div class="attn">
  <div class="attn-h">${ic('shieldalert',14)}<b>В ветке подозрительные файлы: 3</b><span class="t">набор обновлён 15:03 · запуск 4</span></div>
  <div class="attn-b">
   <div class="stale">${ic('info',13)}<div><b>Набор файлов изменился — ничего не принято.</b> Пока вы смотрели, ветка изменилась (правка в клоне, другое окно или CLI), и демон ответил <span class="mono">stale_suspicious_files</span>. Список перечитан через <span class="mono">getTaskDetail</span>: убран <s class="mono">.env.local</s>, изменён <span class="mono">orders-dump.sql</span> (новый blob), новый <span class="mono">.env.seed</span>. Проверьте его и примите ещё раз.</div></div>
   ${sfTable(FILES_STALE, `<span>подсвечены новые и изменённые · прежний blob дампа <span class="mono">c71b5e0</span></span><span class="sp"></span><a>В исключения проекта…</a>`)}
   ${decide(3,'Dev','Test')}
   ${accepted}
  </div>
 </div>
 <div class="tabs"><span class="on">Лента</span><span>Живой лог</span><span>Сводка</span><span>Попытки <span class="n">4</span></span></div>
 <div class="feed">
  ${evr21('sf','shieldalert','Найдены подозрительные файлы: 3 <span class="evcode">suspiciousFilesFound</span>','после гейтов Dev, запуск 4 · переход Dev → Test остановлен · не инцидент, попытка не списана','14:52')}
  ${evr21('','check','Dev завершена · гейты зелёные','<span class="mono">complete_stage</span> · npm test ✓ (318) · eslint ✓ · +412 −36','14:51')}
 </div>
 <div class="composer"><b class="cl">${ic('message',12)}Замечание агенту</b><span class="ph">текст уйдёт агенту, набор не примется</span><span class="btn sm primary">Отправить и продолжить</span></div>
</div>`;
