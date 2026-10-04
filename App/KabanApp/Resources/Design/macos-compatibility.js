/* Rendering compatibility only; approved source bytes remain unchanged. */
(()=>{
 const masonry=document.querySelector('.mas');
 if(masonry){const boxes=[...masonry.children];if(boxes.length===11){masonry.style.columnCount='auto';masonry.style.display='grid';masonry.style.gridTemplateColumns='repeat(3,minmax(0,1fr))';masonry.style.gap='10px';masonry.style.alignItems='start';masonry.replaceChildren();for(const group of [boxes.slice(0,3),boxes.slice(3,7),boxes.slice(7,11)]){const column=document.createElement('div');column.append(...group);masonry.append(column);}}}
 // Long source galleries remain reachable inside a shorter application window.
 if(document.documentElement.scrollHeight>innerHeight){document.documentElement.style.overflow='auto';document.body.style.overflow='visible';}
})();
