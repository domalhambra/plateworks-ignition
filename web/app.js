"use strict";
//====================== Plateworks Ignition — UI layer ======================
// State, rendering, and event wiring. All calculation lives in engine.js (the
// web twin of PlateworksCore, conformance-tested against the Swift core in CI);
// classic scripts share the global lexical scope, so everything engine.js
// declares is directly visible here.

function sevVar(b){ return `var(--sv${b})`; }
// selectable trend metrics (pct pins 0-100; others auto-fit)
const METRICS=[
  {k:"pigU",label:"PIG (unsh)",pct:true,f:o=>o.pigU},
  {k:"pigS",label:"PIG (shd)",pct:true,f:o=>o.pigS},
  {k:"temp",label:"Temp",pct:false,f:o=>o.temp},
  {k:"rh",label:"RH",pct:true,f:o=>o.rh},
  {k:"ffmU",label:"FFM",pct:false,f:o=>o.ffmU}
];

// Estimate plumbing against live screen state
function effectiveRH(){ return S.rhSource==="direct"?S.relativeHumidity:psychro(S.dryBulbF,S.wetBulbF,bandByNum(S.band).p).rh; }
// simple sensitivity edge: perturb dry bulb ±2 and RH/wet-bulb ±3 — does the band change?
function edge(shaded){
  const base=estimate(coreInputs())[shaded?"shaded":"unshaded"];
  let hi=base.pig, lo=base.pig;
  for(const dt of [-2,2]) for(const dw of [-3,3]){
    const dry=S.dryBulbF+dt; let rh;
    if(S.rhSource==="direct"){ rh=Math.min(100,Math.max(0,S.relativeHumidity+dw)); }
    else { const wet=Math.min(S.wetBulbF+dw,dry); rh=psychro(dry,wet,bandByNum(S.band).p).rh; }
    const e=estimate({dryBulbF:dry,rh,month:S.month,timeBand:S.timeBand,aspect:S.aspect,slope:S.slope,elevationDelta:S.elevationDelta})[shaded?"shaded":"unshaded"];
    hi=Math.max(hi,e.pig); lo=Math.min(lo,e.pig);
  }
  if(behavior(hi)!==base.b) return {dir:"↗",pig:hi};
  if(behavior(lo)!==base.b) return {dir:"↘",pig:lo};
  return null;
}
function coreInputs(){ return {dryBulbF:S.dryBulbF,rh:effectiveRH(),month:S.month,timeBand:S.timeBand,aspect:S.aspect,slope:S.slope,elevationDelta:S.elevationDelta}; }

//====================== State ======================
const now=new Date();
const S={
  tab:"ignition",
  dryBulbF:95, rhSource:"direct", relativeHumidity:12, wetBulbF:70, band:4,
  wind:{low:3,high:6,dir:"SW",gust:0},
  month:now.getMonth()+1, timeBand:timeBandFromClock(now.getHours(),now.getMinutes()), clockOverridden:false,
  aspect:"S", slope:"steep", elevationDelta:"level",
  // Alaska elevation thresholds — a labelling choice for the band chips, never
  // a change to the psychrometrics (which take the band directly).
  alaska:false,
  // watch
  obs:[], addressee:"", locationName:"", division:"", siteElevationFeet:null, coordLat:"", coordLon:"",
  siteConfirmed:false, lastRemoved:null, undo:false, editing:null, edit:null,
  history:[], shiftDateMs:0,
  // The observation form: null (closed), "capture", "edit", or "logged" (the
  // post-log broadcast screen). One sheet, two modes — the twin of ObsFormSheet.
  sheet:null, loggedId:null,
  pendingMin:now.getHours()*60+now.getMinutes(), note:"", trendMetric:"pigU"
};
let obsSeq=1;

// ---- persistence: keep the shift across reloads / app restarts. Guarded so a
// private window or blocked storage just no-ops. Forward-compatible: restored
// fields override defaults, new fields keep theirs (Object.assign). ----
// NOT brand copy — do not rename to "plateworks.*". This key holds every saved
// observation; changing it orphans a firefighter's logged data on next open.
const LS_KEY="badwater.obs.v1";
// Latched on the first failed write and never reset — the twin of the native
// app's `persistenceFailed`. The in-memory log is intact and exportable; what
// must not happen is the record quietly failing to survive a reload with
// nothing on screen saying so.
let persistenceFailed=false;
function saveState(){ try{ localStorage.setItem(LS_KEY, JSON.stringify({S:S,obsSeq:obsSeq})); }catch(e){
  if(!persistenceFailed){ persistenceFailed=true; try{ toast("Couldn't save on this device — export before you close the app"); }catch(_){} }
} }
function loadState(){ try{
  const raw=localStorage.getItem(LS_KEY); if(!raw)return;
  const d=JSON.parse(raw);
  // A parseable blob with a mangled shape (schema bug, hand edit, a future
  // version writing through an old cached app) used to crash render() at
  // startup and leave the screen permanently blank. Refuse the restore but
  // keep the bytes under a side key, so nothing is silently destroyed.
  if(d&&d.S&&(("obs" in d.S&&!Array.isArray(d.S.obs))||("history" in d.S&&!Array.isArray(d.S.history)))){
    try{ localStorage.setItem(LS_KEY+".corrupt", raw); }catch(_){}
    return;
  }
  if(d&&d.S){ Object.assign(S,d.S); S.editing=null; S.edit=null;
    // Never restore an open sheet: it would reopen over the record on launch,
    // and a half-entered capture is not a reading anyone should inherit.
    S.sheet=null; S.loggedId=null;
    // The Humidity tab's scratch state and its stored tab selection are gone.
    // Alaska was the one setting worth keeping — it is regional, and a crew
    // that had it on should not have to rediscover it mid-shift.
    if(typeof S.alaska!=="boolean"&&typeof d.S.hAlaska==="boolean")S.alaska=d.S.hAlaska;
    delete S.hDry; delete S.hWet; delete S.hBand; delete S.hAlaska;
    if(S.tab!=="ignition"&&S.tab!=="watch")S.tab="ignition";
    if(typeof d.obsSeq==="number"&&d.obsSeq>obsSeq)obsSeq=d.obsSeq; }
}catch(e){} }
loadState();
if(!S.shiftDateMs)S.shiftDateMs=now.getTime();

// Re-derive month + time band from the wall clock unless the operator has
// overridden them — the twin of IgnitionModel.refreshClock(). Without this, a
// restored session (or a tab left open across a band boundary) kept computing
// the LIVE estimate from a stale band and month while the status strip claimed
// "Tracking clock". Logged obs were never affected (they derive their own band
// from the obs time); this is about the headline live surface.
function refreshClock(){
  if(S.clockOverridden)return false;
  const d=new Date();
  const m=d.getMonth()+1, tb=timeBandFromClock(d.getHours(),d.getMinutes());
  if(m===S.month&&tb===S.timeBand)return false;
  S.month=m; S.timeBand=tb; return true;
}
refreshClock();

// ---- retained shift history (each shift = one day; the crew starts a new one
// daily). A shift snapshot is {obs, division, locationName, dateMs}. ----
function allShifts(){ return S.history.concat([{obs:S.obs,division:S.division,locationName:S.locationName,dateMs:S.shiftDateMs}]); }
function dayShort(ms){ try{ return new Date(ms).toLocaleDateString(undefined,{month:"short",day:"numeric"}); }catch(e){ const d=new Date(ms); return (d.getMonth()+1)+"/"+d.getDate(); } }
function retainedDayCount(){ const s=new Set(); allShifts().forEach(sh=>{ if(sh.obs.length)s.add(new Date(sh.dateMs).toDateString()); }); return s.size; }

//====================== Helpers ======================
const scr=()=>document.getElementById("screen");
function stepField(f,d,min,max){ S[f]=Math.min(max,Math.max(min,S[f]+d)); if(f==="wetBulbF"&&S.wetBulbF>S.dryBulbF)S.wetBulbF=S.dryBulbF; if(f==="dryBulbF"&&S.wetBulbF>S.dryBulbF)S.wetBulbF=S.dryBulbF; render(); }
function clockLabel(min){ const h=Math.floor(min/60)%24,m=min%60; return String(h).padStart(2,"0")+":"+String(m).padStart(2,"0"); }
function esc(s){ return (s||"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
function chip(field,val,label,cur){ return `<button class="chip ${cur===val?"on":""}" data-action="set" data-field="${field}" data-val="${val}">${label}</button>`; }
function stepper(field,label,unit,val,min,max,step,cls){
  step=step||1;
  return `<div class="stepper ${cls||""}"><div class="lbl">${label}</div>
    <div class="val"><span class="num">${val}</span><span class="un">${unit}</span></div>
    <div class="pm"><button data-action="step" data-field="${field}" data-d="${-step}" data-min="${min}" data-max="${max}">−</button>
    <button data-action="step" data-field="${field}" data-d="${step}" data-min="${min}" data-max="${max}">+</button></div></div>`;
}

//====================== Shared weather group (Ignition + Watch) ======================
function weatherGroup(sharedWith,showDerived){
  const src=S.rhSource;
  let secondStepper = src==="direct"
    ? stepper("relativeHumidity","Rel. humidity","%",S.relativeHumidity,0,100,1,"sunkbg")
    : stepper("wetBulbF","Wet bulb","°F",S.wetBulbF,10,130,1,"sunkbg");
  let wetExtras="";
  if(src==="wetBulb"){
    const b=bandByNum(S.band);
    wetExtras=`<div class="chiprow"><div class="lbl">Elevation band · ${b.p} inHg</div>
      <div class="chips">${BANDS.map(x=>chip("band",x.n,bandLabel(x,S.alaska),S.band)).join("")}</div></div>`;
    if(showDerived){
      // Everything the sling reading yields, read off where it was entered —
      // this is the Humidity tab, absorbed. RH stays primary: it is the value
      // that flows into the PIG chain.
      const r=psychro(S.dryBulbF,S.wetBulbF,b.p);
      wetExtras+=`<div class="chiprow"><label class="aktoggle"><input type="checkbox" data-action="toggleAlaska" ${S.alaska?"checked":""}> Alaska elevation thresholds</label></div>`;
      wetExtras+=`<div class="derived"><div><div class="lbl">Rel. humidity</div><div class="lbl" style="text-transform:none">computed from wet bulb</div></div><div class="big">${r.rh}%</div></div>`;
      wetExtras+=`<div class="row">
        <div class="statcard"><div class="lbl">Dew point</div><div class="val"><span class="num">${r.dew}</span><span class="un">°F</span></div></div>
        <div class="statcard"><div class="lbl">WB depression</div><div class="val"><span class="num">${r.dep}</span><span class="un">°F</span></div></div>
      </div>`;
      wetExtras+=`<div class="disc" style="text-align:left">Psychrometric estimate — verify against your belt weather kit tables.</div>`;
    }
  }
  const wind=S.wind; let windExtra="";
  if(wind.high>0){
    windExtra=stepper("windGust","Gust","mph",wind.gust,0,80,1,"sunkbg")
      +`<div class="chiprow"><div class="lbl">Wind from</div><div class="chips">${DIRS.map(d=>chip("windDir",d,d,wind.dir)).join("")}</div></div>`;
  }
  const windRow = `<div class="row">${stepper("windLow","Wind low","mph",wind.low,0,60,1,"sunkbg")}${stepper("windHigh","Wind high","mph",wind.high,0,60,1,"sunkbg")}</div>`;
  return `<div class="group">
    <div class="sect"><span class="st">Weather · IRPG Table A</span><span class="shared">🔗 SHARED · ${sharedWith}</span></div>
    <div class="box group">
      <div class="chiprow"><div class="lbl">Humidity source</div><div class="chips">${chip("rhSource","direct","Direct",src)}${chip("rhSource","wetBulb","From wet bulb",src)}</div></div>
      <div class="row">${stepper("dryBulbF","Dry bulb","°F",S.dryBulbF,10,130,1,"sunkbg")}${secondStepper}</div>
      ${wetExtras}
      ${windRow}
      ${windExtra}
    </div></div>`;
}

//====================== IGNITION tab ======================
function renderIgnition(){
  const e=estimate(coreInputs()); const bu=e.unshaded.b, bs=e.shaded.b;
  const behU=BEHAV[bu]; const rhEff=effectiveRH(); const spot=windSpot(S.wind);
  const g=monthGroup(S.month);
  const clockStrip = S.clockOverridden
    ? `<div class="strip caution"><span>↻</span><span>Month/time set manually — tap to resume clock</span><button data-action="resumeClock">Resume</button></div>`
    : `<div class="strip"><span>◷</span><span>Tracking clock · ${MONTHS[S.month-1]} · ${S.timeBand==="night"?"Night":TIMEBANDS[S.timeBand]}</span></div>`;
  const eU=edge(false), eS=edge(true);
  const bar=`<div class="pigbar">
    <div class="wxrow">
      <div class="wxnode"><span class="k">TEMP</span><span class="v">${S.dryBulbF}<small>°F</small></span></div>
      <div class="wxnode"><span class="k">RH</span><span class="v">${rhEff}<small>%</small></span></div>
      <div class="wxnode"><span class="k">WIND</span><span class="v">${esc(spot)}</span></div>
    </div>
    <div class="pigrow">
      <div class="pnode"><div class="rl"><span class="k">UNSH</span><span class="v" style="color:${sevVar(bu)}">${e.unshaded.pig}<small>%</small></span></div><div class="ubar" style="background:${sevVar(bu)}"></div></div>
      <div class="pnode"><div class="rl"><span class="k">SHD</span><span class="v" style="color:${sevVar(bs)}">${e.shaded.pig}<small>%</small></span></div><div class="ubar" style="background:${sevVar(bs)}"></div></div>
      <div class="beh" style="color:${sevVar(bu)}">${behU.t.toUpperCase()}</div>
    </div></div>`;
  const body=`<div class="pad">
    <div class="titlerow"><span class="title">Ignition</span><span class="lbl">IRPG p.44–49</span></div>
    ${weatherGroup("OBS",true)}
    <div class="group">
      <div class="sect"><span class="st">Calendar · Time · Tables B/C/D</span></div>
      <div class="chiprow"><div class="lbl">Month · ${g} (${groupMonths(g)})</div><div class="chips">${MONTHS.map((m,i)=>chip("month",i+1,m,S.month)).join("")}</div></div>
      <div class="chiprow"><div class="lbl">Time of day</div><div class="chips">${TIMEBANDS.map((t,i)=>chip("timeBand",i,t,S.timeBand)).join("")}${chip("timeBand","night","Night",S.timeBand)}</div></div>
      ${clockStrip}
    </div>
    <div class="group">
      <div class="sect"><span class="st">Site · Corrections</span></div>
      <div class="row">
        <div class="chiprow"><div class="lbl">Aspect</div><div class="chips">${ASPECTS.map(a=>chip("aspect",a,a,S.aspect)).join("")}</div></div>
        <div class="chiprow"><div class="lbl">Slope</div><div class="chips">${chip("slope","gentle","0–30%",S.slope)}${chip("slope","steep","31%+",S.slope)}</div></div>
      </div>
      <div class="chiprow"><div class="lbl">Elevation vs. weather site</div><div class="chips">${chip("elevationDelta","below","Below",S.elevationDelta)}${chip("elevationDelta","level","Level",S.elevationDelta)}${chip("elevationDelta","above","Above",S.elevationDelta)}</div></div>
    </div>
    <div class="group">
      <div class="chain">
        <div class="node"><div class="cl">REF FM</div><div class="cv">${e.rf}</div></div><div class="ar">→</div>
        <div class="node"><div class="cl">CORR</div><div class="cv">${e.night?"night +5":e.unshaded.corr+"/"+e.shaded.corr}</div></div><div class="ar">→</div>
        <div class="node"><div class="cl">FFM</div><div class="cv">${e.unshaded.ffm}/${e.shaded.ffm}%</div></div>
      </div>
      <div class="results">
        <div class="result"><div class="stp" style="background:${sevVar(bu)}"></div><div class="rk">Unshaded</div><div class="rv"><span class="n" style="color:${sevVar(bu)}">${e.unshaded.pig}</span><span class="p" style="color:${sevVar(bu)}">%</span></div><div class="sub">FFM ${e.unshaded.ffm}% · &lt;50% shade</div><div class="edge">${eU?`${eU.dir} near edge — could read ${eU.pig}%`:"&nbsp;"}</div></div>
        <div class="result"><div class="stp" style="background:${sevVar(bs)}"></div><div class="rk">Shaded</div><div class="rv"><span class="n" style="color:${sevVar(bs)}">${e.shaded.pig}</span><span class="p" style="color:${sevVar(bs)}">%</span></div><div class="sub">FFM ${e.shaded.ffm}% · ≥50% shade</div><div class="edge">${eS?`${eS.dir} near edge — could read ${eS.pig}%`:"&nbsp;"}</div></div>
      </div>
      <div class="interp">
        <div class="top"><span class="dot" style="background:${sevVar(bu)}"></span><span class="ti">${behU.t}</span><span class="rg">${behU.r}</span></div>
        <div class="de">${behU.d}</div>
        <div class="ca">${CAUTION}  IRPG p.49</div>
      </div>
      <div class="disc">Decision support only — verify against your IRPG.</div>
    </div>
  </div>`;
  // The same start bar the Obs tab pins, so the capture flow can be entered
  // from either tab. Unlike the Obs copy it stays tappable while gated: the
  // tap carries the operator to the Obs tab, where Confirm site lives.
  const startbar=`<div class="logbar"><button class="btn primary" data-action="goCapture">${S.siteConfirmed?"Start an Observation":"Confirm site to start"}</button></div>`;
  return bar+body+startbar;
}

//====================== WATCH tab ======================
// The month a log freezes comes from the shift's own date, NOT the month chips
// on the Ignition tab. Those chips are a what-if surface — an operator
// forecasting a late-season burn leaves them somewhere else entirely — and the
// native twin has always derived the logged month from the observation's
// timestamp (WeatherWatchModel.pendingObs). The web side used to freeze S.month,
// so a manual override travelled straight into the record and the broadcast.
function monthForLog(){ return new Date(S.shiftDateMs||Date.now()).getMonth()+1; }

function pendingEstimate(){
  const tb=timeBandFromClock(Math.floor(S.pendingMin/60),S.pendingMin%60);
  return estimate({dryBulbF:S.dryBulbF,rh:effectiveRH(),month:monthForLog(),timeBand:tb,aspect:S.aspect,slope:S.slope,elevationDelta:S.elevationDelta});
}

// Everything a Log tap is about to freeze, in one line — built from the same
// inputs logObs() uses, so it cannot describe a different reading. It exists
// because the site factors are shared with the Ignition tab: an aspect scouted
// mid-shift and never set back is what the next obs would freeze and broadcast.
const SLOPE_LABEL={gentle:"0–30%",steep:"31%+"};
const DELTA_LABEL={below:"Below",level:"Level",above:"Above"};
function freezeReceipt(){
  const tb=timeBandFromClock(Math.floor(S.pendingMin/60),S.pendingMin%60);
  const parts=[S.dryBulbF+"°F", effectiveRH()+"% "+(S.rhSource==="wetBulb"?"sling":"direct")];
  if(S.wind.high>0||S.wind.gust>0)parts.push(windSpot(S.wind));
  parts.push(MONTHS[monthForLog()-1]);
  parts.push(clockLabel(S.pendingMin)+" → "+(tb==="night"?"Night":TIMEBANDS[tb]));
  parts.push(S.aspect, SLOPE_LABEL[S.slope], DELTA_LABEL[S.elevationDelta]+" elev");
  return parts.join(" · ");
}
function nowMin(){ const d=new Date(); return d.getHours()*60+d.getMinutes(); }
function obsDueHtml(){
  const cadence=60, now=nowMin();
  const last=S.obs.length?Math.max(...S.obs.map(o=>o.min)):null;
  let icon,msg,caution;
  if(last==null){ icon="◷"; caution=false; msg="First obs of the shift — take one now"; }
  else {
    const due=(last+cadence)%1440;
    // Minutes-of-day wrap at midnight: a 23:50 obs is due at 00:50, and the
    // plain difference read that as "in 1460 min" for a night shift — the
    // overdue branch was unreachable until the next evening. Take the circular
    // distance and read the shorter way around: within 12h ahead it's a
    // countdown, otherwise it's overdue.
    let mins=(due-now+1440)%1440;
    if(mins>720)mins-=1440;
    if(mins<=5){ caution=true; icon="⏰"; msg=mins>=0?`Obs due now · ${clockLabel(due)}`:`Obs overdue ${-mins} min · was due ${clockLabel(due)}`; }
    else { caution=false; icon="◷"; msg=`Next obs ${clockLabel(due)} · in ${mins} min`; } }
  return `<div class="strip ${caution?'caution':''}"><span>${icon}</span><span>${msg}</span></div>`;
}
// Trend overlay — one line per retained day (history + current) on a shared
// time-of-day axis; most recent day solid teal + dotted, earlier days faded/dashed.
function trendSectionHtml(){
  const total=allShifts().reduce((n,sh)=>n+sh.obs.length,0);
  if(total<2)return "";
  const M=METRICS.find(m=>m.k===S.trendMetric)||METRICS[0];
  const chips=METRICS.map(m=>`<button class="chip ${m.k===S.trendMetric?'on':''}" data-action="setTrend" data-k="${m.k}">${m.label}</button>`).join("");
  const dayser=allShifts().map(sh=>({dateMs:sh.dateMs,
      pts:sh.obs.slice().sort((a,b)=>a.min-b.min).map(o=>({min:o.min,v:M.f(o)})).filter(p=>p.v!=null&&!isNaN(p.v))}))
    .filter(d=>d.pts.length).sort((a,b)=>a.dateMs-b.dateMs);
  const allv=dayser.flatMap(d=>d.pts.map(p=>p.v));
  const allmin=dayser.flatMap(d=>d.pts.map(p=>p.min));
  let svg, annotation=M.label;
  if(allv.length>=2){
    let lo=M.pct?0:Math.min(...allv)-5, hi=M.pct?100:Math.max(...allv)+5; if(hi<=lo)hi=lo+1;
    let xlo=Math.min(...allmin), xhi=Math.max(...allmin); if(xhi<=xlo)xhi=xlo+60;
    const W=280,H=92,pad=8;
    const X=m=>pad+(W-2*pad)*((m-xlo)/(xhi-xlo));
    const Y=v=>pad+(H-2*pad)*(1-(v-lo)/(hi-lo));
    const latestMs=Math.max(...dayser.map(d=>d.dateMs));
    const n=Math.max(dayser.length-1,1);
    const paths=dayser.map((d,i)=>{
      const isLatest=d.dateMs===latestMs;
      const line=d.pts.map(p=>`${X(p.min).toFixed(1)},${Y(p.v).toFixed(1)}`).join(" ");
      const op=isLatest?1:(0.3+0.4*(i/n));
      const dash=isLatest?"":' stroke-dasharray="4 3"';
      const dots=isLatest?d.pts.map(p=>`<circle cx="${X(p.min).toFixed(1)}" cy="${Y(p.v).toFixed(1)}" r="3" fill="var(--teal)"/>`).join(""):"";
      return `<polyline points="${line}" fill="none" stroke="${isLatest?'var(--teal)':'var(--muted)'}" stroke-opacity="${op.toFixed(2)}" stroke-width="${isLatest?2.5:1.5}" stroke-linejoin="round" stroke-linecap="round"${dash}/>${dots}`;
    }).join("");
    svg=`<div class="spark"><svg viewBox="0 0 ${W} ${H}" width="100%" height="${H}" preserveAspectRatio="none">${paths}</svg></div>`;
    if(dayser.length>1){
      annotation=`${M.label} · ${dayser.length} days`;
      const leg=dayser.slice().sort((a,b)=>b.dateMs-a.dateMs).map(d=>{
        const isLatest=d.dateMs===latestMs;
        return `<span style="display:inline-flex;align-items:center;gap:4px;margin-right:10px;font-family:var(--mono);font-size:9px;color:var(--muted)"><span style="width:12px;height:2px;display:inline-block;background:${isLatest?'var(--teal)':'var(--muted)'};opacity:${isLatest?1:.6}"></span>${dayShort(d.dateMs)}</span>`;
      }).join("");
      svg+=`<div style="margin-top:6px;display:flex;flex-wrap:wrap">${leg}</div>`;
    }
  } else { svg=`<div class="lbl" style="padding:8px 2px">Not enough obs record this metric yet.</div>`; }
  return `<div class="group"><div class="sect"><span class="st">Trend · ${annotation}</span></div><div class="chips" style="margin-bottom:2px">${chips}</div>${svg}</div>`;
}

function renderWatch(){
  const obs=S.obs.slice().sort((a,b)=>b.min-a.min);
  const latest=obs[0];
  const pend=pendingEstimate();
  const gated=!S.siteConfirmed;

  let heroHtml,broadcastHtml="";
  if(latest){
    heroHtml=`<div class="hero">
      <div class="htop"><span class="htime">${hhmm(latest.min)}</span><span class="lbl">Latest</span></div>
      <div class="results">
        <div class="result" style="border-radius:14px"><div class="stp" style="background:${sevVar(latest.bu)}"></div><div class="rk">Unshaded</div><div class="rv"><span class="n" style="font-size:30px;color:${sevVar(latest.bu)}">${latest.pigU}</span><span class="p" style="color:${sevVar(latest.bu)}">%</span></div></div>
        <div class="result" style="border-radius:14px"><div class="stp" style="background:${sevVar(latest.bs)}"></div><div class="rk">Shaded</div><div class="rv"><span class="n" style="font-size:30px;color:${sevVar(latest.bs)}">${latest.pigS}</span><span class="p" style="color:${sevVar(latest.bs)}">%</span></div></div>
      </div>
      <div class="radio">Wx obs ${hhmm(latest.min)}, temp ${latest.temp}, RH ${latest.rh}, PIG ${latest.pigU} unshaded, ${latest.pigS} shaded</div>
    </div>`;
    broadcastHtml=`<div class="group"><div class="sect"><span class="st">Broadcast · Radio</span></div>
      <div class="broadcast" style="position:relative;padding-top:22px">${esc(latest.broadcast)}<button class="copypill" data-action="copy" data-kind="broadcast">Copy</button></div></div>`;
  } else {
    heroHtml=`<div class="empty"><div class="t">No observations yet</div><div class="lbl">Confirm the site, then Start an Observation</div></div>`;
  }

  // The undo strip lives OUTSIDE the shift-log group: deleting the only obs of
  // the shift used to remove the log section and the undo affordance with it —
  // exactly when the deletion is most likely to be the mis-tap.
  const undoHtml=S.undo&&S.lastRemoved?`<div class="strip caution"><span>↺</span><span>Observation removed</span><button data-action="undo">Undo</button></div>`:"";
  let logHtml="";
  if(obs.length){
    logHtml=`<div class="group"><div class="sect"><span class="st">Shift log · ${obs.length} obs</span></div>
      ${obs.map(o=>`<div class="logrow"><span class="lt">${hhmm(o.min)}</span>
        <div><div class="lp">PIG ${o.pigU}/${o.pigS}</div><div class="lw">${esc(windSpot(o.wind))}${o.note?" · "+esc(o.note):""}</div></div>
        <button class="edt" data-action="editObs" data-id="${o.id}">✎</button>
        <button class="del" data-action="deleteObs" data-id="${o.id}">🗑</button></div>`).join("")}</div>`;
  }

  // The IRPG corrections every logged obs freezes. They live on the shared
  // state the Ignition tab edits, and until now this screen never showed them —
  // while the gate below asked the operator to "review the site factors".
  const siteFactorsHtml=`<div class="group">
    <div class="sect"><span class="st">Site factors · Corrections</span><span class="shared">🔗 SHARED · IGNITION</span></div>
    <div class="row">
      <div class="chiprow"><div class="lbl">Aspect</div><div class="chips">${ASPECTS.map(a=>chip("aspect",a,a,S.aspect)).join("")}</div></div>
      <div class="chiprow"><div class="lbl">Slope</div><div class="chips">${chip("slope","gentle","0–30%",S.slope)}${chip("slope","steep","31%+",S.slope)}</div></div>
    </div>
    <div class="chiprow"><div class="lbl">Elevation vs. weather site</div><div class="chips">${chip("elevationDelta","below","Below",S.elevationDelta)}${chip("elevationDelta","level","Level",S.elevationDelta)}${chip("elevationDelta","above","Above",S.elevationDelta)}</div></div>
  </div>`;

  const siteHtml=`<div class="group"><div class="sect"><span class="st">Site &amp; radio · IMET header</span></div>
    ${gated
      ?`<div class="strip caution"><span>🛡</span><span>Review the site factors, then confirm</span><button data-action="confirmSite">Confirm site</button></div>`
      :`<div class="strip good"><span>🛡</span><span>Site confirmed for this shift</span></div>`}
    <div class="field"><div class="lbl">Radio addressee</div><input data-field="addressee" value="${esc(S.addressee)}" placeholder="e.g. Division W"></div>
    <div class="field"><div class="lbl">Location name</div><input data-field="locationName" value="${esc(S.locationName)}" placeholder="e.g. 659 Road"></div>
    <div class="row">
      <div class="field"><div class="lbl">Division</div><input data-field="division" value="${esc(S.division)}" placeholder="Division W"></div>
      <div class="field"><div class="lbl">Site elevation (ft)</div><input data-field="siteElevationFeet" inputmode="numeric" value="${S.siteElevationFeet??""}" placeholder="4150"></div>
    </div>
    <div class="row">
      <div class="field"><div class="lbl">Latitude</div><input data-field="coordLat" inputmode="decimal" value="${esc(S.coordLat)}" placeholder="38.214"></div>
      <div class="field"><div class="lbl">Longitude</div><input data-field="coordLon" inputmode="decimal" value="${esc(S.coordLon)}" placeholder="-112.398"></div>
    </div></div>`;

  const hasData = obs.length || S.history.length;
  const days = retainedDayCount();
  const exportHtml = hasData?`<div class="group"><div class="sect"><span class="st">Export · ${days>1?days+" days":"Spreadsheet + notes"}</span></div>
    <button class="btn ghost" data-action="exportXlsx">▦ IMET .xlsx</button>
    <div class="btnrow"><button class="btn ghost" data-action="copy" data-kind="notes">Notes table</button></div></div>`:"";

  let historyHtml="";
  if(S.history.length){
    const reminder = days>3?`<div class="strip caution"><span>🗂</span><span>${days} days of observations retained — export the spreadsheet, then clear the days you don't need.</span></div>`:"";
    const rows=S.history.map((sh,i)=>`<div class="logrow"><span class="lt" style="font-size:13px">${dayShort(sh.dateMs)}</span>
      <div><div class="lp">${sh.obs.length} obs</div><div class="lw">${esc(sh.division||sh.locationName||"")}</div></div>
      <button class="del" data-action="deleteDay" data-i="${i}">🗑</button></div>`).join("");
    historyHtml=`<div class="group"><div class="sect"><span class="st">History · ${S.history.length} day${S.history.length===1?"":"s"}</span></div>
      ${reminder}${rows}
      <button class="btn ghost" data-action="clearHistory">Clear all history</button></div>`;
  }
  const newShiftHtml = obs.length?`<div class="group"><button class="btn ghost" data-action="newShift">Start new shift</button></div>`:"";

  const persistHtml=persistenceFailed?`<div class="strip caution"><span>⚠</span><span>Couldn't save the log on this device — export the spreadsheet before you close the app.</span></div>`:"";
  const body=`<div class="pad">
    <div class="titlerow"><span class="title">Obs</span><span class="lbl">${obs.length?obs.length+" obs this shift":"IRPG PMS 461"}</span></div>
    ${persistHtml}${obsDueHtml()}
    ${undoHtml}${heroHtml}${broadcastHtml}${trendSectionHtml()}${logHtml}${siteFactorsHtml}${siteHtml}${exportHtml}${historyHtml}${newShiftHtml}
    <div class="disc">PIG is app-computed — not observed, not a forecast.</div>
  </div>`;
  const logbar=`<div class="logbar"><button class="btn primary" data-action="openCapture" ${gated?"disabled":""}>${gated?"Confirm site to start":"Start an Observation"}</button></div>`;
  return body+logbar+formSheetHtml(pend);
}

// The observation form — one sheet, two modes (the twin of ObsFormSheet), plus
// the post-log success state. Capture writes weather through to the shared
// state (it IS the live reading); edit keeps its own copy so a correction never
// moves the Ignition tab.
function formSheetHtml(pend){
  if(S.sheet==="logged"){
    const o=S.obs.find(x=>x.id===S.loggedId);
    if(!o){ return ""; }
    return `<div class="modalwrap"><div class="modal">
      <div class="strip good"><span>✓</span><span>Logged ${hhmm(o.min)} — read this over the net</span></div>
      <div class="broadcast" style="font-size:17px;line-height:1.5">${esc(o.broadcast)}</div>
      <div class="disc" style="text-align:left">PIG is app-computed — not observed, not a forecast.</div>
      <div class="btnrow"><button class="btn ghost" data-action="copy" data-kind="broadcast">Copy script</button><button class="btn primary" data-action="closeSheet">Done</button></div>
    </div></div>`;
  }
  if(S.sheet==="capture"){
    return `<div class="modalwrap"><div class="modal">
      <div class="titlerow"><span class="title" style="font-size:20px">New observation</span><span class="lbl" style="color:var(--teal)">→ PIG ${pend.unshaded.pig} / ${pend.shaded.pig}</span></div>
      <div class="field"><div class="lbl">Obs time (tap to type)</div>
        <div style="display:flex;gap:8px;align-items:center">
          <input data-field="obsTime" inputmode="numeric" value="${clockLabel(S.pendingMin)}" style="max-width:104px;font-family:var(--round);font-weight:700;font-size:22px;font-variant-numeric:tabular-nums;text-align:center;border:1px solid var(--hair);border-radius:10px;padding:8px;background:var(--surface);color:var(--ink)">
          <span style="flex:1"></span>
          <button class="obsnudge" data-action="obsNudge" data-d="-5">−5m</button>
          <button class="obsnudge" data-action="obsNudge" data-d="5">+5m</button>
        </div></div>
      ${weatherGroup("IGNITION",false)}
      <div class="field"><div class="lbl">Note (optional)</div><textarea data-field="note" rows="2" placeholder="e.g. sun on thermometer">${esc(S.note)}</textarea></div>
      <div class="receipt"><span class="lbl">Freezes</span> <span id="freeze-receipt">${esc(freezeReceipt())}</span></div>
      <div class="btnrow"><button class="btn ghost" data-action="closeSheet">Cancel</button><button class="btn primary" data-action="logObs">Log Observation · ${clockLabel(S.pendingMin)}</button></div>
    </div></div>`;
  }
  if(S.sheet==="edit"&&S.edit){
    const ed=S.edit;
    const windExtra = ed.wind.high>0
      ? stepper("editGust","Gust","mph",ed.wind.gust,0,80,1,"sunkbg")
        +`<div class="chiprow"><div class="lbl">Wind from</div><div class="chips">${DIRS.map(d=>chip("editDir",d,d,ed.wind.dir)).join("")}</div></div>`
      : "";
    return `<div class="modalwrap"><div class="modal">
      <div class="titlerow"><span class="title" style="font-size:20px">Edit observation</span></div>
      <div class="lbl" style="text-transform:none;letter-spacing:0;line-height:1.4">Correcting the ${hhmm(ed.origMin)} reading — recomputes PIG. Neighboring broadcasts are unchanged.</div>
      <div class="field"><div class="lbl">Obs time (tap to type)</div>
        <div style="display:flex;gap:8px;align-items:center">
          <input data-field="editTime" inputmode="numeric" value="${clockLabel(ed.min)}" style="max-width:104px;font-family:var(--round);font-weight:700;font-size:22px;font-variant-numeric:tabular-nums;text-align:center;border:1px solid var(--hair);border-radius:10px;padding:8px;background:var(--surface);color:var(--ink)">
          <span style="flex:1"></span>
          <button class="obsnudge" data-action="editNudge" data-d="-5">−5m</button>
          <button class="obsnudge" data-action="editNudge" data-d="5">+5m</button>
        </div></div>
      <div class="row">${stepper("editTemp","Dry bulb","°F",ed.temp,10,130,1,"sunkbg")}${stepper("editRh","Rel. humidity","%",ed.rh,0,100,1,"sunkbg")}</div>
      <div class="row">${stepper("editWindLow","Wind low","mph",ed.wind.low,0,60,1,"sunkbg")}${stepper("editWindHigh","Wind high","mph",ed.wind.high,0,60,1,"sunkbg")}</div>
      ${windExtra}
      <div class="field"><div class="lbl">Note (optional)</div><textarea data-field="editNote" rows="2" placeholder="e.g. sun on thermometer">${esc(ed.note)}</textarea></div>
      <div class="btnrow"><button class="btn ghost" data-action="editCancel">Cancel</button><button class="btn primary" data-action="editSave">Save</button></div>
    </div></div>`;
  }
  return "";
}

//====================== Broadcast + export text ======================
function renderBroadcast(cur,prev){ return broadcastScript(S.addressee,cur,prev); }
function spotText(){
  const rows=S.obs.slice().sort((a,b)=>a.min-b.min);
  const head=`NWS Spot Request — recent observations\nSite: ${[S.division,S.locationName].filter(Boolean).join(" ")||"—"}   Lat/Long: ${S.coordLat&&S.coordLon?S.coordLat+", "+S.coordLon:"—"}   Elev: ${S.siteElevationFeet??"—"}\n`;
  const body=rows.map(o=>`${hhmm(o.min)}  T ${o.temp}  RH ${o.rh}  Wind ${windSpot(o.wind)}  PIG ${o.pigU}/${o.pigS}`).join("\n");
  return head+"\n"+body;
}
function notesText(){
  const rows=S.obs.slice().sort((a,b)=>a.min-b.min);
  const head="Time\tTemp\tRH\tWind\tPIG(u/s)\tNote";
  // Flatten tabs/newlines out of the note — either tears the tab grid apart —
  // mirroring the native NotesExport.sanitizedNote.
  const flat=s=>(s||"").replace(/[\t\r\n]+/g," ").trim();
  const body=rows.map(o=>`${hhmm(o.min)}\t${o.temp}\t${o.rh}\t${windSpot(o.wind)}\t${o.pigU}/${o.pigS}\t${flat(o.note)}`).join("\n");
  return head+"\n"+body;
}

//====================== IMET .xlsx download ======================
function downloadXlsx(){
  try{
    const bytes=buildXlsx(allShifts(),S.coordLat,S.coordLon);
    const blob=new Blob([bytes],{type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"});
    const url=URL.createObjectURL(blob);
    const a=document.createElement("a"); a.href=url; a.download="PlateworksIgnition-observations.xlsx";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(()=>URL.revokeObjectURL(url),1500);
    toast("Downloaded PlateworksIgnition-observations.xlsx");
  }catch(e){ toast("Spreadsheet export failed — copy the Notes table instead"); }
}

//====================== Actions ======================
function logObs(){
  const tb=timeBandFromClock(Math.floor(S.pendingMin/60),S.pendingMin%60);
  const e=estimate({dryBulbF:S.dryBulbF,rh:effectiveRH(),month:monthForLog(),timeBand:tb,aspect:S.aspect,slope:S.slope,elevationDelta:S.elevationDelta});
  const prev=S.obs.slice().sort((a,b)=>a.min-b.min).filter(o=>o.min<S.pendingMin).pop()||null;
  const o={id:obsSeq++,min:S.pendingMin,temp:S.dryBulbF,rh:effectiveRH(),pigU:e.unshaded.pig,pigS:e.shaded.pig,ffmU:e.unshaded.ffm,ffmS:e.shaded.ffm,bu:e.unshaded.b,bs:e.shaded.b,
    wind:Object.assign({},S.wind),note:S.note.trim(),month:monthForLog(),elevationDelta:S.elevationDelta,elevationFeet:S.siteElevationFeet,aspect:S.aspect,slope:S.slope,spokenLocation:S.locationName.trim()};
  o.broadcast=renderBroadcast(o,prev);
  S.obs.push(o); S.note=""; S.undo=false;
  // Show the frozen script — the thing needed on the radio right now.
  S.sheet="logged"; S.loggedId=o.id;
  render();
}
// Correct a logged obs in place — recompute PIG against its OWN frozen month /
// elevation-delta / site factors, and re-render its broadcast against its
// chronological predecessor. Neighboring obs keep the script they broadcast.
function editSave(){
  const o=S.obs.find(x=>x.id===S.editing); const ed=S.edit;
  if(!o||!ed){ S.editing=null; S.edit=null; render(); return; }
  const tb=timeBandFromClock(Math.floor(ed.min/60),ed.min%60);
  const e=estimate({dryBulbF:ed.temp,rh:ed.rh,month:o.month??S.month,timeBand:tb,
    aspect:o.aspect,slope:o.slope,elevationDelta:o.elevationDelta??S.elevationDelta});
  o.min=ed.min; o.temp=ed.temp; o.rh=ed.rh; o.wind=Object.assign({},ed.wind); o.note=(ed.note||"").trim();
  o.pigU=e.unshaded.pig; o.pigS=e.shaded.pig; o.ffmU=e.unshaded.ffm; o.ffmS=e.shaded.ffm; o.bu=e.unshaded.b; o.bs=e.shaded.b;
  const prev=S.obs.slice().sort((a,b)=>a.min-b.min).filter(x=>x.min<o.min&&x.id!==o.id).pop()||null;
  o.broadcast=renderBroadcast(o,prev);
  S.editing=null; S.edit=null; S.sheet=null; render(); toast("Observation updated");
}
async function copyText(t){ try{ await navigator.clipboard.writeText(t); toast("Copied to clipboard"); }catch(e){ toast("Copy blocked — select & copy manually"); } }
function toast(msg,withUndo){
  const el=document.getElementById("toast");
  el.innerHTML=`<span>${esc(msg)}</span>`+(withUndo?`<button data-action="undo">Undo</button>`:"");
  el.style.display="flex"; clearTimeout(toast._t); toast._t=setTimeout(()=>{el.style.display="none";},2600);
}

//====================== Render + events ======================
function render(){
  document.querySelectorAll(".tab").forEach(t=>t.classList.toggle("on",t.dataset.val===S.tab));
  const s=scr(); const top=s.scrollTop;
  s.innerHTML = S.tab==="ignition"?renderIgnition():renderWatch();
  s.scrollTop=top;
  saveState();
}
document.addEventListener("click",ev=>{
  const b=ev.target.closest("[data-action]"); if(!b)return;
  const a=b.dataset.action;
  if(a==="tab"){ S.tab=b.dataset.val; scr().scrollTop=0; render(); }
  else if(a==="set"){ const f=b.dataset.field,v=b.dataset.val;
    if(f==="windDir"){ S.wind.dir=v; }
    else if(f==="editDir"){ if(S.edit)S.edit.wind.dir=v; }
    else if(f==="timeBand"){ S.timeBand = v==="night"?"night":parseInt(v,10); S.clockOverridden=true; }
    else if(f==="month"){ S.month=parseInt(v,10); S.clockOverridden=true; }
    else if(f==="band"||f==="hBand"){ S[f]=parseInt(v,10); }
    else { S[f]=v; }
    render();
  }
  else if(a==="step"){ const f=b.dataset.field,d=parseInt(b.dataset.d,10),mn=parseInt(b.dataset.min,10),mx=parseInt(b.dataset.max,10);
    if(f==="windLow"){ S.wind.low=Math.min(mx,Math.max(mn,S.wind.low+d)); if(S.wind.low>S.wind.high)S.wind.high=S.wind.low; }
    else if(f==="windHigh"){ S.wind.high=Math.min(mx,Math.max(mn,S.wind.high+d)); if(S.wind.high<S.wind.low)S.wind.low=S.wind.high; }
    else if(f==="windGust"){ S.wind.gust=Math.min(mx,Math.max(mn,S.wind.gust+d)); }
    else if(f==="editTemp"){ if(S.edit){ S.edit.temp=Math.min(mx,Math.max(mn,S.edit.temp+d)); } }
    else if(f==="editRh"){ if(S.edit){ S.edit.rh=Math.min(mx,Math.max(mn,S.edit.rh+d)); } }
    else if(f==="editWindLow"){ if(S.edit){ S.edit.wind.low=Math.min(mx,Math.max(mn,S.edit.wind.low+d)); if(S.edit.wind.low>S.edit.wind.high)S.edit.wind.high=S.edit.wind.low; } }
    else if(f==="editWindHigh"){ if(S.edit){ S.edit.wind.high=Math.min(mx,Math.max(mn,S.edit.wind.high+d)); if(S.edit.wind.high<S.edit.wind.low)S.edit.wind.low=S.edit.wind.high; } }
    else if(f==="editGust"){ if(S.edit){ S.edit.wind.gust=Math.min(mx,Math.max(mn,S.edit.wind.gust+d)); } }
    else if(f==="pendingHour"){ S.pendingMin=Math.min(23*60+ S.pendingMin%60, Math.max(0, S.pendingMin + d*60)); }
    else if(f==="pendingMinute"){ const h=Math.floor(S.pendingMin/60); let m=S.pendingMin%60+d; m=Math.min(55,Math.max(0,m)); S.pendingMin=h*60+m; }
    else { stepField(f,d,mn,mx); return; }
    render();
  }
  else if(a==="resumeClock"){ S.clockOverridden=false; const d=new Date(); S.month=d.getMonth()+1; S.timeBand=timeBandFromClock(d.getHours(),d.getMinutes()); render(); }
  else if(a==="toggleAlaska"){ S.alaska=!S.alaska; render(); }
  else if(a==="openCapture"){
    // Seed the obs time from the clock each time the form opens — a sheet is
    // short-lived, so there is no stale stamp to inherit.
    S.pendingMin=nowMin(); S.sheet="capture"; render();
  }
  else if(a==="goCapture"){
    // From the Ignition tab: land on Obs, then open the capture form past the
    // gate — a gated shift stops at the record, where Confirm site is. Mirrors
    // WatchView.consumeStartCapture on iOS.
    S.tab="watch"; scr().scrollTop=0;
    if(S.siteConfirmed){ S.pendingMin=nowMin(); S.sheet="capture"; }
    render();
  }
  else if(a==="closeSheet"){ S.sheet=null; S.loggedId=null; render(); }
  else if(a==="obsNudge"){ S.pendingMin=Math.min(1439,Math.max(0,S.pendingMin+parseInt(b.dataset.d,10))); render(); }
  else if(a==="setTrend"){ S.trendMetric=b.dataset.k; render(); }
  else if(a==="confirmSite"){ S.siteConfirmed=true; render(); }
  else if(a==="logObs"){ logObs(); }
  else if(a==="deleteObs"){ const id=parseInt(b.dataset.id,10); const i=S.obs.findIndex(o=>o.id===id); if(i>=0){ S.lastRemoved=S.obs[i]; S.obs.splice(i,1); S.undo=true; } render(); }
  else if(a==="editObs"){ const id=parseInt(b.dataset.id,10); const o=S.obs.find(x=>x.id===id);
    if(o){ S.editing=id; S.sheet="edit"; S.edit={origMin:o.min,min:o.min,temp:o.temp,rh:o.rh,wind:Object.assign({low:0,high:0,dir:"N",gust:0},o.wind),note:o.note||""}; } render(); }
  else if(a==="editCancel"){ S.editing=null; S.edit=null; S.sheet=null; render(); }
  else if(a==="editNudge"){ if(S.edit){ S.edit.min=Math.min(1439,Math.max(0,S.edit.min+parseInt(b.dataset.d,10))); } render(); }
  else if(a==="editSave"){ editSave(); }
  else if(a==="undo"){ if(S.lastRemoved){ S.obs.push(S.lastRemoved); S.lastRemoved=null; S.undo=false; } render(); }
  else if(a==="newShift"){
    if(!confirm("Start a new shift? This shift is saved to History; the new shift starts empty."))return;
    if(S.obs.length)S.history.unshift({obs:S.obs,division:S.division,locationName:S.locationName,dateMs:S.shiftDateMs});
    S.obs=[]; S.shiftDateMs=Date.now(); S.siteConfirmed=false; S.lastRemoved=null; S.undo=false;
    S.note=""; S.sheet=null; S.loggedId=null; render();
  }
  else if(a==="clearHistory"){ if(!S.history.length)return;
    if(!confirm(`Clear all ${S.history.length} retained day${S.history.length===1?"":"s"}? Export the spreadsheet first if you still need them.`))return;
    S.history=[]; render(); }
  else if(a==="deleteDay"){ const i=parseInt(b.dataset.i,10);
    if(i>=0&&i<S.history.length){ if(!confirm("Delete this day's observations? Export the spreadsheet first if you still need them."))return; S.history.splice(i,1); } render(); }
  else if(a==="exportXlsx"){ downloadXlsx(); }
  else if(a==="copy"){ const k=b.dataset.kind; const latest=S.obs.slice().sort((x,y)=>y.min-x.min)[0];
    copyText(k==="broadcast"?(latest?latest.broadcast:""):k==="spot"?spotText():notesText()); }
});
// parse "HH:MM" / "HHMM" / "H" -> minutes-of-day, or null while half-typed.
// A digitless string (a bare ":") must not parse: parseInt(""||"0") read it as
// midnight and silently re-timed the pending obs — same fix as the native app.
function parseHM(s){ const c=(s||"").replace(/[^0-9:]/g,""); if(!/[0-9]/.test(c))return null; let h,m;
  if(c.includes(":")){ const p=c.split(":"); h=parseInt(p[0]||"0",10); m=parseInt(p[1]||"0",10); }
  else { const d=c.replace(/[^0-9]/g,""); if(!d)return null; if(d.length<=2){h=parseInt(d,10);m=0;} else {h=parseInt(d.slice(0,-2),10);m=parseInt(d.slice(-2),10);} }
  if(isNaN(h)||isNaN(m)||h<0||h>23||m<0||m>59)return null; return h*60+m; }
// text inputs — update state without re-render (preserve caret/focus)
document.addEventListener("input",ev=>{
  const el=ev.target; const f=el.dataset&&el.dataset.field; if(!f)return;
  if(f==="obsTime"){ const p=parseHM(el.value); if(p!=null)S.pendingMin=p; return; }
  if(f==="editTime"){ if(S.edit){ const p=parseHM(el.value); if(p!=null)S.edit.min=p; } return; }
  if(f==="editNote"){ if(S.edit)S.edit.note=el.value; return; }
  // Strip digit grouping first: "4,150" parsed as 4 — and was then spoken over
  // the radio and exported as a 4-foot site elevation.
  if(f==="siteElevationFeet"){ const n=parseInt(el.value.replace(/[,\s]/g,""),10); S.siteElevationFeet=Number.isFinite(n)?n:null; return; }
  S[f]=el.value;
});
// commit the typed obs time (refresh the live PIG preview) on blur/enter
document.addEventListener("change",ev=>{ if(ev.target.dataset&&ev.target.dataset.field==="obsTime")render(); });
document.getElementById("clock").textContent=clockLabel(now.getHours()*60+now.getMinutes());
// Capture typed-but-not-yet-rendered edits when the app is backgrounded/closed —
// and snap month/band back to the wall clock when the app comes forward, the
// same moment the native app calls refreshClock() on scenePhase.
window.addEventListener("pagehide", saveState);
document.addEventListener("visibilitychange", function(){
  if(document.visibilityState==="hidden"){ saveState(); }
  else if(refreshClock()){ render(); }
});
// live clock + "next obs due" countdown. The status-bar clock always ticks;
// month/band re-derive unless overridden; re-renders skip while a form is open
// or the operator is typing — a rebuild mid-entry would pull the sheet out from
// under their hands (state still updates; the next quiet tick paints it).
setInterval(()=>{
  document.getElementById("clock").textContent=clockLabel(nowMin());
  const moved=refreshClock();
  const typing=document.activeElement&&["INPUT","TEXTAREA"].includes(document.activeElement.tagName);
  if((moved||S.tab==="watch") && !S.sheet && !typing) render();
},30000);
render();
