// v0.2.1 · «Добавить проект» + commit author (GitIdentity). Arch v0.11.21 §5 (addProject / setProjectIdentity, CommandError.params,
// ProjectSummary.identity), §8.2; spec v0.8.23 UC-01. Author lives with the daemon on this Mac, not in .kaban/.
const M = t => `<span class="mono">${t}</span>`;
const apWin = () => `<div class="ap-win">
  <div class="tb"><i></i><i></i><i></i><b>Kaban</b></div>
  <div class="sb"><div class="g">Проекты</div>
   <div class="p"><span class="e">🐗</span>kaban</div><div class="p"><span class="e">🐙</span>mobile-app</div><div class="p"><span class="e">🦉</span>docs-site</div></div>
  <div class="bd">${[0,1].map(()=>`<div class="ln">${[3,2,1,2].map(n=>`<div class="cl"><s></s>${'<div class="cd"></div>'.repeat(n)}</div>`).join('')}</div>`).join('')}</div>
 </div>`;
const apHead = `<div class="sh-h"><span class="sh-ic">${ic('folder',15)}</span><div style="flex:1;min-width:0"><div class="sh-t">Добавить проект</div><div class="sh-s">Папка git-репозитория на этом Маке</div></div><span class="iconbtn">${ic('x',12)}</span></div>`;
const apFolder = `<div class="f2"><span class="l">Папка</span><div class="v">
   <div class="row"><span class="inp mono">${ic('folder',11)}~/dev/shop-api</span><span class="btn">Выбрать…</span></div>
   <div class="hint">git-репозиторий · ветка ${M('main')} · ${M('.kaban/pipeline.yaml')} нет</div></div></div>
 <div class="f2"><span class="l">Шаблон</span><div class="v">
   <div class="cbl"><span class="check">${ic('check',10)}</span>Создать шаблон ${M('.kaban/')} и закоммитить</div>
   <div class="hint">Демон положит шаблон по умолчанию и закоммитит только ${M('.kaban/')}.</div></div></div>`;
const apFoot = (cmd) => `<div class="sep2"></div><div class="sh-f"><span class="sp"></span><span class="btn">Отмена</span><span class="btn primary">${ic('plus',11)}Добавить</span></div><div class="cmdn">→ ${cmd}</div>`;
const apErr = (sub) => `<div class="eb">${ic('alert',13)}<div><span class="t">Не задан автор коммитов: укажите имя и почту<span class="code">identity_required</span></span>${sub}</div></div>`;
const apIdHint = `<div class="hint">Автор сохранится в настройках проекта на этом Маке (не в ${M('.kaban/')}) и пойдёт в git демона через ${M('-c user.name/email')}. Сменить — в настройках проекта.</div>`;
function apSheet(mode) {
  let body;
  if (mode === 'a') {
    body = `${apFolder}
    <div class="f2"><span class="l">Автор</span><div class="v"><div class="src">${ic('info',12)}<div><b>Возьмём из настроек git.</b> Демон один раз выполнит ${M('git -C ~/dev/shop-api config user.name')} и ${M('user.email')} — это конфиг репозитория, глобальный и системный. Пробелы по краям обрежутся. Автор сохранится у демона на этом Маке; сменить — в настройках проекта.</div></div></div></div>
    ${apFoot(`<b>addProject</b>(path, createTemplate)`)}`;
  } else if (mode === 'b') {
    body = `${apErr('В настройках git нашлось только имя, почты нет. Проект не создан.')}
    ${apFolder}
    <div class="f2"><span class="l">Имя</span><div class="v"><span class="inp">Артём Палкин<span class="ftag">из настроек git</span></span></div></div>
    <div class="f2"><span class="l">Почта</span><div class="v"><span class="inp focus"><span class="caret"></span><span class="ph">artem@example.com</span></span>${apIdHint}</div></div>
    ${apFoot(`<b>addProject</b>(path, createTemplate) → identity_required · missing: email`)}`;
  } else {
    body = `${apErr('Повтор с пустой почтой — проект не создан.')}
    ${apFolder}
    <div class="f2"><span class="l">Имя</span><div class="v"><span class="inp">Артём Палкин</span></div></div>
    <div class="f2"><span class="l">Почта</span><div class="v"><span class="inp err focus"><span class="caret"></span></span><span class="errt">${ic('alert',10)}Укажите почту</span>${apIdHint}</div></div>
    ${apFoot(`<b>addProject</b>(path, createTemplate, identity) → identity_required · params.missing: email`)}`;
  }
  return `<div class="ap-frame">${apWin()}<div class="scrim"></div><div class="apsheet glass-strong">${apHead}${body}</div></div>`;
}
const apInvalid = () => `<div class="ap-inset"><div class="apsheet glass-strong">
   ${apErr('Проект не создан.')}
   <div class="f2"><span class="l">Имя</span><div class="v"><span class="inp focus"><span class="caret"></span></span><span class="errt soft">${ic('alert',10)}Имя в настройках git содержит служебные символы, укажите вручную</span></div></div>
   <div class="f2"><span class="l">Почта</span><div class="v"><span class="inp">artem@example.com<span class="ftag">из настроек git</span></span></div></div>
   <div class="cmdn">→ <b>addProject</b>(path, createTemplate) → identity_required · invalid: name, email=artem@example.com</div>
  </div></div>`;
const apOld = () => `<div class="fbox ap-old">
   <h3>${ic('user',13)}Старый демон<span class="k">nil</span></h3>
   <div class="fr"><span>Имя</span><span class="idv dash">—</span></div>
   <div class="fr"><span>Почта</span><span class="idv dash">—</span></div>
   <div class="acts"><span class="btn sm">Изменить…</span><span class="cmd">→ <b>setProjectIdentity</b></span></div>
  </div>`;
const apSettings = () => `<div class="ap-swin">
  <aside class="s2-side">
   <div class="proj" style="display:flex;gap:8px;align-items:center;padding:0 6px 4px">${mascotFace('🦊','wave',22)}<div><div style="font-size:12.5px;font-weight:650">shop-api</div><div class="mono" style="font-size:9.5px;color:var(--text-3)">~/dev/shop-api · main</div></div></div>
   <div class="more">Стадии · Проект · .kaban/ …</div>
   <div class="grp">Проект · на этом Маке</div>
   ${sit('plug','MCP для запусков')}${sit('cpu','Вес и личный максимум')}${sit('sparkles','Маскот')}${sit('user','Автор коммитов','',true)}
  </aside>
  <div class="main">
   <div><div class="pt">Автор коммитов</div><div class="ps">shop-api · хранится у демона на этом Маке, не в ${M('.kaban/')}</div></div>
   <div class="fbox">
    <h3>${ic('user',13)}Имя и почта<span class="k">ProjectSummary.identity</span></h3>
    <div class="fr"><span>Имя</span><span class="idv">Артём Палкин</span></div>
    <div class="fr"><span>Почта</span><span class="idv mono">artem@example.com</span></div>
    <div class="acts"><span class="btn sm">Изменить…</span><span class="cmd">→ <b>setProjectIdentity</b></span><span class="ok">${ic('check',9)}с новых коммитов</span></div>
   </div>
  </div></div>`;
function apPage(el) {
  el.innerHTML = `<div>
   <h1>Kaban v0.2.1 · «Добавить проект» · автор коммитов</h1>
   <div class="lead">Все коммиты демона и агента подписаны автором проекта ${M('GitIdentity { name, email }')} через ${M('-c user.name=… -c user.email=…')}; глобальный конфиг в работе демона не участвует (арх. v0.11.21 §5, §8.2, спека v0.8.23 UC-01). ${M('addProject(path, createTemplate, identity?)')}: нет автора или имя / почта пустые (одни пробелы — тоже) → ${M('identity_required')}, проект не создаётся; детали — ${M('CommandError.params')}: ${M('missing')}, ${M('invalid')} (${M('name')} | ${M('email')} | ${M('name,email')}), найденные ${M('name')} / ${M('email')}. Каждое поле — ровно в одном виде; отклонённое значение не возвращается. Ошибки оранжевые.</div></div>
  <div class="ap-three">
   <div class="ap-col"><div class="ap-lab"><span class="k">а</span>Обычный путь <span class="faint">· автор из настроек git</span></div>
    ${apSheet('a')}
    <div class="ap-cap"><b>Без identity.</b> Демон читает ${M('git -C &lt;repo&gt; config')} (репозиторий, глобальный, системный). Есть имя и почта — проект добавлен, автор сохранён у демона.</div></div>
   <div class="ap-col"><div class="ap-lab"><span class="k">б</span>Ответ ${M('identity_required')} <span class="faint">· первый отказ, без подсветки</span></div>
    ${apSheet('b')}
    <div class="ap-cap"><b>Первый отказ</b> без ${M('identity')}: ${M('missing=email, name=Артём Палкин')}. Имя подставлено («из настроек git»), уточнение «нашлось только имя», фокус в первом поле из ${M('missing')} / ${M('invalid')}, без подсветки.</div></div>
   <div class="ap-col"><div class="ap-lab"><span class="k">в</span>Повтор с пустой почтой <span class="faint">· подсвечено пустое поле</span></div>
    ${apSheet('c')}
    <div class="ap-cap"><b>Отказ вызову с ${M('identity')}</b>: поля из ${M('missing')} / ${M('invalid')} с обводкой, здесь «Укажите почту». Без ключей — только общий текст.</div></div>
  </div>
  <div class="ap-set">
   <div class="ap-col"><div class="ap-lab"><span class="k">${ic('user',11)}</span>Настройки проекта <span class="faint">· «Проект · на этом Маке» → «Автор коммитов»</span></div>${apSettings()}</div>
   <div class="ap-col"><div class="ap-lab"><span class="k">г</span>Первый отказ, ${M('invalid: name')} <span class="faint">· без обводки и без уточнения в плашке</span></div>${apInvalid()}</div>
   <div class="ap-col"><div class="ap-lab"><span class="faint" style="font-size:12px;font-weight:650">Старый демон</span></div>${apOld()}
    <div class="ap-cap">${M('ProjectSummary.identity = nil')} → «—»; «Изменить…» доступна, те же проверки и тексты, что в листе.</div></div>
  </div>`;
}
