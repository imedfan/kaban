function renderSettings(el, tab, left, right, foot, o={}) {
  const stg = (icn, name, k, cnt, on) => `<div class="stg ${on?'on':''}">${ic(icn,13)}<span>${name}</span>${cnt?`<span class="cnt">${cnt}</span>`:''}<span class="k">${k}</span></div>`;
  const tabs = [['tag','Основное'],['gauge','Пропускная способность'],['bot','Исполнитель'],['shield','Права и git'],['box','Окружение'],['login','Вход'],['gates','Гейты'],['route','Переходы'],['timer','Надёжность'],['plug','Хуки']];
  el.innerHTML = `<div class="win">
  <div class="backdrop"><i style="left:-120px;top:-80px;width:520px;height:420px;background:#ffc9a8"></i><i style="left:-60px;top:460px;width:420px;height:520px;background:#a9cbff"></i><i style="left:700px;top:-220px;width:700px;height:340px;background:#d3defc"></i></div>
  <aside class="sidebar glass s-side">
    <div class="sb-top"><div class="lights"><i></i><i></i><i></i></div><span class="sp"></span>${ic('sidebar',15)}</div>
    <div class="proj" style="padding:4px 8px 10px">${mascotFace('🐗','alarm',26)}<div><div class="pn" style="font-size:14px;font-weight:650">kaban</div><div class="ps mono">~/dev/kaban · main</div></div></div>
    <div class="sb-sec">Стадии пайплайна<span class="sp"></span>${ic('plus',12)}</div>
    ${stg('inbox','Backlog','queue','5')}${stg('hammer','Dev','agent','2',true)}${stg('gates','Lint','gate','1')}${stg('eye','AI Review','agent','2')}${stg('usercheck','Human Review','human','2')}${stg('merge','Merge','merge','')}${stg('circlecheck','Done','terminal','')}
    <div class="sb-sec">Проект · pipeline.yaml</div>
    <div class="sb-item">${ic('shield',14)}Git-политика проекта</div>
    <div class="sb-item">${ic('folder',14)}Рабочая копия задачи</div>
    <div class="sb-item">${ic('hand',14)}Лимиты и возвраты</div>
    <div class="sb-sec">Этот Мак · не в репозитории</div>
    <div class="sb-item">${ic('cpu',14)}Вес и личный максимум</div>
    <div class="sb-item">${ic('sparkles',14)}Маскот</div>
    <div class="sp"></div>
    <div class="hint" style="padding:0 8px">Источник правды — закоммиченный <span class="mono">main:.kaban/pipeline.yaml</span>. Сохранение коммитит только <span class="mono">.kaban/</span>.</div>
  </aside>
  <header class="toolbar">
    <div class="tb-title"><b>Dev · настройки стадии</b><span>kaban · kind: agent · id: dev (не меняется)</span></div>
    <span class="sp"></span>
    ${o.invalid?`<span class="valid" style="color:var(--st-incident-fg)">${ic('alert',12)}1 ошибка проверки</span>`:`<span class="valid">${ic('circlecheck',12)}Файл валиден</span>`}
    <div class="capsule glass"><div class="tbtn">${ic('code',13)}pipeline.yaml</div></div>
    <div class="capsule glass" style="padding:0 4px"><div class="tbtn">Отменить</div><div class="tbtn primary" ${o.invalid?'style="opacity:.45"':''}>${ic('check',12)}Сохранить и закоммитить</div></div>
  </header>
  <main class="s-main">
    <div class="s-tabs">${tabs.map(t=>`<span class="${t[1]===tab?'on':''}">${ic(t[0],12)}${t[1]}</span>`).join('')}</div>
    <div class="s-body"><div class="s-left">${left}</div>${right?`<div class="s-right">${right}</div>`:''}</div>
    <div class="s-foot">${foot}</div>
  </main></div>`;
}
