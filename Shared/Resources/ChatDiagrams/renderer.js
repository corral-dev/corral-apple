'use strict';
// Engines are pinned, local and loaded only when first requested. No transcript
// HTML enters this document; only sanitized engine SVG reaches the export DOM.
let mermaidReady, plantReady;
const palette = dark => dark
  ? {ink:'#edf3ef',soft:'#bbcec1',line:'#99ad9f',node:'#2d3c33',rim:'#718c7a',accent:'#96d5b3',note:'#443e2f',noteInk:'#f6e7b6',group:'#252a27',surface:'#1c1c1e'}
  : {ink:'#24312b',soft:'#4f6157',line:'#657c6d',node:'#edf4ef',rim:'#9db4a5',accent:'#2e7d5b',note:'#f6e7b6',noteInk:'#443e2f',group:'#f5f7f5',surface:'#ffffff'};
function loadScript(path) {
  return new Promise((resolve,reject) => {
    const script=document.createElement('script'); script.src=path;
    script.onload=resolve; script.onerror=()=>reject(new Error('engine')); document.head.append(script);
  });
}
function config(p,dark) {
  return {startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,
    theme:'base',look:'classic',htmlLabels:false,fontFamily:'-apple-system, sans-serif',
    maxTextSize:20000,maxEdges:500,
    secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering','theme','look','themeVariables','themeCSS','fontFamily','htmlLabels'],
    themeVariables:{darkMode:dark,background:'transparent',fontFamily:'-apple-system, sans-serif',fontSize:'16px',
      primaryColor:p.node,primaryBorderColor:p.rim,primaryTextColor:p.ink,
      secondaryColor:p.note,secondaryTextColor:p.noteInk,secondaryBorderColor:p.rim,
      tertiaryColor:p.group,tertiaryTextColor:p.ink,tertiaryBorderColor:p.rim,
      lineColor:p.line,textColor:p.ink,mainBkg:p.node,nodeBkg:p.node,nodeBorder:p.rim,nodeTextColor:p.ink,
      clusterBkg:p.group,clusterBorder:p.rim,titleColor:p.soft,edgeLabelBackground:p.surface,
      actorBkg:p.node,actorBorder:p.rim,actorTextColor:p.ink,actorLineColor:p.rim,
      signalColor:p.line,signalTextColor:p.ink,labelBoxBkgColor:p.group,labelBoxBorderColor:p.rim,
      labelTextColor:p.ink,loopTextColor:p.ink,noteBkgColor:p.note,noteTextColor:p.noteInk,noteBorderColor:p.note,
      activationBkgColor:p.node,activationBorderColor:p.rim,classText:p.ink,
      attributeBackgroundColorOdd:p.node,attributeBackgroundColorEven:p.group,compositeBackground:p.group},
    flowchart:{useMaxWidth:false,curve:'linear',padding:14,htmlLabels:false},
    sequence:{useMaxWidth:false,mirrorActors:false},class:{useMaxWidth:false},mindmap:{useMaxWidth:false}};
}
function plantInput(source,p) {
  // Fail closed for preprocessor/file/network access. Bundled C4 is the sole
  // permitted include; the scheme handler additionally serves a fixed manifest.
  if (/(?:%|<\s*(?:img|image)\b|\[\[|https?:\/\/|file:|data:|url\s*\()/i.test(source)) throw new Error('blocked');
  for (const line of source.split('\n')) {
    if (/^\s*!/.test(line) && !/^\s*!include\s+<C4\/C4(?:_[A-Za-z]+)?>\s*$/i.test(line)) throw new Error('blocked');
  }
  const skin=['skinparam backgroundColor transparent','skinparam shadowing false','skinparam roundCorner 10',
    'skinparam defaultFontName sans-serif','skinparam defaultFontSize 16',`skinparam defaultFontColor ${p.ink}`,
    `skinparam ArrowColor ${p.line}`,`skinparam ArrowFontColor ${p.soft}`,
    ...['Class','Participant','Activity','Component','Rectangle','State','Object','Usecase'].flatMap(x=>[
      `skinparam ${x}BackgroundColor ${p.node}`,`skinparam ${x}BorderColor ${p.rim}`,`skinparam ${x}FontColor ${p.ink}`]),
    `skinparam ClassAttributeFontColor ${p.ink}`,`skinparam LifeLineBorderColor ${p.rim}`,
    `skinparam SequenceLifeLineBorderColor ${p.rim}`,`skinparam SequenceLifeLineBackgroundColor ${p.node}`,
    `skinparam NoteBackgroundColor ${p.note}`,`skinparam NoteBorderColor ${p.note}`,`skinparam NoteFontColor ${p.noteInk}`,
    `skinparam ActivityDiamondBackgroundColor ${p.note}`,`skinparam ActivityDiamondFontColor ${p.noteInk}`,'hide footbox'];
  let body=source.trim();
  if (!/^@startuml\b/i.test(body)) body='@startuml\n'+body+'\n@enduml';
  body=body.replace(/^@startuml[^\n]*/i,match=>match+'\n'+skin.join('\n'));
  const c4=[...['person','container','container_db','system','component'].map(x=>
    `UpdateElementStyle("${x}", $bgColor="${p.node}", $fontColor="${p.ink}", $borderColor="${p.rim}")`),
    `UpdateRelStyle($textColor="${p.soft}", $lineColor="${p.line}")`,
    `UpdateBoundaryStyle($bgColor="${p.group}", $fontColor="${p.soft}", $borderColor="${p.rim}")`];
  const lines=body.split('\n'); let last=-1;
  lines.forEach((line,i)=>{if(/^\s*!include\s+<C4\//i.test(line))last=i;});
  if(last>=0)lines.splice(last+1,0,...c4);
  return lines;
}
function sanitize(raw,p) {
  if(raw.length>4*1024*1024 || /Syntax Error\?|Fatal parsing error|From textarea \(line/i.test(raw))throw new Error('invalid');
  const clean=DOMPurify.sanitize(raw,{USE_PROFILES:{svg:true,svgFilters:true,html:true},
    FORBID_TAGS:['script','iframe','object','embed','image','img','audio','video','animate','animateTransform','set'],
    FORBID_ATTR:['src','srcset','target']});
  const doc=new DOMParser().parseFromString(clean,'image/svg+xml'), svg=doc.documentElement;
  if(svg.localName!=='svg'||doc.querySelector('parsererror'))throw new Error('svg');
  for(const node of [svg,...svg.querySelectorAll('*')]) {
    for(const attr of [...node.attributes]) {
      if(/^on/i.test(attr.name)||/href$/i.test(attr.name)&&!attr.value.startsWith('#'))node.removeAttribute(attr.name);
      if(/(?:https?:|file:|data:|javascript:|@import)/i.test(attr.value))node.removeAttribute(attr.name);
    }
    if(node.localName==='style')node.textContent=node.textContent.replace(/@import[^;]*;?/gi,'').replace(/url\(\s*['"]?(?!#)[^)]+\)/gi,'none');
  }
  // The mindmap root needs its own mapping; generic theme variables do not
  // establish root-label contrast in the pinned Mermaid engine.
  if(svg.querySelector('.section-root')) {
    const style=doc.createElementNS('http://www.w3.org/2000/svg','style');
    style.textContent=`.section-root :is(rect,path,circle,polygon){fill:${p.node};stroke:${p.rim}}.section-root text{fill:${p.ink}}.section-root span{color:${p.ink}}`;
    svg.append(style);
  }
  return document.importNode(svg,true);
}
function svgMarkup(svg) {
  const clone=svg.cloneNode(true);
  clone.setAttribute('xmlns','http://www.w3.org/2000/svg');
  return new XMLSerializer().serializeToString(clone);
}
async function rasterize(svg,w,h) {
  // Canvas gives both platforms a transparent inline bitmap without private
  // WebKit background controls. The PDF remains the vector source on macOS.
  const scale=Math.min(2,Math.sqrt(4_000_000/(w*h)));
  const canvas=document.createElement('canvas');
  canvas.width=Math.max(1,Math.ceil(w*scale)); canvas.height=Math.max(1,Math.ceil(h*scale));
  const ctx=canvas.getContext('2d');
  if(!ctx)throw new Error('canvas');
  const image=await new Promise((resolve,reject)=>{
    const node=new Image();
    node.onload=()=>resolve(node); node.onerror=()=>reject(new Error('raster'));
    node.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svgMarkup(svg));
  });
  ctx.drawImage(image,0,0,canvas.width,canvas.height);
  return canvas.toDataURL('image/png').split(',')[1];
}
window.renderDiagram = async function(kind,source,dark) {
  if(source.length>20000)throw new Error('size');
  const p=palette(dark);let raw;
  if(kind==='mermaid') {
    const engine=await (mermaidReady??=import('./mermaid/mermaid.esm.min.mjs').then(m=>m.default));
    // Strip all render-only config, including nested per-type theme/look.
    const input=source.replace(/^\s*---\r?\n[\s\S]*?\r?\n---\s*\r?\n/,'').replace(/%%\{[\s\S]*?\}%%/g,'');
    engine.initialize(config(p,dark));
    if(!await engine.parse(input,{suppressErrors:true}))throw new Error('invalid');
    raw=(await engine.render('corralDrawing',input)).svg;
  } else {
    const lines=plantInput(source,p);
    const engine=await (plantReady??=loadScript('./plantuml/viz-global.js')
      .then(()=>{window.PLANTUML_STDLIB_BASE=new URL('./stdlib/',location.href).href;return import('./plantuml/plantuml.js');}));
    raw=await new Promise((resolve,reject)=>engine.renderToString(lines,resolve,()=>reject(new Error('invalid'))));
  }
  const svg=sanitize(raw,p),out=document.getElementById('out');out.replaceChildren(svg);
  const box=svg.viewBox.baseVal;
  const w=box?.width||parseFloat(svg.getAttribute('width')),h=box?.height||parseFloat(svg.getAttribute('height'));
  if(!Number.isFinite(w)||!Number.isFinite(h)||w<=0||h<=0||w>16000||h>16000)throw new Error('geometry');
  svg.style.width=w+'px';svg.style.height=h+'px';
  await document.fonts.ready;
  const rect=svg.getBoundingClientRect();
  const png=await rasterize(svg,w,h);
  return {width:rect.width,height:rect.height,png};
};
